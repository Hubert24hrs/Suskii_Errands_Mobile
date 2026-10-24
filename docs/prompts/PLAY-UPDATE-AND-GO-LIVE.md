# Prompt — update the app on Google Play, put the backend in production, finish the integrations

Written 2026-10-24 by Claude Code at the owner's request: *"the app is already on Google Play, so
write a prompt to prompt an LLM to update the AAB file and finish other things, including all the
backends and other integrations"*.

## How to use it (for the owner)

1. On your own computer, open the repository root in a coding agent that can run commands:
   Claude Code, or any agent with a terminal. The agent fetches the latest `main` itself.
2. Have these tools installed: `git`, the GitHub CLI `gh` (signed in), Flutter 3.47.1, Java 17,
   Node 22, Docker, the Supabase CLI (`npx supabase@2.117.0`), `gcloud`, Terraform, Ruby 3.3 with
   Bundler.
3. Paste everything between the two lines below as the first message.
4. The agent will ask you for things only you can do: consoles, payments, contracts. **Never paste
   a password, private key, keystore, service-account JSON or API secret into the chat.** When
   the agent needs one, it gives you the exact `gh secret set …` (or console page) to run
   yourself.

---

## Role and goal

You are the release and integration engineer for **Suskii Errands**, an errands and services
marketplace for Africa (Nigeria first). It is a Flutter app (`apps/mobile`), three Next.js web
apps (`apps/web-*`) and a Supabase backend (`supabase/`), with GCP for secrets, backups and
workers (`infra/terraform`). The owner says **the app is already live on Google Play**.

What the repository's run history shows (2026-10-24):

- `mobile-release` run #1 (2026-10-13, `main` at `3fbf3ca`) built the **prod** AAB: package
  `com.suskiierrands.app`, version code **10**.
- It was signed with the upload key from the `prod` environment's secrets, with upload off. The
  owner then uploaded artifact `android-prod-10` to Play by hand.
- The `prod` environment has a `SUPABASE_URL` (the build refuses prod without one).
- **No backend has ever been deployed by the pipeline**: zero `deploy-production` and
  `infra-deploy` runs, and every dev/staging deploy skipped. Unless someone pushed migrations
  by hand, the app on Play talks to an empty project and cannot load.

Your goal, in order:

1. Take over the Play listing safely and ship an **updated AAB** built from the latest `main`,
   through the repository's own pipeline.
2. Put the **backend in production** so that AAB talks to a real backend, not demo data.
3. Turn on every integration that only needs configuration (maps, sign-in, email, SMS, crash
   reports, App Links, the website).
4. Write the **vendor integrations that are still stubs** (payments, push, identity
   verification, calls), each behind the seam the code already has, against the vendor's sandbox.

Work in that order. A later step never goes ahead of an earlier one that failed.

## Read first (before any change)

- `CLAUDE.md`: the project's rules, ownership and status. Its Non-negotiables bind you.
- `docs/spec/SUSKII_BUILD_PROMPT.json`: the source of truth.
- `HANDOFF.md`: the newest entries first, at least back to 2026-10-13.
- Runbooks, in this order:
  - `docs/runbooks/RB-15-store-release.md` (store release; §3.4 is written for exactly this situation);
  - `RB-14-backend-deploy-and-rollback.md`;
  - `RB-16-field-encryption-keys.md`;
  - `RB-08-country-go-live.md` (step 0 is for a new production project);
  - `RB-13-kill-switch-and-forced-update.md`.
- Plans and decisions:
  - `docs/plan/infra-cicd.md`;
  - `docs/plan/timeline.md` §5 (the client action list);
  - `docs/OPEN-DECISIONS.md` (what is still undecided; do not decide those yourself).
- Contracts: `contracts/README.md` and `contracts/v1/`. The apps and the backend are bound by them.

## Non-negotiable rules

- **Secrets**:
  - Never commit or print a secret.
  - Never ask the owner to paste one into the chat.
  - Secrets live in GitHub environment secrets, GCP Secret Manager or Supabase Vault, nowhere else.
  - The Google Maps key is never in the repository; `gitleaks` in CI fails on one.
  - No keystore, `key.properties`, `.p8`, `.p12` or service-account JSON in git, ever.
