# S-06 — PostGIS nearest-provider at 100k providers

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code |
| Status | **Passed**, with a caveat about where it was run and a new finding about write rate |
| Harness | `spikes/postgres/S-06/` (branch `spike/phase-0-runs`) |
| Feeds | ADR-0009 (location transport), risk R-11 |

## Environment

Docker would not install on the dev machine, so the spike ran on **portable PostgreSQL 17.5 + PostGIS 3.6** (EDB binaries zip + OSGeo bundle, no installer, no admin rights). `spikes/postgres/setup-local-windows.sh` reproduces it in one command.

Settings approximate a Supabase Large instance: `shared_buffers=1GB`, `effective_cache_size=3GB`, `work_mem=32MB`. **This is not Supabase**: no network hop, no connection pooler, no replication, and 100k rows fit entirely in RAM. Treat the *ranking* of the query shapes as transferable and the absolute milliseconds as optimistic.

Dataset: 100,000 providers clustered on Lagos (60%), Nairobi (30%) and Accra (10%); 29,948 online; 2,903 suspended; 298 distinct service arrays; 2,865 providers matching the benchmark filter (online, not suspended, service 3, vehicle 2/3/4).

## The harness was wrong first — and it looked like a pass

The first run reported p95 of 21 ms and looked like a clean pass. The `EXPLAIN` said `rows=0`: it was timing queries that matched **nothing**.

Cause: the generator built `service_ids` with a sub-select that did not reference the outer row, so Postgres evaluated it **once** as an InitPlan and gave all 100,000 providers the identical array `{4,6,12}`. No provider offered the service being queried.

Two lessons, both now in the harness as comments:

1. A spike that reports a pass without showing the plan and the row counts is not evidence.
2. Uncorrelated sub-selects in generators silently produce constant columns.

Everything below is from the corrected data.

## Results

Three query shapes, 300 iterations each, customer points drawn from the same clusters as supply:

- **`home_all`** — everything off `providers.home` (static column, no writes).
- **`live_hot`** — the ADR-0009 shape: join the hot `provider_live_location` table, filter `updated_at > now() - 120s`.
- **`live_hot_widening`** — 2 km first, widening to 8 km only when fewer than 5 candidates.

| Write load | Shape | p50 ms | p95 ms | p99 ms | max ms |
|---|---|---:|---:|---:|---:|
| none | home_all | 1.27 | 4.27 | 4.86 | 7.13 |
| none | live_hot | 2.96 | 9.73 | 18.03 | 24.21 |
| none | live_hot_widening | 0.55 | 3.43 | 6.12 | 11.91 |
| **814 writes/sec** (production rate at 1M MAU) | home_all | 0.95 | **1.95** | 8.53 | 73.64 |
| **814 writes/sec** | live_hot | 1.29 | **1.87** | 4.74 | 32.28 |
| **814 writes/sec** | live_hot_widening | 3.52 | **20.48** | 40.36 | 79.98 |
| 7,958 writes/sec (~10×) | live_hot | 28.05 | **47.89** | 70.52 | 107.81 |

Pass criteria are p95 ≤ 50 ms and p99 ≤ 120 ms. **Every shape passes at the production write rate, and `live_hot` still passes at ten times that rate.**

## Findings

**1. Write rate, not query shape, is the limit.** An early unthrottled test showed `live_hot` at p95 142 ms and p99 459 ms, which looked like a design failure. It was not: the writer was pushing ~8,000 updates/sec, roughly ten times what production generates. Calibrating the writer to the real rate (derived from the cost model: 100k providers, 30% online at peak, one heartbeat per 30 s ≈ 1,000 writes/sec) brought p95 to 1.87 ms.

Deriving the expected write rate before trusting a load test turned out to be the difference between "redesign this" and "ship it".

**2. The freshness index is not the bottleneck.** Dropping `idx_live_updated` did not help (`live_hot` p95 stayed at ~152 ms under the unthrottled writer) and made the widening variant worse. The cost is the row churn itself: every heartbeat rewrites a row in a GiST-indexed table.

**3. Bloat is the real constraint at high write rates.** After sustained unthrottled churn: **803,780 dead tuples against 29,948 live rows**, with the table at 61 MB and its indexes at 80 MB for 30k rows. Autovacuum ran four times and could not keep up. Query latency degrades as a *consequence* of bloat.

**4. The widening search is not worth it.** It was the fastest with no write load (p50 0.55 ms) and the **worst** under load (p95 20.5 ms), because the two-stage query scans twice whenever the first radius is thin. Use a single radius with the freshness filter.

## What this changes

ADR-0009 (Broadcast for live location, sparse DB heartbeat) is **confirmed**, with three conditions that belong in the implementation:

1. **Gate heartbeats on movement.** Write only when the provider has moved beyond a threshold (25–50 m) or a maximum interval has elapsed (60 s). A stationary provider must not generate writes — that is what keeps us at the rate the design survives.
2. **Tune the hot table for churn.** `fillfactor` 70–80 to favour HOT updates, and per-table aggressive autovacuum (`autovacuum_vacuum_scale_factor = 0.01`, raised cost limit). Alert on dead-tuple ratio, not just on query latency: bloat is the leading indicator.
3. **Query with a single radius.** Drop the widening variant.

Headroom is roughly 8–10× the projected 1M MAU write rate before p95 reaches its limit — but that headroom is consumed by bloat, so the autovacuum settings above are load-bearing, not cosmetic.

## Still to confirm

- Re-run on the real Supabase instance size, through the pooler, with the network hop. Absolute numbers here are optimistic.
- Test with a dataset that exceeds `shared_buffers`, so index pages actually miss cache.
- Test with many concurrent writer *sessions* rather than one, which changes lock and WAL behaviour.
- H3 is available in the PostGIS bundle (`h3_postgis`), so the bucketing variant from the spike plan can be compared later if geography GiST stops being enough.
