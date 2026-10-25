#!/usr/bin/env python3
"""Escrow an environment's field-encryption KEK (RB-16 section 1, "existing environment").

Reads suskii_field_kek_v1 from Supabase Vault through the Management API and adds it to GCP Secret
Manager in the same process, then reads it back and compares. The value never reaches the screen, a
file, a command line or a shell pipe (Windows PowerShell pipes add a line ending, RB-10).

Usage: python supabase/tools/escrow_kek.py <supabase-project-ref> <gcp-project-id>
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# supabase/tools/<this file>: the CLI must run where supabase/config.toml is.
REPO = str(Path(__file__).resolve().parents[2])
VAULT_NAME = "suskii_field_kek_v1"
SECRET_ID = "suskii-field-kek-v1"
# The CLI validates all of config.toml, including the hook secret it does not use here; this is the
# public placeholder CI uses, not a real secret.
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="


def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, capture_output=True, **kwargs)


def find_rows(text):
    # With --agent no the CLI prints the rows as a bare JSON list; agent mode wraps them in
    # {"rows": [...]}. Accept either, skipping anything else it prints around them.
    decoder, i = json.JSONDecoder(), 0
    while True:
        starts = [p for p in (text.find("[", i), text.find("{", i)) if p >= 0]
        if not starts:
            return None
        i = min(starts)
        try:
            obj, end = decoder.raw_decode(text, i)
        except json.JSONDecodeError:
            i += 1
            continue
        if isinstance(obj, list) and all(isinstance(row, dict) for row in obj):
            return obj
        if isinstance(obj, dict) and isinstance(obj.get("rows"), list):
            return obj["rows"]
        i = end


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref, gcp_project = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("project ref must be 20 lowercase letters")

    sql = f"select decrypted_secret from vault.decrypted_secrets where name = '{VAULT_NAME}'"
    r = run(
        f'npx -y supabase@2.117.0 db query --linked --project-ref {ref} --output-format json --agent no "{sql}"',
        text=True,
        cwd=REPO,
        env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK),
    )
    if r.returncode != 0 or ("{" not in r.stdout and "[" not in r.stdout):
        sys.exit(f"reading the KEK failed (exit {r.returncode}):\n{r.stderr.strip()[-800:]}")
    rows = find_rows(r.stdout)
    if rows is None:
        sys.exit("the CLI answered, but its output held no result rows; nothing was written")
    if len(rows) != 1:
        sys.exit(f"expected one Vault secret named {VAULT_NAME}, found {len(rows)}")
    kek = rows[0]["decrypted_secret"]
    if not re.fullmatch(r"[0-9a-fA-F]{64}", kek or ""):
        sys.exit("the Vault value is not 64 hex characters; stop and read RB-16 section 4")

    exists = run(f"gcloud secrets describe {SECRET_ID} --project {gcp_project}").returncode == 0
    verb = (
        f"gcloud secrets versions add {SECRET_ID} --project {gcp_project} --data-file=-"
        if exists
        else f"gcloud secrets create {SECRET_ID} --project {gcp_project} "
        f"--replication-policy=automatic --data-file=-"
    )
    w = run(verb, input=kek.encode())
    if w.returncode != 0:
        sys.exit(f"writing to Secret Manager failed:\n{w.stderr.decode(errors='replace').strip()[-800:]}")

    back = run(f"gcloud secrets versions access latest --secret {SECRET_ID} --project {gcp_project}")
    if back.returncode != 0 or back.stdout != kek.encode():
        sys.exit("written, but reading it back did not match; check the secret's versions by hand")

    versions = run(
        f'gcloud secrets versions list {SECRET_ID} --project {gcp_project} --format="value(name)" --limit=1',
        text=True,
    ).stdout.strip()
    print(f"Escrowed {VAULT_NAME} from {ref} to {gcp_project}/{SECRET_ID} (version {versions}); "
          f"read back and matched.")


if __name__ == "__main__":
    main()
