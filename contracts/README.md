# Contracts

The API and data agreement both agents build against. **Owned by Claude Code.** Read-only for Kimi Code once published.

## Status: **published — v1.0.0, 2026-09-22, binding**

[`v1/`](v1/README.md) is the agreement. Kimi Code hands off at M8.5 landed on 2026-09-21 and v1
followed the next day. [`v1-preview/`](v1-preview/README.md) is superseded and kept only for the
four decisions it made.

| Path | Owner | State |
|---|---|---|
| `v1/` | Claude Code | **Binding.** Read-only for Kimi Code |
| `tools/` | Claude Code | `generate_v1.py` regenerates the derived half; `check_preview.py` checks the error catalogue. Both run in CI |
| `draft/ui-data-requirements.md` | Kimi Code | Live — the frontend records every data need, action, realtime event and error state here. Input, not authority |
| `CHANGE_REQUESTS.md` | Kimi Code writes, Claude Code resolves | **Open now that v1 exists** |
| `v1-preview/` | Claude Code | Superseded |

Most of `v1/` is **generated from `supabase/migrations`** rather than written, because a catalogue
of 121 functions maintained by hand is a catalogue that is wrong by the end of the week. What is
authored — the state machines, the error catalogue, the Edge Function surface, the fixtures — is
authored because it encodes decisions rather than facts, and each carries whatever mechanical
cross-check is available: a job transition written as two literals in SQL and missing from
`state-machines/job.json` fails CI, as does an `ERR_` code the backend raises and the catalogue
does not list.

Where the draft conflicts with `master_spec` on money, security or the state machine, the spec wins and the UI changes. Those changes are listed in `HANDOFF.md`, not negotiated in the draft.

## What v1 contains

| Artefact | Contents |
|---|---|
| `db-types/` | TypeScript types generated from Supabase, plus JSON Schemas used to generate Dart models |
| `rpc-catalog/` | Every database function clients may call: name, input schema, output schema, errors, required role and mode, idempotency requirement |
| `edge-functions.openapi.yaml` | Every Edge Function endpoint |
| `realtime-events/` | Channel naming, authorisation rules, event names, payload schemas |
| `state-machines/` | Job and offer transition tables with guards, timeouts and side effects |
| `error-codes/` | Stable codes mapped to localisable message keys |
| `storage/` | Bucket names, path conventions, allowed types and sizes, upload method |
| `fixtures/` | Realistic mock data for every screen, including expired offers, failed payment, disputed job, suspended provider |
| `CHANGELOG.md` | Semantic versions and migration notes |

## Rules

1. Clients may call **only** what the contracts list. No inventing endpoints, fields or events.
2. Contracts are versioned. A breaking change needs a new version and a migration note in `HANDOFF.md`.
3. CI fails on contract drift: generated types must match what is committed here.
4. Fixtures match Kimi Code mock data where possible, so the swap from mocks to the real backend is mechanical.
5. Change requests go through `CHANGE_REQUESTS.md`. Claude Code sets each to ACCEPTED, REJECTED or SHIPPED with a reason.

## Design constraints these contracts must honour

From `master_spec` and the Phase 0 decisions:

- Money is integer minor units + ISO 4217 code. Currency exponents vary (UGX = 0), so a currency is never assumed to have two decimals.
- Every price, commission, gateway fee, payout and referral amount arrives as a **server-computed quote or breakdown object**. There is no client-side arithmetic to be trusted.
- Status changes are requested actions, never client assignments. Illegal transitions are rejected with a stable error code.
- Idempotency keys are required on offers, payments, payouts, withdrawals, refunds and state transitions.
- Held funds are described as "held", never "escrow" (ADR-0002).
- Realtime channels are private and per job; live location is Broadcast, not table changes (ADR-0009).
