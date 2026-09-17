# Review of `contracts/draft/ui-data-requirements.md`

| | |
|---|---|
| Reviewer | Claude Code |
| Rolling document | Updated as Kimi appends each milestone |
| Covered so far | M1 (app shell, mode switch), M2 (verification + KYC, including screens) |
| Rule | Kimi's draft is **input, not authority**. Where it conflicts with `master_spec` on money, security or the state machine, the spec wins and the UI changes |

Items marked **[CHANGE]** go to Kimi in `HANDOFF.md`. Items marked **[CONTRACT]** are captured for contracts v1. Items marked **[GOOD]** are recorded so a later refactor does not undo them.

## Overall

The draft is in good shape for the stage. It already treats the server as the source of truth in the places that matter most: `Money` breakdowns come from the server, status changes are requested actions, KYC outcomes are enums with reason keys rather than booleans the client interprets, and file uploads are opaque refs against an upload-only bucket. Those are exactly the properties that are expensive to retrofit.

No client-side business logic was found in M1 or M2 that must move server-side. That is unusual this early and worth saying.

## M1 — app shell, mode switch, navigation

| # | Finding | Type |
|---|---|---|
| 1.1 | `Money` breakdown object (gross, commission, gateway fee estimated/actual, tip, net payout) demanded from the server, never derived in the UI | **[GOOD]** matches ADR-0003 and S-14 |
| 1.2 | Offer TTL and round limits taken from config per category, not hardcoded | **[GOOD]** matches the negotiation state machine |
| 1.3 | Stable error codes with localisable message keys | **[GOOD]** → contracts `error-codes` |
| 1.4 | `getBootstrap()` returns session, country pack, feature flags, unread counts and the active-job banner in **one call** | **[GOOD]** and important: at ~150 ms RTT to Europe (S-01), one round trip per screen is the design constraint. Keep it |
| 1.5 | `setActiveMode` can fail with `ERR_PROVIDER_BUSY_AS_CUSTOMER` | **[CONTRACT]** the spec makes this configurable per country; the UI must treat it as a server decision, which it does |
| 1.6 | Provider home shows "today earnings summary (Money, from server)" | **[GOOD]** |
| 1.7 | Country pack is delivered to clients as a "subset safe for clients" | **[CONTRACT]** contracts v1 must define that subset explicitly — internal fields (vendor routing, thresholds, reviewer notes) never leave the server |
| 1.8 | Realtime events named informally (`job.status_changed`, `offer.created`, `notification.created`) | **[CONTRACT]** these become the authoritative names; channel authorisation is per-job and per-user private channels (S-13), not client-side filtering |
| 1.9 | Active-job banner "shows across modes" | **[GOOD]** matches the spec's mode-switch rule |

**Gap for M3+ (not a fault of M1):** the bootstrap payload will need a `server_time` field. Every countdown in the UI — offer TTL, payment TTL, auto-confirm — must be rendered against server time with a measured client offset, or a device with a wrong clock shows the wrong deadline. **[CHANGE]**

## M2 — verification and KYC

| # | Finding | Type |
|---|---|---|
| 2.1 | Consent is explicit and separate for biometric processing vs criminal-record checks, with timestamp and version stored server-side | **[GOOD]** this is a DPIA requirement (compliance checklist D2), not just a nicety |
| 2.2 | KYC files upload-only via signed URLs; clients hold opaque `uploadRef`s and never read back | **[GOOD]** matches the spec's `kyc-docs` bucket rule exactly |
| 2.3 | Rejection reasons are localisation keys, never free text | **[GOOD]** and it aligns with the spec's "no free-text criminal-history notes" rule |
| 2.4 | Required-step set is server/config decided (vehicle docs only for motorised, address for TRUSTED+) | **[GOOD]** |
| 2.5 | `resolvePayoutAccount` returns a server-computed `nameMatch` | **[GOOD]** the client must never decide a name match |
| 2.6 | Identity adapter is vendor-neutral (`startLivenessSession`, `captureLiveness`, `matchGovernmentId`) | **[GOOD]** matches ADR-0005; the Smile ID SDK version is still pending spike S-05 |
| 2.7 | New error codes proposed: `ERR_FEATURE_UNAVAILABLE`, `ERR_CONSENT_REQUIRED`, `ERR_VERIFICATION_REJECTED`, `ERR_KYC_STEP_INVALID`, `ERR_KYC_INCOMPLETE` | **[CONTRACT]** accepted into the v1 error catalogue |
| 2.8 | Social sign-in throws `ERR_FEATURE_UNAVAILABLE` pending backend config | **[CONTRACT]** Apple guideline 4.8 requires an equivalent privacy-preserving login wherever Google sign-in is offered, so Sign in with Apple ships in the same release as Google — they cannot be staged separately on iOS |
| 2.9 | Verification session has an expiry | **[CONTRACT]** contracts v1 defines the TTL and whether a fresh consent is needed after expiry |

