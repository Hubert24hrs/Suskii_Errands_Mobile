# UI Data Requirements — DRAFT (Kimi Code → Claude Code)

This is the frontend's running list of every piece of data, action, realtime event, and error
state the UI needs from the backend. It is **input, not authority** — Claude Code reconciles it
against `master_spec` and publishes the official `/contracts`.

Conventions used below:
- **Money** = `{ minorUnits: int, currency: ISO4217 }` — never float.
- Timestamps are ISO 8601 UTC. IDs are UUIDs/ULIDs.
- "server-decided" = the UI sends an action request; the server validates, mutates, and returns
  the new state. The client never writes status/amount/commission/rating/verification fields.

---

## Per-screen template

```
### <Screen name> (<route>)
- Data displayed: field (type) ...
- Actions: name(input) → result | error codes
- Realtime events: channel, event, payload
- Pagination: cursor/offset, page size, sort
- Permissions: role/mode/verification required
- Edge cases the UI must render: ...
```

---

## M1 — App shell, mode switch, navigation (2026-09-23)

### App bootstrap (cold start)
- Data displayed: current session (userId, activeMode, verificationSummary), country pack for the
  user's country (currency, languages, status live|beta|disabled, emergency numbers), feature
  flags / remote config (kill switches, forced-update version), unread notification count,
  active-job banner summary (jobId, status, otherPartyName) if any.
- Actions: `getBootstrap()` → snapshot | `ERR_NETWORK`, `ERR_COUNTRY_DISABLED`,
  `ERR_FORCE_UPDATE_REQUIRED`
- Realtime: none at bootstrap; banners subscribe after (see below).
- Permissions: works logged-out (guest) and logged-in.

### Mode switch (profile/drawer, both modes)
- Data displayed: current mode, provider verification status (locked until provider KYC approved),
  active-job presence per mode.
- Actions: `setActiveMode(mode)` → new mode | `ERR_PROVIDER_NOT_VERIFIED`,
  `ERR_PROVIDER_BUSY_AS_CUSTOMER` (provider cannot go online with unresolved customer job — configurable)
- Realtime: mode change reflects across devices (nice-to-have).
- Permissions: authenticated; Provider mode requires provider verification = VERIFIED.

### Customer shell — Home (placeholder in M1)
- Data displayed: greeting name, active jobs (id, category label, status, agreed price Money,
  provider name/rating), quick categories (id, label key, icon key), promo banner (code, title,
  terms), unread counts (notifications, chats).
- Realtime events (mocked now, formalize later): `job.status_changed`,
  `offer.created`, `notification.created` on a per-user private channel.
- Edge cases: empty (no jobs), offline (cached snapshot + banner), country disabled.

### Provider shell — Home/feed (placeholder in M1)
- Data displayed: online status, today earnings summary (Money, from server), open request count
  nearby, document-expiry warnings (document type, days left), verification status if not VERIFIED.
- Actions: `setOnline(bool)` → online state | `ERR_KYC_EXPIRED`, `ERR_SELFIE_CHECK_REQUIRED`,
  `ERR_PROVIDER_BUSY_AS_CUSTOMER`
- Realtime: `request.nearby_created` (provider channel), `offer.countered`, `job.assigned`.

### Cross-cutting data needs identified in M1
- `Money` breakdown object returned by server for any price display (gross, commission, gateway
  fee est./actual, tip, net payout) — UI never derives these.
- Country pack object delivered to clients (subset safe for clients; no internal notes).
- Stable error-code list with localizable message keys (UI maps code → translation key).
- Auth/session model that carries: verification level (customer facial, provider KYC),
  active mode, roles (for future admin surface), country code.
- Offer TTL and negotiation round limits must come from config (per category), not hardcoded.

---

## M2 — Verification + KYC (data/domain foundation, mock-backed)

### Customer facial verification
- Data displayed: session status (consentPending → inProgress → inReview → verified/rejected/expired),
  rejection reason key, session expiry.
- Actions: `giveBiometricConsent()` → session; `startFacialVerification()` → session |
  `ERR_CONSENT_REQUIRED`; `submitIdLookup(sessionId, idType, idNumber)` → session |
  `ERR_KYC_STEP_INVALID`.
- Realtime: `watchCustomerVerification()` — session outcome arrives async after review.
- Consent: explicit, separate records for biometric processing vs criminal-record checks (provider side).
  Server must store consent timestamp/version.

### Provider KYC
- Data displayed: `ProviderKycProfile` — onboarding choices (kind, categories, areas, vehicle) +
  per-step status/attemptCount/rejectionReasonKey + server-computed `overallStatus` + `submittedForReviewAt`.
- Actions: `saveOnboarding(input)`; `submitStep(kind, typedInput)` → profile | `ERR_KYC_STEP_INVALID`;
  `resolvePayoutAccount(input)` → `PayoutAccountResult` (read-only, server-computed nameMatch);
  `submitForReview()` → profile | `ERR_KYC_INCOMPLETE`.
- Realtime: `watchKycProfile()` — step reviews resolve async; officer review updates overall status.
- Files: upload-only via signed upload URLs; clients send opaque `uploadRef`s and never read back.
- Required-step set is server/config-decided (vehicle docs only for motorized vehicles; address for
  TRUSTED+; credentials per category/country).