- **Git**:
  - Branch from `origin/main`, open a pull request, wait for every check to be green, then merge.
  - Never force-push `main`, never skip, disable or quarantine a test, never push an empty commit
    to re-run CI.
  - A red check is yours to root-cause.
- **Money**: integer minor units with an ISO 4217 code (UGX has no minor unit), never floats. The
  server decides prices, money, job states, verification and permissions. Held funds are
  "held", never "escrow". Every create, transition and money operation carries an idempotency
  key.
- **Database**:
  - Every state or money write goes through a database function or an Edge Function.
  - Every exposed table has RLS with pgTAP allow and deny tests.
  - `SECURITY DEFINER` functions use an empty `search_path` and check `auth.uid()`.
  - A schema change regenerates `contracts/v1` (`python3 contracts/tools/generate_v1.py . --write`)
    and updates `contracts/CHANGELOG.md`.
  - Migrations are expand-only; never edit one that has been applied.
- **Vendor facts**:
  - Never invent a vendor's API, payload, signature scheme, model name or legal requirement.
  - Read the vendor's current official documentation, cite it in the code comment or the ADR,
    and test against the vendor's sandbox.
  - Mark anything you could not verify `VERIFY-IN-RESEARCH`, and do not ship it as fact.
- **Decisions**: if a step needs an open decision (`docs/OPEN-DECISIONS.md`) or a legal answer,
  stop and ask the owner. Never pick for them.
- **Documentation is part of done.** Each change updates its runbook, the `CLAUDE.md` status table,
  a dated `HANDOFF.md` entry and, for a decision, an ADR (`docs/adr/`).

## Phase 0 — Orient and prove the repository is green (no changes)

Kimi Code, the frontend agent, may be editing this same folder, so follow `CLAUDE.md` → "Working
alongside Kimi Code": never `git checkout` or `git switch` here. Work in a fresh worktree off
`origin/main` and run everything from it:

```bash
git fetch origin main && git worktree add -b release-work ../suskii-release origin/main
cd ../suskii-release
apps/mobile/tool/bootstrap.sh
npx supabase@2.117.0 start -x studio,imgproxy,logflare,vector,supavisor,edge-runtime,postgres-meta
npx supabase@2.117.0 db reset --local
npx supabase@2.117.0 test db --local supabase/tests/database
(cd supabase/functions && npx deno@2.9.6 test --allow-env)
python3 contracts/tools/check_frontend_calls.py . && python3 contracts/tools/check_screen_parity.py .
(cd apps/mobile && flutter analyze && flutter test)
npm ci && npm run build -w apps/web-customer
```

Also check that the latest `main` is green on GitHub (`gh run list --branch main`). Report what you
found before changing anything.

## Phase 1 — Take over the Play listing (facts before builds)

Ask the owner to give you, or to read out to you, the following from **Play Console**. RB-15 §3.4
explains each item.

1. **Package name.** It must be `com.suskiierrands.app` (the prod build has no suffix; OD-26).
   **If it is anything else, stop.** A package name can never change; ask the owner how to
   proceed.
2. **The highest version code on any track** (App bundle explorer). It should be 10, from run #1,
   and the next pipeline run produces 20. Only if something higher was uploaded by hand, have the
   owner set it as the repository variable:

   ```bash
   gh variable set BUILD_NUMBER_FLOOR --body "<that number>"
   ```

   `mobile-release.yaml` uploads `BUILD_NUMBER_FLOOR + run × 10`, so Play never refuses it as a
   duplicate.
3. **Play App Signing and the upload key** (App integrity page):
   - Confirm Play App Signing is on.
   - Record the **app signing key** SHA-1 and SHA-256, and the **upload key** SHA-1.
   - Find the keystore the owner used for the first upload. Have them run
     `keytool -list -v -keystore <file>` and compare its SHA-1 with Play's upload certificate.
   - If they match, have the owner set the four `ANDROID_UPLOAD_*` secrets in the GitHub `prod`
     environment, per RB-15 §3.1, themselves.
   - If the keystore is lost, have them request an **upload key reset** on that same page and
     register a new upload key made per RB-15 §3.1. Wait for Google to accept it before
     uploading.
