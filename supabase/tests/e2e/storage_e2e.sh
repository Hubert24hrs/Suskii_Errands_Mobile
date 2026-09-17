#!/usr/bin/env bash
# End-to-end proof against a real Storage API (the CLI local stack in CI) that the bucket policies
# behave: a user owns one folder, kyc-docs is write-only for clients, and the service role (the
# backup worker, RB-09) can still read it. pgTAP checks the policy predicates; this checks the
# service that enforces them.
#
# Requires: API_URL, SECRET_KEY (service role) and ANON_KEY from `supabase status -o env`; curl, jq.
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"
ANON_KEY="${ANON_KEY:-${PUBLISHABLE_KEY:-}}"
: "${ANON_KEY:?ANON_KEY or PUBLISHABLE_KEY is required}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
password="storage-e2e-$RANDOM-$RANDOM"
service=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")

check() { # description, actual, expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; failures=$((failures + 1)); fi
}

new_user() { # email prefix -> "<user_id> <access_token>"
  local email="$1-$RANDOM@suskii.test" id token
  id="$(curl -sSf "${service[@]}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p,email_confirm:true}')" \
    "$API_URL/auth/v1/admin/users" | jq -r .id)"
  token="$(curl -sSf -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" \
    "$API_URL/auth/v1/token?grant_type=password" | jq -r .access_token)"
  echo "$id $token"
}

upload() { # bucket, path, token, content-type -> http status
  printf 'not a real photo' > "$tmp/file.bin"
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $3" -H "Content-Type: $4" \
    --data-binary @"$tmp/file.bin" "$API_URL/storage/v1/object/$1/$2"
}

download() { # bucket, path, token -> http status
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $3" "$API_URL/storage/v1/object/$1/$2"
}

read -r alice alice_token <<< "$(new_user alice)"
read -r bob bob_token <<< "$(new_user bob)"

# Buckets come from the migration, not from this script.
buckets="$(curl -sSf "${service[@]}" "$API_URL/storage/v1/bucket")"
check "avatars exists and is private" "$(jq '[.[] | select(.id == "avatars")] | .[0].public' <<< "$buckets")" "false"
check "kyc-docs exists and is private" "$(jq '[.[] | select(.id == "kyc-docs")] | .[0].public' <<< "$buckets")" "false"

check "a user uploads into their own avatar folder" "$(upload avatars "$alice/me.jpg" "$alice_token" image/jpeg)" "200"
check "a user cannot upload into another user's folder" \
  "$([ "$(upload avatars "$bob/evil.jpg" "$alice_token" image/jpeg)" = 200 ] && echo allowed || echo refused)" "refused"
check "an upload outside any user folder is refused" \
  "$([ "$(upload avatars "loose.jpg" "$alice_token" image/jpeg)" = 200 ] && echo allowed || echo refused)" "refused"
check "a content type the bucket does not allow is refused" \
  "$([ "$(upload avatars "$alice/notes.txt" "$alice_token" text/plain)" = 200 ] && echo allowed || echo refused)" "refused"

check "the owner downloads their own avatar" "$(download avatars "$alice/me.jpg" "$alice_token")" "200"
check "another user cannot download it" \
  "$([ "$(download avatars "$alice/me.jpg" "$bob_token")" = 200 ] && echo allowed || echo refused)" "refused"

check "a user uploads their own identity document" "$(upload kyc-docs "$alice/nin-front.jpg" "$alice_token" image/jpeg)" "200"
check "not even the owner can read a kyc document back" \
  "$([ "$(download kyc-docs "$alice/nin-front.jpg" "$alice_token")" = 200 ] && echo allowed || echo refused)" "refused"
check "another user cannot read it either" \
  "$([ "$(download kyc-docs "$alice/nin-front.jpg" "$bob_token")" = 200 ] && echo allowed || echo refused)" "refused"
check "the service role reads it, so backups and review still work" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "${service[@]}" "$API_URL/storage/v1/object/kyc-docs/$alice/nin-front.jpg")" "200"

# A signed URL is how the app shows a private avatar.
signed="$(curl -sS -H "apikey: $ANON_KEY" -H "Authorization: Bearer $alice_token" -H "Content-Type: application/json" \
  -d '{"expiresIn":60}' "$API_URL/storage/v1/object/sign/avatars/$alice/me.jpg" | jq -r '.signedURL // empty')"
if [ -n "$signed" ]; then
  check "a signed URL serves the avatar without a token" \
    "$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/storage/v1$signed")" "200"
else
  echo "FAIL the owner could not create a signed URL for their avatar"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "storage e2e: all checks passed"
