#!/usr/bin/env python3
"""Give a project's database the `worker` secret API key, so pg_cron can run the Edge Function workers.

Fetches the key with the Supabase CLI, writes it and the functions URL to Vault (`worker_api_key`,
`edge_functions_url`), then has the database call `notifications-worker` once through pg_net and
reports the HTTP status the worker answered. The key travels in a private temporary file, never on
a command line or the screen. Prints status lines only.

Before running: create a secret API key named `worker` in the project (Settings -> API Keys), and
deploy `notifications-worker` to it.

Usage: python supabase/tools/set_worker_key.py <supabase-project-ref>
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# supabase/tools/<this file>: the CLI must run where supabase/config.toml is.
REPO = str(Path(__file__).resolve().parents[2])
KEY_NAME = "worker"
# The CLI validates all of config.toml; this is the public placeholder CI uses, not a real secret.
PLACEHOLDER_HOOK = "v1,whsec_Y2ktb25seS1wbGFjZWhvbGRlci1ub3QtYS1zZWNyZXQ="
CLI = "npx -y supabase@2.117.0"


def cli(args, **kwargs):
    return subprocess.run(
        f"{CLI} {args}", shell=True, capture_output=True, text=True, cwd=REPO,
        env=dict(os.environ, SEND_SMS_HOOK_SECRETS=PLACEHOLDER_HOOK), **kwargs,
    )


def first_json(text):
    start = min([i for i in (text.find("["), text.find("{")) if i >= 0], default=-1)
    return json.loads(text[start:]) if start >= 0 else None


def rows(data):
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return next((v for v in data.values() if isinstance(v, list)), [])
    return []


def query_file(ref, sql):
    fd, path = tempfile.mkstemp(suffix=".sql")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(sql)
        r = cli(f'db query --linked --project-ref {ref} --output-format json --agent no -f "{path}"')
    finally:
        os.remove(path)
    if r.returncode != 0:
        sys.exit(f"the database refused the query (exit {r.returncode}):\n{r.stderr.strip()[-800:]}")
    return rows(first_json(r.stdout))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ref = sys.argv[1]
    if not re.fullmatch(r"[a-z]{20}", ref):
        sys.exit("project ref must be 20 lowercase letters")

    r = cli(f"projects api-keys --project-ref {ref} --reveal -o json")
    data = first_json(r.stdout)
    if r.returncode != 0 or data is None:
        sys.exit(f"listing API keys failed (exit {r.returncode}):\n{r.stderr.strip()[-800:]}")
    key = next((i.get("api_key") or "" for i in rows(data) if isinstance(i, dict) and i.get("name") == KEY_NAME), "")
    # Checked before it goes anywhere near SQL: a key is only ever these characters.
    if not re.fullmatch(r"sb_secret_[A-Za-z0-9_\-]{16,200}", key):
        sys.exit(f"no revealed secret key named '{KEY_NAME}' in {ref}; create it under Settings -> API Keys")
    print(f"Found the '{KEY_NAME}' key for {ref} ({len(key)} characters).")

    url = f"https://{ref}.supabase.co/functions/v1"
    query_file(ref, f"""
DO $do$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM vault.secrets WHERE name = 'worker_api_key';
  IF v_id IS NULL THEN
    PERFORM vault.create_secret('{key}', 'worker_api_key', 'Named secret API key the database sends to the Edge Function workers');
  ELSE
    PERFORM vault.update_secret(v_id, '{key}');
  END IF;
  SELECT id INTO v_id FROM vault.secrets WHERE name = 'edge_functions_url';
  IF v_id IS NULL THEN
    PERFORM vault.create_secret('{url}', 'edge_functions_url', 'Base URL of this project''s Edge Functions');
  ELSE
    PERFORM vault.update_secret(v_id, '{url}');
  END IF;
END $do$;
""")
    print("Vault updated: worker_api_key, edge_functions_url.")

    started = query_file(ref, "SELECT private.invoke_edge_worker('notifications-worker') AS request_id;")
    request_id = started[0].get("request_id") if started else None
    if request_id is None:
        sys.exit("the database did not call the worker: is pg_net enabled and the migration applied?")
    for _ in range(20):
        time.sleep(3)
        answered = query_file(ref, f"SELECT status_code, left(content, 200) AS body FROM net._http_response WHERE id = {int(request_id)};")
        if answered and answered[0].get("status_code") is not None:
            status = answered[0]["status_code"]
            print(f"notifications-worker answered HTTP {status}: {answered[0].get('body')}")
            if status in (401, 403):
                sys.exit("the worker refused the key; check that the key is named exactly 'worker'")
            if status == 404:
                sys.exit("notifications-worker is not deployed to this project yet")
            return
    sys.exit("no answer from the worker within a minute; look at net._http_response for request "
             f"{request_id}")


if __name__ == "__main__":
    main()
