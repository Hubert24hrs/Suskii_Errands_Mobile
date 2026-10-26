# Handover

| | |
|---|---|
| Owner | Claude Code (backend and operations); the builder for the accounts |
| Date | 2026-10-26 |
| Status | **Pre-launch.** The testers' sandbox and staging run; nothing takes money; Google Play has a closed test under review |
| Read with | `docs/runbooks/README.md` (operations), `docs/OPEN-DECISIONS.md` (what the client must decide), `docs/plan/timeline.md` (client actions), `HANDOFF.md` (the build log) |

This is the document for whoever takes Suskii Errands over: the client, an operations team, or the
next engineer. It says what exists, where, who controls it today, how to run it, and what is still
missing. It holds **no secret values**: it names each secret and where it lives.

## 1. Who owns what, and the move to the client

**Every account today is in the builder's name**, not the client's: the builder chose personal
accounts to move fast before the client's entity existed. Suskii is owned by a client, so each of
these has to move before launch. The order matters: the domain and the Play organisation account
gate the rest.

| Service | Today | What moves, and how | Blocks |
|---|---|---|---|
| **Domain** `suskiierrand.com` | Cloudflare Registrar, the builder's account (bought 2026-10-24) | Cloudflare's inter-account move: both accounts confirm, DNSSEC off first. The source loses every setting (DNS records, Workers routes, Email Routing, Access), so recreate them in the target from `infra/web/` and §4. Possible once the domain is more than 10 days old, so **from 2026-11-03**; transfer-locked for 30 days after [V: Cloudflare Registrar docs] | Email, the websites, the admin console |
| **Google Play** | Personal developer account "Hubert.dev"; app `com.suskiierrands.app` | **OD-29**: before any build takes payments, the client needs CAC registration, a D-U-N-S number and a Play **organisation** account; then the app is transferred to it and the builder is invited. Play rejected a financial-features declaration on the personal account on 2026-10-25 for exactly this reason | Payments in the app |
| **Apple** | No account | The client enrols as an organisation (same D-U-N-S); iOS push, App Attest and TestFlight wait for it | iOS |
| **GitHub** `Hubert24hrs/Suskii_Errands_Mobile` | The builder's personal account, public repo | Transfer the repository to the client's organisation. Repository secrets stay with the repository [V: GitHub docs]; **whether environment secrets do is not documented** [VERIFY on a throwaway repo first], so plan to re-enter them (§5) | CI/CD |
| **Google Cloud** | Projects `suskii-ops`, `suskii-dev`, `suskii-staging`, `suskii-prod` under the builder's Google account, **no organisation**; billing account "Suskii Errands" `0196B4-E425AB-3D0960` on the builder's card | Add the client as Owner on all four projects, link them to a client billing account, then remove the builder. Better: the client creates a Cloud Identity organisation and the projects move into it. Firebase (push) lives in `suskii-prod` and moves with it | Everything server-side outside Supabase |
| **Supabase** | Organisation "Suskii Errands" (**Free**) in the builder's account: `suskii-dev` (paused), `suskii-staging`, `suskii-prod` (the testers' sandbox) | Invite the client as Owner, transfer ownership, and put the plan on the client's card (Pro for production) | The database |
| **Cloudflare** | The builder's account: the zone, three Workers sites, the admin console's Access policy (the owner's email only), Email Routing for `privacy@` and `support@` | Moves with the domain (above) | |
| **Resend** (email) | The builder's existing Resend account; the domain is verified there | The client opens their own account, verifies the domain again (new DKIM records), and the sandbox's SMTP setting gets the new key | Sign-in emails |
| **Termii** (SMS) | Signed up 2026-10-26 under the workspace name "Tech Tribe Institute", **paused** by the owner; wallet empty | The sender ID "Suskii" needs the client's CAC certificate, business licence and network letters, 2–4 weeks [S: Termii]. Open it in the client's name | Phone sign-in |
| **Android signing** | Upload key at `C:\Users\HP\suskii-signing\upload.jks` on the builder's machine; the password is the builder's. Play App Signing holds the real app key | Hand the keystore and password over through a password manager, never in chat or email. If it is lost, Play can reset the upload key | Every Android release |

**Expiring credentials**: put these in a calendar.

| What | Expires | Rotates through |
|---|---|---|
| Supabase access token `github-deploy-staging` | ~2027-01-23 | RB-10 |
| Supabase access token `github-deploy-dev` | ~2027-01-10 | RB-10 |
| Cloudflare API token (`web-production`) | 2027-01-23 | RB-10 |
| The fixed-code review sign-in for Google's reviewers (sandbox Auth → Phone) | 2027-10-25 | RB-15 |

## 2. Environments

| Environment | Where | What it is for | Deploys |
|---|---|---|---|
| dev | Supabase `suskii-dev`, GCP `suskii-dev` | Development. **Paused** (Free allows two active projects) | Off (`DEPLOY_DEV_ENABLED` unset) |
| staging | Supabase `suskii-staging` (`lglvoguvycdrwwxqynul`), GCP `suskii-staging` | Rehearsals and pre-release checks. Every country `disabled` | **Automatic** from `main` through `pipeline-main` |
| sandbox | Supabase `suskii-prod` (`slfbtdwzoijgzqszfufp`), GCP `suskii-prod` | **The testers' sandbox**: the closed-test app talks to it. It holds the dev seed and was migrated by hand | By hand, with a script the owner runs; **never** `deploy-production` |
| production | Not created | Launch | `deploy-production` (RB-14) |

**The sandbox must be recreated before launch** (RB-15 §3.4): it was seeded with development data
and its field-encryption key was generated in place. Production is a new project built from the
migrations alone, with the five countries `disabled` until RB-08 takes one live.

## 3. How it fits together

One page each, in `docs/plan/`: `architecture-c4.md` (the containers), `data-flow.md` (where
personal data goes), `money-flows.md` (every posting), `rls-policy-matrix.md` (who reads what),
`state-machines/`. The short version:

- **Supabase** is the system of record: Postgres with RLS on every table, database functions
  that are the only write path (the client-callable ones are catalogued in `contracts/v1/rpc-catalog`), eight Edge Functions, Storage, Auth and Realtime.
  `supabase/README.md` has its rules.
- **pg_cron** runs the schedule: notifications every minute, SOS escalation every minute, the
  nightly ledger reconciliation, partition upkeep, KYC expiry, the reputation sweep and more.
  `select jobname, schedule from cron.job` lists them.
- **Google Cloud** runs what Supabase cannot: the backup jobs (Cloud Run Jobs), the AI service
  when it exists, Secret Manager, monitoring and budgets. All of it is Terraform in `infra/terraform`.
- **Cloudflare** serves the three websites (marketing at the apex, the customer web app at `app.`,
  the admin console at `admin.` behind Access) and routes email to people.
- **Clients**: the Flutter app (`apps/mobile`), the three Next.js sites (`apps/web-*`). Kimi Code
  built them; `AGENTS.md` and `README.md` cover building them.

## 4. Running it

| Task | How | Runbook |
|---|---|---|
| Ship backend changes | Merge to `main`: `pipeline-main` checks, then deploys staging, and refuses to finish unless `/health` passes on the new release | RB-14 |
| Roll back functions | `rollback-functions` workflow, to a named SHA | RB-14 |
| Ship the Android app | `mobile-release` workflow (approve the `prod` environment), then promote in Play | RB-15 |
| Ship a website | `web-deploy` workflow with `app=` the site (approve `web-production`) | `infra/web/README.md` |
| Change infrastructure | `infra-deploy` workflow, `plan` then `apply` (approve `infra-<env>`) | RB-14 |
| Turn a feature off | Upsert the flag (RB-13). **No app reads flags yet** (HANDOFF part 19, X.1): today this changes the server and nothing on a phone | RB-13 |
| Anything on fire | RB-01 first, always | RB-01 |

All sixteen runbooks are written. Staging rehearsals so far: RB-03, RB-05 (queue half), RB-06, RB-08
(database half), RB-13 and RB-14. **Not rehearsed**: RB-01 and RB-07 (tabletops; they need people),
RB-02 and RB-04 (a payment gateway), RB-09 on staging (waits on the backup secrets), RB-10 and
RB-16 on staging (secret writes the owner runs), RB-11 and RB-12 (blocked; each says why).

## 5. Secrets: names and places, never values

| Where | Names | Set by |
|---|---|---|
| GCP Secret Manager, per project (created **empty** by Terraform) | `supabase-db-password`, `supabase-service-role-key`, `supabase-db-backup-url`, `supabase-storage-sync-key`, `send-sms-hook-secrets`, `suskii-field-kek-v1`, `google-play-integrity-service-account`, `sentry-dsn-edge-functions`, `sentry-dsn-ai-service`, `fcm-service-account` | The owner, with the helper scripts in `supabase/tools/` and `infra/tools/`, which store a value without showing it |
| GitHub environment `prod` (mobile releases) | `ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD`, `GOOGLE_MAPS_API_KEY`, `PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `FIREBASE_ANDROID_API_KEY` | The owner |
| GitHub environments `dev`, `staging` | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `HEALTH_CHECK_API_KEY` | The owner; `set_health_key.py` for the last |
| GitHub environments `infra-*` | `HEALTH_CHECK_API_KEY` (the uptime checks wait for it) | `set_health_key.py <ref> infra-<env>` |
| GitHub environment `web-production` | `CLOUDFLARE_API_TOKEN`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | The owner |
| Supabase Vault, per project | `edge_functions_url`, `worker_api_key` (pg_cron calls the workers with them); the field-encryption key | `set_worker_key.py <ref>`; the KEK by migration, escrowed with `escrow_kek.py` |
| Supabase secret API keys, per project | `monitoring` (uptime checks), `worker` (pg_cron to the workers), `backup` (the Storage mirror) | Created in the dashboard |

The rules (CLAUDE.md, ADR-0007): no service-role key in any client or the repository, secrets
only in Secret Manager, Vault or GitHub secrets, and rotation through RB-10.

## 6. Alerts and money

**Alerts go to `ALERT_EMAILS`**, today the builder's Gmail. Change it to the client's on-call address
(an `infra-*` variable, then `infra-deploy` apply).

| Alert | Fires when | Then |
|---|---|---|
| *health check failing* | `/health` returns 503 from multiple regions: the database, the outbox, the audit chain, partitions, backups, the ledger reconciliation, notifications or scheduled jobs | RB-01, and the body says which |
| *SOS unacknowledged* (CRITICAL) | An SOS was escalated after three minutes and nobody has acknowledged it | RB-06, now. It is an email, not a pager: a live country needs the console staffed |
| Budgets | 50, 80 and 100% of $20 (dev), $20 (staging), $50 (prod) a month | Look; budgets are alerts, not caps |

**What it costs today**: GCP within the budgets above, Supabase Free, Cloudflare Free, Resend's free
tier, Play's one-off $25 already paid. Cloud Monitoring bills alerting at about **$0.10 a condition a
month** from 2026-05-01 [S: Google's alerting cost guide]; there are two conditions per environment.

**What launch adds**, from `docs/research/cost-model.md` and the vendors' pages at the time of writing:

| Item | Cost | Why |
|---|---|---|
| Supabase Pro for production | $25 a month and up, plus compute | Free compute is not production: the 2026-10-26 load test fits launch traffic with little room to spare |
| Point-in-time recovery | **$100 a month for 7 days** (14 days $200, 28 days $400) on a Pro project [V: Supabase pricing] | RB-09's recovery point; daily logical backups alone lose up to a day. **Owner's decision, 2026-10-26: a launch requirement on the production project, not the sandbox** |
| Apple Developer Program | $99 a year | iOS |
| Play organisation account | $25 once | OD-29 |
| SMS | Per message, prepaid (Termii) | Phone sign-in |

## 7. What is not done

| Gap | Waiting on | Where it is written |
|---|---|---|
| Payments (Flutterwave, Paystack adapters) | Merchant accounts (client action 4), OD-12, OD-29 | Phase 5 in `CLAUDE.md` |
| Identity verification vendor | A contract (client action 7) | RB-05 |
| SOS partner | Client action 12 | RB-06 |
| Phone sign-in by SMS | Termii resumed with a CAC-backed sender ID | §1 |
| AI concierge, in-app calls | Being built (go-live items 5 and 6) | HANDOFF |
| The apps reading feature flags and forcing updates | Kimi (HANDOFF part 19, X.1 and X.2) | RB-13 |
| Independent penetration test | A vendor, booked about six weeks ahead | Timeline row 20 |
| Target-scale load test | The production-sized project, before launch (owner's decision, 2026-10-26) | `tests/load/README.md` |
| Counsel's sign-off: terms, restricted items, funds holding | Counsel (OD-12, OD-24) | `docs/OPEN-DECISIONS.md` |

The open decisions themselves live in `docs/OPEN-DECISIONS.md`, with the default the build uses
until each is answered. Read that file before changing anything about money, verification or a
country.