4. **What the live build talks to.** Have the owner open the Supabase project whose URL is in the
   `prod` environment's `SUPABASE_URL` (dashboard → Database → Migrations, or the Table editor).
   - If it has no migrations, the live app cannot load. Tell the owner plainly, and treat Phase 2
     as urgent.
   - If someone pushed migrations by hand, compare them with `supabase/migrations/`. Plan the first
     `deploy-production` from that state, and get the owner's decision before touching any data. Check the store listing text against
   what the build actually does (RB-15: "the store listing must not promise what the build cannot
   do").
5. **Play Developer API access.** The owner creates a service account with release permissions on
   the app (RB-15 action 21) and stores it as the `PLAY_SERVICE_ACCOUNT_JSON` secret of the `prod`
   environment.

Record the answers (no secrets) in RB-15 §3.4 and in `HANDOFF.md`.

## Phase 2 — Production backend

The designed path is RB-14: `pipeline-main` (checks → dev → staging), then `deploy-production`.
It needs GCP: function secrets come from Secret Manager through Workload Identity. **Do not
invent a second deploy path.** If the owner cannot open GCP billing yet (client action 1), stop
here and say that this is the blocker.

1. **Accounts, made by the owner:**
   - a Supabase organisation with three projects, `dev`, `staging` and `prod`. The region is
     `docs/OPEN-DECISIONS.md` OD-15 (London provisional): confirm it with the owner first;
   - a GCP organisation or projects with billing on;
   - GitHub environments `dev`, `staging`, `production`, `infra-dev`, `infra-staging`,
     `infra-prod`, with required reviewers on the production ones.
2. **GCP**: follow `infra/terraform/README.md`.
   - Run `bootstrap` once, then `envs/<env>` through the `infra-deploy` workflow.
   - Values go into Secret Manager out of band, never through Terraform variables committed
     anywhere.
3. **Field-encryption key** (RB-16): before any real person's data exists, pre-create the KEK and
   **escrow it to GCP Secret Manager**. A KEK that lives only in Vault dies with the project.
   Follow RB-16 step by step.
4. **GitHub environment variables and secrets** per environment. The full list is in the header of
   `.github/workflows/_deploy-supabase.yaml`:
   - variables: `SUPABASE_PROJECT_REF`, `SITE_URL`, `GCP_*`, `ANDROID_PACKAGE_NAME`, `IOS_APP_ID`
     and the rest;
   - secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `HEALTH_CHECK_API_KEY` and the
     rest.

   Then set `DEPLOY_DEV_ENABLED=true` and `DEPLOY_STAGING_ENABLED=true` as repository variables.
5. **Deploy**:
   - Push a commit or re-run `pipeline-main`, and watch dev, then staging, go green. Each ends with
     the `health` smoke test.
   - Then run `deploy-production` with the same SHA and the PITR confirmation.
6. **Prove the production database is right.** Production is built from migrations only, never
   from `supabase/seed/`. Migration `20261024150000_production_reference_data.sql` gives it the
   five countries (all `disabled`), Nigeria's 37 states and the 21 service categories. Run
   `supabase/tools/check_production_reference.sql` against production through the owner's
   session, and expect `ok`.
7. **First admins, legal pages, providers, Nigeria to beta**: RB-08 step 0, then step 2.
   - The first two `super_admin` rows are the one insert made outside the four-eyes flow.
   - The owner names the two people, who each enrol TOTP.
   - Legal pages go in as a migration once counsel has published them (OD-24, action 16).
   - **Nigeria moves to `beta` only when the owner says so.** Until then, nobody can sign up by
     phone; that is intended.
8. **A Play review account** (RB-15 action 25): a fixed test phone number and code in the
   production Auth settings, entered by the owner in Play Console → App content → App access.
   Never committed.

## Phase 3 — Integrations that are configuration only

All are built in the code and wait for keys. Each row has its RB-15 action number.

| Integration | The owner does | You do |
|---|---|---|
| **Google Maps** (action 31) | Google Cloud: enable Maps SDK for Android, Maps SDK for iOS and Maps JavaScript API, with billing on. Create three restricted keys: Android (package `com.suskiierrands.app` plus the **app signing** SHA-1 from Phase 1, plus the upload SHA-1; add `com.suskiierrands.app.dev` plus the test-key SHA-1 for the test APK), iOS (bundle id), web (the site's domains). Then: `gh secret set GOOGLE_MAPS_API_KEY`, and `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` in the web host | Confirm the release build gets the key (`tool/write_release_env.sh` writes it from the secret) and that the pickup map renders on a real device |
| **Test APK signing** (action 32) | Run `apps/mobile/tool/new_test_key.ps1` once and set the four `ANDROID_DEV_*` secrets | Confirm the next `dev-latest` APK is "Signing the test APK with the fixed test key" in the `mobile-native` log |
| **Google sign-in** (action 29) | OAuth clients: web, Android (the app signing **and** upload SHA-1s), iOS | Put the public client IDs in `apps/mobile/config/env/prod.json` (`GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`) by pull request; set `GOOGLE_CLIENT_IDS` (web first) and `GOOGLE_SKIP_NONCE_CHECK=true` as environment variables; the owner sets `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` |
| **Sign in with Apple** (action 30) | A Services ID and a Sign in with Apple key (needs the Apple Developer account, actions 9b and 22) | `APPLE_CLIENT_IDS`; the owner sets `SUPABASE_AUTH_EXTERNAL_APPLE_SECRET` |
| **Email OTP in production** | Pick an SMTP provider and give the sender domain DNS (SPF, DKIM) | Configure custom SMTP for the production Auth project. Supabase's built-in mail service is for testing, with tight rate limits. `VERIFY-IN-RESEARCH` the current limits in Supabase's docs and cite them |
| **SMS OTP** (action 5) | Sender-ID registration and DND whitelisting in Nigeria; an account with the chosen vendor | The vendor adapter (Phase 6.1), then the country's `sms_providers` through a config change (RB-08 step 0.3) |
| **Domain** (action 18, I-2) | Choose and buy the domain | Replace the placeholder `suskii-errands.example` in `apps/mobile/config/env/*.json`, `fastlane/metadata` and the web apps; set `ANDROID_CERT_SHA256` (app signing and upload SHA-256, comma-separated) and `APPLE_TEAM_ID` where the marketing site is hosted, so `assetlinks.json` and `apple-app-site-association` are served; verify App Links on a device |
| **Sentry** (action 28) | A Sentry project | `SENTRY_DSN` secret per environment, and the Edge Functions' DSN in Secret Manager; upload `mapping.txt` and Dart symbols from each release artifact |
| **Play Integrity / App Attest** | Link the Play Integrity API to the GCP project; App Attest needs the Apple account | Secret `google-play-integrity-service-account` in Secret Manager; `APP_ATTEST_ENVIRONMENT=production` |

## Phase 4 — Build and upload the updated AAB

1. In `apps/mobile/pubspec.yaml`, raise the semver `version:` above the version name live on Play.
   The build number comes from the workflow.
2. Add Play release notes: `apps/mobile/fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
   For the current release, the changes since the last upload are:
   - the real app name;
   - no country picker (the country comes from the phone);
   - the provider dashboard;
   - Google Maps for the pickup;
   - nearest providers first;
   - Suskii Meet;
   - Google and Apple sign-in;
   - new service categories.

   Mention only what the production backend and keys actually support at upload time.
3. **Staging first**: Actions → `mobile-release` → environment `staging`, platforms `android`,
   track `internal`. Install from the internal track and run RB-15 §5's smoke list on a real phone.
4. **Production**: run `mobile-release` with `prod` and track `internal`, or tag
   `mobile-v<version>`.
   - Promote internal → production in Play Console, with a staged rollout of 5% → 20% → 50% → 100%,
     a day apart, watching crashes and support tickets.
   - `production` uploads as a draft, so a person starts the rollout.
   - If Play refuses the first API upload, follow RB-15 §3.3: run with `upload: false`, and the
     owner uploads the artifact by hand.
5. Set `min_supported_app_version` (RB-13) only after the update is live everywhere, and only if
   older builds must stop working (for example, a demo build pointed at nothing).
6. Store questionnaires (action 26):
   - update **Data safety** from `docs/store/play-data-safety.md`. Location now includes the
     pickup point, the online provider's position, Suskii Meet and the country inferred at
     sign-up;
   - complete the **precise-location declaration** (enforced from 27 Jan 2027);
   - check the content rating and target audience (OD-28: adults only).

## Phase 5 — Website hosting

Hosting is open decision I-2 in `docs/plan/infra-cicd.md`: Vercel, or Cloudflare via OpenNext.
**Ask the owner.** Then deploy `apps/web-marketing`, `apps/web-customer` and `apps/web-admin`, each
with its production `NEXT_PUBLIC_SUPABASE_*` values and, for the customer site,
`NEXT_PUBLIC_GOOGLE_MAPS_API_KEY`.

- The admin console must sit behind Cloudflare Access or an equivalent, not be open to the
  internet.
- Add a deploy workflow by pull request and keep the existing smoke and E2E suites green.

## Phase 6 — Write the integrations that are still stubs

Each has a seam in the code today: an interface, a `console` development implementation, tests and
a runbook. Build the real one behind the seam, sandbox first. Before writing each one, record the
vendor's current docs (links and the date read) in an ADR or in RB-02/RB-05. Every vendor key goes
in Secret Manager.

1. **SMS**: `supabase/functions/_shared/sms/` (the `SmsProvider` interface, routing and failover).
   - Add the vendor the owner contracted: Termii, Africa's Talking or Infobip, per
     `docs/research/vendor-decision-matrix.md`.
   - Spike S-09 in `docs/research/spike-plan.md` is the acceptance test.
2. **Payments**: Flutterwave first, Paystack second (OD-11). The seam is
   `supabase/functions/_shared/payments/provider.ts` (`PaymentProvider`), used by
   `payments-worker` (checkout, transfer, name enquiry, refund) and `payments-webhook` (verify the
   signature over the raw body, store raw, de-duplicate, verify server-side, then post to the
   ledger).
   - Spike S-12 (`docs/research/spike-plan.md`) against the sandbox is the acceptance test.
   - `console` must never run in production; the code already refuses it.
   - When both pass, propose the country's `payment_providers` and `payout_providers` (RB-08).
   - RB-02 and RB-04 are the runbooks.
3. **Push notifications** (actions 27 and 22): FCM and APNs adapters in
   `supabase/functions/_shared/notifications/sender.ts`. Keep the payload rule that file
   enforces: an identifier and a generic title, never an amount or a name.
   - In the app: add `firebase_messaging`, call the existing `register_device` RPC, ask for
     `POST_NOTIFICATIONS` in context, and add the `remote-notification` background mode (RB-15 §6).
   - `mobile-native.yaml` fails on any sensitive permission you did not declare on purpose.
4. **Identity verification**: Smile ID (OD-13, action 7). `start_verification_session` and the
   KYC tables are built; the vendor half is RB-05's `[VENDOR]` steps.
5. **Calls and the voice concierge** (action 11): the LiveKit access-token Edge Function, and
   number masking with the contracted telephony provider. `calls` already records metadata only,
   **and must never gain a recording**.
6. **AI concierge** (Phase 7, action 1): the FastAPI service on Cloud Run with Vertex AI. Work only
   within `services/ai/tools/allowlist.json`; `raise_sos` stays denied.
7. **SOS partner** (action 12): RB-06's `[PARTNER]` steps.

Each integration is one pull request: tests (Deno or pgTAP, and the apps' journeys when screens
change), contract updates, the runbook marked as rehearsed when you have actually run it, and a
`HANDOFF.md` entry.

## Stop and ask the owner when

- the Play package name is not `com.suskiierrands.app`, or the upload key cannot be matched;
- a step needs an open decision (OD-09, OD-10, OD-12, OD-14 to OD-18, OD-20 to OD-24, OD-26 to
  OD-28) or counsel (legal pages, prohibited items, funds holding);
- a step costs money (billing, vendor plans) or signs a contract;
- a step would move a country to `beta` or `live`, or start a production rollout;
- anything would put a secret in the repository or the chat.

## Definition of done

- Play shows a new version on the production track, from `mobile-release`, built against the
  production backend. It installs over the old one, and RB-15 §5's smoke list passes on a real
  phone, map included.
- `deploy-production` is green on the same SHA; `health` returns 200 with that release.
- Every integration in Phase 3 is configured or listed as blocked with its owner action.
- Phase 6 items are merged with tests green, or listed with the precise blocker (which contract,
  which key).
- `CLAUDE.md`, the runbooks you used (with *Last rehearsed* filled in), `docs/store/` and a dated
  `HANDOFF.md` entry describe what is now true.

Finish with a short report: what shipped (versions, build numbers, SHAs), what is configured,
what is still blocked and on whom. No secrets in the report.

---
