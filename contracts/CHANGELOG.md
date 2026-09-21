# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Contracts v1 is written in Phase 1, after Kimi Code hands off at M8.5. Nothing is published yet, so no client may call a backend endpoint.

## [1.0.0-preview.11] — 2026-09-21 (preview, not binding)

Phase 5, part 6: disputes.

- **Added** `ERR_DISPUTE_NOT_FOUND`, `ERR_DISPUTE_ALREADY_OPEN`, `ERR_DISPUTE_WINDOW_CLOSED`.
  94 codes in all.
- **Added enums** `dispute_status` (`open`, `under_review`, `resolved`, `withdrawn`) and
  `evidence_kind`. 42 enums in all.
- **New functions** `open_dispute`, `submit_dispute_evidence`, `withdraw_dispute` (client), and
  `dispute_queue`, `assign_dispute`, `resolve_dispute` (dispute officer / super admin).
- **New tables** `disputes` (both parties read it) and `dispute_evidence` (**each side reads only
  its own submissions** — evidence you can read before answering is evidence you can tailor a
  story around).
- **`dispute_officer` gets its scope back.** It lost blanket chat access in preview.5 when support
  was scoped to tickets; it now reads a job's conversation, messages and calls when a dispute
  references that job, and not otherwise.
- Opening a dispute moves the job to `disputed` and **freezes settlement**. Withdrawing restores
  the exact status it froze, not `confirmed`.
- A dispute needs money still held: after settlement the answer is `ERR_DISPUTE_WINDOW_CLOSED`.

## [1.0.0-preview.10] — 2026-09-21 (preview, not binding)

Phase 5, part 5: the item float. Additive, but it changes what a charge means.

- **Added** `ERR_NO_ITEM_FLOAT` (client) and `ERR_ITEM_FLOAT_PENDING` (internal). 91 codes in all.
- **New functions** `submit_float_receipt(key, request_id, spent_minor, storage_path)` (provider)
  and `approve_float_receipt(key, request_id)` (customer).
- **`payments.amount_minor` is no longer the job price.** On a request with `item_float_minor`,
  the charge is job + float + a surcharge covering the gateway's fee on the float (OD-04, so the
  provider is reimbursed exactly what they spend). The new `job_amount_minor`, `float_minor` and
  `float_surcharge_minor` columns say how it divides — **read those, do not subtract**.
- **New columns on `jobs`**: `item_float_spent_minor`, `item_float_receipt_path`,
  `item_float_approved_at`.
- A receipt auto-approves after `float_auto_approve_hours` (24, client-visible), the same shape as
  job auto-confirmation. Earnings do not settle while a float is unapproved.
- `cancel_job` refuses once the float has been released: that is a dispute, not a cancellation.

## [1.0.0-preview.9] — 2026-09-21 (preview, not binding)

Phase 5, part 4: promo codes and tips.

- **`start_payment` gains a fourth argument**, `p_promo_code text DEFAULT NULL`. The three-argument
  form was **dropped**, not overloaded: two overloads with defaults would make
  `start_payment(key, request_id)` ambiguous rather than defaulting. Positional callers are
  unaffected; a client naming arguments is too.
- **New functions** `preview_promo(code, request_id)` → `(discount_minor, currency,
  stacks_with_referral)`, and `add_tip(key, request_id, amount_minor)` → payment id.
- **New tables** `promo_codes` (column-level SELECT: `spent_minor` and `max_uses` are **not**
  granted, because knowing the budget tells a customer exactly when to hurry), `promo_redemptions`
  (own rows) and `tips` (job participants).
- **New columns on `payments`**: `kind` (`job` / `tip`) and `discount_minor`. A tip is a separate
  charge on the same job and may sit alongside the job's payment.
- **Added enum** `discount_kind` (`fixed`, `percent`). 40 enums in all. No new error codes:
  `ERR_PROMO_INVALID` already existed and is now `implemented`.
- A promo **never** reduces provider earnings, and a tip carries **no** commission. Both are spec
  rules, and both are asserted against money-flows 4b and 2.

## [1.0.0-preview.8] — 2026-09-21 (preview, not binding)

Phase 5, part 3: cancelling a paid job, and refunds. Additive.

- **Added** `ERR_REFUND_NOT_FOUND`, `ERR_REFUND_EXCEEDS_PAYMENT` (both `surface: internal`).
  89 codes in all.
- **Added enum** `refund_status` (`pending`, `succeeded`, `failed`). 39 enums in all.
- **New function** `cancel_job(key, request_id, reason_code)` → `(refund_minor, fee_minor,
  currency)`. `reason_code` is a **key**, `^[a-z0-9_]{3,60}$`, not a sentence the user typed.
  `cancel_request` still handles a request nobody has paid for; this is the paid half.
