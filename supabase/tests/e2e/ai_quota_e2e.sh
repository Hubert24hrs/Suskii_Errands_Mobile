#!/usr/bin/env bash
# End-to-end proof that Ask Suskii's allowance holds under concurrency (20261103120200): twelve
# messages sent at once by one signed-in person, through the real API, against an allowance of
# three. Before the reservation lock, all twelve were let through. pgTAP cannot show this: one
# transaction cannot race itself.
#
# Requires: API_URL, SECRET_KEY (service role) and ANON_KEY from `supabase status -o env`; curl, jq.
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"
ANON_KEY="${ANON_KEY:-${PUBLISHABLE_KEY:-}}"
: "${ANON_KEY:?ANON_KEY or PUBLISHABLE_KEY is required}"

email="ai-quota-e2e-$RANDOM@suskii.test"
password="e2e-$RANDOM-$RANDOM-pw"
service=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY" -H "Content-Type: application/json")
anon=(-H "apikey: $ANON_KEY")
failures=0
allowance=3
senders=12

check() { # description, actual, expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; failures=$((failures + 1)); fi
}

user_id="$(curl -sSf "${service[@]}" \
  -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p,email_confirm:true}')" \
  "$API_URL/auth/v1/admin/users" | jq -r .id)"
[ -n "$user_id" ] && [ "$user_id" != "null" ] || { echo "could not create the test user"; exit 1; }
token="$(curl -sSf "${anon[@]}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" \
  "$API_URL/auth/v1/token?grant_type=password" | jq -r .access_token)"

# The switch on and the cooldown off, put back as they were on the way out.
flag_before="$(curl -sSf "${service[@]}" \
  "$API_URL/rest/v1/feature_flags?key=eq.concierge.text&country_code=is.null&select=enabled" | jq -r '.[0].enabled')"
limits_before="$(curl -sSf "${service[@]}" \
  "$API_URL/rest/v1/remote_config?key=eq.ai.limits.concierge&country_code=is.null&select=value" | jq -c '.[0].value')"
restore() {
  curl -sS -o /dev/null "${service[@]}" -X PATCH -d "{\"enabled\": $flag_before}" \
    "$API_URL/rest/v1/feature_flags?key=eq.concierge.text&country_code=is.null"
  curl -sS -o /dev/null "${service[@]}" -X PATCH -d "{\"value\": $limits_before}" \
    "$API_URL/rest/v1/remote_config?key=eq.ai.limits.concierge&country_code=is.null"
}
trap restore EXIT
curl -sSf -o /dev/null "${service[@]}" -X PATCH -d '{"enabled": true}' \
  "$API_URL/rest/v1/feature_flags?key=eq.concierge.text&country_code=is.null"
curl -sSf -o /dev/null "${service[@]}" -X PATCH \
  -d "$(jq -n --argjson v "$limits_before" '{value: ($v + {cooldown_seconds: 0})}')" \
  "$API_URL/rest/v1/remote_config?key=eq.ai.limits.concierge&country_code=is.null"
curl -sSf -o /dev/null "${service[@]}" -X PATCH -d '{"country_code": "NG"}' \
  "$API_URL/rest/v1/profiles?user_id=eq.$user_id"
curl -sSf -o /dev/null "${service[@]}" \
  -d "$(jq -n --arg u "$user_id" --argjson n "$allowance" '{user_id:$u, daily_limit_override:$n}')" \
  "$API_URL/rest/v1/ai_usage_accounts"

rpc() { # name, body -> body
  curl -sS "${anon[@]}" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "$2" "$API_URL/rest/v1/rpc/$1"
}
conversation="$(rpc concierge_start '{"p_idempotency_key": "e2e-ai-quota-start-0001"}' | jq -r '.[0].id')"
[ -n "$conversation" ] && [ "$conversation" != "null" ] || { echo "could not open a conversation"; exit 1; }

out="$(mktemp -d)"
for i in $(seq 1 "$senders"); do
  rpc concierge_begin_turn "$(jq -n --arg c "$conversation" --arg k "e2e-ai-quota-turn-$(printf %06d "$i")" \
    '{p_conversation_id:$c, p_idempotency_key:$k}')" > "$out/$i.json" &
done
wait

reserved="$(cat "$out"/*.json | jq -s '[.[] | select(.reserved == true)] | length')"
refused="$(cat "$out"/*.json | jq -s '[.[] | select(.limited == "day")] | length')"
errors="$(cat "$out"/*.json | jq -s '[.[] | select(.code != null or .message != null)] | length')"
rm -rf "$out"
check "every message got an answer, none an error" "$errors" "0"
check "exactly the allowance was reserved" "$reserved" "$allowance"
check "and every other message was told the day's limit is reached" "$refused" "$((senders - allowance))"
rows="$(curl -sSf "${service[@]}" "$API_URL/rest/v1/ai_usage?user_id=eq.$user_id&select=status" | jq 'length')"
check "the ledger holds one row per reserved message" "$rows" "$allowance"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "ai quota end to end: all checks passed"
