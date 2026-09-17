# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Contracts v1 is written in Phase 1, after Kimi Code hands off at M8.5. Nothing is published yet, so no client may call a backend endpoint.

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
