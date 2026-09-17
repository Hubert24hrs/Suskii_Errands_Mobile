#!/usr/bin/env bash
# Tests for write-remote-config.sh: the generated block parses as TOML, carries the expected
# values, adds optional providers only when configured, and refuses bad input.
# Needs bash and python3 (tomllib, 3.11+).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="$HERE/write-remote-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

REF="abcdefghijklmnopqrst"

fresh() {
  cp "$HERE/../config.toml" "$TMP/config.toml"
}

run() {
  env -i PATH="$PATH" "$@" bash "$WRITER" "$TMP/config.toml" > "$TMP/out.log" 2>&1
}

check() { # description, python expression over `r` (the [remotes.deploy] table)
  if python3 - "$TMP/config.toml" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    r = tomllib.load(f)["remotes"]["deploy"]
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

refuses() { # description, env assignments...
  local description="$1"; shift
  fresh
  if run "$@"; then echo "FAIL $description (accepted)"; failures=$((failures + 1)); else echo "ok   $description"; fi
}

fresh
run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" ADDITIONAL_REDIRECT_URLS="https://a.example.com,suskii://auth"
check "minimal block parses with project, site URL and redirects" \
  "r['project_id'] == '$REF' and r['auth']['site_url'] == 'https://app.example.com' and r['auth']['additional_redirect_urls'] == ['https://a.example.com', 'suskii://auth']"
check "SMS hook points at the deployed function" \
  "r['auth']['hook']['send_sms']['uri'] == 'https://$REF.supabase.co/functions/v1/auth-send-sms'"
check "no CAPTCHA, Google or Apple unless configured" \
  "'captcha' not in r['auth'] and 'external' not in r['auth']"

fresh
run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" \
  GOOGLE_CLIENT_IDS="111-web.apps.googleusercontent.com,222-ios.apps.googleusercontent.com" GOOGLE_SKIP_NONCE_CHECK=true \
  APPLE_CLIENT_IDS="com.suskii.errands,com.suskii.errands.web"
check "Google: client IDs in order, nonce check skipped, no secret for native-only" \
  "r['auth']['external']['google'] == {'enabled': True, 'client_id': '111-web.apps.googleusercontent.com,222-ios.apps.googleusercontent.com', 'skip_nonce_check': True}"
check "Apple: client IDs, no secret for native-only" \
  "r['auth']['external']['apple'] == {'enabled': True, 'client_id': 'com.suskii.errands,com.suskii.errands.web'}"

fresh
run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" SUPABASE_AUTH_CAPTCHA_SECRET=x \
  GOOGLE_CLIENT_IDS="111-web.apps.googleusercontent.com" SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET=x \
  APPLE_CLIENT_IDS="com.suskii.errands" SUPABASE_AUTH_EXTERNAL_APPLE_SECRET=x
check "secrets are env() references, never values" \
  "r['auth']['captcha']['secret'] == 'env(SUPABASE_AUTH_CAPTCHA_SECRET)' and r['auth']['external']['google']['secret'] == 'env(SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET)' and r['auth']['external']['apple']['secret'] == 'env(SUPABASE_AUTH_EXTERNAL_APPLE_SECRET)' and r['auth']['external']['google']['skip_nonce_check'] is False"

fresh
run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" GOOGLE_CLIENT_IDS="111-web.apps.googleusercontent.com"
if grep -q "::warning::Google sign-in is enabled without Sign in with Apple" "$TMP/out.log"; then
  echo "ok   Google without Apple warns"
else
  echo "FAIL Google without Apple warns"; failures=$((failures + 1))
fi

refuses "a project ref that is not 20 letters" SUPABASE_PROJECT_REF="short" SITE_URL="https://app.example.com"
refuses "a non-https site URL" SUPABASE_PROJECT_REF="$REF" SITE_URL="http://app.example.com"
refuses "a Google client ID with a quote (TOML injection)" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" \
  GOOGLE_CLIENT_IDS='x.apps.googleusercontent.com"
enabled = false'
refuses "a redirect URL with a quote (TOML injection)" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" \
  ADDITIONAL_REDIRECT_URLS='https://a.example.com"]'
refuses "a redirect URL with a backslash" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" \
  ADDITIONAL_REDIRECT_URLS='https://a.example.com"'
refuses "a non-Google client ID" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" GOOGLE_CLIENT_IDS="abc"
refuses "a bad skip-nonce value" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" \
  GOOGLE_CLIENT_IDS="1-a.apps.googleusercontent.com" GOOGLE_SKIP_NONCE_CHECK=yes
refuses "an Apple client ID with spaces" SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com" APPLE_CLIENT_IDS="com.a b"

fresh
run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com"
if run SUPABASE_PROJECT_REF="$REF" SITE_URL="https://app.example.com"; then
  echo "FAIL a second block is refused"; failures=$((failures + 1))
else
  echo "ok   a second block is refused"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
