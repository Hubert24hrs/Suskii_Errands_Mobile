# CLAUDE.md — Suskii Errands

The single source of truth for this project is **`docs/spec/SUSKII_BUILD_PROMPT.json`**. Read it in full before starting any work.

## Your role

Claude Code is the **backend agent and technical lead**. Follow `master_spec` + `agent_claude_code`. Kimi Code builds every frontend (`agent_kimi_code`); treat that section as context only.

## Ownership

| Path | Owner |
|---|---|
| `supabase/` (migrations, functions, tests, seed), `services/` (ai, voice-agent, workers), `contracts/`, `infra/`, `docs/adr/`, `docs/runbooks/`, `docs/research/`, `docs/audit/` | Claude Code |
| `apps/` (mobile, web-customer, web-marketing, web-admin), `packages/` (design tokens, Dart packages), `contracts/draft/` | Kimi Code. **Do not edit.** Audit and file findings in `HANDOFF.md` instead |
| `HANDOFF.md` | Shared log. Append; never rewrite the other agent's entries |
| `contracts/CHANGE_REQUESTS.md` | Kimi's requests for contract changes |

## Status

- Phase 0 (research) is complete. See `docs/research/CHECKPOINT-PHASE-0.md`.
- Phase 1 starts when Kimi Code hands off at M8.5.
- Phases 0 and 1 produce documents only. Spike code lives on `spike/*` branches under `spikes/` and is throwaway.

## Non-negotiables (from the spec)

- The server is the source of truth for prices, money, job states, verification and permissions.
- Money is integer minor units + ISO 4217 code (use exponents: UGX = 0). Never use floats.
- All state and money writes go through database functions or Edge Functions. RLS on every exposed table with pgTAP allow/deny tests.
- `SECURITY DEFINER` functions use an empty `search_path`, check `auth.uid()` and role/mode, and validate inputs.
- Idempotency keys on every create, transition and money operation. Webhooks: verify signature, store raw, de-duplicate, then verify server-side.
- No service-role key in any client or repo. Secrets live in Supabase secrets/Vault or GCP Secret Manager. Don't use pgsodium (pending deprecation).
- Never fabricate vendor APIs, model names or legal requirements. Mark uncertain items `VERIFY-IN-RESEARCH`.
- Write comments only for non-obvious logic.

## Commands

To be filled in during Phase 2, once `supabase/` and `services/` exist:

- Supabase CLI: local stack, migrations, type generation
- pnpm + Turborepo for TypeScript workspaces
- uv for Python
- Melos for Dart
