#!/usr/bin/env bash
# S-10 — hammer accept_offer() concurrently and assert the invariants.
#
# Works against any Postgres. Set PSQL to how you reach it:
#   Docker:      export PSQL="docker compose exec -T db psql -U postgres -d spike -qAt"
#   Local/portable: export PSQL="/path/to/psql -h 127.0.0.1 -p 55432 -U postgres -d spike -qAt"
#   (local needs PGPASSWORD exported, or a .pgpass entry)
# Defaults to the Docker form.
#
# Usage: ./race.sh [rounds] [concurrency]
set -uo pipefail

ROUNDS="${1:-25}"
CONC="${2:-20}"
PSQL="${PSQL:-docker compose exec -T db psql -U postgres -d spike -qAt}"
# Idempotency keys must be unique per run. The database persists between runs, so a reused
# key correctly replays the previous result - which looks like a failure but is not.
RUN_ID="${RUN_ID:-$(date +%s)-$$}"

fail=0
dupes=0

run_sql() { $PSQL -c "$1" 2>&1; }

echo "S-10: $ROUNDS rounds x $CONC concurrent accepts"
echo "psql: $PSQL"
echo "run id: $RUN_ID"

for round in $(seq 1 "$ROUNDS"); do
  req=$(run_sql "SELECT seed_race($CONC);" | tr -d '[:space:]')
  case "$req" in (''|*[!0-9]*) echo "round $round: seed failed -> $req"; fail=$((fail+1)); continue;; esac

  # Every caller races to accept a DIFFERENT offer on the SAME request, each with its
  # own idempotency key: the worst case for the lock.
  tmp=$(mktemp -d)
  for i in $(seq 1 "$CONC"); do
    (
      offer=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1 OFFSET $((i-1));" | tr -d '[:space:]')
      run_sql "SELECT accept_offer($req, $offer, 'race-$RUN_ID-$round-$i');" > "$tmp/$i.out"
    ) &
  done
  wait

  ok=$(grep -l '"ok": true' "$tmp"/*.out 2>/dev/null | wc -l | tr -d ' ')
  accepted=$(run_sql "SELECT count(*) FROM offers WHERE request_id=$req AND status='ACCEPTED';" | tr -d '[:space:]')
  active=$(run_sql "SELECT count(*) FROM offers WHERE request_id=$req AND status='ACTIVE';" | tr -d '[:space:]')
  events=$(run_sql "SELECT count(*) FROM job_events WHERE request_id=$req AND event='OFFER_ACCEPTED';" | tr -d '[:space:]')
  status=$(run_sql "SELECT status FROM requests WHERE id=$req;" | tr -d '[:space:]')

  # Invariants: exactly one offer accepted, none left active, exactly one event,
  # request moved on, and exactly one caller was told it succeeded.
  if [ "$accepted" != "1" ] || [ "$active" != "0" ] || [ "$events" != "1" ] \
     || [ "$status" != "PAYMENT_PENDING" ] || [ "$ok" != "1" ]; then
    echo "round $round FAIL: accepted=$accepted active=$active events=$events status=$status ok_returns=$ok"
    fail=$((fail+1))
    [ "$accepted" != "1" ] && dupes=$((dupes+1))
  fi
  rm -rf "$tmp"
done

echo
echo "--- same-offer contention (customer double-tap / retry on flaky network) ---"
# Different keys, SAME offer: only the first may act; the rest must be refused, not silently re-run.
for round in $(seq 1 5); do
  req=$(run_sql "SELECT seed_race(5);" | tr -d '[:space:]')
  offer=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1;" | tr -d '[:space:]')
  tmp=$(mktemp -d)
  for i in $(seq 1 "$CONC"); do
    ( run_sql "SELECT accept_offer($req, $offer, 'same-$RUN_ID-$round-$i');" > "$tmp/$i.out" ) &
  done
  wait
  ok=$(grep -l '"ok": true' "$tmp"/*.out 2>/dev/null | wc -l | tr -d ' ')
  events=$(run_sql "SELECT count(*) FROM job_events WHERE request_id=$req AND event='OFFER_ACCEPTED';" | tr -d '[:space:]')
  if [ "$ok" != "1" ] || [ "$events" != "1" ]; then
    echo "same-offer round $round FAIL: ok_returns=$ok events=$events"
    fail=$((fail+1))
  fi
  rm -rf "$tmp"
done
echo "same-offer contention: $((5 * CONC)) attempts checked"

echo
echo "--- idempotent replay ---"
req=$(run_sql "SELECT seed_race(3);" | tr -d '[:space:]')
offer=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1;" | tr -d '[:space:]')
first=$(run_sql "SELECT accept_offer($req, $offer, 'replay-$RUN_ID');")
second=$(run_sql "SELECT accept_offer($req, $offer, 'replay-$RUN_ID');")
echo "first : $first"
echo "second: $second"
events=$(run_sql "SELECT count(*) FROM job_events WHERE request_id=$req AND event='OFFER_ACCEPTED';" | tr -d '[:space:]')
echo "events after replay (must be 1): $events"
[ "$events" != "1" ] && fail=$((fail+1))
echo "$second" | grep -q '"replayed": true' || { echo "replay flag missing"; fail=$((fail+1)); }

echo
echo "--- expired offer is rejected ---"
req=$(run_sql "SELECT seed_race(2);" | tr -d '[:space:]')
offer=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1;" | tr -d '[:space:]')
run_sql "UPDATE offers SET expires_at = now() - interval '1 second' WHERE id=$offer;" >/dev/null
out=$(run_sql "SELECT accept_offer($req, $offer, 'expired-$RUN_ID');")
echo "$out" | grep -q 'OFFER_EXPIRED' || { echo "expired offer was NOT rejected: $out"; fail=$((fail+1)); }
echo "expired offer rejected as expected"

echo
echo "--- second accept on a settled request is rejected ---"
req=$(run_sql "SELECT seed_race(3);" | tr -d '[:space:]')
o1=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1;" | tr -d '[:space:]')
o2=$(run_sql "SELECT id FROM offers WHERE request_id=$req ORDER BY id LIMIT 1 OFFSET 1;" | tr -d '[:space:]')
run_sql "SELECT accept_offer($req, $o1, 'settle-$RUN_ID-1');" >/dev/null
out=$(run_sql "SELECT accept_offer($req, $o2, 'settle-$RUN_ID-2');")
echo "$out" | grep -q 'ILLEGAL_TRANSITION' || { echo "late accept was NOT rejected: $out"; fail=$((fail+1)); }
echo "late accept rejected as expected"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: no double acceptance in $((ROUNDS * CONC)) concurrent attempts"
else
  echo "FAIL: $fail checks failed ($dupes with duplicate acceptance)"
fi
exit "$fail"
