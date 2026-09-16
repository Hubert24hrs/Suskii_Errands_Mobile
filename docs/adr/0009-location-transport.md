# ADR-0009 — Live location travels over Realtime Broadcast; the database gets a sparse heartbeat

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | Validated by spike S-11 (realtime side). Database side measured in [S-06](../research/spikes/S-06-results.md) on 2026-09-16 |

## Context

The spec requires live tracking with realtime delivery under one second, says location pings must not write a database row each time, and asks us to persist only sampled points for history and disputes.

Two cost and load facts shape the design. Supabase bills Realtime messages above the plan allowance, and tracking dominates the message count: at five-second pings a 40-minute job produces roughly 960 messages once send and receive are both counted, which is about $3,700/month at 1M MAU. Separately, matching needs a current position for every online provider, and writing that to Postgres on every ping would mean hundreds of writes per second at scale.

## Decision

We will carry live position over Realtime **Broadcast** on a private per-job channel (`job:{id}`), authorised by RLS on `realtime.messages`, with no database write per ping. Matching reads a separate hot table updated by a **sparse heartbeat RPC** (target every 30–60 seconds, and only when the provider has moved beyond a threshold), not by the tracking stream. For history and disputes we persist a sampled trail (about every 30 seconds while en route) into a partitioned table with a 90-day retention. Ping cadence is remote config: faster en route, slower idle, and backed off on poor networks. Mock-location flags travel with each ping and are recorded on the trail.

## Measured evidence (S-06, 2026-09-16)

Benchmarked at 100k providers / 30k online on portable Postgres 17.5 + PostGIS 3.6:

- At the production write rate for 1M MAU (**814 updates/sec measured**), the hot-table query runs at **p95 1.87 ms, p99 4.74 ms** - far inside the 50 ms target.
- At ~8,000 updates/sec (10x production) it reaches p95 47.9 ms, i.e. the edge of the target. Headroom is roughly 8-10x.
- The limit is **row churn and bloat**, not the query: sustained high-rate churn left 803,780 dead tuples against 29,948 live rows. Dropping the freshness index did not help.
- The widening two-radius search was the worst shape under load and is dropped.

**Three conditions this adds to the decision:**

1. Heartbeats are **movement-gated**: write only after ~25-50 m of movement or a 60 s maximum interval. A stationary provider generates no writes.
2. The hot table gets `fillfactor` 70-80 and per-table aggressive autovacuum (`autovacuum_vacuum_scale_factor = 0.01`, raised cost limit).
3. Monitoring alerts on **dead-tuple ratio**, not only query latency - bloat is the leading indicator.

## Consequences

**Good:** realtime cost and database write load are decoupled from ping frequency; tracking stays smooth on the client while the database sees a fraction of the traffic; the dispute evidence trail is still there.

**Bad / costs:** position for matching can be up to a minute stale, so the matching query must treat freshness as a ranking input; two paths (broadcast and heartbeat) must stay consistent.

**Follow-on work:** channel naming and authorisation in the realtime-events contract; heartbeat RPC with rate limiting; partitioning and retention jobs; S-11 confirms delivery p95 and reconnect behaviour.

## Alternatives considered

| Option | Why not |
|---|---|
| Write every ping to Postgres and stream via Postgres Changes | Hundreds of writes per second at scale, higher latency, and a much larger table |
| Broadcast only, no heartbeat | Matching would have no current position for providers who are online but not on a job |
| Third-party location pipeline | Another vendor and another data-residency question for high-sensitivity data |

## Revisit when

S-11 fails its delivery or reconnect targets, Realtime pricing changes materially, or matching needs sub-30-second freshness.
