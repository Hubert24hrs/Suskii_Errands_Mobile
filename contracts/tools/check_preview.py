#!/usr/bin/env python3
"""Keeps contracts/v1-preview honest against the code (contracts/README.md rule 3: no drift).

Errors (exit 1):
  * an ERR_ code raised by backend code is missing from error-codes.json, or not marked implemented
  * a code marked implemented is no longer raised anywhere
  * enums.json differs from the enums declared in supabase/migrations
  * error-codes.json is malformed (duplicate codes, bad names, unknown status)

Warnings (reported, never failing, because they concern Kimi Code's files):
  * a code in packages/suskii_core/lib/src/errors.dart that the catalogue does not know

Usage:
  python contracts/tools/check_preview.py [repo_root]           check
  python contracts/tools/check_preview.py [repo_root] --write   regenerate enums.json
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

CODE = re.compile(r"\bERR_[A-Z0-9_]*[A-Z0-9]\b")
ENUM = re.compile(r"CREATE\s+TYPE\s+public\.(\w+)\s+AS\s+ENUM\s*\((.*?)\)\s*;", re.IGNORECASE | re.DOTALL)
STATUSES = {"implemented", "planned", "client"}


@dataclass(frozen=True)
class Finding:
    level: str  # "error" | "warning"
    message: str
    file: str | None = None

    def annotation(self) -> str:
        location = f" file={self.file}" if self.file else ""
        return f"::{self.level}{location}::{self.message}"


def backend_sources(root: Path) -> list[Path]:
    files = sorted((root / "supabase" / "migrations").glob("*.sql"))
    files += sorted(
        p for p in (root / "supabase" / "functions").rglob("*.ts") if not p.name.endswith("_test.ts")
    )
    files += sorted((root / "services").glob("*/src/**/*.py"))
    return files


def raised_codes(root: Path) -> dict[str, str]:
    """code -> first file (relative) that raises it."""
    found: dict[str, str] = {}
    for path in backend_sources(root):
        for code in CODE.findall(path.read_text(encoding="utf-8", errors="replace")):
            found.setdefault(code, path.relative_to(root).as_posix())
    return found


def declared_enums(root: Path) -> dict[str, list[str]]:
    enums: dict[str, list[str]] = {}
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        text = re.sub(r"--[^\n]*", "", path.read_text(encoding="utf-8"))
        for name, body in ENUM.findall(text):
            enums[name] = re.findall(r"'([^']*)'", body)
    return dict(sorted(enums.items()))


def client_codes(root: Path) -> set[str]:
    path = root / "packages" / "suskii_core" / "lib" / "src" / "errors.dart"
    return set(CODE.findall(path.read_text(encoding="utf-8"))) if path.exists() else set()


def check(root: Path) -> list[Finding]:
    preview = root / "contracts" / "v1-preview"
    findings: list[Finding] = []

    catalogue = json.loads((preview / "error-codes.json").read_text(encoding="utf-8"))
    entries = catalogue["codes"]
    seen: set[str] = set()
    for entry in entries:
        code = entry.get("code", "")
        if not re.fullmatch(r"ERR_[A-Z0-9_]*[A-Z0-9]", code):
            findings.append(Finding("error", f"malformed code name {code!r}", "contracts/v1-preview/error-codes.json"))
        if code in seen:
            findings.append(Finding("error", f"duplicate code {code}", "contracts/v1-preview/error-codes.json"))
        seen.add(code)
        if entry.get("status") not in STATUSES:
            findings.append(Finding("error", f"{code}: unknown status {entry.get('status')!r}", "contracts/v1-preview/error-codes.json"))

    status = {e["code"]: e.get("status") for e in entries}
    raised = raised_codes(root)
    for code, where in sorted(raised.items()):
        if code not in status:
            findings.append(Finding("error", f"{code} is raised but missing from error-codes.json", where))
        elif status[code] != "implemented":
            findings.append(Finding("error", f"{code} is raised but marked {status[code]}; mark it implemented", where))
    for code, st in sorted(status.items()):
        if st == "implemented" and code not in raised:
            findings.append(Finding("error", f"{code} is marked implemented but no backend code raises it",
                                    "contracts/v1-preview/error-codes.json"))

    committed = json.loads((preview / "enums.json").read_text(encoding="utf-8"))["enums"]
    declared = declared_enums(root)
    if committed != declared:
        changed = sorted(set(committed) ^ set(declared) | {k for k in committed if declared.get(k) != committed[k]})
        findings.append(Finding("error", f"enums.json is out of date for: {', '.join(changed)} "
                                         "(run contracts/tools/check_preview.py --write)",
                                "contracts/v1-preview/enums.json"))

    for code in sorted(client_codes(root) - set(status)):
        findings.append(Finding("warning", f"{code} is used by the app but not in the preview catalogue "
                                           "(add it to error-codes.json or rename it in the app)",
                                "packages/suskii_core/lib/src/errors.dart"))
    return findings


def write_enums(root: Path) -> None:
    path = root / "contracts" / "v1-preview" / "enums.json"
    doc = {
        "version": "1.0.0-preview.8",
        "binding": False,
        "source": "Generated from CREATE TYPE ... AS ENUM in supabase/migrations by contracts/tools/check_preview.py. "
                  "Values are the snake_case wire format. Adding a value is additive; renaming or removing one is breaking.",
        "enums": declared_enums(root),
    }
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0] if args else ".").resolve()
    if "--write" in argv:
        write_enums(root)
    findings = check(root)
    for finding in findings:
        print(finding.annotation())
    errors = sum(f.level == "error" for f in findings)
    print(f"check_preview: {errors} error(s), {len(findings) - errors} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
