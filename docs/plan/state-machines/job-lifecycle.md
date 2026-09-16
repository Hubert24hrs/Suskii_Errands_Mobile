# Job lifecycle state machine

| | |
|---|---|
| Owner | Claude Code |
| Date | 2026-09-16 |
| Status | Phase 1 draft — becomes `contracts/state-machines/` at M8.5 |
| Evidence | Spec `job_lifecycle`; spike [S-10](../../research/spikes/S-10-results.md) (contention), [S-14](../../research/spikes/S-14-results.md) (money), [S-13](../../research/spikes/S-13-results.md) (who may call) |

> **Naming.** States are written `UPPER_SNAKE` here, as in the spec. Database and wire values are lower `snake_case` (`offers_received`), per [erd.md](../erd.md#conventions); Dart enums map them.

## Rules that hold for every transition

1. **The server owns status.** Clients call a function and receive the new state. No client writes a status column — enforced by column grants, not convention (S-13).
2. **One transition, one transaction.** Lock the request row `FOR UPDATE`, check the guard, write the new state, write the event, enqueue side effects. S-10 showed this holds at 30-way contention with zero deadlocks.
3. **Idempotent by key.** Every transition takes a client-generated idempotency key, unique per user action. A replay returns the original result and does not act again.
4. **Illegal transitions are rejected and logged**, with a stable error code — never silently ignored.
5. **Every transition writes an append-only event plus an outbox record.** Notifications, analytics, AI follow-up, referral accrual and settlement all hang off the outbox, never off the transition itself.
6. **Timeouts are jobs, not client timers.** A countdown shown in the UI is a display of `expires_at`; the transition is performed by a scheduled worker.

## States

| State | Meaning | Money position |
|---|---|---|
| `DRAFT` | Being composed, possibly by the AI concierge | none |
| `PUBLISHED` | Visible to matched providers | none |
| `OFFERS_RECEIVED` | At least one active offer | none |
| `NEGOTIATING` | A counter-offer is outstanding | none |
| `AGREED` | Both sides agreed a price; awaiting payment start | none |
| `PAYMENT_PENDING` | Payment initiated, awaiting gateway confirmation | customer charged, unconfirmed |
| `PAID_HELD` | Funds confirmed and held by the platform | `held_funds` |
| `ASSIGNED` | Provider committed; job not started | `held_funds` |
| `EN_ROUTE` | Provider travelling to pickup | `held_funds` |
| `ARRIVED` | Provider at pickup | `held_funds` |
| `IN_PROGRESS` | Work under way (after pickup PIN) | `held_funds` |
| `COMPLETED_BY_PROVIDER` | Proof submitted, awaiting customer | `held_funds` |
| `CONFIRMED` | Customer confirmed, or auto-confirmed | `held_funds`, dispute window running |
| `SETTLEMENT_PENDING` | Payout requested from the gateway | `held_funds` → in flight |
| `SETTLED` | Payout succeeded | `provider_earnings` |
| `CLOSED` | Terminal, healthy | settled |
| `CANCELLED` | Terminal, cancelled by a party or by the system | refunded per policy |
| `EXPIRED` | Terminal, no offers or no payment in time | none or refunded |
| `DISPUTED` | Dispute open; payouts frozen | `held_funds` frozen |
| `REFUNDED` | Terminal, money returned | `refunds_payable` → customer |

## Transition table

Actors: **C** customer, **P** provider (or assigned worker), **S** system/worker, **A** admin (role in brackets). Guards are checked inside the transaction after the row lock.

| # | From | To | Actor | Guard | Side effects (via outbox) |
|---|---|---|---|---|---|
| 1 | — | `DRAFT` | C | Customer verified? **no** — drafting is allowed unverified | — |
| 2 | `DRAFT` | `PUBLISHED` | C | Customer facial verification `VERIFIED`; country `live`/`beta`; category allowed; price within guardrails; not self-dealing | Match providers (PostGIS), fan-out notifications, start no-offer timer |
| 3 | `PUBLISHED` | `OFFERS_RECEIVED` | S | First offer created | Notify customer |
| 4 | `OFFERS_RECEIVED` | `NEGOTIATING` | C or P | Counter within round limit (default 5) | Notify counterparty, reset offer TTL |
| 5 | `NEGOTIATING` | `OFFERS_RECEIVED` | S | Counter accepted or withdrawn, other offers remain | — |
| 6 | `OFFERS_RECEIVED` / `NEGOTIATING` | `AGREED` | C | Offer `PENDING`, not expired, provider still eligible (verified, not suspended, docs valid, not blocked) | Accept offer, **expire all sibling offers**, snapshot commission rate and agreed amount, create payment intent |
| 7 | `AGREED` | `PAYMENT_PENDING` | C | Payment initialised server-side; gateway routed by country pack | Set payment TTL (default 15 min) |
| 8 | `PAYMENT_PENDING` | `PAID_HELD` | S | **Signature-verified webhook plus server-side verify call** — never the client | Ledger: customer → `held_funds`; notify both; assign |
| 9 | `PAYMENT_PENDING` | `NEGOTIATING` | S | Payment TTL elapsed, offer still valid | Release hold attempt, notify customer |
| 10 | `PAYMENT_PENDING` | `EXPIRED` | S | Payment TTL elapsed, no valid offer remains | — |
| 11 | `PAID_HELD` | `ASSIGNED` | S | Provider confirmed (individual) or dispatcher assigned a verified worker (business) | Open chat + call window, issue pickup PIN to customer |
| 12 | `ASSIGNED` | `EN_ROUTE` | P | Provider online; location permission granted; not mock-location | Start tracking channel, ETA |
| 13 | `EN_ROUTE` | `ARRIVED` | P | Within geofence of pickup, or manual with reason | Notify customer |
| 14 | `ARRIVED` | `IN_PROGRESS` | P | **Pickup PIN verified server-side**, attempt-limited | Item float released if applicable (OD-04) |
| 15 | `IN_PROGRESS` | `COMPLETED_BY_PROVIDER` | P | Required proof present: photo(s), delivery PIN where required, receipt for item float | Notify customer, start auto-confirm timer |
| 16 | `COMPLETED_BY_PROVIDER` | `CONFIRMED` | C | — | Start dispute window, accrue referral as `PENDING` |
| 17 | `COMPLETED_BY_PROVIDER` | `CONFIRMED` | S | Auto-confirm window elapsed **and** PIN verified **and** proof exists (spec) | As above, flagged auto-confirmed |
| 18 | `CONFIRMED` | `SETTLEMENT_PENDING` | S | Dispute window elapsed; no open dispute; provider payout account verified and name-matched | Create payout; referral `PENDING` → `EARNED` → `HOLDING` |
| 19 | `SETTLEMENT_PENDING` | `SETTLED` | S | Payout webhook confirms success | Ledger: `held_funds` → `provider_earnings`, `gateway_fees`, `platform_revenue`, `referral_earnings` (zero-sum, S-14) |
| 20 | `SETTLEMENT_PENDING` | `CONFIRMED` | S | Payout failed or reversed | Alert finance, retry with backoff, notify provider |
| 21 | `SETTLED` | `CLOSED` | S | Ratings window elapsed or both rated | Reputation recompute; referral `HOLDING` → `AVAILABLE` |
| 22 | `PUBLISHED` / `OFFERS_RECEIVED` / `NEGOTIATING` | `EXPIRED` | S | No acceptance within the request TTL | AI suggests a price adjustment (spec) |
| 23 | any pre-`PAID_HELD` | `CANCELLED` | C or P | — | Free cancellation; counts toward cancellation-rate metrics |
| 24 | `PAID_HELD` … `IN_PROGRESS` | `CANCELLED` | C | Cancellation fee by state and elapsed time (country pack) | Refund minus fee; gateway fee per OD-08; notify provider |
| 25 | `PAID_HELD` … `IN_PROGRESS` | `CANCELLED` | P | Provider-initiated: full refund to customer, penalty to provider metrics | Refund; reliability score down |
| 26 | `ASSIGNED` / `EN_ROUTE` | `PAID_HELD` | C | Provider not en route within timeout — **reassign with no penalty to the customer** (spec) | Release provider, re-open matching, keep funds held |
| 27 | `PAID_HELD` … `CONFIRMED` | `DISPUTED` | C or P | Within dispute window | **Freeze payout**, open dispute with evidence bundle, SLA timer |
| 28 | `DISPUTED` | `CONFIRMED` | A (Dispute Officer) | Resolved in provider's favour | Resume settlement path |
| 29 | `DISPUTED` | `REFUNDED` | A (Dispute Officer) | Resolved in customer's favour, full or partial | Ledger reversal; referral `REVERSED` (clawback) |
| 30 | `CANCELLED` / `DISPUTED` | `REFUNDED` | S | Refund confirmed by gateway webhook | Ledger: `held_funds` → `refunds_payable` → customer |
| 31 | `REFUNDED` / `CANCELLED` / `EXPIRED` | `CLOSED` | S | Terminal bookkeeping complete | — |

## Timeouts

All configurable per country and category; these are the defaults.

| Timer | Starts | Default | On expiry |
|---|---|---|---|
| Offer TTL | Offer created | 10 min | Offer → `EXPIRED` (#5 if others remain) |
| Request TTL | `PUBLISHED` | 60 min | #22 → `EXPIRED`, AI price suggestion |
| Payment TTL | `PAYMENT_PENDING` | 15 min | #9 / #10 |
| Provider start timeout | `ASSIGNED` | 15 min | #26 reassign without penalty |
| Auto-confirm | `COMPLETED_BY_PROVIDER` | 24 h | #17, only with PIN + proof |
| Dispute window | `CONFIRMED` | 24 h | #18 settlement proceeds |
| Referral hold | Referral `EARNED` | 72 h | `HOLDING` → `AVAILABLE` |
| Call window | `ASSIGNED` | until 24 h after completion | Calls refused outside it |

## Guards worth naming

- **Self-dealing block** (#2, #6): same user, device fingerprint, or verified identity on both sides is refused server-side. This is a spec rule and a fraud vector, checked at publish *and* at accept, because identities can merge in between.
- **Provider eligibility** (#6, #11): verified, not suspended, police clearance and vehicle documents unexpired, allowed vehicle type for the zone, not blocked by this customer. Re-checked at accept — eligibility can lapse between offer and acceptance.
- **Payment truth** (#8): only a signature-verified webhook plus a server-side verify call may move a job into `PAID_HELD`. Spec rule; it is the single most abusable transition.
- **Proof completeness** (#15): the required proof set is configuration per category, not a hardcoded list.

## What the client may do

Everything above is a server function. Kimi's UI calls one of these and renders the returned state:

| UI action | Function | Returns |
|---|---|---|
| Publish | `publish_request(request_id, idempotency_key)` | job snapshot |
| Accept an offer | `accept_offer(request_id, offer_id, idempotency_key)` | job + payment intent |
| Start payment | `start_payment(request_id, method, idempotency_key)` | gateway checkout handle |
| Cancel | `cancel_job(request_id, reason_code, idempotency_key)` | job + cancellation fee breakdown |
| Provider status updates | `set_job_status(request_id, target, evidence, idempotency_key)` | job snapshot |
| Verify PIN | `verify_pin(request_id, pin, idempotency_key)` | job snapshot |
| Confirm completion | `confirm_completion(request_id, idempotency_key)` | job + receipt breakdown |
| Open dispute | `open_dispute(request_id, reason_code, evidence_refs, idempotency_key)` | dispute |

The transitions with actor **S** have no client entry point at all.

## Open questions for contracts v1

1. Does `PAID_HELD → ASSIGNED` need to be visible to the UI as a separate state, or can the client treat `PAID_HELD` and `ASSIGNED` as one "waiting for provider" state? Kimi's M3/M4 screens will answer this.
2. Reassignment (#26) returns to `PAID_HELD`. That keeps the payment intact but means the same job can visit `PAID_HELD` twice — the event log must make the second visit distinguishable for analytics.
3. ~~Partial refunds from a dispute (#29) leave the job `REFUNDED` even when the provider was paid part of the value.~~ **Resolved 2026-09-16:** partial refunds live on the **payment**, not the job. Kimi's `PaymentStatus` already has `partiallyRefunded`, so the job goes to `REFUNDED` and `payments.status = partially_refunded` carries the nuance. No new job state.
