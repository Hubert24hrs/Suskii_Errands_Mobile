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

---

## M3 — Request creation, concierge, offers (2026-09-17)

### Create request (`/customer/requests/new`)
- Data displayed: catalog categories (id, label key, icon key); country-pack currency for the money
  fields; price band for the chosen category (`min`/`max`/`suggested` Money + `confidence` +
  `basis: rules|history` — `basis` added to the domain `PriceBand` this milestone so the UI can
  label "based on similar errands" vs "typical range"); optional prefill from concierge handoff
  (categoryId, description, pickup label, preferred price Money).
- Actions: `createRequest(input, idempotencyKey)` → draft JobRequest (one key per create intent,
  held in screen state so a retried publish replays instead of double-creating);
  `publishRequest(jobId, idempotencyKey)` → JobRequest | `ERR_VERIFICATION_REQUIRED` (UI routes to
  `/verify/customer`), `ERR_VALIDATION`, `ERR_IDEMPOTENCY_KEY_REUSED`.
- Input fields sent: categoryId, description, pickup PlaceRef (label + landmarkNote), optional
  destination PlaceRef, urgency (flexible|standard|urgent|emergency), optional scheduledAt,
  optional preferredPrice/itemFloat/declaredValue Money, photo refs (opaque upload refs at M9).
- Edge cases: save-as-draft (creates the draft, no publish); schedule picker (urgency stays
  `flexible` semantics server-side); permission/verification wall on publish.
- Photos are local file paths in the mock; official contract needs an upload-ref flow like KYC docs.

### Concierge chat (`/customer/concierge`)
- Data displayed: conversation (id, status, turns with role user|assistant|system, localized
  intent label keys, slot chips), streaming assistant text, extracted `ConciergeSlots` mirrored
  into a draft JobRequest after the first turn.
- Actions: `startConversation(language)` → conversation; `sendMessage(conversationId, text,
  idempotencyKey)` → turn(s) | `ERR_UNSUPPORTED_LANGUAGE` (only `en` + `pcm`); publish/handoff from
  the summary card reuses the same draft (`publishRequest`, or navigate to
  `/customer/requests/new?...prefill`).
- Realtime: assistant reply streams as partial text events (mock: chunked stream); draft syncs per
  turn.
- Languages: en + pcm from day one; other locales rejected with `ERR_UNSUPPORTED_LANGUAGE` so the
  UI can fall back to the form.
- SOS card surfaces the country-pack `emergencyNumbers` (label keys + numbers) — no new data need.

### Voice concierge (`/customer/concierge/voice`)
- Data displayed: session state (connecting|listening|thinking|speaking|ended), live transcript
  lines, error state.
- Actions: adapter `startSession(conversationId, language)` → VoiceSession |
  `ERR_UNSUPPORTED_LANGUAGE` (pcm voice rejected in mock — UI offers text fallback);
  `events(sessionId)` stream of VoiceEvent (state + partial text); `endSession(sessionId)`.
- Open decision OD-17 still stands: real voice provider + barge-in semantics are backend's call;
  the UI only depends on the adapter interface.

### Offers board (inside request detail)
- Data displayed: per offer — providerName/providerRating/providerTrustLevel, amount Money,
  payoutEstimate Money (server-computed, display-only), status, round, createdAt, optional
  message, distanceMeters, etaMinutes, expiresAt (countdown rendered against server-clock offset).
- Actions: `acceptOffer(offerId, idempotencyKey)`, `declineOffer(offerId, idempotencyKey)`,
  `counterOffer(offerId, amount, message?, idempotencyKey)` → updated offer/job |
  `ERR_OFFER_EXPIRED`, `ERR_INVALID_STATE`, `ERR_IDEMPOTENCY_KEY_REUSED`.
- Realtime: `watchOffers(jobId)` — new offers and status flips (accepted/declined/expired/
  superseded-by-counter) push to the board.
