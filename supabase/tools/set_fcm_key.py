#!/usr/bin/env python3
"""Create the push sender's key straight into Secret Manager, and optionally into a Supabase project.

Makes a key for `fcm-sender@<gcp-project>` (Terraform creates the account) and stores it as a new
version of the `fcm-service-account` secret. With --supabase-ref, it also sets the key as the
`FCM_SERVICE_ACCOUNT_JSON` function secret: the sandbox needs that, because the deploy pipeline,
which does it for the other environments, is never run against the sandbox (RB-15 §3.4). The key
passes through private temporary files that are deleted at once, never the screen or a command line.

Usage:
  python supabase/tools/set_fcm_key.py <gcp-project>                         # Secret Manager only
  python supabase/tools/set_fcm_key.py <gcp-project> --supabase-ref <ref>    # and the functions
  python supabase/tools/set_fcm_key.py <gcp-project> --supabase-ref <ref> --reuse
                                        # reuse the latest stored key instead of making a new one
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = str(Path(__file__).resolve().parents[2])
SECRET = "fcm-service-account"
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="


def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kwargs)


def private_file(content=""):
    fd, path = tempfile.mkstemp()
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    project = args[0]
    ref = args[args.index("--supabase-ref") + 1] if "--supabase-ref" in args else None
    reuse = "--reuse" in args
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project):
        sys.exit("not a GCP project id")
    if ref and not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("project ref must be 20 lowercase letters")
    account = f"fcm-sender@{project}.iam.gserviceaccount.com"

    if not reuse:
        key_file = private_file()
        try:
            r = run(f'gcloud iam service-accounts keys create "{key_file}" --iam-account {account} --project {project}')
            if r.returncode != 0:
                sys.exit(f"creating the key failed (is Terraform applied for {project}?):\n{r.stderr.strip()[-600:]}")
            key = json.load(open(key_file, encoding="utf-8"))
            if key.get("client_email") != account or "private_key" not in key:
                sys.exit("the created file is not a service-account key for fcm-sender")
            r = run(f'gcloud secrets versions add {SECRET} --data-file "{key_file}" --project {project}')
            if r.returncode != 0:
                sys.exit(f"storing the key failed:\n{r.stderr.strip()[-600:]}")
        finally:
            os.remove(key_file)
        print(f"Key {key['private_key_id'][:8]}… for {account} stored as a new version of {SECRET}.")

    if not ref:
        return
    r = run(f"gcloud secrets versions access latest --secret {SECRET} --project {project}")
    if r.returncode != 0:
        sys.exit(f"reading {SECRET} failed:\n{r.stderr.strip()[-600:]}")
    compact = json.dumps(json.loads(r.stdout), separators=(",", ":"))
    if "'" in compact:
        sys.exit("unexpected quote in the key; not written")
    env_file = private_file(f"FCM_SERVICE_ACCOUNT_JSON='{compact}'\n")
    try:
        s = run(f'npx -y supabase@2.117.0 secrets set --project-ref {ref} --env-file "{env_file}"', cwd=REPO,
                env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK))
    finally:
        os.remove(env_file)
    if s.returncode != 0:
        sys.exit(f"setting the function secret failed:\n{s.stderr.strip()[-600:]}")
    print(f"FCM_SERVICE_ACCOUNT_JSON set on Supabase project {ref}.")


if __name__ == "__main__":
    main()
