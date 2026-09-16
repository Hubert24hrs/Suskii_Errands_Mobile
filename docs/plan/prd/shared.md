# PRD — Shared stories (both app modes and the customer web app)

Conventions in [README.md](README.md) §4. Refs: JL = [job-lifecycle.md](../state-machines/job-lifecycle.md), RLS = [rls-policy-matrix.md](../rls-policy-matrix.md), MF = [money-flows.md](../money-flows.md), TM = [threat-model.md](../threat-model.md), DF = [data-flow.md](../data-flow.md).

## Accounts, sign-in, customer verification, mode switch

### SH-01 — Choose country and language
*As a new user, I want to pick my country and language before signing in, so that prices, payment methods and rules match where I am.*
- Only countries whose pack is `live` or `beta` are selectable; `beta` is labelled.
- Language list comes from the country pack; launch set is English and Nigerian Pidgin, and the choice can be changed later without signing out (SH-32).
- Country determines currency, phone format, payment routing, ID types and emergency numbers for every later screen; the user cannot transact in a different country's currency (spec: no cross-currency jobs).
- Refs: country packs; OD-07, OD-14.

### SH-02 — Sign in with phone OTP
*As a user, I want to sign in with my phone number and a one-time code, so that I don't need a password.*
- Phone numbers are validated against the selected country's format and allowed prefixes; numbers outside live/beta countries are refused before any SMS is sent (R-31).
- A Turnstile challenge precedes the OTP request; OTP requests are rate-limited per number, IP and device, and the limit returns `ERR_OTP_RATE_LIMITED` with a retry time.
- SMS is sent through the Send SMS Hook with per-country provider routing and failover; the code autofills on Android where supported.
- The first successful sign-in creates the account in **Customer mode** (spec).
- Refs: S-09; TM §4; SH-38.

### SH-03 — Sign in with email
*As a user, I want to add and sign in with an email address, so that I have a second way in and can receive receipts.*
- Email OTP sign-in works for accounts with a verified email; adding an email requires confirming a code.
- Providers must have a verified email (spec provider flow); customers may skip.

