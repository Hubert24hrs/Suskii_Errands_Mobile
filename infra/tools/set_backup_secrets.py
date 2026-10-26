#!/usr/bin/env python3
"""Give an environment's backup jobs their two secrets, without showing either.

  supabase-db-backup-url     postgresql://postgres.<ref>:<password>@<session pooler>:5432/postgres
                             Cloud Run reaches Supabase over IPv4 only, and only the pooler is IPv4;
                             the session mode (5432) is what pg_dump needs.
  supabase-storage-sync-key  the project's secret API key named `backup`, for the Storage API mirror.

The database password is read from Secret Manager (`supabase-db-password`) or, if that has no version,
asked for without echo. The session pooler host is in Supabase -> Connect -> Session pooler.
Before running: create a secret API key named `backup` in the Supabase project (Settings -> API Keys).

Usage: python infra/tools/set_backup_secrets.py <gcp-project> <supabase-project-ref> <pooler-host>
"""

import getpass
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

REPO = str(Path(__file__).resolve().parents[2])
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="
CLI = "npx -y supabase@2.117.0"


def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kwargs)


def cli(args):
    return run(f"{CLI} {args}", cwd=REPO, env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK))


def first_json(text):
    start = min([i for i in (text.find("["), text.find("{")) if i >= 0], default=-1)
    return json.loads(text[start:]) if start >= 0 else None


def add_version(project, secret, value):
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(value)
        r = run(f'gcloud secrets versions add {secret} --data-file "{path}" --project {project}')
    finally:
        os.remove(path)
    if r.returncode != 0:
        sys.exit(f"storing {secret} failed:\n{r.stderr.strip()[-600:]}")
    print(f"{secret}: new version stored.")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    project, ref, host = sys.argv[1], sys.argv[2], sys.argv[3]
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project) or not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("bad project id or project ref")

    if not re.fullmatch(r"aws-\d+-[a-z0-9-]+\.pooler\.supabase\.com", host):
        sys.exit("pooler host looks wrong; copy it from Supabase -> Connect -> Session pooler")
    user = f"postgres.{ref}"
    print(f"Pooler: {host} as {user}.")

    p = run(f"gcloud secrets versions access latest --secret supabase-db-password --project {project}")
    password = p.stdout.strip() if p.returncode == 0 else ""
    if not password:
        password = getpass.getpass(f"Database password for {ref} (not shown): ")
    if not password:
        sys.exit("no password")
    url = f"postgresql://{user}:{urllib.parse.quote(password, safe='')}@{host}:5432/postgres?sslmode=require"
    add_version(project, "supabase-db-backup-url", url)

    k = cli(f"projects api-keys --project-ref {ref} --reveal -o json")
    keys = first_json(k.stdout) or []
    keys = keys if isinstance(keys, list) else next((v for v in keys.values() if isinstance(v, list)), [])
    key = next((i.get("api_key") or "" for i in keys if isinstance(i, dict) and i.get("name") == "backup"), "")
    if not re.fullmatch(r"sb_secret_[A-Za-z0-9_\-]{16,200}", key):
        sys.exit(f"no revealed secret key named 'backup' in {ref}; create it under Settings -> API Keys")
    add_version(project, "supabase-storage-sync-key", key)


if __name__ == "__main__":
    main()
