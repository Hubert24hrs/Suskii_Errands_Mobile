#!/usr/bin/env python3
"""Store a LiveKit Cloud project's credentials for in-app calls, without showing the secret.

Asks for the project URL (wss://<project>.livekit.cloud), the API key and the API secret (the
secret is read without echo), checks their shape, and stores them as one JSON version of the
`livekit-credentials` secret in Secret Manager. The deploy pipeline hands them to the `call-token`
function on every deploy. With --supabase-ref it also sets them on that Supabase project
directly, which the testers' sandbox needs because the pipeline never deploys to it (RB-15 §3.4).

Where to find them: LiveKit Cloud -> your project -> Settings -> Keys -> Create key. Copy the
URL, the key and the secret straight into this script's prompts, never into chat or a file.

Usage:
  python infra/tools/set_livekit_credentials.py <gcp-project> [--supabase-ref <ref>]
"""

import getpass
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = str(Path(__file__).resolve().parents[2])
SECRET = "livekit-credentials"
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="


def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kwargs)


def private_file(content):
    fd, path = tempfile.mkstemp()
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    return path


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    project = args[0]
    ref = args[args.index("--supabase-ref") + 1] if "--supabase-ref" in args else None
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project):
        sys.exit("not a GCP project id")
    if ref and not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("project ref must be 20 lowercase letters")

    url = input("LiveKit project URL (wss://...livekit.cloud): ").strip()
    if not re.fullmatch(r"wss://[a-z0-9-]+(\.[a-z0-9-]+)+", url, re.I):
        sys.exit("that is not a wss:// project URL")
    api_key = input("LiveKit API key: ").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", api_key):
        sys.exit("that does not look like a LiveKit API key")
    api_secret = getpass.getpass("LiveKit API secret (not shown): ").strip()
    if len(api_secret) < 16 or re.search(r"\s|'", api_secret):
        sys.exit("that does not look like a LiveKit API secret")

    payload = json.dumps({"url": url, "api_key": api_key, "api_secret": api_secret}, separators=(",", ":"))
    path = private_file(payload)
    try:
        r = run(f'gcloud secrets versions add {SECRET} --data-file "{path}" --project {project}')
    finally:
        os.remove(path)
    if r.returncode != 0:
        sys.exit(f"storing {SECRET} failed (is Terraform applied for {project}?):\n{r.stderr.strip()[-600:]}")
    print(f"{SECRET}: new version stored in {project} (key {api_key[:4]}…).")

    if not ref:
        return
    env_file = private_file(
        f"LIVEKIT_URL='{url}'\nLIVEKIT_API_KEY='{api_key}'\nLIVEKIT_API_SECRET='{api_secret}'\n")
    try:
        s = run(f'npx -y supabase@2.117.0 secrets set --project-ref {ref} --env-file "{env_file}"', cwd=REPO,
                env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK))
    finally:
        os.remove(env_file)
    if s.returncode != 0:
        sys.exit(f"setting the function secrets failed:\n{s.stderr.strip()[-600:]}")
    print(f"LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET set on Supabase project {ref}.")


if __name__ == "__main__":
    main()
