"""Check every backend call the frontends make against contracts/v1.

The contract is generated from the migrations, so it is the backend as it is. This checks the
other half: that what the apps send still matches it. A renamed argument, a dropped function or a
column the role was never granted fails here, in CI, instead of at runtime on somebody's phone.

Read, where the apps talk to the backend:
  Dart  packages/suskii_data/lib/src/supabase  the gateway's rpc / select* / count / stream /
                                               upsert / update calls
  TS    apps/web-*/src                         supabase-js .rpc(...) and .from(t).select(cols),
                                               and the web gateway's select calls

Arguments must be written as a literal map at the call site, or passed through a helper that
takes `String function` and calls `rpc(function, {...})`; a map built anywhere else is invisible
here, which is why the repositories do not build them elsewhere.

Usage: python3 contracts/tools/check_frontend_calls.py <repo root>   (exit 1 on any finding)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DART_DIR = "packages/suskii_data/lib/src/supabase"
TS_GLOBS = ("apps/web-*/src/**/*.ts", "apps/web-*/src/**/*.tsx")


def balanced(text: str, start: int) -> str:
    """The text from text[start] (an opening bracket) to its matching close."""
    depth = 0
    for i in range(start, len(text)):
        char = text[i]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


class Checker:
    def __init__(self, root: Path) -> None:
        catalogue = json.loads((root / "contracts/v1/rpc-catalog/index.json").read_text())
        tables = json.loads((root / "contracts/v1/db-types/tables.json").read_text())["tables"]
        self.root = root
        self.functions = {f["name"]: f for f in catalogue["functions"]}
        self.tables = {t["name"].split(".", 1)[1]: t for t in tables}
        self.findings: list[str] = []
        self.used: set[str] = set()

    def function(self, where: str, name: str, keys: list[str]) -> None:
        self.used.add(name)
        spec = self.functions.get(name)
        if spec is None:
            self.findings.append(f"{where}: rpc {name!r} is not in the contract")
            return
        arguments = {a["name"]: a for a in spec["arguments"]}
        for key in keys:
            if key not in arguments:
                self.findings.append(
                    f"{where}: rpc {name}: argument {key!r} does not exist "
                    f"(has {sorted(arguments)})")
        for argument in spec["arguments"]:
            if not argument["optional"] and argument["name"] not in keys:
                self.findings.append(
                    f"{where}: rpc {name}: required argument {argument['name']!r} not passed")

    def columns(self, where: str, table: str, names: list[str], privilege: str) -> None:
        spec = self.tables.get(table)
        if spec is None:
            self.findings.append(f"{where}: table {table!r} is not client-readable in the contract")
            return
        granted = spec.get("privileges", {}).get(privilege, {}).get("authenticated")
        if granted is None:
            self.findings.append(f"{where}: {privilege} on {table} not granted to authenticated")
            return
        existing = {c["name"] for c in spec["columns"]}
        for raw in names:
            column = raw.strip()
            if not column or "(" in column or column == "*":
                continue
            column = column.split(":")[-1].split("::")[0].strip()
            if column not in existing:
                self.findings.append(f"{where}: {table}.{column} does not exist")
            elif granted != ["*"] and column not in granted:
                self.findings.append(f"{where}: {privilege} {table}.{column} not granted")

    def dart(self) -> None:
        for path in sorted((self.root / DART_DIR).glob("*.dart")):
            text = path.read_text()
            for match in re.finditer(r"\.rpc\(\s*'(\w+)'", text):
                call = balanced(text, match.start() + len(".rpc"))
                where = f"{path.name}:{text[: match.start()].count(chr(10)) + 1}"
                self.function(where, match.group(1), re.findall(r"'(p_\w+)'\s*:", call))
            # Helpers that take the function name and call `rpc(function, {...})`: each call site
            # is checked with its own keys plus the ones the helper always adds.
            for helper in re.finditer(r"Future<[^\n]*?>\s+(_\w+)\(\s*String function", text):
                body_at = text.index("rpc(function", helper.end())
                fixed = re.findall(r"'(p_\w+)'\s*:", balanced(text, body_at + len("rpc")))
                for match in re.finditer(rf"\b{helper.group(1)}\(\s*'(\w+)'", text):
                    call = balanced(text, match.start() + len(helper.group(1)))
                    where = f"{path.name}:{text[: match.start()].count(chr(10)) + 1}"
                    keys = re.findall(r"'(p_\w+)'\s*:", call)
                    self.function(where, match.group(1), sorted(set(keys + fixed)))
            for match in re.finditer(
                    r"(selectSingle|selectList|countRows|streamRows)\(\s*'(\w+)'(?:\s*,\s*'([^']*)')?",
                    text):
                where = f"{path.name}:{text[: match.start()].count(chr(10)) + 1}"
                names = (match.group(3) or "").split(",") if match.group(1) != "countRows" else []
                self.columns(where, match.group(2), names, "SELECT")
            for match in re.finditer(r"(upsertRows|updateRows)\(\s*'(\w+)'", text):
                call = balanced(text, match.start() + len(match.group(1)))
                where = f"{path.name}:{text[: match.start()].count(chr(10)) + 1}"
                privilege = "UPDATE" if match.group(1) == "updateRows" else "INSERT"
                self.columns(where, match.group(2), re.findall(r"'(\w+)'\s*:", call), privilege)

    def typescript(self) -> None:
        for path in sorted({p for g in TS_GLOBS for p in self.root.glob(g)}):
            text = path.read_text()
            relative = path.relative_to(self.root)
            for match in re.finditer(r"\.rpc(?:<[^>]*>)?\(\s*['\"](\w+)['\"]", text):
                open_at = match.start() + text[match.start() : match.end()].index("(")
                body = balanced(text, open_at)[1:-1]
                brace = body.find("{")
                keys = re.findall(r"\b(p_\w+)\b\s*[:,}]", body[brace:]) if brace >= 0 else []
                where = f"{relative}:{text[: match.start()].count(chr(10)) + 1}"
                self.function(where, match.group(1), sorted(set(keys)))
            for match in re.finditer(
                    r"\.from\(\s*['\"](\w+)['\"]\s*\)\s*\.select\(\s*['\"`]([^'\"`]*)['\"`]", text):
                where = f"{relative}:{text[: match.start()].count(chr(10)) + 1}"
                self.columns(where, match.group(1), match.group(2).split(","), "SELECT")
            # The web gateway takes table and columns as its first two string arguments.
            for match in re.finditer(r"\.(selectSingle|selectList)\(\s*'(\w+)',\s*(\w+|'[^']*')", text):
                columns = match.group(3)
                if columns.startswith("'"):
                    names = columns.strip("'").split(",")
                else:
                    constant = re.search(rf"const {columns}\s*=\s*'([^']*)'", text)
                    if constant is None:
                        continue
                    names = constant.group(1).split(",")
                where = f"{relative}:{text[: match.start()].count(chr(10)) + 1}"
                self.columns(where, match.group(2), names, "SELECT")


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".")
    checker = Checker(root)
    checker.dart()
    checker.typescript()
    for finding in checker.findings:
        print(finding)
    print(f"check_frontend_calls: {len(checker.used)} of {len(checker.functions)} contract "
          f"functions called by the apps, {len(checker.findings)} finding(s)")
    return 1 if checker.findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
