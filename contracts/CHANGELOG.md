# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Contracts v1 is written in Phase 1, after Kimi Code hands off at M8.5. Nothing is published yet, so no client may call a backend endpoint.

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
