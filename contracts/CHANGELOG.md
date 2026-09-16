# Contracts Changelog

All notable changes to the published contracts. Semantic versioning: **MAJOR** for breaking changes (a client built against the previous version stops working), **MINOR** for additive changes, **PATCH** for clarifications and fixture fixes.

Every MAJOR entry must link a migration note in `HANDOFF.md`.

## [Unreleased]

Contracts v1 is written in Phase 1, after Kimi Code hands off at M8.5. Nothing is published yet, so no client may call a backend endpoint.

Planned for v1.0.0:
- db-types, rpc-catalog, edge-functions.openapi.yaml, realtime-events, state-machines, error-codes, storage, fixtures.
- Job and offer state machines with guards, TTLs and side effects.
- Money representation: integer minor units + ISO 4217, with quote and breakdown objects.