### Auth additions
- `requestEmailOtp(email)` / `verifyEmailOtp(email, code)` → AppUser | `ERR_OTP_INVALID`.
- `signInWithGoogle()` / `signInWithApple()` → currently `ERR_FEATURE_UNAVAILABLE` (placeholder).

### New error codes needed in the official contract
`ERR_FEATURE_UNAVAILABLE`, `ERR_CONSENT_REQUIRED`, `ERR_VERIFICATION_REJECTED`,
`ERR_KYC_STEP_INVALID`, `ERR_KYC_INCOMPLETE`.

### Identity verification adapter
- Vendor-neutral surface for Smile ID (or S-05 pick): `startLivenessSession()`, `captureLiveness(id)`,
  `matchGovernmentId(sessionId, idType, idNumber)` — outcomes are enums + reason keys, never booleans
  the client interprets.

### M2 screens (UI side)

#### Welcome / country + language selection (`/welcome`, first run)
- Data displayed: country list with per-country status chip (live/beta/coming soon) from
  `getCountryPack(code)`; language options (en/pcm from the country pack's supportedLanguages).
- Actions: select country (drives bootstrap country pack server-side later); set locale (local).
- Permissions: signed-out. Disabled countries are not selectable.
- Edge cases: country disabled, pack fetch failure (retry), offline.

#### Auth (`/auth`, extended)
- Data displayed: segmented phone/email sign-in, OTP entry, demo hint.
- Actions: `requestPhoneOtp` / `verifyPhoneOtp`, `requestEmailOtp` / `verifyEmailOtp` → AppUser |
  `ERR_OTP_INVALID`, `ERR_OTP_RATE_LIMITED`, `ERR_NETWORK`. Social: `signInWithGoogle/Apple` →
  `ERR_FEATURE_UNAVAILABLE` (buttons shown disabled).
- Follow-on: post-sign-in MFA prompt placeholder (`/auth/mfa`, informational, skippable) — real MFA
  settings arrive in a later milestone; needs a per-user `mfaEnabled` flag in the session model.

#### Customer facial verification (`/verify/customer`)
- Data displayed: session status, rejection reason key, liveness instructions/status, ID type list
  (per country pack: NIN/BVN/voter's card/driver's licence/passport for NG), result states.
- Actions: `giveBiometricConsent()` (explicit, timestamped consent record); adapter
  `startLivenessSession()`/`captureLiveness(sessionId)` → outcome + reasonKey;
  `submitIdLookup(sessionId, idType, idNumber)` → session | `ERR_CONSENT_REQUIRED`,
  `ERR_KYC_STEP_INVALID`.
- Realtime: `watchCustomerVerification()` flips in-review → verified/rejected after review.
- Entry points: profile verification row; home banner while `customerVerification != VERIFIED`
  (spec: verification required before publishing first request / paying — enforce server-side on
  `createRequest` with `ERR_PERMISSION_DENIED`, already mocked).
- Edge cases: liveness failure (retry per IdentityCheckOutcome), session expiry, rejection with
  localized reason + retry.

#### Provider onboarding (`/provider/onboarding`)
- Data displayed: individual/business choice (+ business name), services multi-select (catalog
  categories), service areas (country-pack launch cities for now — need a proper service-area list
  with ids + label keys in the official contract), vehicle type.
- Actions: `saveOnboarding(input)` → profile.
- Permissions: authenticated; reachable in customer mode (it is the entry to provider verification).

#### Provider KYC checklist (`/provider/kyc`)
- Data displayed: `ProviderKycProfile` (overall status chip, per-step status + attemptCount +
  rejectionReasonKey), submit-for-review state.
- Actions: `submitStep(kind, typedInput)` → profile | `ERR_KYC_STEP_INVALID`; per-step forms:
  government ID (idType + number), provider facial (adapter liveness → submit sessionId), ID
  document capture (idType + number + opaque uploadRef), police clearance (cert number + issue/expiry
  dates + uploadRef + separate criminal-record consent), address, guarantor, payout account
  (`resolvePayoutAccount` read-only name lookup → resolvedName + server-computed nameMatch shown
  before submit), vehicle documents (licence/registration/insurance refs; required only for
  motorized vehicles — server decides), credentials (description + uploadRefs).
  `submitForReview()` → profile | `ERR_KYC_INCOMPLETE`.
- Realtime: `watchKycProfile()` — each step flips in-review → verified/rejected async; officer
  review owns the overall status.
- Files: upload-only; clients hold opaque `uploadRef`s (signed URLs at M9), never read back.
- Rejection reasons are localization keys only (`kycRejectPoliceClearanceExpired` mocked); no
  free-text criminal-history notes ever reach the client (per spec data_handling).
- Entry points: profile provider-verification row; mode switch to Provider when unverified redirects
  here via `/provider/onboarding`.

### Open needs for the official contract (from M2 UI work)
- Country pack should carry the supported government-ID types per country (UI currently hardcodes
  the NG set: `nin`, `bvn`, `votersCard`, `driversLicence`, `passport`).
- Service-area catalog endpoint (id + label key) — UI currently reuses `launchCities` strings.
- Bank list endpoint for payout-account selection (UI currently uses a free bank-code field).
- Consent records: biometric vs criminal-record, each with timestamp + copy version.
- `mfaEnabled` on the session/user model for the real MFA milestone.

---

## Later milestones
Sections for M3..M8 screens get appended here as those milestones are built.