### Changes needed for M2

| # | Change | Why |
|---|---|---|
| 2.A | **The ongoing selfie check needs a UI state now, not later.** The draft covers onboarding verification but not the recurring check before going online (spec `ongoing_checks`; cost driver OD-13). Provider "go online" must handle `ERR_SELFIE_CHECK_REQUIRED` — which the M1 draft already lists — by launching a liveness session, not just showing an error | **[CHANGE]** |
| 2.B | **Police clearance needs expiry-aware states.** Per country-pack research, a Nigerian certificate is valid ~3 months and costs ₦30,000 (OD-09). The provider UI needs "expiring in N days" and "expired — job acceptance blocked" states, driven by server-supplied dates, plus the document-expiry centre from the spec's provider screens | **[CHANGE]** |
| 2.C | **Consent version must be surfaced.** When legal text changes, a user must re-consent. The UI needs a "consent out of date" path, not only first-time consent | **[CHANGE]** |

### M2 screens (reviewed 2026-09-16)

Kimi extended M2 with screen-level detail: welcome/country selection, auth, customer facial verification, provider onboarding and the KYC checklist.

| # | Finding | Type |
|---|---|---|
| 2.10 | `ERR_OTP_RATE_LIMITED` is a first-class error | **[GOOD]** — supports the SMS-pumping control in the threat model (R-31) |
| 2.11 | Social sign-in buttons shown disabled rather than hidden | **[GOOD]** |
| 2.12 | Police clearance submits certificate number + issue/expiry dates + upload ref + a **separate** criminal-record consent | **[GOOD]** matches the ERD's `kyc.police_clearances` and the DPIA |
| 2.13 | Payout account shows the server-resolved name and `nameMatch` **before** submit | **[GOOD]** — also the key control against payout redirection (R-32) |
| 2.14 | **Verification is enforced on `createRequest`** with `ERR_PERMISSION_DENIED`. The spec lets unverified customers browse and use the AI concierge, and blocks only **publishing** a request and paying. Enforcing at create would stop the concierge drafting a request for an unverified user | **[CHANGE]** — enforce on publish (job lifecycle #2), with a specific code `ERR_VERIFICATION_REQUIRED` so the UI can route to `/verify/customer` instead of showing a generic denial |
| 2.15 | ID types hardcoded to the Nigerian set | **[CONTRACT]** — country pack carries `accepted_id_types` (already in the country-pack drafts) |
| 2.16 | Service-area catalog, bank list and `mfaEnabled` requested | **[CONTRACT]** — accepted: `list_service_areas(country)`, `list_payout_institutions(country, rail)` (covering mobile money, not only banks), `mfa_enrolled` on the session model |
| 2.17 | MFA prompt is skippable for users | **[GOOD]** for customers and providers; **admins cannot skip** — enforced as `aal2` in the database (RLS matrix) |

### From the data-flow review

| # | Change | Why |
|---|---|---|
| D.1 | **Push notification payloads carry no message text, addresses or amounts** — only an id; the app fetches content after the device is unlocked | Push payloads transit Google and Apple (data-flow flow 18); a chat preview in a notification discloses conversation content to a third party and on the lock screen |
| D.2 | **KYC captures are never cached on the device** after upload | Data-flow flows 2, 4, 5 |

### M2 code review — `suskii_domain` and mock data layer (commit `e473c9b`, reviewed 2026-09-16)

Kimi committed M1 + M2. This pass reads the code rather than the draft, against the job lifecycle, offer machine, ERD and data flow. It is a milestone review, not the formal audit (that starts at M8.5, `docs/audit/README.md`).

**Holding up well:** no money arithmetic anywhere in `apps/mobile` (all amounts come from a server `PriceBreakdown`); no "escrow" in either locale file; rejection reasons are keys, never free text; KYC files are opaque upload refs; criminal-record consent is separate; vendor SDKs sit behind `IdentityVerificationAdapter`; `requestStatusChange(jobId, target)` maps cleanly onto `set_job_status`.

| # | Finding | Severity | Type |
|---|---|---|---|
| C.1 | **No repository method carries an idempotency key** (`createRequest`, `cancelRequest`, `acceptOffer`/`declineOffer`/`counterOffer`, `submitOffer`, `requestStatusChange`, `confirmCompletion`, both `requestWithdrawal`s, `submitStep`, `submitForReview`, `sendMessage`). Every one of these server functions requires it. Add an `idempotencyKey` parameter now, generated once per user intent (UUIDv7) and reused on retry of that same intent — carried-forward item 2 | High | **[CHANGE]** |
| C.2 | **`IdentityVerificationAdapter.matchGovernmentId` returns `matchedName`.** Government-ID lookup is server-to-vendor (data-flow flow 4), not a device call, and returning the registry name makes the app a *NIN → full name* lookup oracle for anyone who types someone else's number. Keep liveness capture on the device adapter; move ID lookup to `VerificationRepository.submitIdLookup` only, returning outcome + `reasonKey`, never a name. (The payout `resolvedName` is different and fine: it is the account holder confirmation users expect, shown for the caller's own submission and rate-limited server-side) | High | **[CHANGE]** |
| C.3 | `RequestRepository` has no `publishRequest`. With 2.14 accepted, create saves a draft and `publish_request` is the verification gate | Medium | **[CHANGE]** (M3, already planned) |
| C.4 | No `withdrawOffer` for providers, though `OfferStatus.withdrawn` exists (offer machine: `withdraw_offer`) | Medium | **[CHANGE]** |
| C.5 | `requestStatusChange` has no evidence argument; `set_job_status` takes proof refs for `ARRIVED` and `COMPLETED_BY_PROVIDER` | Medium | **[CONTRACT]** |
| C.6 | `Money` exponents are a client table **defaulting to 2** for unknown codes. A zero-exponent currency missing from the table would render 100× too small. The server `currencies` table is authoritative: ship exponents in the country pack, and make an unknown code throw in debug rather than default | Medium | **[CHANGE]** + **[CONTRACT]** |
| C.7 | `Money` JSON keys are `minorUnits`/`currency`; the ERD uses `amount_minor` + `currency`. Settle in contracts v1 together with N.6 (snake_case) | Low | **[CONTRACT]** — **settled in `contracts/v1-preview` (2026-09-17): `{ amount_minor, currency }`** |
| C.8 | `mediaPaths` / `uploadRefs` are local paths in the mock; on the wire they are Storage object keys returned by the signed-upload call | Low | **[CONTRACT]** |

