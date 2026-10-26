# Load tests

Test strategy §5. Two kinds, and only the first exists yet.

## `db_launch_profile.sql`: the database paths, at launch scale, on a real project

One `DO` block that seeds 10,000 online providers around Lagos with fresh heartbeats and one
verified customer, times the database-heavy paths one call at a time, and **ends by raising its
measurements, so every write rolls back**. Nothing is left behind, which makes it safe on staging:

| Path | Calls | Target (§5) |
|---|---:|---|
| `nearby_providers` (the customer's map) | 300 | p95 ≤ 50 ms |
| `publish_request`, with the fan-out its trigger runs synchronously (20 providers, 20 notifications) | 100 | p95 ≤ 300 ms |
| `create_offer` from a matched provider | 100 | p95 ≤ 300 ms |
| `heartbeat` | 300 | — (S-06 covers the write rate) |

```bash
npx supabase@2.117.0 db query --linked --project-ref <ref> --output-format json --agent no -f tests/load/db_launch_profile.sql
```

The result is the error message: `BENCH_RESULT {…}`. An error is the only way out of a `DO` block
that also undoes everything it did.

**What it does not measure.** It is one session, so it measures cost per call, not contention. It
has no network hop or PostgREST, so add the round trip. Realtime (chat, location broadcast) and
payment webhooks are not in it, and spike S-11 must run before the Realtime profiles are trusted.

## Target scale and HTTP load: not yet

The target-scale profile (100k providers, 500 q/s, heartbeats at 814 writes/s) needs a project
upsized to production compute (§5), which costs money and needs the owner's yes. The k6 HTTP
suite needs test users that can sign in on that project. **Owner's decision, 2026-10-26: run both on
the production-sized project before launch** (timeline row 19), not on an upsized staging.

## Runs

| Date | Project | Result |
|---|---|---|
| 2026-10-26 | Staging (`suskii-staging`, Supabase Free compute) | [Record](../../docs/research/load-2026-10-26-launch-profile.md): `nearby_providers` p95 72 ms failed the 50 ms target; fixed by `…20261026180000_matching_set_based` to p95 20 ms |
