#!/usr/bin/env python3
"""Every bare import a function reaches must be in that function's own deno.json.

`deno check` and `deno test` run from supabase/functions, where the workspace root's deno.json
lends its imports to every member, so a function can type-check and pass every test while
importing a package only the root maps. The deploy bundles each function with its own import map
and nothing else, and fails there instead: `notifications-worker` reached `jose` through
`_shared/notifications/fcm.ts`, and two staging deploys failed (2026-10-26) with every check green.

This walks each function's graph of local files from index.ts and compares, statically, with no
network and no Deno.

Usage: python supabase/tools/check_function_imports.py [supabase/functions]
"""

import json
import re
import sys
from pathlib import Path

SPEC = re.compile(r"""(?:^|[\s;])(?:import|export)\b[^'"]*?\bfrom\s*['"]([^'"]+)['"]"""
                  r"""|(?:^|[\s;])import\s*['"]([^'"]+)['"]"""
                  r"""|\bimport\(\s*['"]([^'"]+)['"]\s*\)""", re.M)
SCHEMES = ("jsr:", "npm:", "node:", "http:", "https:", "data:")


def specifiers(path: Path):
    text = path.read_text(encoding="utf-8")
    # Comments can mention imports; strip them first so a doc example is not a dependency.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    for m in SPEC.finditer(text):
        yield next(g for g in m.groups() if g)


def package(spec: str) -> str:
    parts = spec.split("/")
    return "/".join(parts[:2]) if spec.startswith("@") else parts[0]


def mapped(spec: str, imports: dict) -> bool:
    if spec in imports:
        return True
    # deno.json maps a package name to its subpaths too (`@supabase/server` covers `.../core`).
    return package(spec) in imports or any(k.endswith("/") and spec.startswith(k) for k in imports)


def check(fn_dir: Path) -> list[str]:
    config = fn_dir / "deno.json"
    imports = json.loads(config.read_text(encoding="utf-8")).get("imports", {}) if config.exists() else {}
    problems, seen, queue = [], set(), [fn_dir / "index.ts"]
    while queue:
        f = queue.pop().resolve()
        if f in seen or not f.exists():
            continue
        seen.add(f)
        for spec in specifiers(f):
            if spec.startswith((".", "/")):
                queue.append(f.parent / spec)
            elif not spec.startswith(SCHEMES) and not mapped(spec, imports):
                problems.append(f"{fn_dir.name}: '{spec}' (from {f.relative_to(fn_dir.parent.resolve())}) "
                                f"is not in {fn_dir.name}/deno.json")
    return sorted(set(problems))


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else "supabase/functions").resolve()
    functions = sorted(p.parent for p in root.glob("*/index.ts") if not p.parent.name.startswith("_"))
    problems = [p for fn in functions for p in check(fn)]
    for p in problems:
        print(f"::error::{p}")
    print(f"check_function_imports: {len(functions)} function(s), {len(problems)} unmapped import(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
