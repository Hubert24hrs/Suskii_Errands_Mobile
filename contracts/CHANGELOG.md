# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Nothing pending.

## [1.0.0] - 2026-09-22 - **contracts v1, binding**

Kimi Code's M8.5 hand-off landed on 2026-09-21 and unblocked Stage B. `contracts/v1/` is now the
agreement; `contracts/v1-preview/` is superseded.

**Most of it is generated.** `contracts/tools/generate_v1.py` replays `supabase/migrations` the way
Postgres does -- CREATE adds, DROP removes, GRANT and REVOKE accumulate -- and emits the RPC
catalogue, the client-readable tables with their column-level privileges, the enums, the buckets
and the realtime topics. CI runs it without `--write` and fails on any difference. The parser was
validated against the one piece of ground truth available: it reproduces the 144-function
`authenticated` execute allowlist that `00_structure_test.sql` asserts against the live database,
exactly, with no difference in either direction.

- **`rpc-catalog/index.json`** -- 121 callable functions with arguments, return shapes, the error
  codes each can raise, the idempotency key where there is one (62 of them), and what the caller
  must be. `rpc-catalog/private.json` lists the 23 `private.*` helpers granted to `authenticated`
  that are **not** callable, so the grant does not read like a mistake.
- **`db-types/tables.json`** -- the 64 tables a client reads directly, with **column-level**
  privileges. Four tables are narrower than they look; `promo_codes` withholds the budget.
- **`enums.json`** (45), **`storage/buckets.json`** (6), **`realtime-events/channels.json`** (5 topics).
- **`state-machines/job.json`** and **`offer.json`** -- authored, because many transitions are
  written in SQL with a variable source state and a generated table could only be partial. The
  reverse check is mechanical and is in CI.
- **`error-codes/`** -- moved from the preview, 109 codes, unchanged in content.
- **`edge-functions.openapi.yaml`** -- the six functions. Exactly one is callable by an app.
- **`fixtures/`** -- expired offer, failed payment, disputed job, suspended provider, and the
  spec's worked money example.

### Corrections this shook out

- **Job transition 9 was wrong in the Phase 1 design doc.** It said `payment_pending -> negotiating`;
  the implementation returns the request to `agreed`, which is right, because `negotiating` means a
  counter-offer is outstanding and after an accepted offer none is. The contract records `agreed`
  and says why. Found by the state-machine cross-check on its first run.
- **`ERR_PROOF_REQUIRED`'s description was stale** and now names both gates.

### For Kimi Code, at M9

- **Ids are UUIDs.** The mocks use `req-1`, `disp-1`, `off-2`. Anything that parses, sorts or routes
  on an id needs checking; deep links are the sharp edge.
- **`messages.id` is `bigint`**, not a UUID, because chat is partitioned. Treat it as an opaque
  string rather than an `int`.
- **Arguments are passed by name**, and an optional one is omitted rather than passed as `null`.
- **A provider reads a request only once the job is funded.** There is no query that returns an
  exact address to a provider who has not been assigned a funded job.
- `CHANGE_REQUESTS.md` is open.

## [1.0.0-preview.18] — 2026-09-22 (preview, not binding)

The Participant column of the RLS matrix, which was never implemented. No new error codes, no
signature changes — a read that the matrix always specified and no policy delivered.

- **`requests` is now readable by the assigned provider.** Through RLS, not a new function: a
  plain select on the request behind a job the caller is assigned to. The gate is
  `jobs.assigned_at`, so it opens when the customer's money is held and not when the offer is
  accepted. Before this, a provider who accepted a delivery could not read the address.