## M3 foundation — domain, data, core (uncommitted work in the shared tree, reviewed 2026-09-16)

Kimi reported the M3 foundation verified (domain 21/21, data 58/58, core 7/7, analyze clean). Reviewed from the working tree before commit.

**Landed from earlier reviews:** C.2 (government-ID lookup removed from the device adapter, with a comment explaining why), C.3 (`publishRequest` with `ERR_VERIFICATION_REQUIRED`), C.4 (`withdrawOffer`), C.6 (unknown currency asserts instead of silently using exponent 2), N.6 (snake_case `@JsonValue` on every enum, with a wire-format test), cross-carried item 1 (`serverTime` in bootstrap + `ServerClock`). `ServiceCategory` defaults (offer TTL 600 s, 5 counter rounds) match the offer machine. **[GOOD]**

| # | Finding | Severity | Type |
|---|---|---|---|
| C.1 | **Still open, and wider:** no idempotency key on any mutating method, now including `publishRequest`, `withdrawOffer`, `publishDraft` and concierge `sendMessage` | High | **[CHANGE]** |
| M3.1 | `ConciergeRepository.publishDraft(conversationId)` "performs create + publish server-side". That gives the concierge path a publish capability, which [ai-design.md](ai-design.md) §4.2 excludes. Instead the concierge saves a **server-side draft** as it goes (`save_request_draft`), `ConciergeDraft` carries its `requestId`, and the confirm button calls the same `RequestRepository.publishRequest(requestId, idempotencyKey)` as the form. One publish path, one verification gate | Medium | **[CHANGE]** |
| M3.2 | `ConciergeDraft.readyToPublish` is one case of the turn's `proposed_action`. Model it as an enum on the assistant message: `none`, `show_publish_card`, `show_offer_comparison`, `show_sos_card`, `handoff_to_form` (ai-design §5.3). The SOS and hand-off-to-form cases need UI | Medium | **[CHANGE]** |
| M3.3 | `ConciergeDraft` has `preferredPrice`, `itemFloat`, `declaredValue`. Fine for display, but they are only ever set from UI controls on the publish card — the server rejects them from the model (ai-design §5.3). Do not build a flow where the assistant "fills in" a price | Low | **[GOOD]** with a constraint |
| M3.4 | `VoiceConciergeAdapter` throws `ERR_UNSUPPORTED_LANGUAGE` for `pcm` inside the adapter. The fallback is right, but whether Pidgin voice is available is decided by S-08 and may change without a release; read it from a per-language flag in bootstrap/remote config | Low | **[CHANGE]** |
| M3.5 | `ServerClock` measures elapsed time with `DateTime.now()`, which jumps when the user or the network changes the device clock. Use a monotonic `Stopwatch` started at sync, re-sync on later responses, and subtract half the request round trip | Low | **[CHANGE]** |
| M3.6 | `PriceBand` has `confidence` + `sampleSize`; the backend also returns `basis` (`rules`/`history`), and `getPriceBand` needs `urgency` (the band function takes category, city, urgency, distance). Contracts v1 will carry all of them | Low | **[CONTRACT]** |

