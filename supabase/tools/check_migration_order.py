#!/usr/bin/env python3
"""Every migration a branch adds must sort after every migration already on the base branch.

`supabase db push` applies migrations in version order and refuses one older than the newest it
has already applied ("Found local migration files to be inserted before the last migration on
remote database"). Two branches written in parallel can each pick a timestamp, merge in the other
order, and leave `main` undeployable: on 2026-10-26 `…20261026160000` merged after `…170000` had
reached staging, and three staging deploys failed before anyone looked. This fails the pull request
instead. Renaming is then free: nothing has applied a migration that has not merged.

Usage: python supabase/tools/check_migration_order.py <base-ref>     (e.g. origin/main)
"""

import re
import subprocess
import sys

MIGRATIONS = "supabase/migrations/"
VERSION = re.compile(r"^(\d{14})_[a-z0-9_]+\.sql$")


def names(ref: str | None) -> set[str]:
    cmd = ["git", "ls-tree", "--name-only", ref, MIGRATIONS] if ref else ["git", "ls-files", MIGRATIONS]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return {line.rsplit("/", 1)[-1] for line in out.splitlines() if line.strip()}


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.exit(__doc__)
    base = names(argv[1])
    head = names(None)
    bad_names = sorted(n for n in head if not VERSION.match(n))
    for n in bad_names:
        print(f"::error file={MIGRATIONS}{n}::migration file names are <14-digit version>_<snake_case>.sql")
    newest = max((n[:14] for n in base if VERSION.match(n)), default="0" * 14)
    added = sorted(n for n in head - base if VERSION.match(n))
    late = [n for n in added if n[:14] <= newest]
    for n in late:
        print(f"::error file={MIGRATIONS}{n}::{n[:14]} is not after {newest}, the newest migration on "
              f"{argv[1]}; rename it to a later version before merging")
    print(f"check_migration_order: {len(added)} added, newest on {argv[1]} {newest}, {len(late)} out of order")
    return 1 if late or bad_names else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
