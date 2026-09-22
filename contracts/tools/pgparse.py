#!/usr/bin/env python3
"""Read `supabase/migrations` the way Postgres does: in order, replaying every statement.

A migration set is not a description of a schema, it is a recording of how one was built. A
function created in one file and dropped and recreated with a different signature in another has
*two* definitions on disk and one in the database, and a contract generated from the first
reading is a contract for a database nobody is running. So this replays: CREATE adds, DROP
removes, GRANT and REVOKE accumulate, and what is left at the end is what exists.

Used by `generate_v1.py`. Kept separate because the parsing is the part worth testing on its own
(`test_pgparse.py`), and because the same replay answers questions the allowlist checker and the
error-code checker ask in their own ways today.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# A dollar-quoted body: $$ ... $$ or $tag$ ... $tag$. Bodies nest ($q$ inside $$), so the tag has
# to match rather than "run to the next dollar sign".
DOLLAR_OPEN = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


def strip_line_comments(sql: str) -> str:
    """Remove `--` comments that are not inside a string or a dollar-quoted body."""
    out: list[str] = []
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            out.append(sql[i : j + 1])
            i = j + 1
        elif ch == "$":
            m = DOLLAR_OPEN.match(sql, i)
            if m:
                close = m.group(0)
                end = sql.find(close, m.end())
                end = n if end == -1 else end + len(close)
                out.append(sql[i:end])
                i = end
            else:
                out.append(ch)
                i += 1
        elif ch == "-" and i + 1 < n and sql[i + 1] == "-":
            j = sql.find("\n", i)
            i = n if j == -1 else j
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def split_statements(sql: str) -> list[str]:
    """Split on semicolons that are not inside a string or a dollar-quoted body."""
    statements: list[str] = []
    buf: list[str] = []
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(sql[i : j + 1])
            i = j + 1
        elif ch == "$":
            m = DOLLAR_OPEN.match(sql, i)
            if m:
                close = m.group(0)
                end = sql.find(close, m.end())
                end = n if end == -1 else end + len(close)
                buf.append(sql[i:end])
                i = end
            else:
                buf.append(ch)
                i += 1
        elif ch == ";":
            statements.append("".join(buf).strip())
            buf = []
            i += 1
        else:
            buf.append(ch)
            i += 1
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return [s for s in statements if s]


def split_top_level(text: str, sep: str = ",") -> list[str]:
    """Split on `sep` at bracket depth zero, respecting quotes. Argument lists contain types
    like `numeric(10, 2)` and `char(2)[]`, so a naive split loses them."""
    parts: list[str] = []
    depth = 0
    buf: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n and text[j] != "'":
                j += 1
            buf.append(text[i : j + 1])
            i = j + 1
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    last = "".join(buf).strip()
    if last:
        parts.append(last)
    return parts


ARG_MODES = {"in", "out", "inout", "variadic"}


@dataclass
class Argument:
    name: str | None
    sql_type: str
    has_default: bool
    default: str | None = None

    @property
    def optional(self) -> bool:
        return self.has_default


@dataclass
class Function:
    schema: str
    name: str
    args: list[Argument]
    returns: str
    language: str
    security_definer: bool
    body: str
    source: str  # migration file that last defined it
    grants: set[str] = field(default_factory=set)

    @property
    def qualified(self) -> str:
        return f"{self.schema}.{self.name}"

    @property
    def arg_types(self) -> list[str]:
        return [normalise_type(a.sql_type) for a in self.args]

    @property
    def signature(self) -> str:
        """The identity Postgres uses: name plus input argument types."""
        return f"{self.qualified}({', '.join(self.arg_types)})"


ALIASES = {
    "int": "integer",
    "int2": "smallint",
    "int4": "integer",
    "int8": "bigint",
    "bool": "boolean",
    "float8": "double precision",
    "float4": "real",
    "timestamptz": "timestamp with time zone",
    "timestamp": "timestamp without time zone",
    "varchar": "character varying",
    "character": "char",
}


def normalise_type(raw: str) -> str:
    """Compare types the way Postgres would, so a GRANT's `timestamptz` finds a CREATE's
    `timestamp with time zone`."""
    t = " ".join(raw.strip().lower().split())
    array = ""
    while t.endswith("[]"):
        array += "[]"
        t = t[:-2].strip()
    # `char(2)` and `char` are the same type for signature purposes; length is not part of it.
    base = re.sub(r"\s*\([^)]*\)\s*$", "", t).strip()
    base = ALIASES.get(base, base)
    if base == "char":
        base = "character"
    return base + array


CREATE_FN = re.compile(
    r"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:(\w+)\.)?(\w+)\s*\(",
    re.IGNORECASE,
)
DROP_FN = re.compile(
    r"^\s*DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?(?:(\w+)\.)?(\w+)\s*\(([^)]*)\)",
    re.IGNORECASE,
)
RETURNS_RE = re.compile(r"\)\s*RETURNS\s+(.+?)\s+(?:LANGUAGE|AS|STABLE|IMMUTABLE|VOLATILE|SECURITY|SET|STRICT|PARALLEL|COST|WINDOW)\b", re.IGNORECASE | re.DOTALL)
LANGUAGE_RE = re.compile(r"\bLANGUAGE\s+(\w+)", re.IGNORECASE)
GRANT_RE = re.compile(
    r"^\s*GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+(.*?)\s+TO\s+([^;]+)$",
    re.IGNORECASE | re.DOTALL,
)
REVOKE_RE = re.compile(
    r"^\s*REVOKE\s+(?:ALL|EXECUTE)(?:\s+PRIVILEGES)?\s+ON\s+FUNCTION\s+(.*?)\s+FROM\s+([^;]+)$",
    re.IGNORECASE | re.DOTALL,
)


def _match_paren(text: str, open_idx: int) -> int:
    """Index just past the `)` matching the `(` at open_idx."""
    depth = 0
    i, n = open_idx, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced parentheses in function signature")


def parse_arguments(raw: str) -> list[Argument]:
    args: list[Argument] = []
    for piece in split_top_level(raw):
        if not piece:
            continue
        text = piece.strip()
        default = None
        has_default = False
        m = re.search(r"\s+DEFAULT\s+(.+)$", text, re.IGNORECASE | re.DOTALL)
        if m:
            has_default = True
            default = m.group(1).strip()
            text = text[: m.start()].strip()
        elif "=" in text and not re.search(r"\w\s*\(\s*[^)]*=", text):
            head, _, tail = text.partition("=")
            has_default, default, text = True, tail.strip(), head.strip()
        tokens = text.split()
        if not tokens:
            continue
        mode_skipped = False
        if tokens[0].lower() in ARG_MODES:
            if tokens[0].lower() in {"out", "inout"}:
                # OUT arguments are part of the result, not the signature. Nothing here uses
                # them, but silently mis-reading one would corrupt a signature.
                raise ValueError(f"OUT argument not supported: {piece!r}")
            tokens = tokens[1:]
            mode_skipped = True
        # `p_name text` vs a bare `text`: a leading identifier that is not itself a type name.
        name = None
        if len(tokens) >= 2:
            name = tokens[0]
            sql_type = " ".join(tokens[1:])
        else:
            sql_type = " ".join(tokens)
        del mode_skipped
        args.append(Argument(name=name, sql_type=sql_type, has_default=has_default, default=default))
    return args


def _parse_signature_list(raw: str) -> list[tuple[str, str, list[str]]]:
    """A GRANT/REVOKE names functions as `schema.name(type, type)`, comma separated."""
    out: list[tuple[str, str, list[str]]] = []
    for piece in split_top_level(raw):
        m = re.match(r"(?:(\w+)\.)?(\w+)\s*\((.*)\)\s*$", piece.strip(), re.DOTALL)
        if not m:
            continue
        schema = (m.group(1) or "public").lower()
        name = m.group(2).lower()
        types = [normalise_type(t) for t in split_top_level(m.group(3)) if t.strip()]
        out.append((schema, name, types))
    return out


CREATE_TABLE = re.compile(
    r"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(\w+)\.)?(\w+)\s*\(",
    re.IGNORECASE,
)
ALTER_TABLE = re.compile(r"^\s*ALTER\s+TABLE\s+(?:ONLY\s+)?(?:(\w+)\.)?(\w+)\s+(.*)$", re.IGNORECASE | re.DOTALL)
# One ALTER may carry several actions: `ADD COLUMN a text, ADD COLUMN b integer`. Matching the
# whole tail as one column swallows the rest and invents a column called "ADD".
ADD_COLUMN_CLAUSE = re.compile(
    r"\bADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+(.*?)(?=,\s*(?:ADD|DROP|ALTER|RENAME|SET|VALIDATE)\b|$)",
    re.IGNORECASE | re.DOTALL,
)
ALTER_DROP_COLUMN = re.compile(
    r"^\s*ALTER\s+TABLE\s+(?:(\w+)\.)?(\w+)\s+DROP\s+COLUMN\s+(?:IF\s+EXISTS\s+)?(\w+)",
    re.IGNORECASE,
)
# Things that appear in a CREATE TABLE body but are not columns.
TABLE_CONSTRAINT = re.compile(
    r"^\s*(CONSTRAINT|PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|EXCLUDE|LIKE)\b", re.IGNORECASE
)


@dataclass
class Column:
    name: str
    sql_type: str
    not_null: bool
    has_default: bool


@dataclass
class Table:
    schema: str
    name: str
    columns: list[Column]
    source: str
    # privilege -> role -> columns ("*" means the whole row). Column-level grants are the
    # difference between "a customer may edit their draft" and "a customer may edit anything",
    # so they belong in a contract rather than in somebody's memory.
    privileges: dict[str, dict[str, set[str]]] = field(default_factory=dict)

    @property
    def qualified(self) -> str:
        return f"{self.schema}.{self.name}"

    def grant(self, privilege: str, role: str, columns: set[str]) -> None:
        held = self.privileges.setdefault(privilege, {}).setdefault(role, set())
        if "*" in columns or "*" in held:
            self.privileges[privilege][role] = {"*"}
        else:
            held |= columns

    def revoke(self, privileges: set[str], role: str) -> None:
        for p in list(self.privileges):
            if p in privileges or "ALL" in privileges:
                self.privileges[p].pop(role, None)
                if not self.privileges[p]:
                    del self.privileges[p]


TABLE_GRANT = re.compile(
    r"^\s*GRANT\s+(.*?)\s+ON\s+(?:TABLE\s+)?(.*?)\s+TO\s+([^;]+)$", re.IGNORECASE | re.DOTALL
)
TABLE_REVOKE = re.compile(
    r"^\s*REVOKE\s+(.*?)\s+ON\s+(?:TABLE\s+)?(.*?)\s+FROM\s+([^;]+)$", re.IGNORECASE | re.DOTALL
)
PRIVILEGE = re.compile(
    r"\b(ALL(?:\s+PRIVILEGES)?|SELECT|INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER)\b"
    r"(?:\s*\(([^)]*)\))?",
    re.IGNORECASE,
)


def parse_privilege_list(raw: str) -> list[tuple[str, set[str]]]:
    """`SELECT, UPDATE (a, b)` -> [("SELECT", {"*"}), ("UPDATE", {"a","b"})]."""
    out: list[tuple[str, set[str]]] = []
    for m in PRIVILEGE.finditer(raw):
        name = " ".join(m.group(1).upper().split())
        if name.startswith("ALL"):
            name = "ALL"
        cols = {c.strip().lower() for c in split_top_level(m.group(2))} if m.group(2) else {"*"}
        out.append((name, cols))
    return out


def parse_columns(raw: str) -> list[Column]:
    columns: list[Column] = []
    for piece in split_top_level(raw):
        text = piece.strip()
        if not text or TABLE_CONSTRAINT.match(text):
            continue
        tokens = text.split()
        if len(tokens) < 2:
            continue
        name = tokens[0].strip('"')
        # The type runs until the first column constraint keyword.
        rest = " ".join(tokens[1:])
        m = re.search(
            r"\s+(NOT\s+NULL|NULL|DEFAULT|PRIMARY\s+KEY|UNIQUE|CHECK|REFERENCES|GENERATED|COLLATE)\b",
            rest,
            re.IGNORECASE,
        )
        sql_type = (rest[: m.start()] if m else rest).strip()
        columns.append(
            Column(
                name=name,
                sql_type=sql_type,
                not_null=bool(re.search(r"\bNOT\s+NULL\b", rest, re.IGNORECASE))
                or bool(re.search(r"\bPRIMARY\s+KEY\b", rest, re.IGNORECASE)),
                has_default=bool(re.search(r"\bDEFAULT\b", rest, re.IGNORECASE)),
            )
        )
    return columns


def load_tables(migrations_dir: Path) -> dict[str, Table]:
    """Replay CREATE TABLE and ALTER TABLE ADD/DROP COLUMN. Partitions of a partitioned table
    are skipped: they carry the parent's shape and would drown the catalogue."""
    tables: dict[str, Table] = {}
    for path in sorted(migrations_dir.glob("*.sql")):
        text = strip_line_comments(path.read_text(encoding="utf-8"))
        for stmt in split_statements(text):
            head = stmt.lstrip()[:120].upper()
            if head.startswith("CREATE TABLE"):
                m = CREATE_TABLE.match(stmt)
                if not m:
                    continue
                if re.search(r"\bPARTITION\s+OF\b", stmt, re.IGNORECASE):
                    continue
                schema = (m.group(1) or "public").lower()
                open_idx = stmt.index("(", m.end() - 1)
                close_idx = _match_paren(stmt, open_idx)
                t = Table(
                    schema=schema,
                    name=m.group(2).lower(),
                    columns=parse_columns(stmt[open_idx + 1 : close_idx - 1]),
                    source=path.name,
                )
                tables[t.qualified] = t
            elif head.startswith("ALTER TABLE"):
                m = ALTER_TABLE.match(stmt)
                if not m:
                    continue
                key = f"{(m.group(1) or 'public').lower()}.{m.group(2).lower()}"
                t = tables.get(key)
                if t is None:
                    continue
                actions = m.group(3)
                for name, tail in ADD_COLUMN_CLAUSE.findall(actions):
                    if any(existing.name == name.lower() for existing in t.columns):
                        continue
                    parsed = parse_columns(f"{name} {tail}")
                    t.columns.extend(parsed)
                dm = ALTER_DROP_COLUMN.match(stmt)
                if dm:
                    t.columns = [c for c in t.columns if c.name != dm.group(3).lower()]
            elif head.startswith("GRANT ") and " ON FUNCTION" not in head:
                m = TABLE_GRANT.match(stmt)
                if not m:
                    continue
                roles = {r.strip().lower() for r in split_top_level(m.group(3)) if r.strip()}
                for target in split_top_level(m.group(2)):
                    t = tables.get(_qualify(target))
                    if t is None:
                        continue
                    for privilege, cols in parse_privilege_list(m.group(1)):
                        for role in roles:
                            t.grant(privilege, role, cols)
            elif head.startswith("REVOKE ") and " ON FUNCTION" not in head:
                m = TABLE_REVOKE.match(stmt)
                if not m:
                    continue
                roles = {r.strip().lower() for r in split_top_level(m.group(3)) if r.strip()}
                privileges = {p for p, _ in parse_privilege_list(m.group(1))}
                for target in split_top_level(m.group(2)):
                    t = tables.get(_qualify(target))
                    if t is None:
                        continue
                    for role in roles:
                        t.revoke(privileges, role)
    return tables