- Edge cases: empty (waiting state), expired offer (actions disabled, countdown at zero),
  counter sheet validation (amount required, currency locked to the job's).

### Request detail (`/customer/requests/:id`)
- Data displayed: full JobRequest — status chip + milestone timeline (published → offers →
  accepted → in progress → handover), description, pickup/destination (+ landmarkNote), urgency,
  scheduledAt, preferred price/item float/declared value, cancel affordance while cancellable.
- Actions: `publishRequest` (drafts), `cancelRequest(jobId, reasonKey, idempotencyKey)` |
  `ERR_INVALID_STATE`; reason is a fixed key set (changeOfPlans|foundProvider|duplicate|
  priceTooHigh|other) — localized client-side, server stores the key.
- Realtime: `watchJob(jobId)`.

### Open needs for the official contract (from M3 UI work)
- `PriceBand.basis` (rules|history) is now in the domain model; please carry it into the pricing
  contract so the UI label stays truthful.
- Offer `expiresAt` semantics (who sets it, whether counters extend it) — mock uses a fixed TTL.
- Concierge → draft sync: mock creates the draft from the first slot batch; official contract
  should state whether drafts are server-side from turn one (preferred) or client-posted.
- Photo upload-ref flow for request photos (same shape as KYC upload refs).
- Voice session transport (WebSocket vs WebRTC) and partial-transcript event schema (OD-17).

---

## M4 — Payments, tracking, chat, calls, SOS, completion, ratings (2026-09-18)

### Payment checkout (`/customer/requests/:id/pay`)
- Data displayed: agreed price Money (from the job), payment method list (card / bank_transfer /
  mobile_money / ussd — per-country availability should come from the country pack), payment
  status + TTL countdown (server timestamp + clock offset), gateway decline reason key,
  off-app instructions (USSD code, transfer reference).
- Actions: `initializePayment(jobId, method, idempotencyKey)` → PaymentSession |
  `ERR_VERIFICATION_REQUIRED` (UI routes to `/verify/customer`), `ERR_PERMISSION_DENIED` (not the
  customer), `ERR_INVALID_STATE` (job not AGREED/PAYMENT_PENDING or already paid).
- Realtime: `watchPaymentForJob(jobId)` — pending → held (webhook + server-side verify) or failed;
  the job follows (PAYMENT_PENDING → PAID_HELD / back to AGREED on failure). The client NEVER
  marks a payment successful.
- Edge cases: retry within the TTL returns the in-flight payment; gateway decline shows a
  localized reason and re-opens the method picker.

### Live tracking (`/customer/requests/:id/track`)
- Data displayed: provider `GeoPoint` stream, job pickup/destination points, status headline.
- Realtime: `watchProviderLocation(jobId)` (mock samples ticks; Realtime Broadcast server-side).
- Actions: `createTripShareLink(jobId, idempotencyKey)` → `{ url, expiresAt }` (1 h mock) —
  shareable expiring link for trusted contacts (spec: safety.live_trip_share).
- Note for the contract: location event schema (point + timestamp + accuracy?) and sampling
  policy are backend decisions; the UI just consumes the stream.

### Job chat (`/customer/requests/:id/chat`, list in Messages tab)
- Data displayed: message list (text, image, voice_note, location, offer_card, system), read
  receipts (`readAt`), empty state.
- Actions: `sendMessage(jobId, type, {text|mediaPath|location}, idempotencyKey)` → ChatMessage.
- Realtime: `watchMessages(jobId)`.
- Open needs: typing indicators, read-receipt writes (`markRead`), AI moderation outcomes
  (blocked-message signal), and media upload refs are not in the mock — contract should define.

### Masked call (`/customer/requests/:id/call`)
- Data displayed: call state (connecting/ringing/active/ended/failed), masked-number notice.
- Actions: adapter `startCall(jobId, idempotencyKey)` → CallSession (opaque id; server-minted
  token) | `ERR_PERMISSION_DENIED` (not a participant / outside the call window),
  `ERR_CALL_IN_PROGRESS` (one active call per job); `events(sessionId)` stream;
  `setMuted(sessionId, muted)`; `endCall(sessionId)`.
- Open needs: token transport (LiveKit), missed-call system message + push, PSTN fallback
  surfacing (spec: communication.voice_calls).

### SOS + trip sharing (sheet on request detail / tracking)
- Data displayed: active alert state, trusted-contacts-notified count, country-pack emergency
  numbers.
- Actions: `triggerSos(jobId, location?, idempotencyKey)` → SosAlert (re-trigger while active
  returns the same alert) | `ERR_INVALID_STATE` (job not active), `ERR_PERMISSION_DENIED`;
  `watchActiveSos(jobId)`; `createTripShareLink` (above).
- Open needs: trusted-contact management UI (M5 settings) — the contract should carry the
  contact list + notification result per contact.

### Completion + ratings (on request detail)
- Data displayed: handover PIN (server-generated, customer-only — new `JobRequest.handoverPin`),
  "provider marked done" state, existing rating (stars + tags).
- Actions: `confirmCompletion(jobId, idempotencyKey)` → CONFIRMED (releases held payment
  server-side); `submitRating(jobId, stars, tagKeys, comment?, idempotencyKey)` |
  `ERR_INVALID_STATE` (not rateable / already rated / stars out of range),
  `ERR_PERMISSION_DENIED` (not a participant); `getMyRatingForJob(jobId)`.
- Open needs: PIN lifecycle (when generated, regeneration, expiry), auto-confirm window value,
  rating aggregation display (Bayesian average on profiles).
