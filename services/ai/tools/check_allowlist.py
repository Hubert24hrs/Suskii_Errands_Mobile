#!/usr/bin/env python3
"""Enforce the AI tool allowlist (`docs/plan/ai-design.md` section 4.2).

The design states the containment structurally rather than as a prompt:

    the AI service's database client is generated from an allowlist file, and a CI test fails
    if the generated client exposes any function not on it.

There is no generated client yet - the FastAPI service needs Vertex AI and GCP billing - so this
checks the allowlist itself against the migrations, which is the half that can be true today and
the half that goes stale first. Three rules:

1. Every allowed function exists. An allowlist naming a function nobody wrote is a promise the
   service cannot keep, and the failure would arrive at runtime in front of a user.
2. Nothing is on both lists.
3. Every denied function exists too. This is the rule that earns its place: a denial naming a
   function that has been renamed has stopped protecting anything, and looks exactly like a
   denial that works.

Run: python services/ai/tools/check_allowlist.py [repo_root]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

FUNCTION_RE = re.compile(r"CREATE (?:OR REPLACE )?FUNCTION public\.(\w+)\s*\(")
DROP_RE = re.compile(r"DROP FUNCTION public\.(\w+)\s*\(")


def declared_functions(root: Path) -> set[str]:
    """Every `public.` function the migrations leave behind, in order."""
    live: set[str] = set()
    for path in sorted((root / "supabase" / "migrations").glob("*.sql")):
        src = path.read_text(encoding="utf-8")
        # A DROP followed by a CREATE in the same file is a signature change, not a removal, so
        # the CREATEs are applied after the DROPs of that file.
        for name in DROP_RE.findall(src):
            live.discard(name)
        for name in FUNCTION_RE.findall(src):
            live.add(name)
    return live


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    spec = json.loads((root / "services" / "ai" / "tools" / "allowlist.json").read_text("utf-8"))

    allow: dict[str, str] = {}
    for surface, names in spec["allow"].items():
        for name in names:
            allow[name] = surface
    deny = set(spec["deny"])
    live = declared_functions(root)

    findings: list[str] = []

    for name, surface in sorted(allow.items()):
        if name not in live:
            findings.append(
                f"{name} is allowed for the {surface} but no migration creates it - "
                "the service would fail at runtime, in front of somebody"
            )

    for name in sorted(deny):
        if name not in live:
            findings.append(
                f"{name} is denied but no migration creates it - a denial that names nothing "
                "has stopped protecting anything, usually because the function was renamed"
            )

    both = sorted(set(allow) & deny)
    for name in both:
        findings.append(f"{name} is on both the allow and deny lists, so the file says nothing")

    for f in findings:
        print(f"::error file=services/ai/tools/allowlist.json::{f}")

    print(
        f"check_allowlist: {len(allow)} allowed, {len(deny)} denied, "
        f"{len(findings)} finding(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
