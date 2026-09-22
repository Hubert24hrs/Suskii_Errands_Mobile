#!/usr/bin/env python3
"""Check `docs/plan/rls-policy-matrix.md` against the schema it describes.

Three audit passes this week found the same failure mode, and a fourth would have found it again:

    U.1  the matrix defines `R:scope` on ~50 cells; one function read `country_scope`
    U.3  the matrix names `get_provider_card()`; it did not exist
    V.1  the matrix has a Participant column; two tables carried `R:part` and neither
         policy had a participant clause

Each was found by a person reading the matrix against the migrations, and none was found by the
test suite -- because **a deny test passes whether the denial is correct or the allow clause was
simply never written**. From inside the suite those two are indistinguishable.

This is the control that tells them apart. It does not try to prove a policy is *correct*; it
proves the matrix and the schema are talking about the same things:

  A. every function the matrix names exists
  B. every table the matrix gives a row to exists
  C. a cell that names specific columns has a column-restricted grant, not a whole-row one
  D. a table with an `R:scope` cell has a policy that actually reads the admin scope
  E. a table with an `R:part` cell has a policy that actually tests participation

C, D and E are heuristics over policy text, so they are wrong sometimes. That is what
`rls-matrix-waivers.json` is for: a divergence is either fixed or **written down with a reason**,
and "written down with a reason" is the half that was missing.

Run: python supabase/tools/check_rls_matrix.py [repo_root]
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "contracts" / "tools"))
import pgparse  # noqa: E402

MATRIX = Path("docs/plan/rls-policy-matrix.md")
WAIVERS = Path("supabase/tools/rls-matrix-waivers.json")

# A row whose first cell is a single backticked identifier is a table (or a function, when it has
# parentheses). Everything else in the file is prose or a legend.
ROW = re.compile(r"^\|\s*`([\w.]+)(\([^)]*\))?`[^|]*\|(.*)\|\s*$")
# `name(` anywhere in the document: the matrix names functions inline as well as in rows.
NAMED_FN = re.compile(r"`(\w+)\s*\(")
# A cell such as `U:own(`a`, `b`)` or `R:part (status, amount)`.
COLUMN_CELL = re.compile(r"\b([RIU]):(\w+)\s*\(([^)]*)\)")

# Words that look like a function call but are SQL syntax or prose.
NOT_FUNCTIONS = {"CHECK", "UNIQUE", "PRIMARY", "REFERENCES", "USING", "WITH"}

SCOPE_HELPERS = (
    "admin_scope_allows",
    "admin_may_read_country",
    "admin_may_read_request",
    "admin_may_read_user",
    "admin_may_read_countries",
    "admin_scope_allows_any",
    "support_ticket_scope",
    "dispute_scope",
    "fraud_subject_countries",
    "moderation_subject_countries",
)
PARTICIPANT_HELPERS = (
    "is_job_participant",
    "is_assigned_job_provider",
    "is_matched_provider",
    "provider_id",
    "worker_id",
    "participant",
)


def load_waivers(root: Path) -> dict:
    path = root / WAIVERS
    if not path.exists():
        return {}
    doc = json.loads(path.read_text(encoding="utf-8"))
    return {w["id"]: w for w in doc.get("waivers", [])}


# Sections that are not tables: the legend, the role list, and the surfaces that have their own
# checkers (storage policies are asserted structurally; realtime topics come from the generator).
NON_TABLE_SECTIONS = (
    "Legend",
    "Roles and how they are established",
    "Why this matrix",
    "Storage bucket policies",
    "Realtime channel authorisation",
    "pgTAP obligations",
)


def matrix_rows(text: str) -> list[tuple[str, str, bool]]:
    """(identifier, rest-of-row, is_function) for every table/function row in the matrix."""
    out = []
    section = ""
    for line in text.split("\n"):
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        if any(section.startswith(s) for s in NON_TABLE_SECTIONS):
            continue
        m = ROW.match(line)
        if not m:
            continue
        name = m.group(1)
        if name.lower() in {"cell", "table", "role", "bucket", "topic", "check", "object"}:
            continue
        if len(name) <= 2:  # legend rows: `R`, `F`
            continue
        out.append((name, m.group(3), m.group(2) is not None))
    return out


def policies_by_table(root: Path) -> dict[str, list[str]]:
    """table -> the text of every policy that survives the replay.

    A policy dropped and recreated later must not leave its old body behind; otherwise a policy
    that once had a scope clause looks like it still does.
    """
    live: dict[tuple[str, str], str] = {}
    # `split_statements` has already removed the trailing semicolon, so the body is simply the
    # rest of the statement. An earlier version of this anchored the body on a `;` that is never
    # there, matched nothing, and left rules D and E silently dead -- which is the same class of
    # bug this whole checker exists to catch, so it is worth the comment.
    create = re.compile(r"^\s*CREATE\s+POLICY\s+(\w+)\s+ON\s+([\w.]+)\b", re.IGNORECASE)
    drop = re.compile(r"^\s*DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?(\w+)\s+ON\s+([\w.]+)", re.IGNORECASE)
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = pgparse.strip_line_comments(path.read_text(encoding="utf-8"))
        for stmt in pgparse.split_statements(text):
            d = drop.match(stmt)
            if d:
                live.pop((_qualify(d.group(2)), d.group(1).lower()), None)
                continue
            c = create.match(stmt)
            if c:
                live[(_qualify(c.group(2)), c.group(1).lower())] = stmt[c.end() :]
    by_table: dict[str, list[str]] = {}
    for (table, _policy), body in live.items():
        # Only `public` tables are in the matrix's table sections; a policy on `storage.objects`
        # or `realtime.messages` belongs to a different section with its own rules, and letting
        # one of those land under a same-named public table is how a false positive is born.
        if not table.startswith("public."):
            continue
        by_table.setdefault(table.split(".")[-1], []).append(body)
    return by_table


def _qualify(name: str) -> str:
    n = name.strip().strip('"').lower()
    return n if "." in n else f"public.{n}"


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    text = (root / MATRIX).read_text(encoding="utf-8")
    waivers = load_waivers(root)
    functions = pgparse.load(root / "supabase" / "migrations")
    tables = pgparse.load_tables(root / "supabase" / "migrations")
    policies = policies_by_table(root)

    have_fn = {f.name for f in functions.values()}
    have_tbl = {t.name for t in tables.values()}
    findings: list[tuple[str, str]] = []
    suppressed: set[str] = set()

    def report(fid: str, message: str) -> None:
        if fid in waivers:
            suppressed.add(fid)
            return
        findings.append((fid, message))

    # A. Functions the matrix names.
    for name in sorted({n for n in NAMED_FN.findall(text) if n not in NOT_FUNCTIONS}):
        if name not in have_fn:
            report(
                f"fn:{name}",
                f"the matrix names `{name}()` and no migration creates it "
                "(build it, rename the matrix, or waive it with a reason)",
            )

    # B. Tables the matrix gives a row to.
    rows = matrix_rows(text)
    for name, _rest, is_function in rows:
        # A row whose label carries parentheses is a function; rule A already covered it.
        if is_function or "." in name or name in have_fn:
            continue
        if name not in have_tbl:
            report(
                f"table:{name}",
                f"the matrix has a row for table `{name}` and no migration creates it",
            )

    # C. Cells that name specific columns must have a column-restricted grant.
    for name, rest, _is_fn in rows:
        table = tables.get(f"public.{name}")
        if table is None:
            continue
        for verb, _scope, cols in COLUMN_CELL.findall(rest):
            listed = {c.strip().strip("`") for c in cols.split(",") if c.strip()}
            # Only act on cells that actually list column names.
            if not listed or not all(re.fullmatch(r"\w+", c) for c in listed):
                continue
            if not listed & {c.name for c in table.columns}:
                continue  # a parenthetical that is prose, not a column list
            privilege = {"R": "SELECT", "I": "INSERT", "U": "UPDATE"}[verb]
            granted = table.privileges.get(privilege, {}).get("authenticated")
            if granted is None:
                continue
            if "*" in granted:
                report(
                    f"cols:{name}:{privilege}",
                    f"the matrix restricts {privilege} on `{name}` to ({', '.join(sorted(listed))}) "
                    f"but the grant covers every column",
                )
            elif not listed <= granted:
                report(
                    f"cols:{name}:{privilege}",
                    f"the matrix lists ({', '.join(sorted(listed))}) for {privilege} on `{name}`; "
                    f"the grant is ({', '.join(sorted(granted))})",
                )

    # D and E. A scope or participation cell needs a policy that says so.
    for name, rest, _is_fn in rows:
        if f"public.{name}" not in tables:
            continue
        bodies = " ".join(policies.get(name, []))
        if not bodies:
            continue
        if "R:scope" in rest and not any(h in bodies for h in SCOPE_HELPERS):
            report(
                f"scope:{name}",
                f"the matrix gives `{name}` an R:scope cell but no policy on it reads an admin "
                "scope helper -- this is the U.1 shape",
            )
        if "R:part" in rest and not any(h in bodies for h in PARTICIPANT_HELPERS):
            report(
                f"part:{name}",
                f"the matrix gives `{name}` an R:part cell but no policy on it tests participation "
                "-- this is the V.1 shape",
            )

    for fid, message in findings:
        print(f"::error file={MATRIX.as_posix()}::[{fid}] {message}")

    # A waiver is stale only when the thing it excuses has stopped diverging -- which
    # means it neither fired nor was suppressed this run.
    stale = sorted(set(waivers) - suppressed - {f for f, _ in findings})
    for fid in stale:
        # A waiver for something that no longer diverges is itself a small lie.
        print(f"::warning file={WAIVERS.as_posix()}::waiver [{fid}] no longer matches anything; remove it")

    print(
        f"check_rls_matrix: {len(rows)} matrix rows, {len(waivers)} waiver(s), "
        f"{len(findings)} finding(s), {len(stale)} stale waiver(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
