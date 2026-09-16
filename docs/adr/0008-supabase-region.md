# ADR-0008 — Host Supabase in London (eu-west-2), provisionally

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | Spike S-01 (latency), counsel on residency (OD-15) |
| Measurement status | First S-01 run 2026-09-16 was inconclusive: the dev machine is behind a European VPN, so its ordering reflects the egress, not Lagos. See [S-01-results.md](../research/spikes/S-01-results.md) |

## Context

The spec asks us to pick the Supabase region by measured latency from Lagos, Nairobi, Johannesburg and Cairo, and by data-residency rules. Phase 0 confirmed that **Supabase has no African region**: Cape Town is not offered for new projects, and the region list covers the Americas, Europe and APAC only [V]. Supabase also notes that region choice is a data-location control, not a compliance guarantee [V].

So every user action crosses a submarine cable. West African cables (MainOne, Equiano, 2Africa) land in Portugal and the UK, while East African routes favour Marseille, which makes London and Paris the two credible candidates [A]. Kenya has local-copy expectations for some processing and Ghana has a pending bill that would localise biometric data [S].

## Decision

We will provision dev, staging and production in **London (`eu-west-2`)** as the provisional choice, and confirm or change it with spike S-01 before any production data exists. Because latency is structural, the architecture compensates: one round trip per user action (RPCs compose server-side), Realtime Broadcast for live location, cached read-mostly config, and optimistic UI reconciled by the server. Biometric templates stay vendor-side and KYC files stay encrypted, so the residency exposure is limited to identifiers and transaction records. If counsel requires in-country copies, the fallback is self-hosted Supabase in `af-south-1` or GCP `africa-south1`, which is costed in the vendor matrix.

## Consequences

**Good:** managed platform with read replicas, PITR and backups; a single primary keeps the ledger and state machine simple.

**Bad / costs:** structural round-trip latency for every African user; the 300 ms RPC p95 target has little headroom; a residency ruling could force a migration.

**Follow-on work:** S-01 measurements; a latency budget per screen for Kimi; read-replica placement; a documented migration path to self-hosting.

## Alternatives considered

| Option | Why not |
|---|---|
| Paris (`eu-west-3`) | Plausible winner for East Africa; S-01 decides between it and London |
| Frankfurt / Ireland | Longer paths to West Africa on current evidence |
| Mumbai (`ap-south-1`) | Only helps East Africa and hurts Lagos, our first market |
| Self-host in Africa now | Best residency and latency, but we would operate Postgres, Realtime and Auth ourselves from day one |

## Revisit when

S-01 measurements land, Supabase announces an African region, or counsel requires in-country storage for a live country.