- **What it costs depends on when and who.** A customer cancelling before the provider is
  `en_route` pays nothing; after that, `cancellation_fee_bps` (10% by default, remote-config,
  OD-19) plus the gateway fee comes out of the refund (OD-08). A provider cancelling always
  refunds in full. Show the fee before the user confirms — `cancellation_fee_bps` is
  client-visible for exactly that.
- **New table** `refunds`, readable by the job's participants. A refund is `pending` until the
  gateway confirms it; the money leaves `held_funds` immediately because the platform owes it
  from the moment it cancels.

## [1.0.0-preview.7] — 2026-09-21 (preview, not binding)

Phase 5, part 2: payment records and the webhook intake. Additive.

- **Added** `ERR_PAYMENT_NOT_FOUND` (`surface: internal`). 87 codes in all.
- **Changed to `implemented`**: `ERR_PAYMENT_FAILED`, raised when a gateway reports a charge for
  an amount that is not the job's.
- **New function** `start_payment(key, request_id, method?)` → `(payment_id, amount_minor,
  currency, status)`. It creates an intent and **nothing more**: `checkout_url` is NULL until a
  worker with gateway credentials fills it in, and no such worker exists yet. Calling it again on
  a live intent returns the same one rather than a second charge.
- **New table** `payments`, readable by the job's participants. The client never writes it and
  never confirms a payment: the only path into `paid_held` is a signature-verified webhook.
- `webhook_events` has no policy for any client role, deliberately — a raw gateway payload carries
  whatever the gateway put in it.

## [1.0.0-preview.6] — 2026-09-21 (preview, not binding)

Phase 5's first slice: the double-entry ledger. Additive.

- **Added** `ERR_LEDGER_UNBALANCED`, `ERR_LEDGER_CURRENCY_MISMATCH`, `ERR_LEDGER_EMPTY_ENTRY`,
  all `surface: internal`. 86 codes in all.
- **No new enums in the catalogue**, deliberately: `ledger.owner_kind`, `ledger.account_type` and
  `ledger.transaction_kind` live in the `ledger` schema, which no client role can reach. They are
  not part of the client contract and the generator does not pick them up.
- **New function** `public.my_balances()` → `(account_type, currency, balance_minor)` for the
  caller's own wallet, provider earnings and referral earnings. **Amounts are returned positive**:
  these are liabilities in the books, so the stored balance is negative and the function negates
  it. Do not negate again.

## [1.0.0-preview.5] — 2026-09-21 (preview, not binding)

Phase 8's first slice: support tickets, the scope they open, and suspension. Additive in the
catalogue; **one access change is a tightening, not an addition** — see below.

- **Added** `ERR_TICKET_NOT_FOUND`, `ERR_TICKET_CLOSED` (new category `support`) and
  `ERR_PROVIDER_NOT_FOUND`. 83 codes in all.
- **Added enum** `support_ticket_status` (`open`, `waiting_on_user`, `waiting_on_support`,
  `resolved`, `closed`). 38 enums in all.
- **Breaking for admin surfaces, on purpose:** a `support_agent` can no longer read every
  conversation, message or call. Reading a job's chat now requires a support ticket that names
  that job (RLS matrix §8, a DPIA control). `dispute_officer` loses that access entirely until
  `disputes` exists in Phase 5. An admin console that listed conversations directly must go
  through a ticket instead.

## [1.0.0-preview.4] — 2026-09-21 (preview, not binding)

Phase 6's database half: calls, notification delivery and scheduled errands. Additive.

- **Added** `ERR_CALL_NOT_FOUND` and `ERR_CALL_WINDOW_CLOSED` (implemented), and
  `ERR_PSTN_UNAVAILABLE` (**planned**, see below). 80 codes in all.
- **New category** `communication`.
- **Clarified** `ERR_CALL_IN_PROGRESS`: still `planned`, and now documented as **never raised**.
  `start_call` resolves a simultaneous attempt by returning the live call and setting `is_caller`
  false, rather than refusing the second caller (SH-12). Apps should branch on `is_caller`, not on
  this code.
- **Added enum** `call_status` (`ringing`, `active`, `ended`, `missed`, `declined`, `failed`).
  37 enums in all.
- **Added enum values** `call_incoming` and `call_missed` to `notification_kind`. Adding a value is
  additive, but an app that switches exhaustively on `kind` must handle them.
