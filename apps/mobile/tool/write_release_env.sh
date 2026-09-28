#!/usr/bin/env bash
# Writes build/env/<env>.json for a release: config/env/<env>.json with the environment's
# public client values (SUPABASE_URL, SUPABASE_ANON_KEY, SENTRY_DSN) from the workflow's
# secrets. The Fastfile prefers this file over the committed one.
#
# A staging or prod build without a backend would be the mock app (AppConfig.usesMockBackend)
# shipped to a store, so this refuses to write one. Nothing here is a secret in the security
# sense: these values end up in the app binary, as every public client key does.
#
#   SUPABASE_URL=... SUPABASE_ANON_KEY=... tool/write_release_env.sh prod
set -euo pipefail

env="${1:?usage: write_release_env.sh dev|staging|prod}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$here/config/env/$env.json"
out="$here/build/env/$env.json"
test -f "$src" || { echo "no define file for '$env'"; exit 1; }

if [ "$env" != dev ]; then
  for v in SUPABASE_URL SUPABASE_ANON_KEY; do
    test -n "${!v:-}" || { echo "$v is empty: a $env build would run on the mock backend"; exit 1; }
  done
  case "$SUPABASE_URL" in https://*) ;; *) echo "SUPABASE_URL must be https for $env"; exit 1 ;; esac
fi

mkdir -p "$(dirname "$out")"
python3 - "$src" "$out" <<'PY'
import json, os, sys
src, out = sys.argv[1], sys.argv[2]
defines = json.load(open(src))
for key in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "SENTRY_DSN"):
    value = os.environ.get(key, "")
    if value:
        defines[key] = value
json.dump(defines, open(out, "w"), indent=2)
PY
echo "wrote $out"
