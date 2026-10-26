# Load test, 2026-10-26 — launch profile on staging

| | |
|---|---|
| Run by | Claude Code (go-live item 3: load tests) |
| Project | `suskii-staging`, Supabase **Free** compute (the smallest there is) |
| Harness | `tests/load/db_launch_profile.sql`, one block, every write rolled back |
| Data | 10,000 online providers within about 13 km of central Lagos, fresh heartbeats, one service; 1,110 of them within 5 km of the median query point |
| Targets | Test strategy §5, launch-scale profile |

## Results

Same data, same project, same calls, before and after `…20261026180000_matching_set_based`:

| Path | n | Before p50 / p95 / p99 | After p50 / p95 / p99 | Target | |
|---|---:|---|---|---|---|
| `nearby_providers` | 300 | 67.5 / 72.1 / 537.6 ms | **19.2 / 20.0 / 52.6 ms** | p95 ≤ 50 ms | fail → **pass** |
| `publish_request` + fan-out | 100 | 83.5 / 106.7 / 425.5 ms | **48.6 / 59.8 / 129.1 ms** | p95 ≤ 300 ms | pass |
| `create_offer` | 100 | 3.1 / 4.0 ms | 3.4 / 4.1 ms | p95 ≤ 300 ms | pass |
| `heartbeat` | 300 | 0.3 / 0.4 ms | 0.3 / 0.3 ms | — | |

The answers did not change: 1,110 providers in range, 20 fan-outs per request, 2,000 notifications,
zero offer errors. A separate run compared an inlined form against the current function at 200
points and found no difference in any count.

## Why the nearest-provider query failed

S-06 measured this shape at p95 2–10 ms on local Postgres with 100k providers. On staging it was
seven to thirty times slower, and the cost scaled with the candidates rather than the table: the
query called `private.is_active_provider` and `private.is_blocked_pair` **once per candidate row**.
A SQL function with a `SET` clause (both have `SET search_path = ''`, and `is_blocked_pair` is
also `SECURITY DEFINER`) is never inlined, so 1,110 candidates meant 2,220 function calls a query.
`match_providers` had the same pattern with `is_blocked_pair` and `vehicle_allowed_at`.

The fix writes the checks as joins and anti-joins. Vehicle zones are evaluated once per vehicle
type, at most seven calls, instead of once per candidate. `66_matching_set_based_test` holds both
functions to the definitions they no longer call, so the copies cannot drift without CI saying so.

## What the fix also found

`match_providers` wrote its own provider checks and never had the organisation suspension that
`is_active_provider` gained in Phase 8. So a worker whose business was suspended was still matched,
and was notified about requests they could not bid on. Fixed in the same migration; the test fails
three assertions without it.

## What this did not measure

- **Contention.** One session, one call at a time. At the launch rate the new cost is roughly 1 CPU-second
  a second for `nearby_providers` alone (50 q/s × 20 ms) on the smallest compute, which fits but
  leaves little room. Production should not run on Free compute.
- **The network.** No PostgREST hop and no TLS: add the round trip from Lagos.
- **Realtime and webhooks.** The chat, location broadcast and payment webhook profiles need S-11
  and a gateway respectively.
- **Target scale.** 100k providers at 500 q/s needs an upsized project (test strategy §5), which
  costs money. Not run.
