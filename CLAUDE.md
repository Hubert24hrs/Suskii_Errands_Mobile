# CLAUDE.md — Suskii Errands

The single source of truth for this project is **`docs/spec/SUSKII_BUILD_PROMPT.json`**. Read it in full before starting any work.

## Your role

Claude Code is the **backend agent and technical lead**. Follow `master_spec` + `agent_claude_code`. Kimi Code builds every frontend (`agent_kimi_code`); treat that section as context only.

## Ownership

| Path | Owner |
|---|---|
| `supabase/` (migrations, functions, tests, seed), `services/` (ai, voice-agent, workers), `contracts/` (except `draft/`), `infra/`, `docs/adr/`, `docs/runbooks/`, `docs/research/`, `docs/audit/`, `docs/OPEN-DECISIONS.md`, `CLAUDE.md` | Claude Code |
| `apps/` (mobile, web-customer, web-marketing, web-admin), `packages/`, `contracts/draft/`, `contracts/CHANGE_REQUESTS.md`, `AGENTS.md`, `.github/workflows/frontend-ci.yaml` | Kimi Code. **Do not edit.** Audit and file findings in `HANDOFF.md` instead |
| `HANDOFF.md`, `README.md` | Shared. Append; never rewrite the other agent's entries |

## Working alongside Kimi Code

Kimi edits **this same working tree at the same time**. Untracked files that are not yours will appear mid-session; leave them alone.

- **Never `git checkout` or `git switch` here** — it moves `HEAD` under Kimi, and Kimi's next commit lands on your branch.
- Commit from a throwaway worktree instead: `git worktree add -b <branch> <scratch>/wt origin/main`, copy in your paths, commit, push, `git worktree remove`.
- Stage only Claude-owned paths. Do not commit `HANDOFF.md`, `apps/`, `packages/` or Kimi's config; edit `HANDOFF.md` in place and let Kimi commit it.
- Remote: `https://github.com/Hubert24hrs/Suskii_Errands_Mobile`. Phase 0 and the backend docs are merged into `main` (fast-forward, 2026-09-16); the working branch was deleted, so `main` is the only branch. Work from a fresh worktree branch off `origin/main` each time.
- After merging, fast-forward the shared tree with `git reset --mixed origin/main` rather than `git pull`: it moves the ref and the index without rewriting files Kimi may be editing.

## Status

| | |
|---|---|
| Phase 0 — Deep research | **Complete.** See `docs/research/CHECKPOINT-PHASE-0.md` |
| Phase 1 — Planning, contracts v1 | **Stage A in progress** (`docs/plan/`): backend truth that does not depend on the hand-off. Stage B (contracts v1 + fixtures) waits for M8.5 |
| Spikes | S-06, S-10, S-13, S-14 passed. The rest need credentials or devices — `docs/research/spikes/README.md` |
| Kimi | M1 + M2 committed (`e473c9b`), reviewed (C.1–C.8). M3 in progress; foundation reviewed from the working tree (M3.1–M3.6). C.1 idempotency keys still open |
| Next Claude work | Phase 1 Stage A #13: revised timeline — the last Stage A deliverable (#1–#12 done, PRD in `docs/plan/prd/`) |

Phases 0 and 1 produce documents only. Spike code is throwaway: `spike/*` branches, under `spikes/`, never in `apps/`, `supabase/` or `services/`.

## Document map

| File | What it is for |
|---|---|
| `docs/OPEN-DECISIONS.md` | OD-01…OD-21 awaiting the client or counsel. Quote it in every checkpoint |
| `docs/adr/` | Architecture decision records, indexed in `docs/adr/README.md` |
| `docs/research/` | Phase 0 evidence: report, vendor matrix, country packs, compliance and DPIA, risks, cost model, spikes |
| `docs/plan/` | Phase 1: state machines, UI draft review, architecture documents feeding contracts v1 |
| `docs/runbooks/` | Operational procedures, one per failure mode |
| `docs/audit/` | Dated audit findings after each integration milestone |
| `contracts/README.md` | What contracts v1 will contain and the rules that bind both agents |

## Maintenance policy — keep these current

Documentation is part of the definition of done, not a postscript. Update on the trigger, in the same change:

| When this happens | Update |
|---|---|
| A major technical decision is made | New ADR in `docs/adr/` + a row in its index. Never edit an accepted ADR; supersede it |
| A spike finishes | `docs/research/spikes/S-xx-results.md`; flip any ADR that was `Proposed` on it; adjust the risk register |
| The client or counsel answers an open decision | `docs/OPEN-DECISIONS.md` (status, date, answer, implementing ADR), and the ADR itself |
| A phase ends | Phase checkpoint file + `HANDOFF.md` entry + this file's Status table; re-list unresolved ODs |
| A vendor price, API or country rule changes | `docs/research/REPORT.md` (with the source), `cost-model.md`, the affected `country-packs/*.yaml` field and its `_status` |
| A new risk appears or one changes score | `docs/research/risk-register.md` |
| A feature is built | Its runbook, contract entry, and the commands section below |
| An audit runs | `docs/audit/AUDIT-<date>.md` + findings for Kimi in `HANDOFF.md` |
| Contracts change | `contracts/CHANGELOG.md` (semver) + a migration note in `HANDOFF.md` for breaking changes |

Two rules: never delete a decision or a finding, supersede it; and every factual claim carries its evidence tag — `[V]` verified from an official source, `[S]` secondary, `[A]` assumption. Nothing tagged `[A]` may be implemented as fact.

## Non-negotiables (from the spec)

- The server is the source of truth for prices, money, job states, verification and permissions.
- Money is integer minor units + ISO 4217 code (use the exponent table: UGX = 0). Never use floats.
- All state and money writes go through database functions or Edge Functions. RLS on every exposed table with pgTAP allow/deny tests.
- `SECURITY DEFINER` functions use an empty `search_path`, check `auth.uid()` and role/mode, and validate inputs.
- Idempotency keys on every create, transition and money operation. Webhooks: verify signature, store raw, de-duplicate, then verify server-side.
- No service-role key in any client or repo. Secrets live in Supabase Vault or GCP Secret Manager. Don't use pgsodium (ADR-0007).
- Held funds are "held", never "escrow" (ADR-0002).
- Never fabricate vendor APIs, model names or legal requirements. Mark uncertain items `VERIFY-IN-RESEARCH`.
- Write comments only for non-obvious logic.

## Commands

Backend commands arrive in Phase 2, when `supabase/` and `services/` are created. Tooling: Supabase CLI (local stack, migrations, type generation), pnpm + Turborepo for TypeScript, uv for Python, Melos for Dart, pre-commit hooks for formatting, linting and secret scanning.

Frontend commands are Kimi's and live in `README.md`.
