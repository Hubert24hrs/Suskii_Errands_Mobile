# S-10 — Concurrent offer acceptance

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code |
| Status | **Passed.** Zero double acceptances across 750 concurrent attempts |
| Harness | `spikes/postgres/S-10/` (branch `spike/phase-0-runs`) |
| Feeds | Risk R-12 (critical), Phase 3 negotiation functions |

## Why this matters

R-12 is one of the eight critical risks: if two providers can both "win" one request, we dispatch two people and may charge twice. The spec requires that accepting an offer locks the request row, expires all other offers and emits realtime events **in one transaction**, with idempotency keys on the operation.

## Environment

Portable PostgreSQL 17.5 (no Docker; see [S-06 results](S-06-results.md) for why). The function under test mirrors the intended production shape: `SECURITY DEFINER`, empty `search_path`, idempotency table, row lock on the request, guarded state transition, sibling-offer expiry and an append-only event.

## What was tested

| Scenario | Attempts | Result |
|---|---|---|
| 20 rounds × 30 callers racing to accept **different** offers on the same request, each with its own key | 600 | Exactly one acceptance every round |
| 5 rounds × 30 callers racing to accept the **same** offer (customer double-tap, flaky-network retry) | 150 | Exactly one acceptance every round |
| Same idempotency key sent 5× concurrently | 5 | One acted, four replayed the stored result |
| Replay of a used key, sequentially | 2 | Second returns the original result with `replayed: true`, no second event |
| Accepting an expired offer | 1 | Rejected, `OFFER_EXPIRED` |
| Accepting a second offer after the request settled | 1 | Rejected, `ILLEGAL_TRANSITION_FROM_PAYMENT_PENDING` |

Invariants asserted after every round: exactly one offer `ACCEPTED`, none left `ACTIVE`, exactly one `OFFER_ACCEPTED` event, request moved to `PAYMENT_PENDING`, and exactly one caller told it succeeded.

`pg_stat_database` reported **0 deadlocks** across the run. Rollbacks are expected and correct: the losing callers raise `ILLEGAL_TRANSITION` or `OFFER_NOT_ACTIVE`.

## The harness was wrong once, and the failure was informative

A mid-run execution reported 12 failed checks, with `0 with duplicate acceptance`. The idempotency keys were reused from an earlier run against the same persistent database, so calls correctly **replayed** prior results — which the assertions read as "more than one caller succeeded".

The function was right; the harness was wrong. Keys are now namespaced per run. The underlying lesson is worth carrying into production: **an idempotency key is only meaningful for one logical attempt**, so clients must generate a fresh key per user action, not per screen or per session. A reused key silently returns a stale result — exactly what it is designed to do.

## Findings for the production implementation

1. **The shape works.** Lock the request row with `FOR UPDATE`, guard the state, accept, expire siblings, write the event, store the idempotency result — all in one transaction. Keep it.
2. **Concurrent identical keys are safe here because of the row lock**, not because of the idempotency check itself. The check-then-insert has a theoretical window: two callers both find no key, both proceed. In this flow the request-row lock serialises them, so the second sees the stored result. For operations with **no such shared lock** (a withdrawal, say), insert the key first with `ON CONFLICT DO NOTHING` and treat "no row inserted" as a replay. Write it that way everywhere, so the pattern does not depend on a lock that a future operation may lack.
3. **Losing callers need a friendly error, not a raw exception.** They currently get `ILLEGAL_TRANSITION_FROM_PAYMENT_PENDING` or `OFFER_NOT_ACTIVE_EXPIRED`. Contracts v1 should map these to stable error codes with localisable messages ("Another provider was just selected"), which is a UI change list item for Kimi.
4. **Events must be exactly once.** The event count assertion is the one that catches an outbox double-fire. Keep it in the permanent tests.

## Carry into Phase 3

These assertions become pgTAP tests, more or less as written:

- exactly one acceptance under N-way contention;
- same-offer contention;
- replay returns the original result without acting again;
- expired offer rejected;
- accept after settlement rejected;
- exactly one event per acceptance.

Then re-run against Supabase, where the pooler and network add failure modes this local test cannot show (statement timeouts, connection resets mid-transaction).

## Carried in, 2026-09-18

`accept_offer` ships in `supabase/migrations/20260918120100_marketplace_offers.sql` with the shape
above — request row lock, guarded transition, sibling expiry, one event, idempotency stored — and
finding 2 applied everywhere: `private.idempotency_claim` inserts the key first and treats "no row
inserted" as a replay, so no operation depends on a lock it may not have.

Of the assertions listed above, all but true N-way contention are now permanent pgTAP tests
(`supabase/tests/database/12_offers_test.sql`): single acceptance, sibling expiry with a reason,
replay without a second event, expired offer rejected, a losing caller told `ERR_OFFER_NOT_ACTIVE`,
exactly one `offer.accepted` event. Concurrency itself needs more than one session, so it stays in
this harness until the load tests run against a real Supabase project with the pooler in front.
