# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Contracts v1 is written in Phase 1, after Kimi Code hands off at M8.5. Nothing is published yet, so no client may call a backend endpoint.

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