- **`request_media` rows are readable by the assigned provider and by a matched one** — a
  provider with an offer thread. The storage objects were already reachable (Phase 3 widened
  `may_read_request_media` to the feed's own test); it was the rows describing them that were
  customer-only, so the table and the bucket disagreed. They agree now.
- **`job_events` is readable by the provider.** Its provider clause had never evaluated true.
- **A bidding provider still reads no request.** Deliberate and tested. Do not build a surface
  that shows an exact address to a provider who has not been assigned a funded job.
- **Clarification:** `ERR_PROOF_REQUIRED`'s description was stale — it said per-category proof
  sets were future work, and they shipped on 2026-09-18. It now names both gates (the category's
  `proof_requirements` counts and the delivery PIN) and says that `DETAIL` carries the kind and
  the count that is short.

## [1.0.0-preview.17] — 2026-09-22 (preview, not binding)

Phase 7's deterministic layer and the last of the country scope. No new error codes.

- **New client functions, and none of them needs a model.** `get_price_band(category, urgency,
  city)` for the request form's price hint; `get_availability_summary(category, lat, lng, radius)`
  for "are there people nearby"; `rank_offers(request_id)` for the offers board's compare;
  `get_job_summary(request_id)` for the tracking screen; `get_category_requirements(category_id)`.
- **Eight admin KPI functions** — `kpi_jobs_by_state`, `kpi_gmv`, `kpi_funnel`,
  `kpi_verification_queue`, `kpi_disputes`, `kpi_payout_failures`, `kpi_referral_campaign`,
  `kpi_supply_demand`. These are the admin dashboard's numbers whether or not an assistant ever
  asks for them.
- **Note for the offers board (M3):** `rank_offers` returns a `score` and a `factors` object. It
  is **not a price sort** — half the weight is price relative to the offers on the table, and the
  rest is reputation, so a cheap newcomer can beat a dearer veteran and an equally-priced veteran
  beats the newcomer. `factors.cheapest` and `factors.new_provider` are there so the card can say
  *why* rather than presenting a number nobody can argue with. An unrated provider scores a
  neutral 0.6, not zero.
- **Note for the request form (M3):** `get_price_band` returns `basis` — `rules` or `history` —
  and `sample_size`. Show them. A band resting on a country's configured guardrails is a
  suggestion; a band resting on two hundred jobs is a measurement, and a UI that renders both the
  same way is lying about one of them. **It can also return no row at all**, which is the honest
  answer for a category nobody has priced; show no hint rather than a zero.
- **Note for any admin screen:** every `kpi_*` cell below ten comes back **NULL**, not zero.
  A suppressed cell and an empty one are different claims and a dashboard that renders both as
  `0` will confidently report a market that does not exist. Render NULL as "—".

## [1.0.0-preview.16] — 2026-09-22 (preview, not binding)

Phase 9's second pass: the RLS surface, the notification dispatcher, and four signature changes.

- **BREAKING (preview): four client functions take an idempotency key as their first argument.**
  `add_trusted_contact`, `invite_member`, `accept_organization_invite` and
  `start_verification_session` now match every other create and transition on the platform.
  Free today because contracts are non-binding and no client calls the backend yet; it will not
  be free after M8.5, which is why it is done now. Audit N.1.
- **Added** `public.get_provider_card(provider_id)` — **the offers board's missing half.** The RLS
  matrix has named this function since Phase 1 and it did not exist, so a customer comparing
  offers could learn nothing about the providers. Returns name, avatar, trust level, verified
  badge, rating **with its count**, vehicle type, verified business name and member-since.
  A reason is required: you have an offer from them, or a job with them, or you are an admin who
  may read them. Anything else is `ERR_PERMISSION_DENIED`, not an empty row.
- **Added** `ERR_NOTIFICATION_UNDELIVERED` (`surface: internal`). 109 codes in all.
- **Note for the admin dashboard (M8):** `admin_users.country_scope` is enforced now. An officer
  with a scope sees only their countries, on twenty-eight tables. A screen that assumed a
  support agent could see the whole platform will show fewer rows, and that is the fix, not a
  bug. `super_admin` is never scoped.
- **Note for every app:** a business can no longer be renamed after it is verified, so a
  "change legal name" control must be hidden once `verification_status = 'verified'`. RLS matches
  nothing, so the update silently writes nothing rather than erroring — check the row back.

## [1.0.0-preview.15] — 2026-09-22 (preview, not binding)

Phase 9's first hardening pass, the trip trail, and the admin verbs for people and businesses.

- **Added** `ERR_CHARGEBACK_NEEDS_REVIEW` and `ERR_INVALID_AMOUNT` (both `surface: internal`) and
  `ERR_ORGANIZATION_NOT_FOUND`. 108 codes in all.
- **New client functions**: `job_trail(request_id)` for the trip replay, and the admin set —
  `business_verification_queue`, `decide_business_verification`, `suspend_organization`,
  `reinstate_organization`, `admin_organization_summary`, `admin_user_search`,
  `admin_user_summary`, `admin_revoke_user_sessions`.
- **Note for the mobile and web apps (M4, M5):** `job_trail` returns the route **only after the
  job ends**. While it is live, the provider's position comes from the realtime channel, one
  point at a time, exactly as it does today. A tracking screen must not call `job_trail` during a
  job and fall back to realtime on the error; it will get a 403 every time.
- **Note for the admin dashboard (M8):** `admin_user_search` takes at least four characters and
  matches an exact id, a **phone-number suffix** or a **display-name prefix** — not a substring.
  A search box that expects `LIKE '%term%'` behaviour will look broken; say what it matches.
  Every search and every profile read writes an audit row before returning, so a screen that
  polls the summary on a timer is generating audit noise.
- **No behaviour change for a payment client.** The five fixes are all server-side: partition
  scheduling, the refund seam, a chargeback posting, promo/referral stacking, and a health check.

## [1.0.0-preview.14] — 2026-09-22 (preview, not binding)

The referral programme, the admin configuration verbs, and the analytics views. Three new client
surfaces, all additive.

- **Added** `ERR_REFERRAL_CODE_NOT_FOUND`, `ERR_REFERRAL_ALREADY_ATTRIBUTED`, `ERR_REFERRAL_SELF`,
  `ERR_REFERRAL_TOO_LATE`, `ERR_CONFIG_CHANGE_NOT_FOUND`, `ERR_COUNTRY_PACK_INCOMPLETE`.
  105 codes in all.
- **No new enum values.** `referral_commission_status` has been in `enums.json` since Phase 2 and
  is now reachable: `pending → earned → holding → available`, or `reversed`.
- **New client functions** for the referral hub (M5): `my_referral_code()`,
  `claim_referral_code(key, code)`, `my_referrals(limit)`, `my_referral_summary()`. A referrer
  sees their own earnings; a referee never sees what somebody earned from them.
- **New admin functions**: `propose_config_change`, `review_config_change`,
  `config_change_queue`, `country_pack_readiness`, `analytics_report`. Config is a proposal and a
  second signature, never a direct write — the tables still grant no writes to any client role.
- **Note for the admin dashboard (M8):** a change to a commission or referral rate, a country
  going live, or a referral campaign needs **two** approvers, and a change never applies until the
  last one signs. `config_change_queue` returns `approvals_required` and `approvals_given`; show
  both. A refused apply — an incomplete country pack — leaves the change `pending`, not `applied`.
- **`ERR_REFERRAL_SELF` is only the obvious case.** A referral claimed from a handset the referrer
  has also used is accepted and silently blocked, because telling somebody which signal caught
  them is a free oracle. The client sees a success either way.

## [1.0.0-preview.13] — 2026-09-21 (preview, not binding)

The payment provider abstraction and its two Edge Functions. No client-facing change.

- **Added** `ERR_NO_PROVIDER_CONFIGURED` and `ERR_PAYOUT_KEY_UNAVAILABLE`, both
  `surface: internal` and neither with a SQLSTATE: they are worker outcomes recorded on an outbox
  event, not database errors. 99 codes in all.
- **No new client functions.** `payments-webhook` is called by a gateway and `payments-worker` by
  a schedule; the `gateway_*` RPCs they use are granted to `service_role` alone.
- **The Flutterwave and Paystack adapters are not in this release and are not missing by
  accident.** Their endpoint paths, payload shapes and signature schemes are not in the research,
  and spike S-12 settles them against a sandbox that needs merchant accounts.

## [1.0.0-preview.12] — 2026-09-21 (preview, not binding)

Phase 5, part 7: payout accounts, payouts and withdrawals. **Phase 5's database half is complete.**

- **Added** `ERR_PAYOUT_ACCOUNT_NOT_FOUND`, `ERR_PAYOUT_NOT_FOUND`, `ERR_WITHDRAWAL_NOT_FOUND`.
  97 codes in all.
- **Changed to `implemented`**: `ERR_INSUFFICIENT_BALANCE`, `ERR_WITHDRAWAL_BELOW_MINIMUM`.
- **Added enums** `payout_rail`, `payout_status`, `withdrawal_status`. 45 enums in all.
- **New functions** `add_payout_account`, `available_balance(source, currency)`,
  `request_withdrawal`, `approve_withdrawal`.
- **New tables** `payout_accounts` (column-level read — **the ciphertext is granted to nobody**,
  so a user cannot read back their own account number and neither can a stolen session),
  `payouts` and `withdrawals`, all own-rows.
- **`ERR_WITHDRAWAL_NEEDS_APPROVAL` is still not a code and will not become one.** The decision in
  preview.1 stands: a withdrawal awaiting approval is a *status*. It is now a real one —
  `withdrawal_status = 'awaiting_approval'`, returned by `request_withdrawal` — so the app has
  something concrete to switch on. The constant in `suskii_core` should go.
- An unverified payout account cannot receive money: `verified_at` is set by the bank's name
  enquiry, never by a client.

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