## M3 progress check (working tree, 2026-09-16 23:05 — Kimi mid-edit, nothing committed)

**State:** M3 is still uncommitted. The last Kimi commit is `e473c9b` (M1 + M2). The domain, data and core packages were being edited minutes before this check; **no M3 screens exist yet under `apps/`**, so request creation, concierge and offer UI cannot be reviewed. This pass covers the interface and mock changes that respond to the M3 foundation review.

**Landed well:**
- **C.1 (was High):** `idempotencyKey` is now required on 25 method signatures across requests, offers, provider actions, job progress, chat, wallet, referrals, concierge and KYC. `newIdempotencyKey()` is documented as one key per user intent, reused only on retry. **[GOOD]**
- **M3.1:** `publishDraft` is gone. `ConciergeDraft.requestId` exists, and the doc comment states that the concierge holds no publish capability. **[GOOD]**
- **M3.2:** `ConciergeMessage.proposedAction` uses exactly the five ai-design values with snake_case wire names. **[GOOD]**
- **M3.4:** voice availability comes from bootstrap (`AppBootstrap.voiceLanguages`), not the adapter. **[GOOD]**
- **M3.5:** `ServerClock` extrapolates with a monotonic `Stopwatch`. **[GOOD]**

| # | Finding | Severity | Type |
|---|---|---|---|
| M3.7 | **`newIdempotencyKey()` always throws.** It calls `Random.secure().nextInt(1 << 62)`, but Dart's `nextInt` accepts a maximum of at most 2³². Reproduced: `RangeError (max): Must be positive and <= 2^32`. Every mutating action that generates a key would crash, and on web `1 << 62` is not even representable. Fix: draw the 74 random bits from several `nextInt(1 << 32)` calls (or 10 random bytes), keeping the version nibble `7` and variant bits `10`. The existing regex test will catch it once `flutter test` runs on `suskii_core` | **High** | **[CHANGE]** |
| M3.8 | **The mock's idempotency is looser than the backend's.** It keys results by `operation:key` and ignores the payload, so `counterOffer` with the same key and a *different amount* silently replays the old result. The backend keys by user + key, stores a request hash, and refuses a mismatched payload or operation with `ERR_IDEMPOTENCY_KEY_REUSED` (pgTAP `02_internals_test.sql`). Store a hash of the arguments and throw that code on mismatch, so a UI that accidentally reuses a key fails in mocks rather than first in staging | Medium | **[CHANGE]** |
| M3.9 | `verifyHandoverPin(jobId, pin)` has no idempotency key. The job lifecycle defines `verify_pin(request_id, pin, idempotency_key)`, because attempts are counted server-side: a network retry must not spend a second attempt towards lockout | Medium | **[CHANGE]** |
| M3.10 | `ConciergeDraft.requestId` is set "once every slot is filled". ai-design §4.1 and PRD CU-01 save the server-side draft **as details are gathered**, so a customer who leaves mid-conversation resumes with their draft. The field can stay; the comment and the mock should set it from the first saved slot | Low | **[CONTRACT]** |
| M3.6 | Still open: `getPriceBand` takes no `urgency`, and the band carries no `basis` | Low | **[CONTRACT]** |
| M3.11 | `voiceLanguages` is a `Map<String, bool>` in bootstrap; the backend seed had `voice_languages` as a list (`["en"]`). **The backend changes to match**: `{"en": true, "pcm": false}` | — | Backend change, done |