- **New client-writable column** `profiles.timezone` (IANA name, nullable). Quiet hours are
  evaluated in it; unset, they fall back to the country's first city. Apps should write the device
  zone at sign-in and when it changes.
- `request_pstn_fallback` returns **NULL** when no masked number is allocated, which is every
  case today: no telephony provider is contracted. It does not raise, because raising would
  roll back the `call.pstn_requested` event in the same transaction, and counting how often
  people reach for the phone is the only thing the seam is currently good for. Treat NULL as
  "not available yet"; `ERR_PSTN_UNAVAILABLE` is reserved for a provider that exists and
  refuses.

## [1.0.0-preview.3] — 2026-09-21 (preview, not binding)

Phase 4: safety, the KYC spine and moderation. Additive; nothing that existed changed meaning.

- **Added** `ERR_TRUSTED_CONTACT_LIMIT`, `ERR_SOS_NOT_FOUND` (safety), `ERR_CONSENT_REQUIRED`,
  `ERR_KYC_STEP_INVALID`, `ERR_IDENTITY_ALREADY_REGISTERED` (verification), and
  `ERR_CONTENT_NOT_ALLOWED`, `ERR_MODERATION_CASE_NOT_FOUND`, `ERR_FRAUD_FLAG_NOT_FOUND`
  (moderation and risk). 77 codes in all.
- **New category** `moderation`.
- `ERR_CONTENT_NOT_ALLOWED` carries the rule key in PostgREST's `details`. It is the only refusal
  moderation makes: a held request publishes and a flagged message delivers (OD-21 fail-open), so
  an app must not treat a hold as an error. Retrying the same text produces the same refusal.
- **Added enums** `sos_status`, `sos_partner_integration`, `kyc_decision`, `moderation_action`,
  `moderation_category`, `moderation_case_status`, `fraud_flag_status`. 36 enums in all.

## [1.0.0-preview.2] — 2026-09-18 (preview, not binding)

The marketplace core (Phase 3, ADR-0014) raised codes the catalogue had only reserved, and added
two enums. Additive: nothing that existed changed meaning.

- **Added** `ERR_REQUEST_NOT_FOUND`, `ERR_CATEGORY_NOT_FOUND` (requests), and `ERR_OFFER_NOT_FOUND`,
  `ERR_OFFER_NOT_YOUR_TURN`, `ERR_OFFER_ALREADY_PENDING` (negotiation). 55 codes in all.
- **Changed to `implemented`** (reserved before, raised now): `ERR_ILLEGAL_TRANSITION`,
  `ERR_VERIFICATION_REQUIRED`, `ERR_OFFER_EXPIRED`, `ERR_OFFER_NOT_ACTIVE`,
  `ERR_OFFER_ROUNDS_EXHAUSTED`, `ERR_PRICE_OUT_OF_RANGE`, `ERR_SELF_DEALING_BLOCKED`.
- **Clarified** `ERR_PRICE_OUT_OF_RANGE`: today it is the country hard maximum per category. The
  minimum-viable-payout half needs the commission rate (OD-06).
- **Added enums** `request_channel` (`app`, `web`, `concierge`, `voice`) and `offer_thread_status`
  (`open`, `closed`). 21 enums in all.

## [1.0.0-preview.1] — 2026-09-17 (preview, not binding)

Pinned early because both agents already build against these (PHASE-1-PLAN exception). See `v1-preview/README.md`.

- **Added** `v1-preview/error-codes.json`: 49 codes — 21 implemented (CI-checked against backend code), 22 planned, 6 app-side — with SQLSTATE, HTTP status, retryability and the expected app behaviour.
- **Added** `v1-preview/auth-error-mapping.json`: Supabase Auth error codes mapped to app codes.
- **Added** `v1-preview/enums.json`: 19 enums generated from the migrations.
- **Added** `v1-preview/money.schema.json`: `{ amount_minor, currency }` (resolves review C.7).
- **Decisions:** `ERR_COUNTRY_NOT_SUPPORTED` replaces the app code `ERR_COUNTRY_DISABLED`; a withdrawal awaiting approval is a status, not `ERR_WITHDRAWAL_NEEDS_APPROVAL`.
- **Tooling:** `tools/check_preview.py` and `.github/workflows/contracts.yaml` fail CI on error-code or enum drift.

Planned for v1.0.0:
- db-types, rpc-catalog, edge-functions.openapi.yaml, realtime-events, state-machines, error-codes, storage, fixtures.
- Job and offer state machines with guards, TTLs and side effects.
- Money representation: integer minor units + ISO 4217, with quote and breakdown objects.
