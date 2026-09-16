# RB-01 — Something is broken in production: running an incident

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | Defines SEV1–SEV3 for every other runbook |
| Last rehearsed | Not yet — tabletop exercise before the first production deploy; then every 6 months |
| Related | [infra-cicd.md](../plan/infra-cicd.md) §7 (SLOs, alerts); RB-07 (breach), RB-09 (restore), RB-13 (kill switch), RB-14 (deploy and rollback) |

Response times and on-call staffing below are **proposals [A]**: the client decides who is on call and when (timeline client actions). Until then, the named on-call is whoever holds the pager rota the client approves.

## Severity ladder

Pick the **highest** row that matches. When unsure, go one level up; downgrading later is cheap.

| Severity | Any one of these | First response [A] | Updates [A] |
|---|---|---|---|
| **SEV1** | Money moved wrongly or held funds at risk · personal, biometric, criminal-record, ID or payout data exposed (also start **RB-07**) · SOS path not working · core flows (sign-in, publish, offer, accept, pay, track, complete) down in a live country · audit chain broken (`ops.audit_chain_broken`) | 15 min, any hour | Every 30 min |
| **SEV2** | A core flow degraded (slow, partial, one gateway or SMS route failing) · health endpoint 503 for > 5 min · a failed production deploy (RB-14) · a beta country fully down | 30 min in waking hours, 1 h at night | Every 60 min |
| **SEV3** | Non-core feature broken (concierge, promos, referrals dashboard) with a working fallback · staging or dev down · cost alert at 80% | Next working day | Daily |

Safety overrides everything: **any report that a person may be in danger is handled under RB-06 immediately**, whatever the technical severity.

## Symptoms (how incidents arrive)

| Source | Example |
|---|---|
| Uptime alert | *suskii-prod: health check failing* (Cloud Monitoring, email channels) |
| Health body | `checks.audit_chain.status = fail`, `checks.outbox.status = fail`, `checks.scheduled_jobs.status = warn` |
| Sentry | New issue spike on a function, filtered by `release` |
| Budget alert | GCP budget at 80% or 100% |
| Support / users | Tickets, social media, partner calls (SOS partner, gateway, KYC vendor) |
| Vendors | Status pages or account managers for Supabase, Flutterwave, Paystack, Smile ID, LiveKit, SMS providers |

## Roles

A small team will double up; the roles still need names in the incident channel.

| Role | Does | Does not |
|---|---|---|
| **Incident commander (IC)** | Declares severity, owns decisions, assigns work, decides when it is over | Debug alone in silence |
| **Operator** | Diagnoses and applies fixes from the runbooks | Change production outside a runbook step without telling the IC |
| **Comms** | Status updates internally, to support, to partners and — with the client — to users and regulators | Promise causes or timelines not confirmed by the IC |
| **Scribe** | Timestamped log of every action and observation | Summarise later from memory |

## Immediate actions (first 15 minutes)

1. **Open the incident**: channel named `inc-YYYYMMDD-short-name`; post severity, IC, what is known, and the start time (UTC and Lagos time).
2. **Stabilise before diagnosing**:
   - Bad deploy suspected → roll back functions (RB-14).
   - A feature is causing harm → switch it off (RB-13).
   - Personal data may be exposed → start RB-07 in parallel **now**; its clocks start at awareness, not at confirmation.
   - Money path affected → pause the affected payment method or payouts via RB-13 flags; never "fix" balances by hand.
3. **Check the health endpoint** and note which check fails.
4. **Tell support** what users will see and what to say (see Communication).

**Stop conditions:**
- Never edit ledger rows, payment statuses, verification outcomes or the audit log by hand.
- Never disable RLS, drop a policy, or grant a client role wider access to "get things working".
- Never share production data (exports, screenshots with personal data) in the incident channel.
- Never restore a backup without the IC and a second approver (RB-09).

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Overall health | `GET /functions/v1/health` with the `monitoring` key | 200, `status` ok |
| Recent deploys | GitHub Actions → Deployments | No deploy in the hour before the incident, or roll back first |
| Function errors | Sentry by `release` and `function`; `x-request-id` from user reports | No new issue groups |
| Database load and locks | Supabase dashboard → Database → Query performance, active connections | No long-running locks, connections under pool size |
| Advisors | `supabase db advisors --linked` from a trusted shell | No new security findings |
| Scheduled jobs | Health `checks.scheduled_jobs`; `cron.job_run_details` | No failures in the last hour |
| Vendors | Status pages of Supabase, GCP, Flutterwave, Paystack, Smile ID, LiveKit, SMS providers | Operational |
| Costs | GCP billing, Supabase usage | No unexpected spike (e.g. SMS pumping, R-31) |

## Resolution

Resolve through the runbook for the failure mode (RB-02…RB-14). When there is none, the IC decides; the scribe records the exact commands so the runbook can be written afterwards.

## Closing an incident

The IC closes it when the SLO signal has been healthy for 30 minutes and no user-facing harm is ongoing. Money and data incidents close only when reconciliation (RB-03) or the breach assessment (RB-07) is complete.

## Communication

| Audience | SEV1 | SEV2 | SEV3 | Who |
|---|---|---|---|---|
| Client leadership | Immediately | Within 1 h | Daily summary | IC |
| Support agents | Immediately, with a script | Within 30 min | If asked | Comms |
| Users | In-app banner / status message for a core-flow outage; never speculate on cause | If a flow is visibly broken | No | Comms, approved by client |
| Partners (gateway, KYC, SOS, SMS) | When their service is involved | When involved | No | Operator |
| Regulators | Only through RB-07 | — | — | Client + counsel |
| Kimi Code | If app behaviour or contracts are affected (`HANDOFF.md`) | Same | Same | Claude Code |

Message template for users: *"Some people can't [do X] right now. Your money is safe and held by Suskii. We're working on it and will update here by [time]."* Never say "escrow" (ADR-0002); never mention other users.

## After the incident

- Blameless write-up within 48 h (SEV1, SEV2): timeline, impact, root cause, what went well, what didn't, follow-ups with owners.
- Follow-up tasks filed; a missing test or alert is a follow-up by default.
- The runbook used is corrected where it was wrong or missing.
- SEV1 write-ups reviewed with the client.