def _qualify(target: str) -> str:
    name = target.strip().strip('"')
    return name.lower() if "." in name else f"public.{name.lower()}"


def load(migrations_dir: Path) -> dict[str, Function]:
    """Replay every migration. Returns signature -> Function for what survives."""
    live: dict[str, Function] = {}
    for path in sorted(migrations_dir.glob("*.sql")):
        raw = path.read_text(encoding="utf-8")
        text = strip_line_comments(raw)
        source = path.name
        for stmt in split_statements(text):
            head = stmt.lstrip()[:200].upper()

            if head.startswith("DROP FUNCTION"):
                m = DROP_FN.match(stmt)
                if m:
                    schema = (m.group(1) or "public").lower()
                    types = [normalise_type(t) for t in split_top_level(m.group(3)) if t.strip()]
                    live.pop(f"{schema}.{m.group(2).lower()}({', '.join(types)})", None)
                continue

            if head.startswith("CREATE FUNCTION") or head.startswith("CREATE OR REPLACE FUNCTION"):
                m = CREATE_FN.match(stmt)
                if not m:
                    continue
                schema = (m.group(1) or "public").lower()
                name = m.group(2).lower()
                open_idx = stmt.index("(", m.end() - 1)
                close_idx = _match_paren(stmt, open_idx)
                args = parse_arguments(stmt[open_idx + 1 : close_idx - 1])
                rest = stmt[close_idx - 1 :]
                rm = RETURNS_RE.search(rest)
                returns = " ".join(rm.group(1).split()) if rm else "void"
                lm = LANGUAGE_RE.search(rest)
                fn = Function(
                    schema=schema,
                    name=name,
                    args=args,
                    returns=returns,
                    language=(lm.group(1).lower() if lm else "sql"),
                    security_definer=bool(re.search(r"\bSECURITY\s+DEFINER\b", rest, re.IGNORECASE)),
                    body=rest,
                    source=source,
                )
                previous = live.get(fn.signature)
                if previous is not None:
                    fn.grants = set(previous.grants)  # CREATE OR REPLACE keeps privileges
                live[fn.signature] = fn
                continue

            if head.startswith("GRANT EXECUTE"):
                m = GRANT_RE.match(stmt)
                if not m:
                    continue
                roles = {r.strip().lower() for r in split_top_level(m.group(2)) if r.strip()}
                for schema, name, types in _parse_signature_list(m.group(1)):
                    fn = live.get(f"{schema}.{name}({', '.join(types)})")
                    if fn is not None:
                        fn.grants |= roles
                continue

            if head.startswith("REVOKE ALL ON FUNCTION") or head.startswith("REVOKE EXECUTE ON FUNCTION"):
                m = REVOKE_RE.match(stmt)
                if not m:
                    continue
                roles = {r.strip().lower() for r in split_top_level(m.group(2)) if r.strip()}
                for schema, name, types in _parse_signature_list(m.group(1)):
                    fn = live.get(f"{schema}.{name}({', '.join(types)})")
                    if fn is not None:
                        fn.grants -= roles
                        if "public" in roles:
                            fn.grants.clear()
                continue
    return live
