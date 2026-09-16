# ADR-0004 — Build the payment adapter on Flutterwave v3, not the v4 beta

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | — |

## Context

The Flutterwave v4 API is in public beta with OAuth 2.0, a dedicated sandbox and new orchestrator charge and transfer flows [S]. v3 is the generally available generation and is what the mobile money, transfers and settlement documentation describes [V]. Money flows land in Phase 5, and we cannot absorb beta-surface churn on the path that moves customer funds.

## Decision

We will implement the `PaymentProvider` adapter against Flutterwave **v3**, keeping every Flutterwave detail behind that interface: charge creation, webhook verification, server-side verification, refunds, transfers and settlement reads. We will track v4 and migrate only after it is GA and a spike has replayed our full flow against it. Paystack sits behind the same interface as the second African rail.

## Consequences

**Good:** a stable, documented surface; the adapter shields the rest of the system from generation changes.

**Bad / costs:** v3 lacks the OAuth and sandbox conveniences of v4; we carry a migration later.

**Follow-on work:** adapter interface in contracts v1; webhook signature and replay tests; a v4 migration spike when GA lands.

## Alternatives considered

| Option | Why not |
|---|---|
| Start on v4 now | Public beta; breaking changes land outside our control on the money path |
| Support both generations at once | Doubles the surface to test for no launch benefit |

## Revisit when

v4 reaches GA with a migration guide, or v3 gets a deprecation date.
