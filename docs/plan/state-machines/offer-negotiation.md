# Offer and negotiation state machine

| | |
|---|---|
| Owner | Claude Code |
| Date | 2026-09-16 |
| Status | Phase 1 draft — becomes `contracts/state-machines/` at M8.5 |
| Evidence | Spec `negotiation_engine`, `job_lifecycle`; spike [S-10](../../research/spikes/S-10-results.md) |

> **Naming.** States are written `UPPER_SNAKE` here, as in the spec. Database and wire values are lower `snake_case` (`offers_received`), per [erd.md](../erd.md#conventions); Dart enums map them.

> **Reconciled 2026-09-16** with Kimi's `OfferStatus` enum: this draft first used `ACTIVE`/`REJECTED`; it now uses Kimi's `PENDING`/`DECLINED` so the domain package does not change.

Negotiation is the product's differentiator (Phase 0 §1: inDrive's model, at a 12.5% take rate against incumbents' 15–30%). It is also where money and fairness meet, so the rules are strict.

## Offer states

| State | Meaning |
|---|---|
| `PENDING` | Live, within TTL, awaiting the counterparty (`pending` in Kimi's `OfferStatus`) |
| `COUNTERED` | Superseded by a counter-offer in the same thread |
| `ACCEPTED` | Won the request — exactly one per request, ever |
| `DECLINED` | Declined explicitly by the counterparty (`declined` in Kimi's `OfferStatus`) |
| `WITHDRAWN` | Pulled by its author before acceptance |
| `EXPIRED` | TTL elapsed, or a sibling offer was accepted |

## Transitions

| # | From | To | Actor | Guard | Side effects |
|---|---|---|---|---|---|
| 1 | — | `PENDING` | Provider | Provider eligible; request `PUBLISHED`/`OFFERS_RECEIVED`/`NEGOTIATING`; **not self-dealing**; amount within guardrails; provider has no unresolved blocking job | Notify customer; request → `OFFERS_RECEIVED`; start TTL |
| 2 | `PENDING` | `COUNTERED` | C or P | Round count < max (default 5); author is the counterparty, not the same side twice | New `PENDING` offer in the thread; request → `NEGOTIATING`; TTL resets |
| 3 | `PENDING` | `ACCEPTED` | Customer | Offer `PENDING` and unexpired; provider still eligible; request in an acceptable state | **All sibling offers → `EXPIRED` in the same transaction**; request → `AGREED`; commission rate and amount snapshotted |
| 4 | `PENDING` | `DECLINED` | Customer | — | Notify provider; thread closed, others unaffected |
| 5 | `PENDING` | `WITHDRAWN` | Provider | Not yet accepted | Notify customer if it was the last active offer |
| 6 | `PENDING` | `EXPIRED` | System | TTL elapsed | If no `PENDING` offers remain, request → `PUBLISHED` |
| 7 | `PENDING` | `EXPIRED` | System | A sibling was accepted (#3) | Emitted as part of the accept transaction, not separately |
| 8 | `PENDING` | `EXPIRED` | System | Provider became ineligible (suspended, documents expired, went offline past grace) | Notify provider with the reason |

Terminal states are `ACCEPTED`, `DECLINED`, `WITHDRAWN`, `EXPIRED`, `COUNTERED`.

## The invariants S-10 proved

Measured: 750 concurrent acceptance attempts, zero double acceptances, zero deadlocks.

1. **At most one `ACCEPTED` offer per request, ever.** Enforced by locking the request row, not by a unique index alone — the index would reject the second write, but the lock lets us return a meaningful error instead of a constraint violation.
2. **Accepting expires siblings in the same transaction.** A provider must never see an offer as live after losing.
3. **Exactly one `OFFER_ACCEPTED` event.** The outbox drives payment, notifications and analytics; a double-fire would double-charge.
4. **Replays return the original outcome.** A retried accept with the same idempotency key returns the first result with `replayed: true`, and does not act again.
5. **Losing callers get a stable error**, not a raw exception: `ERR_OFFER_NOT_ACTIVE`, `ERR_ILLEGAL_TRANSITION`, `ERR_OFFER_EXPIRED`. These map to localisable messages ("Another provider was just selected").

## Negotiation thread rules

- A **thread** is one provider negotiating on one request. A request has many threads; a thread has many offers, each superseding the last.
- **Round limit** (default 5) counts offers in a thread, both directions. On the limit, only accept, decline or withdraw remain.
- **Alternation**: the same side may not counter twice in a row. A provider who wants to lower their price withdraws and re-offers, which is visible in history.
- **History is append-only.** Offers are never mutated; a change is a new row. The customer sees the full thread (spec: "negotiation history").
- **TTL resets** on each counter, since the counterparty needs time to respond. The *request* TTL does not reset — otherwise a slow negotiation could keep a stale request alive indefinitely.

## Pricing guardrails

Checked server-side on every offer and counter:

| Check | Source | Behaviour |
|---|---|---|
| Soft min / max | Country pack, per category | Warn; allow with confirmation |
| Hard max | Country pack | Reject: `ERR_PRICE_OUT_OF_RANGE` |
| Minimum viable payout | commission + estimated gateway fee | Reject if the provider would net ≤ 0 |
| AI price band (P25–P75) | Price intelligence service | **Advisory only.** The spec forbids AI setting prices |

The provider always sees an estimated payout **from the server** before submitting: `offer − commission − estimated gateway fee`. Kimi's M1 draft already records this as a server-provided breakdown; it stays that way.

## What the client may do

| UI action | Function | Notes |
|---|---|---|
| Submit an offer | `create_offer(request_id, amount_minor, message, idempotency_key)` | Provider only |
| Counter | `counter_offer(thread_id, amount_minor, message, idempotency_key)` | Either side, alternating |
| Accept | `accept_offer(request_id, offer_id, idempotency_key)` | Customer only |
| Decline | `decline_offer(offer_id, idempotency_key)` | Customer only |
| Withdraw | `withdraw_offer(offer_id, idempotency_key)` | Author only |
| Compare offers | `compare_offers(request_id)` | AI advisory, read-only |

Expiry has no client entry point: it is a scheduled worker.

## Realtime events

Private per-request channel for the customer; private per-provider channel for each provider's own threads. A provider must never see a rival's amount — enforced by channel authorisation, not by the client filtering (S-13: RLS on `realtime.messages`).

| Event | To | Payload |
|---|---|---|
| `offer.created` | customer | offer summary, provider card, expires_at |
| `offer.countered` | counterparty | new amount, round number, expires_at |
| `offer.accepted` | winner + request channel | job snapshot |
| `offer.expired` | author | offer id, reason |
| `request.no_offers` | customer | AI price suggestion |

## Open questions for contracts v1

1. Should the customer be able to counter **all** active offers at once ("best and final")? It is a strong UX for a marketplace with thin supply, but it multiplies notifications and complicates the round count. Deferred to Kimi's M3 screens.
2. Is the round limit per thread or per request? Per thread here. Per request would let one aggressive provider exhaust the customer's rounds.
3. Should accepting auto-decline the other threads, or expire them? Expire, as above — "declined" implies a customer judgement that did not happen.