### SH-04 — Sign in with Google or Apple
*As a user, I want to sign in with Google or Apple, so that sign-in is one tap.*
- Sign in with Apple is offered on iOS whenever Google sign-in is offered (store rule, N-13).
- A social sign-in still requires a verified phone number before publishing, offering or paying.
- Until providers are configured, buttons are shown disabled with "coming soon" (Kimi's M2 behaviour).

### SH-05 — Manage my profile
*As a user, I want to set my name and photo, so that the other party knows who they are dealing with.*
- Users can edit only display name, language and avatar; trust level, verification status and mode are server-owned (RLS; S-13 finding 1).
- Changing the profile photo triggers face re-verification for providers (spec ongoing checks).
- Phone number changes start a cooling-off period for withdrawals and payout-account changes (SH-38).

### SH-06 — Verify my face as a customer
*As a customer, I want to verify my identity once, so that I can publish requests and pay.*
- Browsing, drafting requests and using the AI concierge work **unverified**; `publish_request` and payment return `ERR_VERIFICATION_REQUIRED` and the app routes to verification (spec; review 2.14).
- The flow is: explicit biometric consent → active and passive liveness in the vendor SDK → face match against a government ID record or ID document per the country pack.
- Biometric captures go from the device to the vendor; Suskii stores outcome, reference id and reason key only, and nothing is cached on the device after upload (DF flows 2–4).
- Outcomes are delivered by vendor webhook; the app shows pending, verified, or rejected with a localized reason and a retry path within the attempt limit.
- The ID lookup returns an outcome and reason key only, never the name on the ID record (review C.2).
- Refs: S-05; ADR-0005; OD-13.

### SH-07 — Give and withdraw consent
*As a user, I want to see what I agreed to and change it, so that I stay in control of my data.*
- Biometric consent and (for providers) criminal-record-check consent are **separate** and explicit, each recorded with version, timestamp and country (spec).
- Marketing consent is separate from transactional notifications.
- Withdrawing biometric consent explains the consequence (cannot publish, pay or work as a provider) and triggers vendor-side deletion where the law requires it.
- Re-consent is requested when a consent text version changes.

### SH-08 — Switch between Customer and Provider mode
*As a user who also provides services, I want to switch modes from my profile, so that I can hire and work from one app.*
- Provider mode is unavailable until provider verification is `VERIFIED`; attempting it opens provider onboarding (`ERR_PROVIDER_NOT_VERIFIED`).
- Each mode keeps its own navigation and state; an active job banner stays visible in both modes (spec).
- Switching is a server call (`set_active_mode`); the server re-checks verification.
- A provider cannot go online while they have an active customer job needing their attention, when configured (spec; PR-10).

### SH-09 — Protect my account with MFA
*As a user, I want to add an authenticator app, so that a stolen SIM is not enough to take my account.*
- TOTP enrolment is optional and skippable for customers and providers; admins cannot skip it (AD-01).
- When enrolled, withdrawals, payout-account changes and new-device sign-ins require the second factor.

## Chat, calls, notifications

### SH-10 — Chat with the other party on a job
*As a customer or provider, I want to message the other party about a job, so that we can coordinate without sharing phone numbers.*
- A chat thread exists per job and is available to exactly the two participants (or the assigned business worker and dispatcher), from offer negotiation until the call window closes; others get 0 rows (RLS).
- Supports text, images, voice notes, location pins, offer cards and system messages, with read receipts and typing indicators (spec).
- Messages are delivered over a private realtime channel; missed messages are fetched on reconnect so none are lost on N5 networks.
- Images have EXIF removed for display; phone numbers are never shown.
- Refs: DF flow 15; retention 12 months.

### SH-11 — Moderated chat
*As a user, I want abusive or scam messages caught, so that I'm protected.*
- Deterministic rules run on every message before delivery; AI moderation runs within the moderation timeout.
- Messages proposing off-platform or cash payment are flagged: the sender sees a warning that such payments are not protected, the recipient sees a safety notice, and the item enters the moderation queue (spec: cash not allowed).
- Prohibited items and services from the country pack are flagged the same way.
- If AI moderation is unavailable, deterministic rules still apply and messages deliver into an async review queue (OD-21 default).

### SH-12 — Call the other party in the app
*As a customer or provider, I want to call the other party in the app, so that we can talk without exposing numbers.*
- Calls are allowed only between the job's participants, from assignment until 24 h after completion (configurable); tokens are minted server-side, room-scoped and short-lived.
- One active call per job; simultaneous attempts are resolved server-side into one call.
- **No recording.** Only metadata is stored (participants, times, duration, quality, fallback used).
- Refs: spec communication; DF flow 16.

### SH-13 — Receive a call when the app is closed
*As a user, I want incoming calls to ring like a normal phone call even when the app is closed, so that I don't miss the provider at the gate.*
- iOS: CallKit incoming-call UI via PushKit; every VoIP push is reported to CallKit immediately, and VoIP push is never used for non-call events (store rule).
- Android: full-screen incoming call when the full-screen-intent permission is granted; a heads-up notification fallback when denied (Android 14+); phoneCall/microphone foreground service types during calls.
- Ring-rate targets: iOS ≥ 99%, Android ≥ 95% on the device matrix (S-03).
- **Gated** on S-03 passing on the device lab.

### SH-14 — Fall back to a masked phone call
*As a user on a poor data connection, I want to switch to a regular phone call, so that we can still talk.*
- Offered when call quality drops below threshold or data is unavailable; connects both parties through a proxy number per country, never revealing either real number.
- Available only inside the same call window as SH-12.
- **Gated** on a telephony provider per country (REPORT §6; vendor matrix).

### SH-15 — See missed calls
*As a user, I want to know I missed a call, so that I can call back.*
- A missed call creates a system message in the job chat and a push notification (spec).

### SH-16 — Control notifications
*As a user, I want to choose how I'm notified and set quiet hours, so that I get what matters without noise.*
- Per-channel preferences for push, SMS, email and in-app inbox; transactional and marketing are separate switches (spec).
- Quiet hours suppress marketing and non-urgent notifications; job-critical events (offer accepted, provider arrived, SOS, payment failure, incoming call) are never suppressed.
- Channel abstraction is ready for WhatsApp without a UI change.

### SH-17 — Private notifications and inbox
*As a user, I want notifications that don't reveal private details on my lock screen, and an inbox to read them later.*
- Push payloads contain a notification id and a generic title only — no message text, addresses or amounts; the app fetches content after unlock (DF rule 1; review D.1).
- Every notification is also in the in-app inbox with unread counts.

## Wallet and referrals

### SH-18 — See my wallet
*As a user, I want to see my balances, so that I know what is available, pending and held.*
- Customers see credits and refunds; providers see available, pending and lifetime earnings; referrers see referral earnings by status.
- Balances are derived server-side from the double-entry ledger and never computed in the app.
- Amounts display with the currency's exponent (UGX has no decimals).
- Refs: MF; S-14.

### SH-19 — See transaction history and receipts
*As a user, I want every money movement listed with a receipt, so that I can check what happened.*
- Paginated history of payments, holds, releases, refunds, payouts, tips, referral commissions and reversals, each with status and a localized description.
- A completed job receipt shows the server's breakdown: agreed amount, promo, tip, item float spent and refunded; for providers also commission, gateway fee and payout.
- Receipts can be shared or downloaded as PDF.

### SH-20 — Share my referral link
*As a verified user, I want a referral link and QR code, so that I earn when people I invite use Suskii.*
- Only verified users (customer or provider, individual or business) get a code (spec).
- Links are App Links / Universal Links / web URLs with deferred deep linking so attribution survives install; attribution window defaults to 30 days from click.
- A code can be entered manually at signup, before the first job only.
- Self-referral is blocked using device, phone, email, face duplicate check, government ID hash, payout account and card fingerprint (spec anti-fraud); the referrer sees "not eligible" without the reason detail.

### SH-21 — Track my referrals
*As a referrer, I want a dashboard of invites and earnings, so that I can see what my referrals produce.*
- Shows link and QR, invites, sign-ups, active referrals, earnings by status (pending, earned, holding, available, reversed), withdrawal history, milestone badges and an opt-in leaderboard (spec).
- Referred users are shown by first name or masked handle only.

### SH-22 — Earn referral commission
*As a referrer, I want to earn 2.5% of net on my referrals' completed jobs, so that inviting people is worth it.*
- Commission = `round_half_even(net × 0.025)` per eligible referrer, where net = agreed amount − platform commission, on every confirmed job where the referred user is customer or provider, for the duration set by OD-02.
- Single level only: no earnings from a referral's referrals.
- States: `PENDING` → `EARNED` (job confirmed) → `HOLDING` (dispute window + fraud hold, default 72 h) → `AVAILABLE`, or `REVERSED` on refund, chargeback or fraud; a negative balance offsets future earnings.
- Funded from platform commission by default, so provider earnings are unaffected (OD-01); both-sides-referred jobs follow OD-03.
- Campaign boosted rates apply only within the campaign's time box and budget cap, enforced transactionally (AD-17).
- Refs: MF scenarios; OD-01, OD-02, OD-03.

### SH-23 — Withdraw referral earnings
*As a referrer, I want to withdraw available referral earnings, so that I receive them as cash.*
- Requires completed KYC for withdrawals, a payout account whose name matches the verified identity, and a balance above the per-currency minimum (spec).
- Rooted, emulated or tampered devices are ineligible to earn or withdraw (spec).
- Large withdrawals follow the single and four-eyes approval thresholds (AD-14).
- Tax withholding and annual statements per country when counsel requires them (OD-18).

## Safety

### SH-24 — Raise an SOS
*As a customer or provider on an active job, I want an SOS button, so that help comes if I'm in danger.*
- The SOS button is visible on every active-job screen in both modes and reachable in one tap plus one confirmation.
- Raising SOS sends live location and job details to Suskii operations **and** the contracted security/emergency partner for that city, notifies the user's trusted contacts, and shows local emergency numbers from the country pack (spec).
- Works on degraded networks; if the request cannot be sent, the app shows the emergency numbers from the cached country pack immediately.
- SOS is never routed through the AI concierge (ai-design §4.2).
- Partner acknowledgement is tracked and escalates in the ops console if not received (AD-21).
- Refs: RB-06; DF flow 23.

### SH-25 — Manage trusted contacts
*As a user, I want to add up to 5 trusted contacts, so that they're told if something goes wrong.*
- Up to 5 contacts per user (spec).
- On Android contacts are chosen with the system Contact Picker; the app does not request `READ_CONTACTS` (Play policy; review item 5).

### SH-26 — Share my live trip
*As a user on an active job, I want to share a live tracking link, so that someone I trust can follow the trip.*
- The link is tokenised, expiring, and shows the live position and job status only while the job is active; it works without an account.
- Tokens are stored hashed; revoking the share or ending the job ends access.
- Refs: DF flow 14.

### SH-27 — Block someone
*As a user, I want to block the other party, so that we're never matched again.*
- Either party can block; blocked pairs are never matched, cannot see each other's requests or offers, and cannot call or message (spec).
- Blocking during an active job does not cancel it automatically; the user is offered cancel, report or support.

### SH-28 — Report someone or something
*As a user, I want to report a person, message, request or review, so that Suskii can act.*
- Report reasons are fixed keys; free-text details are optional and moderated.
- Reports enter the moderation or trust-and-safety queue with the linked evidence; the reporter gets a confirmation and an outcome notice without details about the other account.

### SH-29 — Prohibited items and services are refused
*As Suskii, I want requests, chat, receipts and reviews checked against each country's prohibited list, so that the platform isn't used for illegal errands.*
- Rules and AI moderation check requests at publish, chat messages, receipts and reviews against the country pack list (spec).
- A blocked request shows which rule applies and cannot be rephrased around by the concierge (ai-design §5.2).
- Repeat attempts feed the risk engine.

## Ratings and reputation

### SH-30 — Rate the other party
*As a customer or provider, I want to rate the other side after a job, so that good behaviour is rewarded.*
- Both sides can rate once per job after confirmation, within the ratings window; ratings are hidden from the other party until both rate or the window closes.
- A star rating with optional tags and a moderated comment.
- Ratings on disputed jobs are held until the dispute resolves.

### SH-31 — See reputation and trust level
*As a user, I want to see someone's rating, completed jobs and trust level, so that I can decide whom to trust.*
- Averages use Bayesian smoothing so a single rating does not dominate (spec).
- Trust levels NEW, VERIFIED, TRUSTED, ELITE are computed server-side; TRUSTED and above require address verification (spec).
- Businesses and their workers each carry a reputation (BU-10).

## Settings, accessibility, localization, offline, account lifecycle

### SH-32 — Change language and settings
*As a user, I want to change language, theme and saved places, so that the app suits me.*
- Language switch applies immediately across the app without restart; server-sent text uses localization keys.
- Saved places store a label, landmark note and optional pin (addressing norms in CU-06).

### SH-33 — Use the app with accessibility needs
*As a user with low vision or who uses a screen reader, I want the app to work with my settings, so that I can use it independently.*
- Core flows (sign in, verify, publish, accept, pay, track, confirm, SOS) are fully operable with TalkBack and VoiceOver.
- Text scales to 200% without clipping core actions; contrast meets WCAG AA; dark mode supported.
- Layouts are RTL-ready (spec).

### SH-34 — Use the app on low data or offline
*As a user with expensive or patchy data, I want a low-data mode and offline behaviour, so that the app stays usable.*
- Low-data mode reduces image quality, map tiles and background refresh.
- Recent jobs, chat and the country pack are cached for offline viewing.
- Status updates and proof uploads go to an outbox and replay with their original idempotency keys when back online, exactly once and in order (I-17).

### SH-35 — Forced update and kill switches
*As Suskii, I want to force an upgrade or switch off a broken feature remotely, so that users aren't harmed by a bad release.*
- Bootstrap carries `min_supported_app_version`; below it, the app shows a blocking update screen with a store link.
- Feature flags and kill switches per country turn features off with a graceful fallback screen, never a crash (RB-13).

### SH-36 — Delete my account
*As a user, I want to delete my account in the app, so that my data is removed.*
- Available in-app (Apple and Google requirement, N-13) and on the web.
- Blocked with an explanation while a job is active, a dispute is open, or a withdrawable balance remains (the user is prompted to withdraw first).
- Personal data is deleted or anonymised; financial records, KYC records and audit entries are retained for their legal periods and are listed in the confirmation screen.
- Deletion is confirmed by OTP or MFA.

### SH-37 — Export my data and read how it's handled
*As a user, I want a copy of my data and to know where it's processed, so that I can exercise my rights.*
- Data export produces a machine-readable archive of profile, requests, messages, ratings and transactions, delivered to a signed link that expires.
- The privacy notice states that data is hosted outside the user's country (EU, per ADR-0008) and lists processor categories, per the country's data-protection law (OD-15).

### SH-38 — Keep my account secure
*As a user, I want to see my devices and be protected against SIM swap, so that nobody takes over my earnings.*
- Active sessions and devices are listed and can be signed out remotely.
- After a phone-number change or sign-in from a new device: withdrawals and payout-account changes are blocked for a cooling-off period and require face re-verification; the old email gets an alert (TM §1, R-32).
- Sensitive actions (payment, withdrawal, going online, SOS) carry a device integrity token (Play Integrity / App Attest) checked server-side; rooted or emulated devices can still use basic features but cannot earn referrals or withdraw.

### SH-39 — Accept terms per country
*As a user, I want to see and accept the terms and privacy policy for my country, so that I know the rules.*
- Legal documents are versioned per country; acceptance is recorded with version and time.
- A new required version prompts acceptance on next open before transacting.
