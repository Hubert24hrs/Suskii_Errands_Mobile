# RB-09 — Data is damaged or lost: restoring the database, and the restore drill

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | SEV1 for production data loss or corruption (RB-01) |
| Last rehearsed | Not yet — quarterly drill on staging, first one before launch |
| Related | [infra-cicd.md](../plan/infra-cicd.md) §8 (targets); RB-01, RB-07, RB-13, RB-14; `infra/terraform` (backup bucket) |

## What exists, and what does not yet

Be honest about this during an incident: plan with what is actually there.

| Layer | Target (§8) | Status on 2026-09-16 |
|---|---|---|
| Supabase **point-in-time recovery (PITR)** on production | RPO ≤ 5 min [A — confirm granularity on the chosen plan] | Planned: enabled when the production project is created (client action). PITR is a paid add-on [S] |
| Daily **logical backup** (`pg_dump`) to the EU backup bucket | Survives loss of the Supabase project or account | Bucket and `backup-worker` identity in Terraform; **the worker is not built yet** (services/workers) |
| Nightly **automated restore test** of the logical backup | Row counts and ledger balance check | Not built yet — follows the worker |
| Storage bucket sync (private buckets, `kyc-docs` separately) | Nightly | Not built yet |
| Schema and configuration as code | Rebuild a project from git | **Exists**: migrations, `config.toml`, Terraform, deploy pipelines (RB-14) |

**RTO target: ≤ 4 h [A].** Until the logical backup and its restore test exist, production relies on PITR alone, and a lost Supabase project cannot be restored from Suskii-owned copies. This is a launch blocker, tracked in the timeline (Phase 10 "backups, PITR").

## Symptoms

- Rows missing or wrong after a deploy, a migration, a bad admin action or a bug.
- Ledger health: unbalanced transactions or reconciliation drift (RB-03).
- Audit chain broken (`ops.audit_chain_broken`): possible tampering, which is also RB-07.
- The Supabase project, region or account is unavailable for an extended period.

## Impact

Restoring the whole database **rewinds everyone's data** to the chosen point: payments, offers, chat and verifications made after that time are lost from the database even though gateways, vendors and users remember them. A restore is therefore the last resort after smaller repairs have been ruled out.

## Immediate actions

1. Open a SEV1 incident (RB-01). If personal data may have been exposed, start RB-07 too.
2. **Stop the damage from growing**: switch off the feature or job causing it (RB-13); pause deploys (disable `DEPLOY_*_ENABLED`); pause payouts and withdrawals if money data is involved.
3. **Pin the moment**: the last known-good time, from audit rows, deploy times (GitHub Deployments), `job_events`, or the first error in Sentry. Write it down in UTC.
4. **Choose the smallest repair** using the table below.

| Situation | Preferred repair |
|---|---|
| A few rows wrong, cause understood | Forward-fix migration or a reviewed one-off function through the pipeline; audit-logged |
| A table's data damaged, rest fine | Restore to a **separate project** at the pinned time and copy back only the affected rows |
| Widespread corruption, or the cause is unknown and ongoing | Full PITR restore of production to the pinned time |
| Supabase project lost | Rebuild from code (RB-14 pipeline) + latest logical backup — **not possible until the backup worker exists** |

**Stop conditions:**
- A full production restore needs the **IC and a second named approver**, recorded in the incident log.
- Never restore over production to "look at" old data; restore to a separate project for investigation.
- Never hand-edit ledger, payment or verification rows to match a guess. Money repairs go through posting functions so the ledger stays zero-sum.
- Never delete the damaged data before a copy is taken: it is evidence.

## Resolution

### Full PITR restore (production)

1. Announce a maintenance window to users (RB-01 comms). Switch on the kill switches for publishing, payments and payouts (RB-13) so no new writes arrive mid-restore.
2. Supabase dashboard → project → Database → Backups → Point in time: choose the pinned time. The exact console path and whether restore is in-place or to a new project are **confirmed in the first drill** [S].
3. After the restore completes:
   - `supabase migration list --linked` — local and remote match.
   - `GET /functions/v1/health` — 200.
   - `SELECT private.run_audit_chain_check();` — `ok`.
   - Ledger health check (RB-03) — zero unbalanced transactions.
4. **Reconcile what was rewound**: payments confirmed by gateways after the pinned time (gateway dashboards and stored webhooks), verifications completed at the KYC vendor, payouts sent. Replay them through the normal functions; never re-insert rows by hand.
5. Switch features back on one at a time; watch health and Sentry for 30 minutes.

### Partial restore via a separate project

1. Create a restore project in the client's Supabase organisation (or use PITR restore-to-new-project where the plan supports it [S]).
2. Restore it to the pinned time; never point apps or deploy pipelines at it.
3. Export only the affected rows by id; review the diff with a second person.
4. Apply them to production through a reviewed migration or function (audit-logged). Delete the restore project afterwards; it contains production personal data.

## The drill (quarterly, on staging)

1. Write known sentinel rows to staging; record the time T.
2. Damage them deliberately (delete a table's rows through a migration on a branch deployed to staging).
3. Restore staging to T using the steps above; time every step.
4. Verify: sentinel rows present, migrations match, health 200, audit chain ok.
5. Record in the table below. A drill that exceeds the RTO target is a finding.

| Date | Environment | Method | Time to restore | RTO met? | Findings |
|---|---|---|---|---|---|
| — | — | — | — | — | First drill before launch |

## Backout

A restore cannot be undone except by restoring again to a later point. That is why the pinned time and the second approver matter.

## Communication

RB-01 for users and the client. If data was lost for identifiable people, counsel decides whether RB-07 obligations apply.

## After the incident

- Write-up with the pinned time, data lost, data replayed, and what could not be recovered.
- Follow-ups: the missing test or guard that let the damage happen; progress on the logical backup worker if it was needed and missing.