## M3 follow-up check (working tree, 2026-09-17 03:50 — still uncommitted, still no screens)

Kimi fixed every open finding from the progress check about 25 minutes before this pass. Verified, not just read:

| # | Finding | Status | How it was verified |
|---|---|---|---|
| M3.7 | `newIdempotencyKey()` threw on every call | **Fixed** | Random bits now composed from ≤ 32-bit draws. Ran the file standalone: 20,000 keys, all valid UUIDv7, all unique, variant nibbles 8/9/a/b all present |
| M3.8 | Mock idempotency ignored the payload | **Fixed** | `idempotent()` stores an argument hash and throws `ERR_IDEMPOTENCY_KEY_REUSED` on mismatch; all payload-carrying calls pass one (amounts, PIN, text, ID lookup); tests in `mock_m3_test.dart` |
| M3.9 | `verifyHandoverPin` had no key | **Fixed** | Signature takes `idempotencyKey`; the doc says a retry replays without spending an attempt; the mock hashes the PIN |
| M3.10 | Concierge `requestId` only when complete | **Fixed** | Doc and field comment: set from the first saved slot, resumable |
| M3.6 | `getPriceBand` has no `urgency`; no `basis` | Open | Contract item for Stage B |

**Package suites on the current working tree** (run from a temporary copy, so the shared tree was not touched): `suskii_core` 9 passed, `suskii_domain` 21 passed, `suskii_data` 64 passed.

Remaining low-severity notes, for Stage B rather than now:

| # | Note | Type |
|---|---|---|
| M3.12 | The mock scopes keys per operation *and* target (`counterOffer:<offerId>`), so one key reused on two different offers replays instead of failing; the backend keys by user + key and refuses a different operation or payload | **[CONTRACT]** — backend behaviour is the reference |
| M3.13 | `createRequest`'s argument hash covers category and description only; a retry with a changed pickup or price replays the first result | Low **[CHANGE]** when the request form lands |

**Still to review:** every M3 screen (request form, concierge text and voice, offers and negotiation) once they exist in `apps/mobile`.

## M3 foundation hand-off (working tree, 2026-09-17 04:20 — still uncommitted, still no M3 screens)

Kimi reports the M3 foundation complete. M3.7–M3.10 were already verified in the follow-up check. New since then: the
M2 screens in `apps/mobile` now pass `idempotencyKey` at 8 call sites (`setActiveMode`, `setOnline`, `saveOnboarding`,
`submitStep`, `submitForReview`, `giveBiometricConsent`, `startFacialVerification`, `submitIdLookup`). Double taps are
already blocked by each page's `_busy` flag.

| # | Finding | Severity | Type |
|---|---|---|---|
| M3.14 | Every call site creates the key inline (`idempotencyKey: newIdempotencyKey()`), so tapping the button again after an error sends a **new** key. After a timeout where the server did finish, that repeats the operation: a second paid ID lookup (`submitIdLookup`), a duplicate KYC step, a second facial session. Keep one key per user intent in the page state: create it when the intent starts, reuse it on every retry, and replace it only after success or when the user changes the input. This is safe with the backend: a call that fails with an error rolls back its key claim, so the same key runs again; only a call that finished replays its result | Medium | **[CHANGE]** |

Cross-cutting item 2 is corrected below (its "fresh per attempt" wording led here).

## Browser run of the committed app (M2, commit `e473c9b`, 2026-09-17)

Built `apps/mobile` for the web in a throwaway copy (the app has no web target; Kimi's tree was
not touched) and drove it in a browser at 375x812. Splash, welcome, country and language choice,
the three onboarding cards and the sign-in screen all render and behave.

