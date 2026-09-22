#!/usr/bin/env python3
"""Generate contracts v1 from the backend, so it cannot describe a database nobody is running.

`contracts/README.md` rule 3 is that CI fails on contract drift. The only way a catalogue of 121
functions stays true is if nobody ever writes it by hand: this reads `supabase/migrations`,
replays it (see `pgparse.py`), and emits the parts of contracts v1 that are facts about the
schema rather than decisions about the product.

Generated here:
  rpc-catalog/index.json    every function a client may call: arguments, return, errors, the
                            roles that may execute it, whether it needs an idempotency key, and
                            what it requires of the caller
  rpc-catalog/private.json  the `private.*` helpers granted to `authenticated`. PostgREST cannot
                            reach `private`, so these are NOT callable -- they are listed because
                            an RLS policy calls them as the invoking role, and a reader who finds
                            the grant deserves to know why it is there
  enums.json                every Postgres enum and its wire values, in order
  storage/buckets.json      buckets, their path conventions and who may read or write
  realtime-events/channels.json  channel names, authorisation and payload shape

Hand-authored, because they are decisions and not facts: error-codes/, state-machines/,
fixtures/, edge-functions.openapi.yaml.

Usage:
  python contracts/tools/generate_v1.py [repo_root]           check for drift (exit 1 if any)
  python contracts/tools/generate_v1.py [repo_root] --write   regenerate
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pgparse  # noqa: E402

ENUM = re.compile(r"CREATE\s+TYPE\s+public\.(\w+)\s+AS\s+ENUM\s*\((.*?)\)\s*;", re.IGNORECASE | re.DOTALL)
ERR = re.compile(r"\bERR_[A-Z0-9_]*[A-Z0-9]\b")
ADMIN_ROLES = re.compile(r"has_admin_role\s*\(\s*ARRAY\[([^\]]*)\]", re.IGNORECASE)

# SQL type -> how it appears on the wire through PostgREST's JSON.
SCALARS: dict[str, dict] = {
    "uuid": {"type": "string", "format": "uuid"},
    "text": {"type": "string"},
    "character": {"type": "string"},
    "character varying": {"type": "string"},
    "boolean": {"type": "boolean"},
    "smallint": {"type": "integer"},
    "integer": {"type": "integer"},
    "bigint": {"type": "integer"},
    "numeric": {"type": "string", "note": "numeric arrives as a string; parse as decimal, never as a float"},
    "double precision": {"type": "number"},
    "real": {"type": "number"},
    "timestamp with time zone": {"type": "string", "format": "date-time"},
    "timestamp without time zone": {"type": "string", "format": "date-time"},
    "date": {"type": "string", "format": "date"},
    "interval": {"type": "string"},
    "jsonb": {"type": "object"},
    "json": {"type": "object"},
    "bytea": {"type": "string", "format": "byte"},
    "void": {"type": "null"},
    "record": {"type": "object"},
    "trigger": {"type": "null"},
}


def wire_type(sql_type: str, enums: dict[str, list[str]]) -> dict:
    t = pgparse.normalise_type(sql_type)
    array = False
    while t.endswith("[]"):
        array = True
        t = t[:-2]
    bare = t.split(".")[-1]
    if bare in enums:
        node: dict = {"type": "string", "enum": enums[bare], "enum_name": bare}
    elif t in SCALARS:
        node = dict(SCALARS[t])
    elif bare in SCALARS:
        node = dict(SCALARS[bare])
    elif t.startswith("setof "):
        return wire_type(t[6:], enums)
    else:
        node = {"type": "object", "sql_type": t}
    if array:
        node = {"type": "array", "items": node}
    return node


def returns_shape(fn: pgparse.Function, enums: dict[str, list[str]]) -> dict:
    """`RETURNS TABLE (...)` is a row set; `SETOF x` is a row set of x; anything else is scalar."""
    raw = fn.returns.strip()
    low = raw.lower()
    m = re.match(r"table\s*\((.*)\)\s*$", low, re.DOTALL)
    if m:
        # Re-slice from the original to keep the declared casing of type names.
        inner = raw[raw.index("(") + 1 : raw.rindex(")")]
        columns = []
        for piece in pgparse.split_top_level(inner):
            tokens = piece.split()
            if len(tokens) < 2:
                continue
            columns.append({"name": tokens[0], "type": wire_type(" ".join(tokens[1:]), enums)})
        return {"kind": "rows", "columns": columns}
    if low.startswith("setof "):
        rest = raw[6:].strip()
        if rest.lower().endswith("%rowtype") or "." in rest:
            return {"kind": "rows", "of": rest}
        return {"kind": "rows", "items": wire_type(rest, enums)}
    if low == "void":
        return {"kind": "none"}
    return {"kind": "scalar", "schema": wire_type(raw, enums)}


CALLER_BINDING = re.compile(
    r"\b(\w+)\s+uuid\s*:=\s*(?:private\.require_user\(\)|auth\.uid\(\))", re.IGNORECASE
)


def caller_variables(body: str) -> set[str]:
    """The local variables that hold the caller's own id.

    Needed because a guard applied to somebody else is not a requirement on the caller.
    `accept_offer` is a customer action whose body contains
    `require_active_provider(v_thread.provider_id)` -- a check that the *provider being accepted*
    is still active. Reading that as "the caller must be an active provider" would have the
    customer's accept button greyed out for every customer on the platform.
    """
    names = {m.group(1).lower() for m in CALLER_BINDING.finditer(body)}
    names.update({"auth.uid()", "private.require_user()"})
    return names


def _guards_the_caller(body: str, helper: str, callers: set[str]) -> bool:
    for m in re.finditer(helper + r"\s*\(\s*([^)]*?)\s*\)", body, re.IGNORECASE):
        if m.group(1).strip().lower() in callers:
            return True
    return False


def requirements(fn: pgparse.Function) -> dict:
    body = fn.body
    callers = caller_variables(body)
    req: dict = {}
    req["authenticated"] = "private.require_user" in body or "auth.uid()" in body
    roles: list[str] = []
    for group in ADMIN_ROLES.findall(body):
        roles += re.findall(r"'(\w+)'", group)
    if roles:
        req["admin_roles"] = sorted(set(roles))
        # `private.has_admin_role` reads `auth.uid()` itself and returns false below aal2, so it
        # always tests the caller and always implies MFA.
        req["mfa"] = "aal2"
    if _guards_the_caller(body, r"private\.(?:require|is)_active_provider", callers):
        req["active_provider"] = True
    if _guards_the_caller(body, r"private\.require_dispatchable_worker", callers):
        req["dispatchable_worker"] = True
    return req


def describe(fn: pgparse.Function, enums: dict[str, list[str]]) -> dict:
    args = []
    for a in fn.args:
        node = {
            "name": a.name,
            "sql_type": pgparse.normalise_type(a.sql_type),
            "schema": wire_type(a.sql_type, enums),
            "optional": a.optional,
        }
        if a.default is not None:
            node["default"] = a.default
        args.append(node)
    errors = sorted(set(ERR.findall(fn.body)))
    idem = next((a.name for a in fn.args if a.name and "idempotency" in a.name), None)
    return {
        "name": fn.name,
        "schema": fn.schema,
        "signature": fn.signature,
        "arguments": args,
        "returns": returns_shape(fn, enums),
        "errors": errors,
        "idempotency_key": idem,
        "security_definer": fn.security_definer,
        "executable_by": sorted(fn.grants),
        "requires": requirements(fn),
        "defined_in": fn.source,
    }


def declared_enums(root: Path) -> dict[str, list[str]]:
    enums: dict[str, list[str]] = {}
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = pgparse.strip_line_comments(path.read_text(encoding="utf-8"))
        for name, body in ENUM.findall(text):
            enums[name] = re.findall(r"'([^']*)'", body)
    return dict(sorted(enums.items()))


BUCKET_INSERT = re.compile(
    r"INSERT\s+INTO\s+storage\.buckets\s*\([^)]*\)\s*VALUES\s*(.*?)(?:ON\s+CONFLICT|;)",
    re.IGNORECASE | re.DOTALL,
)
BUCKET_SIZE = re.compile(
    r"UPDATE\s+storage\.buckets\s+SET\s+file_size_limit\s*=\s*([^;]*?)\s+WHERE\s+id\s*=\s*'([^']+)'",
    re.IGNORECASE | re.DOTALL,
)
BUCKET_MIME = re.compile(
    r"UPDATE\s+storage\.buckets\s+SET\s+allowed_mime_types\s*=\s*ARRAY\[([^\]]*)\]\s*WHERE\s+id\s*=\s*'([^']+)'",
    re.IGNORECASE | re.DOTALL,
)
OBJECT_POLICY = re.compile(
    r"CREATE\s+POLICY\s+(\w+)\s+ON\s+storage\.objects\s+FOR\s+(\w+)\s+TO\s+([^\s]+)\s+"
    r"(USING|WITH\s+CHECK)\s*\((.*?)\)\s*;",
    re.IGNORECASE | re.DOTALL,
)


def storage_buckets(root: Path) -> dict:
    """Buckets, their limits and the policies on them. Every bucket is private: a public one
    would put a KYC document or a proof photo on a guessable URL."""
    buckets: dict[str, dict] = {}
    policies: dict[str, list[dict]] = {}
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = pgparse.strip_line_comments(path.read_text(encoding="utf-8"))
        for values in BUCKET_INSERT.findall(text):
            for tup in re.findall(r"\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)", values, re.IGNORECASE):
                buckets.setdefault(
                    tup[0],
                    {"id": tup[0], "public": tup[2].lower() == "true", "defined_in": path.name},
                )
        for expr, bucket in BUCKET_SIZE.findall(text):
            if bucket in buckets:
                try:
                    buckets[bucket]["max_bytes"] = int(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307
                except Exception:
                    buckets[bucket]["max_bytes_expression"] = " ".join(expr.split())
        for mimes, bucket in BUCKET_MIME.findall(text):
            if bucket in buckets:
                buckets[bucket]["allowed_mime_types"] = re.findall(r"'([^']+)'", mimes)
        # A DROP POLICY later in the run replaces an earlier one of the same name.
        for name in re.findall(r"DROP\s+POLICY\s+(\w+)\s+ON\s+storage\.objects", text, re.IGNORECASE):
            for rows in policies.values():
                rows[:] = [p for p in rows if p["policy"] != name]
        for name, action, role, clause, expr in OBJECT_POLICY.findall(text):
            m = re.search(r"bucket_id\s*=\s*'([^']+)'", expr)
            if not m:
                continue
            policies.setdefault(m.group(1), []).append(
                {
                    "policy": name,
                    "action": action.upper(),
                    "role": role.strip().rstrip(","),
                    "clause": clause.upper().replace("  ", " "),
                }
            )
    for bucket, rows in policies.items():
        if bucket in buckets:
            buckets[bucket]["policies"] = sorted(rows, key=lambda p: (p["action"], p["policy"]))
    return dict(sorted(buckets.items()))


BROADCAST_CALL = re.compile(
    r"private\.broadcast\(\s*(.*?)\s*,\s*('(?:[^']*)'|\w+)\s*,", re.DOTALL
)


EVENT_ASSIGNMENT = re.compile(r"\bv_event\s*:=\s*(.*?);", re.DOTALL)


def realtime_topics(root: Path) -> dict:
    """Topic patterns and the events sent to them, read out of the broadcast calls themselves.

    Two wrinkles. The declaration of `private.broadcast` itself looks like a call, so it is
    skipped by requiring a literal in the topic. And one caller passes the event in a variable,
    so the literals assigned to that variable in the same file are collected instead -- a topic
    documented as "(varies)" tells a client nothing it can subscribe to.
    """
    found: dict[str, set[str]] = {}
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = pgparse.strip_line_comments(path.read_text(encoding="utf-8"))
        variable_events: set[str] = set()
        for expr in EVENT_ASSIGNMENT.findall(text):
            # `'offer.' || NEW.status::text` is a family of events, not an event; record it as a
            # pattern so a client knows to match on the prefix.
            for prefix in re.findall(r"'([a-z_]+\.)'\s*\|\|", expr):
                variable_events.add(prefix + "{status}")
            for lit in re.findall(r"'([a-z_]+\.[a-z_]+)'", expr):
                variable_events.add(lit)
        for topic_expr, event in BROADCAST_CALL.findall(text):
            # A call always names its topic with a literal first segment. The declaration of
            # `broadcast` itself begins with the parameter, and its body contains quotes, so a
            # "does it contain a quote" test lets the declaration through.
            if not topic_expr.lstrip().startswith("'"):
                continue
            parts = [p.strip() for p in topic_expr.split("||")]
            rendered = ""
            for p in parts:
                lit = re.fullmatch(r"'([^']*)'", p)
                rendered += lit.group(1) if lit else "{id}"
            if event.startswith("'"):
                found.setdefault(rendered, set()).add(event.strip("'"))
            else:
                found.setdefault(rendered, set()).update(variable_events or {f"({event})"})
    return {topic: sorted(events) for topic, events in sorted(found.items())}


PREAMBLE_RPC = (
    "Generated by contracts/tools/generate_v1.py from supabase/migrations. Do not edit by hand. "
    "Every function here is reachable through PostgREST as supabase.rpc(name, args); arguments "
    "are passed by name, so an optional one may simply be omitted."
)
PREAMBLE_PRIVATE = (
    "Generated. These are NOT callable by a client: PostgREST exposes only the public schema. "
    "They are granted to authenticated because an RLS policy calls them as the invoking role, "
    "and a grant with no explanation reads like a mistake. Listed so it does not."
)


def build(root: Path) -> dict[str, object]:
    live = pgparse.load(root / "supabase" / "migrations")
    tables = pgparse.load_tables(root / "supabase" / "migrations")
    enums = declared_enums(root)

    public_fns = sorted(
        (f for f in live.values() if f.schema == "public" and (f.grants & {"authenticated", "anon"})),
        key=lambda f: f.name,
    )
    private_fns = sorted(
        (f for f in live.values() if f.schema == "private" and ("authenticated" in f.grants)),
        key=lambda f: f.name,
    )

    index = {
        "$comment": PREAMBLE_RPC,
        "generated_from": "supabase/migrations",
        "count": len(public_fns),
        "anonymous": sorted(f.name for f in public_fns if "anon" in f.grants),
        "functions": [describe(f, enums) for f in public_fns],
    }
    private_index = {
        "$comment": PREAMBLE_PRIVATE,
        "count": len(private_fns),
        "functions": [
            {
                "name": f.name,
                "signature": f.signature,
                "executable_by": sorted(f.grants),
                "defined_in": f.source,
            }
            for f in private_fns
        ],
    }
    # A `SETOF public.x` return is the shape of that table; a client reading the catalogue should
    # not have to go and look it up.
    for entry, fn in zip(index["functions"], public_fns):
        of = entry["returns"].get("of")
        if not of:
            continue
        t = tables.get(pgparse.normalise_type(of).replace("%rowtype", ""))
        if t is not None:
            entry["returns"]["columns"] = [
                {"name": c.name, "type": wire_type(c.sql_type, enums), "nullable": not c.not_null}
                for c in t.columns
            ]

    client_tables = {
        q: t
        for q, t in sorted(tables.items())
        if {"authenticated", "anon"} & set(t.privileges.get("SELECT", {}))
    }
    tables_doc = {
        "$comment": (
            "Generated. Tables a client may read directly through PostgREST, with the column and "
            "column-level privileges they hold. RLS decides WHICH ROWS -- see "
            "docs/plan/rls-policy-matrix.md; these grants decide WHICH COLUMNS. A column absent "
            "from an UPDATE grant is server-owned and cannot be written from a client at all."
        ),
        "count": len(client_tables),
        "tables": [
            {
                "name": t.qualified,
                "columns": [
                    {
                        "name": c.name,
                        "type": wire_type(c.sql_type, enums),
                        "nullable": not c.not_null,
                        "server_default": c.has_default,
                    }
                    for c in t.columns
                ],
                "privileges": {
                    privilege: {
                        role: sorted(cols)
                        for role, cols in sorted(by_role.items())
                        if role in {"authenticated", "anon"}
                    }
                    for privilege, by_role in sorted(t.privileges.items())
                    if {"authenticated", "anon"} & set(by_role)
                },
                "defined_in": t.source,
            }
            for t in client_tables.values()
        ],
    }

    return {
        "rpc-catalog/index.json": index,
        "rpc-catalog/private.json": private_index,
        "db-types/tables.json": tables_doc,
        "enums.json": {
            "$comment": "Generated from supabase/migrations. Wire values are snake_case, in declaration order.",
            "enums": enums,
        },
        "storage/buckets.json": {
            "$comment": (
                "Generated. Every bucket is private; uploads and reads go through a signed URL. "
                "The path convention is enforced by the policies listed, not by convention."
            ),
            "buckets": storage_buckets(root),
        },
        "realtime-events/channels.json": {
            "$comment": (
                "Generated from the private.broadcast() calls in the migrations. Topics are "
                "private: private.may_join_topic authorises every join, and a broadcast is a "
                "courtesy rather than a guarantee -- the tables are the truth and a client "
                "refetches on reconnect (ADR-0009)."
            ),
            "topics": realtime_topics(root),
        },
    }


JOB_TRANSITION = re.compile(
    r"job_transition\s*\(\s*[^,]+,\s*'(\w+)'\s*,\s*'(\w+)'", re.IGNORECASE
)


def check_state_machine(root: Path) -> list[str]:
    """The half of the state machine that can be mechanical.

    `state-machines/job.json` is authored, because many transitions are written with a variable
    source state and a generator could only produce a partial table. But the reverse direction
    works: every from/to pair written as two literals in the migrations must appear in the
    contract. That catches the failure that matters -- somebody adds a transition in SQL and the
    contract still describes the machine as it used to be.
    """
    path = root / "contracts" / "v1" / "state-machines" / "job.json"
    if not path.exists():
        return ["contracts/v1/state-machines/job.json is missing"]
    machine = json.loads(path.read_text(encoding="utf-8"))
    declared = {
        (src, t["to"])
        for t in machine["transitions"]
        for src in (t["from"] or [])
    }
    states = {s["name"] for s in machine["states"]}
    findings: list[str] = []
    seen: set[tuple[str, str]] = set()
    for p in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = pgparse.strip_line_comments(p.read_text(encoding="utf-8"))
        for frm, to in JOB_TRANSITION.findall(text):
            if frm not in states or to not in states:
                continue  # not a job_status pair (other machines use the same helper shape)
            seen.add((frm, to))
    for frm, to in sorted(seen - declared):
        findings.append(
            f"supabase/migrations performs the job transition {frm} -> {to}, which "
            "contracts/v1/state-machines/job.json does not list"
        )
    return findings


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 and not argv[1].startswith("-") else ".").resolve()
    write = "--write" in argv
    out_root = root / "contracts" / "v1"
    artefacts = build(root)

    drift: list[str] = []
    for rel, payload in artefacts.items():
        path = out_root / rel
        rendered = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
        if write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rendered, encoding="utf-8", newline="\n")
        else:
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current != rendered:
                drift.append(rel)

    # The authored artefacts are never rewritten, only checked against the code.
    machine_findings = check_state_machine(root)

    if write:
        print(f"generate_v1: wrote {len(artefacts)} artefact(s) under contracts/v1")
        for f in machine_findings:
            print(f"::error file=contracts/v1/state-machines/job.json::{f}")
        return 1 if machine_findings else 0

    for rel in drift:
        print(
            f"::error file=contracts/v1/{rel}::{rel} is out of date with supabase/migrations. "
            "Run: python contracts/tools/generate_v1.py . --write"
        )
    for f in machine_findings:
        print(f"::error file=contracts/v1/state-machines/job.json::{f}")
    print(
        f"generate_v1: {len(artefacts)} artefact(s) checked, {len(drift)} out of date; "
        f"state machine: {len(machine_findings)} finding(s)"
    )
    return 1 if (drift or machine_findings) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
