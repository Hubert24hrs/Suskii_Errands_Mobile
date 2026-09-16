# CLAUDE.md — Suskii Errands

The single source of truth for this project is **`docs/spec/SUSKII_BUILD_PROMPT.json`**. Read it in full before starting any work.

## Your role

Claude Code is the **backend agent and technical lead**. Follow `master_spec` + `agent_claude_code`. Kimi Code builds every frontend (`agent_kimi_code`); treat that section as context only.

## Ownership

| Path | Owner |
|---|---|
| `supabase/` (migrations, functions, tests, seed), `services/` (ai, voice-agent, workers), `contracts/` (except `draft/`), `infra/`, `.github/workflows/backend-*.yaml`, `docs/adr/`, `docs/runbooks/`, `docs/research/`, `docs/audit/`, `docs/OPEN-DECISIONS.md`, `CLAUDE.md` | Claude Code |
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
| Phase 1 — Planning, contracts v1 | **Stage A complete** (`docs/plan/`, 2026-09-16): state machines, ERD, RLS matrix, money flows, C4, threat model, data flow, AI design, infra/CI-CD, test strategy, PRD (147 stories), timeline. Stage B (contracts v1 + fixtures) waits for M8.5 |
| Spikes | S-06, S-10, S-13, S-14 passed. The rest need credentials or devices — `docs/research/spikes/README.md` |
| Kimi | M1 + M2 committed (`e473c9b`). M3 uncommitted, packages only (no screens yet); progress check 2026-09-16: C.1, M3.1, M3.2, M3.4, M3.5 fixed; open M3.7 (key generator throws — High), M3.8–M3.10 |
| Phase 2 — Backend foundation | **Started 2026-09-16** before contracts v1 (ADR-0013, user-approved). Done and green in CI: 9 migrations, 117 pgTAP assertions (`backend-db.yaml`); Edge Functions `auth-send-sms` and `device-integrity`, 33 Deno tests (`backend-functions.yaml`). Observability: `health` function + DB health checks + Sentry-ready instrumentation. Terraform for GCP in `infra/terraform` (validated, not applied; `infra.yaml` CI). Deploy pipelines: `pipeline-main` (checks → dev → staging), `deploy-production`, `rollback-functions`, `infra-deploy`; runbook RB-14. Security CI: `security.yaml` (project policy checks, gitleaks, osv-scanner; weekly). Phase 2 runbooks written: RB-01, RB-07, RB-09, RB-10, RB-13, RB-14 (none rehearsed yet). Open: SMS vendor adapters (S-09), iOS App Attest, Cloudflare/Sentry Terraform (after domain decision I-2). Needs GCP billing + a Supabase org for deployed environments |
| Next Claude work | Phase 2 build complete: deploy pipelines exist but are switched off until the client's GCP projects, Supabase org and GitHub environments exist (RB-14 checklist). Phase 3 waits for contracts v1; rolling review of Kimi's milestones (recheck C.1, M3.1 at M3 commit); Stage B at M8.5. Launch base case: week of 7 Jun 2027 |

Phases 0 and 1 produce documents only. Spike code is throwaway: `spike/*` branches, under `spikes/`, never in `apps/`, `supabase/` or `services/`. From Phase 2, `supabase/` holds production code — see `supabase/README.md` for its rules.

## Document map

| File | What it is for |
|---|---|
| `docs/OPEN-DECISIONS.md` | OD-01…OD-21 awaiting the client or counsel. Quote it in every checkpoint |
| `docs/adr/` | Architecture decision records, indexed in `docs/adr/README.md` |
| `docs/research/` | Phase 0 evidence: report, vendor matrix, country packs, compliance and DPIA, risks, cost model, spikes |
| `docs/plan/` | Phase 1: state machines, UI draft review, architecture, AI design, infra, test strategy, PRD (`prd/`), timeline with the client action list |
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

Backend (details and rules in `supabase/README.md`; CLI pinned to 2.117.0):

```bash
npx supabase@2.117.0 start                         # needs Docker
npx supabase@2.117.0 db reset --local              # all migrations + dev seed from zero
npx supabase@2.117.0 test db --local supabase/tests/database  # pgTAP
npx supabase@2.117.0 db advisors --local --type all --level warn --fail-on warn
bash supabase/local-fallback/run-plain-postgres.sh # no-Docker fallback (PSQL, PG* env vars)
cd supabase/functions && npx deno@2.9.6 test --allow-env   # Edge Functions (also fmt --check, lint, check */index.ts)
terraform -chdir=infra/terraform/envs/dev init -backend=false && terraform -chdir=infra/terraform/envs/dev validate
```

This dev machine has no Docker: use the fallback with the portable PostgreSQL 17 + PostGIS + pgTAP install (`spikes/postgres/setup-local-windows.sh`; antivirus has deleted its binaries twice — re-extract from the cached zip). CI on GitHub is the authority.

Tooling still to come: pnpm + Turborepo for TypeScript, uv for Python, pre-commit hooks for formatting, linting and secret scanning.

Frontend commands are Kimi's and live in `README.md`.