| # | Finding | Severity | Type |
|---|---|---|---|
| M3.15 | **Sign-in never reaches the app.** Entering a phone number, sending the code and submitting any 6-digit code runs the mock sign-in (button shows its spinner, no error) and then stays on `/auth` for ever. Cause: `authStateProvider` is never subscribed, so `redirect` keeps reading `signedOut`. The only subscriber is `ref.listen(authStateProvider, …)` inside `_routerRefreshProvider` (`app/router.dart`), and that provider is never watched — it is pulled in with `ref.read` from `routerProvider` — so under Riverpod 3 its listeners stay paused and the stream is never opened. Proof: with one real listener attached to `authStateProvider`, the same build signs in and routes to `/auth/mfa`; without it, `authStateProvider.value` stays `null` even after `verifyPhoneOtp` succeeds. Suggested fix: register the listens inside `routerProvider` itself (it is watched by the app widget) against a `ValueNotifier` created there, and drop `_routerRefreshProvider`. Please add a regression test that pumps `SuskiiApp`, calls `verifyPhoneOtp` and expects the route to leave `/auth` — a widget test would have caught this | **High** | **[BUG]** |
| M3.16 | Country fixtures disagree with the wave-1 set (ADR-0001, OD-14, backend seed): the picker offers Nigeria, Kenya, Ghana and South Africa, with South Africa `disabled` ("Coming soon") and **Uganda missing**. The backend seeds NG `live`, and KE, GH, ZA and UG all `beta`. Demo data, not a contract, but the country list is what a reviewer reads as the launch scope | Low | **[CHANGE]** |
| M3.17 | Provider feed mixes countries: a Nigerian provider sees open requests priced in ₦, GH₵ and KSh in one list. The backend will scope the feed by country and city (PostGIS matching, Phase 3), so this is mock data only — but demos read it as the product rule | Low | **[CHANGE]** |

Not defects, noted while testing: the Google and Apple buttons correctly say "Coming in the next
milestone" (the backend can now be configured for both, per-environment); deep links to a signed-in
route bounce back to `/auth` as the redirect intends.

## Naming alignment with the domain package (checked 2026-09-16)

Checked Kimi's `suskii_domain` enums and entities against the ERD so names do not drift.

| # | Finding | Type |
|---|---|---|
| N.1 | `JobStatus` has exactly the spec's 20 states, and `isTerminal` matches the lifecycle's terminal set | **[GOOD]** |
| N.2 | `PaymentStatus.partiallyRefunded` resolves the job-lifecycle open question: partial refunds live on the payment, not a new job state | **[GOOD]** — adopted |
| N.3 | `OfferStatus` uses `pending`/`declined`; the first state-machine draft said `ACTIVE`/`REJECTED`. **Backend adopts Kimi's names** | **[GOOD]** — no change for Kimi |
| N.4 | `PriceBreakdown.commissionRateBps` stores the rate as integer basis points. **Backend adopts this** (`*_bps integer` in the ERD) — better than a numeric rate | **[GOOD]** — adopted |
| N.5 | `Urgency` has four levels (`flexible`/`standard`/`urgent`/`emergency`); the country-pack drafts assumed three multipliers. Country packs get a fourth | **[CONTRACT]** — backend change |
| N.6 | **Enum wire format.** Dart enums are camelCase (`offersReceived`); Postgres and Supabase-generated types use snake_case (`offers_received`). Recommend snake_case on the wire, with `@JsonValue` mappings in Dart — cheaper now than after M3 adds more enums | **[CHANGE]** |

## Cross-cutting, carried forward

Recorded now so they are not rediscovered at M8.5:

1. **`server_time` in bootstrap** and an offset applied to every countdown. **[CHANGE]**
2. **Idempotency keys are per user intent** — never per screen or per session. S-10 showed a reused key correctly replays, which in a UI would look like a tap that silently did nothing, so a new intent (new input, or the previous call succeeded) needs a new key. **Superseded wording, 2026-09-17:** the original text said "generated fresh per attempt"; retries of the same intent must reuse the key (M3.14). **[CHANGE]**
3. **Currency exponent, never `/100`.** Kimi's `Money` already carries an exponent table with UGX = 0; a golden test should lock that so a later refactor cannot reintroduce a hardcoded divisor. **[CHANGE]**
4. **"Held by Suskii", never "escrow"** in any locale file (ADR-0002, a legal constraint per country). **[CHANGE]**
5. **Trusted contacts must use the Android Contact Picker**, not `READ_CONTACTS` (Play policy, April 2026). **[CHANGE]**
6. Realtime channels are private and per job/per user; a provider must never receive a rival's offer amount even in a payload the UI chooses not to render. **[CONTRACT]**
7. **Enum wire values are `snake_case`** with `@JsonValue` mappings on the Dart enums (N.6). **[CHANGE]**

## Still to review

M3 onwards: request creation, offers and negotiation, payments, tracking, chat, calls, SOS, completion and ratings, wallet, earnings, withdrawals, referrals, promos, disputes, support, settings, provider tools, business console, the three web apps and admin. Each milestone gets a section here, and the resulting change list goes to `HANDOFF.md` as it is found — not saved up for M8.5.
