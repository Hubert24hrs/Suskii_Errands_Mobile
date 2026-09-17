# ADR-0014 — Build the marketplace core before contracts v1

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-18 |
| Supersedes | — |
| Extends | [ADR-0013](0013-backend-foundation-before-contracts-v1.md) |

## Context

Phase 2 (backend foundation) is finished and everything left in it waits on someone else: client
accounts for deploys, a vendor decision for SMS, a DeviceCheck key for Apple's fraud metric, a
domain decision for Cloudflare and Sentry. Phase 3 (marketplace core) is the launch critical path.

The spec orders Phase 3 after contracts v1, and contracts v1 waits for Kimi Code's M8.5 hand-off —
by the current timeline around W7 (2 November 2026). Waiting would leave the backend idle for weeks
on the one path that decides the launch date.

Two things changed since that order was written:

1. **The design is already fixed in Phase 1.** The ERD, the job lifecycle, the offer and negotiation
   state machine and the RLS matrix are written and reviewed. Contracts v1 will be *derived* from
   these tables, not the other way round.
2. **The shapes are visible from both sides.** Kimi Code's domain package and mock repositories
   (M3, committed) show exactly what the apps send and expect, and `contracts/v1-preview` already
   pins the error codes, enums and money shape, with CI enforcing the match.

ADR-0013 set the precedent for the foundation, on the condition that pre-contract migrations stay
editable until a shared environment applies them. No shared environment exists yet.

## Decision

Build the marketplace core now, in the order of the state machines: service taxonomy and requests
first, then offers and negotiation, then matching, then the job lifecycle.

The conditions from ADR-0013 carry over unchanged:

- **Migrations stay editable in place** until the first shared environment applies them. The moment
  a Supabase project runs `db push`, editability ends and changes become new migrations.
- **Every new error code and enum value lands in `contracts/v1-preview` in the same change**, where
  CI checks it against the code that raises it.
- **Names follow the ERD and Kimi Code's domain package**, so contracts v1 is a description of what
  exists rather than a renaming exercise.

What this does *not* license: anything the state machines leave open, anything that needs an open
decision answered (money rules, OD-06, OD-08, OD-19), or vendor APIs that are not verified.

## Consequences

**Good.** The critical path moves while the frontend is still on mocks. Kimi Code can start calling
real functions at M9 against something that exists. Contracts v1 becomes a writing-up exercise over
working code, which is faster and more honest than the reverse.

**Cost.** Some churn is likely where the apps discover a field the backend named differently; the
preview's drift check and `HANDOFF.md` are where that gets settled, and migrations remain editable
until deployment.

**Risk.** Building state machines before the money rules are answered invites rework in Phase 5. The
mitigation is scope: the pre-money states only (draft, published, offers, negotiation, agreement),
and no cancellation-fee or refund logic until OD-08 and OD-19 come back.
