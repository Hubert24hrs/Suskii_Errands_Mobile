#!/usr/bin/env python3
"""Lock Firebase's Android API key to the Suskii app and copy it into a GitHub environment secret.

Firebase creates an "Android key (auto created by Firebase)" when an Android app is registered. The
app needs it (FIREBASE_ANDROID_API_KEY) to get a push token. This finds that key, restricts it to
package com.suskiierrands.app signed by the SHA-1s given (Play app signing and the upload key, RB-15),
prints which APIs it may call, and sets it in GitHub without showing it. Prints status lines only.

Usage:
  python infra/tools/set_firebase_api_key.py <gcp-project> <github-env> --sha1 <AA:BB:..> [--sha1 ...]
"""

import json
import re
import subprocess
import sys

GH_REPO = "Hubert24hrs/Suskii_Errands_Mobile"
PACKAGE = "com.suskiierrands.app"


def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, capture_output=True, **kwargs)


def main():
    args = sys.argv[1:]
    if len(args) < 4 or "--sha1" not in args:
        sys.exit(__doc__)
    project, env = args[0], args[1]
    sha1s = [args[i + 1] for i, a in enumerate(args) if a == "--sha1"]
    for s in sha1s:
        if not re.fullmatch(r"([0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}", s):
            sys.exit(f"not a SHA-1 fingerprint: {s}")
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project) or not re.fullmatch(r"[a-z-]+", env):
        sys.exit("bad project or environment name")

    r = run(f"gcloud services api-keys list --project {project} --format=json")
    if r.returncode != 0:
        sys.exit(f"listing keys failed:\n{r.stderr.decode(errors='replace')[-600:]}")
    keys = [k for k in json.loads(r.stdout) if "auto created by Firebase" in (k.get("displayName") or "")
            and "Android" in (k.get("displayName") or "")]
    if len(keys) != 1:
        sys.exit(f"expected one Firebase Android key in {project}, found {len(keys)}")
    name = keys[0]["name"]
    targets = [t.get("service") for t in (keys[0].get("restrictions") or {}).get("apiTargets", [])]
    print(f"Key: {keys[0]['displayName']} ({name.rsplit('/', 1)[-1][:8]}…)")
    print(f"It may call: {', '.join(targets) if targets else 'ANY API (no API restriction)'}")

    apps = " ".join(f"--allowed-application=sha1_fingerprint={s.lower().replace(':', '')},package_name={PACKAGE}"
                    for s in sha1s)
    u = run(f"gcloud services api-keys update {name} {apps} --project {project}")
    if u.returncode != 0:
        sys.exit(f"restricting the key failed:\n{u.stderr.decode(errors='replace')[-600:]}")
    print(f"Restricted to {PACKAGE} signed by {len(sha1s)} certificate(s).")

    s = run(f"gcloud services api-keys get-key-string {name} --format=value(keyString)")
    key = s.stdout.decode().strip()
    if s.returncode != 0 or not key.startswith("AIza"):
        sys.exit("reading the key string failed")
    g = run(f"gh secret set FIREBASE_ANDROID_API_KEY --env {env} --repo {GH_REPO}", input=key.encode())
    if g.returncode != 0:
        sys.exit(f"setting the GitHub secret failed:\n{g.stderr.decode(errors='replace')[-400:]}")
    print(f"FIREBASE_ANDROID_API_KEY set in '{env}'.")


if __name__ == "__main__":
    main()
