# RB-14 — A backend deploy failed, or a release must be rolled back

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | SEV2 (production functions unhealthy after deploy); SEV3 (dev or staging) |
| Last rehearsed | Not yet — rehearse on staging as soon as it exists; must be within 6 months of launch |
| Related | [infra-cicd.md](../plan/infra-cicd.md) §6; ADR-0013; RB-01 (incidents), RB-09 (PITR restore), RB-10 (key rotation); workflows `pipeline-main`, `deploy-production`, `rollback-functions`, `infra-deploy` |

## How deploys work (read once, before you need it)

| Stage | Trigger | Workflow | Gate |
|---|---|---|---|
| Checks | Every push to `main` touching `supabase/**` | `pipeline-main` → `backend-db`, `backend-functions` | Migrations from zero, pgTAP, lint, advisors, Deno fmt/lint/check/test |
| Dev | After checks pass | `pipeline-main` → `_deploy-supabase` (`dev`) | Repository variable `DEPLOY_DEV_ENABLED=true` |
| Staging | After dev succeeds (or dev disabled) | `pipeline-main` → `_deploy-supabase` (`staging`) | `DEPLOY_STAGING_ENABLED=true` |
| Production | Manual: Actions → **deploy-production** → SHA + PITR confirmation | `deploy-production` → `_deploy-supabase` (`production`) | SHA on `main` **and** a successful staging deployment of that SHA; `production` environment reviewers |
| Infrastructure | Manual: Actions → **infra-deploy** → env + plan/apply | `infra-deploy` | `infra-<env>` environment reviewers |

Each Supabase deploy runs, in order (§6.2): **migrations** (dry run, then apply) → **function secrets** from GCP Secret Manager → **Edge Functions** → **auth/project config** (`config push` with a generated `[remotes.deploy]` block) → **smoke test** (`/functions/v1/health` must return 200 with `release` equal to the deployed SHA).

## Symptoms

- A `pipeline-main`, `deploy-production` or `rollback-functions` run is red.
- The uptime alert *"suskii-<env>: health check failing"* fires after a deploy.
- Sentry shows a new error spike tagged with the new `SUSKII_RELEASE`.

## Impact

Depends on the failed step:

| Failed step | What users see | Money or data at risk? |
|---|---|---|
| Configuration check, link, dry run | Nothing: nothing was changed | No |
| Migrations — apply | Possibly nothing (a failed migration rolls back its transaction) or, if a later migration failed, a partially migrated schema | Possibly: treat production as SEV2 |
| Function secrets / Edge Functions | Functions on the old code with new secrets, or a mix of old and new functions | OTP delivery and device checks may fail |
| Auth config | Sign-in behaviour changes (hooks, redirect URLs, CAPTCHA) | Sign-in may fail |
| Smoke test | New functions are live but unhealthy | Depends on the failing check |

## Immediate actions (first 5 minutes)

1. Open the failed run and note the **failed step** and the **SHA**.
2. If the failure is in *Configuration check*, *Link* or *Migrations — dry run*: nothing changed. Fix the configuration and re-run. Stop here.
3. If production users are affected (smoke test or uptime alert): declare an incident per RB-01 and go to **Roll back functions** below. Do not wait for a diagnosis.
4. If a migration **apply** failed in production: go to **Migration failed** below.

**Stop conditions:**
- **Never roll back a migration by hand** (no manual `DROP`, no editing `supabase_migrations.schema_migrations`). Fix forward, or restore per RB-09.
- **Never edit an applied migration file** to make a re-run pass: the pipeline refuses out-of-order history on purpose (ADR-0013).
- Never deploy to production a SHA that did not succeed on staging, and never bypass the `production` environment.
- Never paste secrets into workflow inputs or logs; secrets come only from Secret Manager and GitHub environment secrets.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Which release is live | `GET https://<ref>.supabase.co/functions/v1/health` with the `monitoring` API key | `release` = expected SHA, `status` ok or warn |
| Which check fails | Same response, `checks` | Each check `ok` or `skipped` |
| Function errors | Sentry, filter `release:<sha>` and `function:<name>` | No new issue groups |
| Function logs | Supabase dashboard → Edge Functions → Logs; search `request.completed` / `request.unhandled_error` and the `x-request-id` | Status 2xx, no unhandled errors |
| Migration state | `supabase migration list --linked` in a trusted shell | Local and remote columns identical |
| Last good release | Actions → deployments for the environment | Most recent successful deploy SHA |

