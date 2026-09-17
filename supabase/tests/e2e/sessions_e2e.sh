#!/usr/bin/env bash
# End-to-end proof against a real GoTrue (the CLI local stack in CI) that revoking a session
# actually stops it: the revoked session's refresh token is rejected, the caller's own keeps
# working. pgTAP can only show the rows disappear — this shows what that means to a signed-in app.
#
# Requires: API_URL, SECRET_KEY (service role) and ANON_KEY from `supabase status -o env`; curl, jq.
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"
# The CLI has used both names for the public key.
ANON_KEY="${ANON_KEY:-${PUBLISHABLE_KEY:-}}"
: "${ANON_KEY:?ANON_KEY or PUBLISHABLE_KEY is required}"

email="sessions-e2e-$RANDOM@suskii.test"
password="e2e-$RANDOM-$RANDOM-pw"
service=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")
anon=(-H "apikey: $ANON_KEY")
failures=0

check() { # description, actual, expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; failures=$((failures + 1)); fi
}

user_id="$(curl -sSf "${service[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p,email_confirm:true}')" \
  "$API_URL/auth/v1/admin/users" | jq -r .id)"
[ -n "$user_id" ] && [ "$user_id" != "null" ] || { echo "could not create the test user"; exit 1; }

sign_in() { # -> "<access_token> <refresh_token>"
  curl -sSf "${anon[@]}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" \
    "$API_URL/auth/v1/token?grant_type=password" | jq -r '.access_token + " " + .refresh_token'
}

read -r old_access old_refresh <<< "$(sign_in)"
read -r new_access new_refresh <<< "$(sign_in)"

rpc() { # method, body, access token -> body
  curl -sS "${anon[@]}" -H "Authorization: Bearer $3" -H "Content-Type: application/json" \
    -d "${2:-{\}}" "$API_URL/rest/v1/rpc/$1"
}

listed="$(rpc list_sessions '{}' "$new_access")"
check "both sign-ins are listed" "$(jq 'length' <<< "$listed")" "2"
check "exactly one session is current" "$(jq '[.[] | select(.is_current)] | length' <<< "$listed")" "1"
current_id="$(jq -r '[.[] | select(.is_current)][0].id' <<< "$listed")"
check "the current session has an id" "$([ -n "$current_id" ] && [ "$current_id" != null ] && echo yes)" "yes"
check "a session carries its user agent" "$(jq '[.[] | select(.user_agent != null)] | length > 0' <<< "$listed")" "true"

# The refresh token of the older session works before revocation.
before="$(curl -sS -o /dev/null -w '%{http_code}' "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$old_refresh" '{refresh_token:$t}')" "$API_URL/auth/v1/token?grant_type=refresh_token")"
check "the other session can refresh before revocation" "$before" "200"

revoked="$(rpc revoke_other_sessions '{}' "$new_access")"
check "sign out everywhere else removed one session" "$revoked" "1"

after="$(curl -sS -o /dev/null -w '%{http_code}' "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$old_refresh" '{refresh_token:$t}')" "$API_URL/auth/v1/token?grant_type=refresh_token")"
check "the revoked session can no longer refresh" "$([ "$after" = 200 ] && echo refreshed || echo refused)" "refused"

mine="$(curl -sS -o /dev/null -w '%{http_code}' "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$new_refresh" '{refresh_token:$t}')" "$API_URL/auth/v1/token?grant_type=refresh_token")"
check "the caller's own session still refreshes" "$mine" "200"

# A second user cannot revoke this user's session.
other_email="sessions-e2e-other-$RANDOM@suskii.test"
curl -sSf "${service[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$other_email" --arg p "$password" '{email:$e,password:$p,email_confirm:true}')" \
  "$API_URL/auth/v1/admin/users" > /dev/null
other_access="$(curl -sSf "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$other_email" --arg p "$password" '{email:$e,password:$p}')" \
  "$API_URL/auth/v1/token?grant_type=password" | jq -r .access_token)"
foreign="$(rpc revoke_session "$(jq -n --arg id "$current_id" '{p_session_id:$id}')" "$other_access")"
check "another user gets ERR_SESSION_NOT_FOUND" "$(jq -r .message <<< "$foreign")" "ERR_SESSION_NOT_FOUND"

still="$(curl -sS -o /dev/null -w '%{http_code}' "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$new_refresh" '{refresh_token:$t}')" "$API_URL/auth/v1/token?grant_type=refresh_token")"
check "the targeted session survived the foreign attempt" "$still" "200"

# Best effort: the stack is thrown away with the job, and GoTrue can answer 500 when deleting a
# user that still has sessions or identities.
curl -sS "${service[@]}" -X DELETE "$API_URL/auth/v1/admin/users/$user_id" > /dev/null || true

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "sessions e2e: all checks passed"
