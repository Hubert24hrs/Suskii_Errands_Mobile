#!/usr/bin/env python3
"""Copy a project's `monitoring` secret API key into HEALTH_CHECK_API_KEY without the clipboard.

Fetches the key with the Supabase CLI, proves it against the project's `health` function, and only
then sets it in the GitHub environments named on the command line. Prints status lines only.

Usage: python supabase/tools/set_health_key.py <supabase-project-ref> <github-env> [<github-env> ...]
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# supabase/tools/<this file>: the CLI must run where supabase/config.toml is.
REPO = str(Path(__file__).resolve().parents[2])
GH_REPO = "Hubert24hrs/Suskii_Errands_Mobile"
KEY_NAME = "monitoring"
# The CLI validates all of config.toml; this is the public placeholder CI uses, not a real secret.
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="


def find_key(data):
    items = data if isinstance(data, list) else next(
        (v for v in data.values() if isinstance(v, list)), [])
    for item in items:
        if isinstance(item, dict) and item.get("name") == KEY_NAME:
            return item.get("api_key") or ""
    return ""


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ref, envs = sys.argv[1], sys.argv[2:]
    if not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("project ref must be 20 lowercase letters")

    r = subprocess.run(
        f"npx -y supabase@2.117.0 projects api-keys --project-ref {ref} --reveal -o json",
        shell=True, capture_output=True, text=True, cwd=REPO,
        env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK),
    )
    start = min([i for i in (r.stdout.find("["), r.stdout.find("{")) if i >= 0], default=-1)
    if r.returncode != 0 or start < 0:
        sys.exit(f"listing API keys failed (exit {r.returncode}):\n{r.stderr.strip()[-800:]}")
    key = find_key(json.loads(r.stdout[start:]))
    if not key.startswith("sb_secret_") or "•" in key or "*" in key:
        sys.exit(f"no revealed secret key named '{KEY_NAME}' in {ref}; create it under Settings → API Keys")
    print(f"Found the '{KEY_NAME}' key for {ref} ({len(key)} characters).")

    req = urllib.request.Request(f"https://{ref}.supabase.co/functions/v1/health", headers={"apikey": key})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read() or b"{}")
            print(f"health answered HTTP {resp.status}, release {body.get('release', '?')}")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            sys.exit(f"health refused the key: HTTP {e.code} {e.read()[:200]!r}; nothing was changed in GitHub")
        # Any other status means the key got through; an unhealthy project is for the deploy to report.
        print(f"health accepted the key but answered HTTP {e.code} {e.read()[:200]!r}")

    for env in envs:
        s = subprocess.run(
            f"gh secret set HEALTH_CHECK_API_KEY --env {env} --repo {GH_REPO}",
            shell=True, input=key.encode(), capture_output=True,
        )
        if s.returncode != 0:
            sys.exit(f"setting the secret in '{env}' failed:\n{s.stderr.decode(errors='replace').strip()}")
        print(f"HEALTH_CHECK_API_KEY set in '{env}'.")


if __name__ == "__main__":
    main()