## Resolution

### Roll back functions (fastest recovery)

1. Actions → **rollback-functions** → environment, and the **last known-good SHA** from *Deployments*.
2. The workflow checks the SHA is on `main`, then redeploys that commit's Edge Functions and secrets. It does **not** touch migrations or auth config.
3. Expected: the smoke test passes with `release` equal to the rollback SHA; the uptime alert clears within 5 minutes.
4. If the rolled-back functions are incompatible with a migration that already applied: migrations are expand-only (§6.3), so older functions keep working. If they do not, that expand/contract rule was broken — escalate as SEV1 and fix forward.

### Migration failed

1. Read the error in *Migrations — apply*. Each migration runs in its own transaction; confirm which ones applied with `supabase migration list --linked`.
2. **Lock or statement timeout** (another session held a lock): re-run the pipeline in a quieter window. The same SHA can be re-deployed.
3. **Data-dependent failure** (e.g. a constraint fails on real data): write a new migration that fixes data or the constraint, merge it, and let it flow through dev and staging.
4. **Data damaged by a migration**: stop writes if needed (kill switch, RB-13), then restore per RB-09. Only the database owner and one other approver may start a restore.

### Auth config push failed

1. Compare the generated `[remotes.deploy]` block in the run log with the environment variables (`SITE_URL`, `ADDITIONAL_REDIRECT_URLS`, project ref).
2. Fix the variable and re-run the deploy for the same SHA; `config push` is idempotent.

### Infrastructure apply failed

1. Re-run **infra-deploy** with `plan` to see the current drift.
2. Fix the Terraform in a PR and apply again. Never apply locally against production except for the one-time bootstrap.

## Backout

- A functions rollback is undone by deploying the newer SHA again through `deploy-production` (it must still have passed staging).
- A forward-fix migration is itself subject to this runbook.

## Communication

- Production incident: follow RB-01 roles and channels.
- Tell Kimi Code (`HANDOFF.md`) when a rollback changes behaviour the apps rely on, such as error codes or response shapes.

## After the incident

- Timeline written up within 24 h
- Follow-up tasks filed (missing test, missing expand/contract step, flaky smoke test)
- This runbook corrected where it was wrong
- Uptime and Sentry alerts tuned if they fired late or noisily

## One-time setup per environment (checklist)

| Item | Where |
|---|---|
| GCP project + billing; `terraform apply` of `infra/terraform/envs/<env>` by a named admin (creates WIF, deployer and terraform-runner identities, secret names) | `infra/terraform/README.md` |
| Secret values added: `send-sms-hook-secrets`, `sentry-dsn-edge-functions`, `google-play-integrity-service-account` (optional), `supabase-db-password` | GCP Secret Manager |
| Supabase project in the client organisation; named secret API key `monitoring` | Supabase dashboard |
| GitHub environment `<env>` (`dev`, `staging`, `production`) with the variables and secrets listed at the top of `_deploy-supabase.yaml`; required reviewers on `production` (needs a paid GitHub plan on a private repo, infra-cicd I-1) | GitHub → Settings → Environments |
| GitHub environment `infra-<env>` with the variables listed in `infra-deploy.yaml` | GitHub → Settings → Environments |
| Repository variables `DEPLOY_DEV_ENABLED` / `DEPLOY_STAGING_ENABLED` = `true`, and `TF_STATE_BUCKET` | GitHub → Settings → Variables |
| First deploy watched end to end; rollback rehearsed once on staging | This runbook |
