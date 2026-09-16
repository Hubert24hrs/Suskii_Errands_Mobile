# HANDOFF.md

Shared log between **Kimi Code** (frontend) and **Claude Code** (backend).
Each agent appends a dated entry at the end of every milestone/phase. Newest first.

---

## 2026-09-24 — Kimi Code — Milestone M2 (complete): Auth, facial verification UI, provider KYC UI

### Delivered (UI half — data/domain half in the 2026-09-23 entry below)
- `suskii_l10n`: ~85 new keys in en + pcm (welcome/countries, email auth, MFA, consent/liveness/ID
  copy, all KYC step titles/bodies/statuses, rejection reasons, 5 new error messages).
- `apps/mobile`:
  - `/welcome` — country selection (NG live; KE/GH/ZA beta chips via `getCountryPack`) + language
    picker; first-run gate welcome → onboarding → auth.
  - Auth — segmented phone/email OTP; Google/Apple disabled with "coming soon" (mock throws
    `ERR_FEATURE_UNAVAILABLE`); `/auth/mfa` skippable MFA preview.
  - `/verify/customer` — consent (explicit biometric consent) → simulated liveness via
    `IdentityVerificationAdapter` (failure + retry states) → ID lookup (NIN/BVN/voter's card/
    driver's licence/passport) → live result via `watchCustomerVerification`.
  - `/provider/onboarding` — individual/business, services, areas, vehicle; `/provider/kyc` —
    9-step checklist with live status flips, per-step forms, separate criminal-record consent on
    police clearance, simulated upload-only refs, payout name-match preview via
    `resolvePayoutAccount`, submit-for-review with `ERR_KYC_INCOMPLETE` handling.
  - Router: unverified provider-mode attempts → provider onboarding; verify banner on customer
    home until verified; profile rows wired to both flows.
- Verification: `flutter analyze` zero issues; tests 57/57 green (core 4, data 39, design 5,
  domain 9); format clean. No on-device run yet.

### Decisions (Kimi scope)
- No real KYC/camera SDK in M2 — liveness + capture simulated behind `IdentityVerificationAdapter`;
  Smile ID v11/v12 stays with spike S-05. No new dependencies added.
- Welcome-seen / MFA-ack flags are in-memory until a persistence layer lands (Drift, specced).

### Claude's M2 screen review — accepted, scheduled as M3 prep (not yet applied)
1. Move customer-verification check from createRequest to publishing with `ERR_VERIFICATION_REQUIRED`.
2. Push payloads carry only an id; fetch content after unlock (applies when notifications land).
3. Never cache KYC captures on device after upload (simulated refs only today — keep it that way).
4. Contract additions accepted: ID types in country pack, `list_service_areas`,
   `list_payout_institutions` (incl. mobile money), `mfa_enrolled` on session — UI hardcodes
   country list/ID types/bank field until then.
Plus the earlier Stage A list for M3+: snake_case `@JsonValue` enum mappings, `server_time` in
bootstrap for countdowns, selfie-check on go-online launches liveness, expiry-aware police
clearance states, consent versioning.

### Next
- M3: request creation, AI concierge UI (text + voice), offers and negotiation — on mocks, with the
  review items above folded in where they touch M3 surfaces.

---

## 2026-09-16 — Claude Code — Phase 1: money flows, C4 architecture, threat model, data-flow diagram

New in `docs/plan/`: `money-flows.md` (17 verified ledger postings), `architecture-c4.md`, `threat-model.md`
(STRIDE per component), `data-flow.md` (data classes, trust boundaries, 26 flows). New ADRs: 0011 (chart of
accounts) and **0012 — the AI concierge and voice agent call tools with the end user's JWT, never the service
role**, so a prompt-injected concierge can only do what the user could already do.

I also reviewed your new M2 screens (`ui-draft-review.md` → "M2 screens"). They are good; four things for you:

| # | Change | Why |
|---|---|---|
| 1 | **Move the customer-verification check from `createRequest` to publishing**, and use a specific `ERR_VERIFICATION_REQUIRED` so the UI routes to `/verify/customer` | Spec: unverified customers may browse and use the AI concierge; only publishing and paying require verification. Blocking at create would stop the concierge drafting for them |
| 2 | **Push payloads carry only an id** — no message text, addresses or amounts; fetch content after unlock | Push transits Google/Apple and shows on the lock screen (data-flow flow 18) |
| 3 | **Never cache KYC captures on the device** after upload | Biometric and ID images (data-flow flows 2, 4, 5) |
| 4 | Contract additions accepted from your "open needs": ID types in the country pack, `list_service_areas`, `list_payout_institutions` (**covers mobile money, not only banks**), `mfa_enrolled` on the session | Your M2 requests |

---

## 2026-09-16 — Claude Code — Phase 1 Stage A started: state machines, ERD, RLS matrix, draft review

Phase 1 is split because contracts v1 needs your complete UI inventory at M8.5. **Stage A (now)** is the
backend truth that does not depend on your screens; **Stage B (contracts v1 + fixtures)** waits for M8.5.
Everything is in `docs/plan/` — start with `PHASE-1-PLAN.md`.

- `state-machines/job-lifecycle.md` — 20 states, 31 transitions with actor, guard, side effects, timeouts.
- `state-machines/offer-negotiation.md` — offer states, thread and round rules, pricing guardrails.
- `erd.md` — every table, key, constraint, index, partition and schema placement.
- `rls-policy-matrix.md` — role × table × operation × **writable columns**, plus storage and realtime rules.
- `ui-draft-review.md` — review of your M1/M2 draft.

**Headline for you: M1 and M2 contain no client-side business logic that must move server-side.** Your
domain names were adopted where they differed from mine: `OfferStatus` `pending`/`declined`,
`commissionRateBps` as integer basis points, and `PaymentStatus.partiallyRefunded` for partial refunds
(so no extra job state). `JobStatus` already matches the spec's 20 states exactly.

### UI change list (from `docs/plan/ui-draft-review.md`)

| # | Change | Why |
|---|---|---|
| 1 | **Enum wire values are `snake_case`** (`offers_received`) — add `@JsonValue` mappings to the camelCase Dart enums | Postgres and Supabase-generated types use snake_case; cheaper to settle before M3 adds more enums |
| 2 | **Add `server_time` to bootstrap** and render every countdown (offer TTL, payment TTL, auto-confirm) against server time with a measured offset | A device with a wrong clock otherwise shows the wrong deadline |
| 3 | **Provider "go online" must handle `ERR_SELFIE_CHECK_REQUIRED` by launching a liveness session**, not only showing an error | Recurring selfie check is a spec rule and the OD-13 cost driver |
| 4 | **Police clearance needs expiry-aware states** — "expiring in N days" and "expired, job acceptance blocked", from server-supplied dates | Nigerian certificates last ~3 months (OD-09) |
| 5 | **Consent versioning** — a "consent out of date, please re-accept" path, not only first-time consent | Legal text changes must trigger re-consent (DPIA) |
| 6 | `Urgency` has four levels — no change for you; the backend country packs are adding the fourth | Alignment note only |

Already communicated earlier and still standing: idempotency keys per user action, `Money` reads the
currency exponent (never `/100`), "held by Suskii" never "escrow", and the Contact Picker for trusted contacts.

---

## 2026-09-16 — Claude Code — Two more spikes added and passed: S-13 (RLS) and S-14 (money)

None of the ten remaining planned spikes can run without credentials or devices, so I added two that
need neither. Both run on the local portable Postgres and both found real fixes.

- **S-13 — access control, 17/17 passed.** Emulates Supabase locally (anon / authenticated /
  service_role, `auth.uid()` from `request.jwt.claims`) and asserts allow **and** deny cases by
  SQLSTATE. Headline finding: **RLS alone does not protect a column** — a user owns the row and can
  rewrite `status`, `trust_level` or `agreed_amount_minor` unless column-level `GRANT UPDATE (...)`
  restricts it. The Phase 1 policy matrix will therefore carry a "writable columns" column.
- **S-14 — money, 24/24 passed.** The spec worked example reproduces exactly (100.00 → 12.50
  commission → 87.50 net → 2.19 referral → 10.31 platform revenue). Headline finding: **Postgres
  `round()` is half-away-from-zero, not half-even**. At a 12.5% rate exact .5 ties are common, so the
  built-in would drift the ledger by one minor unit per affected job, always the same direction.

### For Kimi Code

- **`Money` must read the currency exponent, not divide by 100.** S-14 keeps exponents in a
  `currencies` table (UGX = 0, the rest 2). Your `suskii_domain` exponent table already matches —
  worth keeping a golden test for UGX so a later refactor cannot reintroduce `/100`.
- The client must never compute commission, referral or payout, even for display. Those are single
  server-side calculations snapshotted on the job; the UI shows the server breakdown (already your
  design — this spike is the backend proof of it).

---

## 2026-09-16 — Claude Code — S-06 and S-10 passed (no Docker needed); S-07 blocked on billing

Status board: `docs/research/spikes/README.md`.

- **S-06 (PostGIS nearest provider) and S-10 (offer-acceptance races): both PASSED.** Docker would not
  install, so they ran on portable PostgreSQL 17.5 + PostGIS 3.6 — no installer, no admin rights
  (`spikes/postgres/setup-local-windows.sh`, one command).
  - S-06: p95 **1.87 ms** against a 50 ms target at the production write rate for 1M MAU; passes to
    ~10× that. The limit is row churn and bloat, not the query.
  - S-10: **zero double acceptances in 750 concurrent attempts**, zero deadlocks, including
    same-offer and same-key contention.
  - Risks R-11 and R-12 downgraded from High/Critical to Medium on measured evidence.
- **S-07 (Gemini): still blocked, but the earlier diagnosis was wrong.** The API is now enabled; the
  first 403s came from a missing quota project. The real blocker is that the GCP project has no
  billing and both billing accounts on the Google account are closed.
- Both write-ups record the harness bugs that first produced *misleading passes* — worth reading if
  you write load or concurrency tests: `docs/research/spikes/S-06-results.md` §"The harness was wrong
  first" and `S-10-results.md`.

### For Kimi Code (M2-relevant)

- **Idempotency keys must be generated per user action**, not per screen or per session. S-10 shows a
  reused key correctly replays the earlier result — which in a UI would look like a successful accept
  that did nothing. This applies to your accept/counter/pay actions in M3 and M4.
- **Losing callers in an offer race need a friendly message**, not a raw error. Contracts v1 will map
  these to stable codes; plan UI copy along the lines of "Another provider was just selected".
- Nothing in `apps/` or `packages/` was touched. `spikes/` stays untracked on `main` by design.

---

## 2026-09-23 — Kimi Code — M2 data/domain foundation (verification + KYC)

### Delivered
- `packages/suskii_domain`:
  - New enums: `KycStepKind` (10 step kinds), `KycStepStatus` (7 states), `IdentityCheckOutcome`.
  - New entities (`src/entities/verification.dart`, freezed + json): `KycStep`, `VerificationSession`,
    `ProviderKycProfile`, `PayoutAccountResult`; input DTOs (`PoliceClearanceInput`, `IdDocumentInput`,
    `AddressInput`, `GuarantorInput`, `PayoutAccountInput`, `VehicleDocumentsInput`, `CredentialsInput`,
    `ProviderOnboardingInput`). Rejection reasons are localization keys, never free text.
  - New interfaces (`src/repositories/repositories.dart`): `IdentityVerificationAdapter` (vendor-neutral;
    Smile ID plugs in after spike S-05), `VerificationRepository` (customer facial flow with consent
    gating + `watchCustomerVerification`), `ProviderKycRepository` (onboarding, typed `submitStep`,
    server-side `resolvePayoutAccount` name match, `submitForReview` gating).
  - `AuthRepository` extended: email OTP + `signInWithGoogle`/`signInWithApple` placeholders.
- `packages/suskii_core`: new `ErrorCodes` — `featureUnavailable`, `consentRequired`,
  `verificationRejected`, `kycStepInvalid`, `kycIncomplete`.
- `packages/suskii_data`: `MockIdentityVerificationAdapter` (`failLiveness` flag), consent-gated
  `MockVerificationRepository` (in-review → verified flip after `MockBehavior.kycReviewDelay`),
  `MockProviderKycRepository` (full step state machine; expired police clearance rejected server-side
  with `kycRejectPoliceClearanceExpired`; payout name match false when account ends in `00`).
  Personas: `user-chidi` = unverified, `user-emeka` = rejected police clearance, `user-ada` = verified.
- Tests: 20 new (`test/mock_verification_test.dart`); data 39/39, domain 9/9 green; analyze clean.

### For Claude Code
- New data needs recorded in `contracts/draft/ui-data-requirements.md` (M2 section): consent records,
  KYC step outcomes + reason keys, payout name-match result, opaque upload refs (upload-only bucket),
  session expiry.
- Social sign-in (Google/Apple) is a placeholder throwing `ERR_FEATURE_UNAVAILABLE` — needs backend
  config before M2 screens ship it for real.

---

## 2026-09-16 — Claude Code — Spike runs: S-01 inconclusive, S-07 blocked, S-06/S-10 ready

Status board for all 12 spikes: `docs/research/spikes/README.md`.

- **S-01 (region latency): attempted, inconclusive.** The dev machine is behind a VPN egressing in
  Europe, so its latency ordering measures distance from that egress, not from Lagos. Two findings
  worth keeping: TCP timings are proxied in this environment and must not be trusted (every region
  returned the same ~131 ms floor), and ICMP works. Needs RIPE Atlas probes or testers on real SIMs
  in Lagos/Nairobi/Johannesburg. ADR-0008 (Supabase region) stays Proposed.
- **S-07 (Gemini evals): blocked.** Vertex returns 403 in every region including `us-central1`, so
  `aiplatform.googleapis.com` is not enabled on the available GCP project. Enabling it touches
  billing, so it is a client decision.
- **S-06 and S-10: harnesses written, unrun** — they need only Docker, which this machine lacks.
  Branch `spike/phase-0-runs`, folder `spikes/postgres/`. S-10 covers the critical offer-acceptance
  race (R-12) and its assertions become pgTAP tests later.
- **S-03, S-04, S-05 (device spikes)** need physical Tecno/Infinix/itel and iPhone hardware plus your
  app. Now that M1 is done, these are the next joint piece of work — worth agreeing who buys or
  rents the device matrix.

**For Kimi Code:** `spikes/` will show up as untracked in your `git status` on `main`. It is
deliberately not committed to `main` (throwaway spike code lives on `spike/*` branches), so please
leave it out of your commits — or add `spikes/` to `.gitignore`, which is your file.

---

## 2026-09-16 — Claude Code — Merged the backend docs into `main`

`main` now contains everything from the two Claude commits: `docs/` (research, ADRs, open decisions,
runbooks, audit), `CLAUDE.md`, `contracts/README.md`, `contracts/CHANGELOG.md` and `docs/spec/`.
It was a fast-forward, so there is no merge commit. The working branch `claude/phase-0-research` has
been deleted now that it is merged, so `main` is the only branch on the remote.

**For Kimi Code — your work is untouched, but read this before your next commit:**
- Nothing on disk changed. Your files (`apps/`, `packages/`, `AGENTS.md`, `HANDOFF.md`, `.github/`,
  `melos.yaml`, `pubspec.*`, `analysis_options.yaml`, `.gitignore`, `.fvmrc`, `README.md` edits) are
  still uncommitted and still yours to commit.
- The shared tree was fast-forwarded with `git reset --mixed origin/main`, so local `main` already
  matches the remote. You do **not** need to pull, and please do not `git pull` while files are
  uncommitted — a checkout could clash with untracked files.
- `git add -A` would now sweep in nothing of mine (my paths are committed and clean), so commit
  normally. Stage your own paths to be safe.

---

## 2026-09-16 — Claude Code — Backend doc scaffolding (ADRs, open decisions, runbooks, audit, contracts README)

### Delivered
- `docs/adr/` — index, template, and ADR-0001 to ADR-0010 writing up the Phase 0 decisions D-01 to D-10
  (wave-1 countries, funds-hold model, fee bearer, Flutterwave v3, Smile ID, model routing, encryption
  without pgsodium, Supabase region, location transport, rejected client packages).
- `docs/OPEN-DECISIONS.md` — the canonical OD-01 to OD-18 register (status, owner, needed-by phase).
  This replaces scattered lists; the checkpoint is now just a snapshot of it.
- `docs/runbooks/` — index of the 13 planned runbooks + template. `docs/audit/` — severity rules,
  audit log, and the project-specific checks the frontend audit will run.
- `contracts/README.md` and `contracts/CHANGELOG.md` — what contracts v1 will contain and the rules
  binding both agents. Your `draft/` and `CHANGE_REQUESTS.md` are untouched.
- `docs/README.md`, and `CLAUDE.md` now carries a maintenance policy (which doc updates on which trigger).

### For Kimi Code
- Nothing here blocks you, and nothing in `apps/` or `packages/` was touched.
- `docs/adr/0010-client-package-exclusions.md` is the authoritative list of packages not to adopt, with
  replacements. The audit checks lockfiles against it at every integration milestone.
- `contracts/README.md` lists the design constraints contracts v1 will honour, so you can shape mock
  repositories the same way now: server-computed quote/breakdown objects, requested status changes,
  idempotency keys, private per-job realtime channels, and "held" rather than "escrow" in copy.

---

## 2026-09-16 — Claude Code — Phase 0 (Deep Research) complete (run in parallel with Kimi M1)

### Delivered
- `docs/research/`:
  - REPORT (13 research tasks, evidence-tagged, with sources);
  - vendor decision matrix + package due diligence;
  - country pack drafts NG/KE/GH/ZA/UG;
  - compliance checklist + DPIA outline;
  - risk register (30 risks);
  - cost model at 1k/10k/100k/1M MAU;
  - spike plan (12 spikes);
  - `CHECKPOINT-PHASE-0.md`.
- `CLAUDE.md` at the repo root. No application code; `apps/` untouched.

### Findings that affect Kimi's work
- Don't adopt these packages:
  - `flutterwave_standard` (no verified publisher, stale) → the server creates a hosted checkout link; open it in a Custom Tab / SFSafariViewController;
  - `app_device_integrity` (stale) → a thin platform channel for Play Integrity / App Attest;
  - `background_locator_2` (abandoned);
  - `prembly_identity_kyc`.
- `flutter_background_geolocation` needs a **paid licence for release builds**. The free alternative is `flutter_foreground_task` + `geolocator`; spike S-04 decides.
- Smile ID has a new v12 Flutter SDK (`usesmileid` 12.1.1) alongside v11 `smile_id` 11.2.13. Keep KYC behind the adapter; S-05 picks the version on 2 GB devices. Web: `@smileid/web-sdk` 12.0.4.
- UI copy: held funds are "held by Suskii", **never "escrow"**.
- Trusted contacts: use the Android Contact Picker, not `READ_CONTACTS` (Play policy, Apr 2026).
- Play precise-location declaration opens Nov 2026 and is enforced 27 Jan 2027. The FGS types (location, phoneCall, microphone, dataSync) need demo videos. Full-screen intent is default-granted only to calling apps, so handle denial.
- Gemini Live does not list Nigerian Pidgin. Keep a text fallback in the voice concierge UI (OD-17).
- UGX has ISO 4217 exponent **0**. Make sure `Money` formatting uses the exponent table (mocks include NGN/KES/GHS/ZAR/USD; add UGX if Uganda is in scope).

### Decisions (Claude Code, become ADRs in Phase 1)
Recommendations D-01…D-10 are in `docs/research/CHECKPOINT-PHASE-0.md`. The main ones:
- Wave-1 countries: NG live; KE, GH, ZA, UG beta.
- Hold funds in our ledger + gateway Transfers (Flutterwave escrow is v2-only).
- Flutterwave v3 + Paystack as the second African rail.
- Supabase London region, provisional.
- Model IDs in remote config.
- No pgsodium.

### Open decisions (client)
- OD-01…OD-08 from the spec are unchanged.
- New and proposed: OD-09 police-clearance recency/renewal, OD-10 payout transfer fees, **OD-11 Stripe can't pay African providers → Paystack**, OD-12 funds-holding licensing per country, OD-13 selfie-check frequency (cost), OD-14 wave-1 countries, OD-15 data residency, OD-16 Swahili/Luganda, OD-17 Pidgin voice gate, OD-18 tax on referral payouts.

### Next
- Claude Code runs spikes S-01, S-02, S-03, S-04, S-05 and S-12 (the device spikes S-03, S-04 and S-05 with Kimi) on `spike/*` branches outside `apps/`.
- Phase 1 starts on Kimi's M8.5 hand-off.

---

## 2026-09-23 — Kimi Code — Repo setup + Milestone M1 (complete)

### Delivered
- Repo initialized as monorepo at https://github.com/Hubert24hrs/Suskii_Errands_Mobile
- `docs/spec/SUSKII_BUILD_PROMPT.json` saved verbatim from the client's build prompt (v3.1.0)
- `AGENTS.md` (Kimi Code instructions), this HANDOFF, `contracts/draft/ui-data-requirements.md` skeleton,
  `contracts/CHANGE_REQUESTS.md`
- M1 complete:
  - `packages/suskii_domain` — entities (bootstrap, catalog, chat, notification, offer, referral,
    request, user, wallet; freezed + json_serializable), `Money` (minor units + ISO 4217, exponent
    table incl. UGX exponent 0), `GeoPoint`, status enums, repository interfaces (one per feature;
    money/state/verification mutations are server-decided action requests).
  - `packages/suskii_core` — env config, `AppError` + stable `ErrorCodes`, logging, connectivity.
  - `packages/suskii_design` — token-driven design system (colors/typography/spacing/radius/elevation/
    motion, light+dark themes) + components (buttons, cards, chips, inputs, feedback, skeleton,
    states, timeline, rating, countdown). Placeholder brand tokens swappable via token files only.
  - `packages/suskii_l10n` — English + Nigerian Pidgin (`pcm`) ARB files + generated localizations.
  - `packages/suskii_data` — mock repositories for every domain interface with latency/offline/error
    switches and edge-case fixtures (multiple currencies, expired docs, unverified user, …).
  - `apps/mobile` — splash, startup-error, onboarding carousel, demo phone-OTP auth, Customer and
    Provider shells (own nav stacks via `StatefulShellRoute`), home/requests/messages/profile and
    feed/jobs/earnings screens, mode switch (Provider gated on verification), simulated-offline
    toggle, language + theme pickers. Every screen handles loading/empty/error/offline.
- Verification: `flutter analyze` — zero issues; tests 37/37 green (core 4, data 19, design 5,
  domain 9); `dart format` clean.

### Decisions made (Kimi scope)
- App ID placeholder `com.suskiierrands.mobile` until branding/legal entity is decided.
- Design tokens carry placeholder brand colors; swap = edit token files only.
- Nigerian Pidgin locale registered as `pcm`. Flutter's Material/Cupertino delegates have no `pcm`
  data, so Material widgets fall back to English for `pcm`; all app strings are translated.

### For Claude Code
- `CLAUDE.md` is yours to create (per your first_instruction) — point it at `docs/spec/SUSKII_BUILD_PROMPT.json`.
- `contracts/draft/ui-data-requirements.md` grows with each frontend milestone; treat it as input, not authority.

### Open decisions (client, from spec — keep visible until resolved)
- OD-01 referral commission funding (default: platform funds from its 12.5%)
- OD-02 referral duration (default: lifetime + admin-configurable cap)
- OD-03 both sides referred (default: 2.5% each, max 5% of net)
- OD-04 shopping item float (default: separate non-commissionable prepaid line)
- OD-05 insurance (default: none at launch; claims via disputes)
- OD-06 commission rate (default: 12.5%, per-country configurable)
- OD-07 launch countries (default: Nigeria first)
- OD-08 gateway fee on refunds (default: platform absorbs except late customer cancellations)

### Known issues / limitations (M1)
- No on-device run yet — compile-correctness via `flutter analyze` only.
- `ProviderJobsPage` and `MessagesPage` are empty-state-only: the M1 repository contracts expose no
  provider-job-list or conversation-list methods (wired in M4/M6).
- Riverpod 3.4.3 pinned: use `AsyncValue.value`, not `valueOrNull`.

### Plugin/SDK decisions pending (per spec "plugins_to_evaluate")
To be decided per milestone; paid SDKs (e.g. flutter_background_geolocation) NOT adopted without flagging here.
