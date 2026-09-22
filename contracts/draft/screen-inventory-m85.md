# Screen inventory — M8.5 hand-off

Every shipped screen/route mapped to the PRD stories it implements
(`docs/plan/prd/{shared,customer,provider,business,web,admin}.md`), plus gap analysis.
Sources enumerated from the actual route files:

- Mobile: `apps/mobile/lib/app/router.dart` (34 routes).
- Web customer: `apps/web-customer/src/app/[locale]/(app)/**/page.tsx` (17 pages + root locale redirect).
- Web marketing: `apps/web-marketing/src/app/[locale]/**/page.tsx` (12 pages + root locale redirect).
- Web admin: `apps/web-admin/src/app/(console)/**/page.tsx` + `sign-in` (19 pages).

All surfaces run on the mock data layer (`packages/suskii_data` mocks; `src/mocks/` in the web apps) pending M9 wiring.

## Mobile — customer mode (pre-auth + customer shell)

| Route / screen | Story IDs | Notes |
|---|---|---|
| `/splash` — SplashPage | SH-35 (partial) | Bootstrap gate; no dedicated forced-update screen |
| `/startup-error` — StartupErrorPage | SH-34, SH-35 (partial) | Bootstrap failure (offline, disabled country, force update) |
| `/welcome` — WelcomePage | SH-01 | Country picker; status from server-style country pack |
| `/onboarding` — OnboardingPage | SH-01 | Language selection, intro |
| `/auth` — AuthPage | SH-02, SH-03, SH-04 | Phone/email OTP; social buttons disabled "coming soon" per SH-04 |
| `/auth/mfa` — MfaPromptPage | SH-09 (placeholder) | Acknowledge-only prompt once per session (M2 placeholder) |
| `/verify/customer` — CustomerVerificationPage | SH-06, SH-07 | Consent + liveness flow simulated; vendor SDK is a mock seam |
| `/customer/home` — CustomerHomePage (shell tab) | CU-01 (entry), SH-08 (active-job banner) | Greeting, active jobs, category grid |
| `/customer/requests` — CustomerRequestsPage (shell tab) | CU-03 (drafts), CU-09 (partial) | Request list incl. drafts; no separate scheduled-errands list (CU-32) |
| `/customer/messages` — MessagesPage (shell tab) | SH-10, SH-17 | Conversation list; doubles as notification inbox (partial SH-17) |
| `/customer/profile` — ProfilePage (shell tab) | SH-05, SH-08, SH-32, SH-34 (partial) | Identity, mode switch, language/theme, demo offline toggle |
| `/customer/requests/new` — CreateRequestPage | CU-03, CU-04, CU-05, CU-06, CU-07, CU-08 | Schedule picker in-form; photos are local paths in mock |
| `/customer/concierge` — ConciergePage | CU-01, CU-07, CU-09 (partial), SH-24 (distress card) | Server-side draft, publish card; `_SosCard` on distress phrases |
| `/customer/concierge/voice` — VoiceConciergePage | CU-02 (mock) | LiveKit seam; pcm voice rejected by mock (`ERR_UNSUPPORTED_LANGUAGE`) |
| `/customer/requests/:id` — RequestDetailPage | CU-07, CU-09–CU-15, CU-18, CU-21, CU-24, CU-25, SH-24, SH-30 | OffersBoard (offers/counters/TTLs), OpenDisputeSheet, RatingSheet, SosSheet; float shown as amount only (no CU-22 receipt review UI) |
| `/customer/requests/:id/pay` — PaymentPage | CU-16, CU-17, CU-29 (promo) | 15-min TTL countdown; simulated webhook flips to PAID_HELD (mock seam) |
| `/customer/requests/:id/track` — TrackingPage | CU-19, SH-24, SH-26 | Canvas plot, no map SDK; trip-share link to clipboard |
| `/customer/requests/:id/chat` — ChatPage | SH-10, SH-11, SH-15 (partial) | Text/image; moderation warnings from mock rules |
| `/customer/requests/:id/call` — CallPage | SH-12, SH-14, SH-15 | LiveKit seam; masked-call fallback simulated (no telephony partner) |
| `/customer/wallet` — WalletPage | SH-18, SH-19, SH-23, CU-28 (partial) | Balances, history, shared WithdrawSheet |
| `/customer/referrals` — ReferralsPage | SH-20, SH-21, SH-22 (display), SH-23 | Code, campaign stats, withdrawal; amounts server-computed in mock |
| `/customer/promos` — PromosPage | CU-29 | `ERR_PROMO_INVALID` handling |
| `/customer/disputes` — DisputesPage | CU-26, CU-28 (partial) | Status, SLA, outcome with refund amount; opening happens from request detail |
| `/customer/support` — SupportPage | CU-27 | Ticket list + open; polls `watchTickets` on mocks (no realtime) |
| `/customer/support/:id` — SupportTicketPage | CU-27 | Ticket thread |
| `/customer/settings` — SettingsPage | SH-16, SH-25, SH-36, SH-37 | Channels + quiet hours, trusted contacts (max 5), data export, account deletion |

## Mobile — provider mode

| Route / screen | Story IDs | Notes |
|---|---|---|
| `/provider/onboarding` — ProviderOnboardingPage | PR-01, SH-08 (gate) | Checklist with server-configured steps; reachable from customer mode |
| `/provider/kyc` — ProviderKycPage (+ `provider_kyc_step_forms.dart`) | PR-02, PR-03, PR-04, PR-05, PR-06, PR-07, PR-08, BU-02 (partial) | Step forms per country config; vendor SDK + document upload are mock seams |
| `/provider/feed` — ProviderFeedPage (shell tab) | PR-10, PR-11, PR-14 | Online toggle, today's earnings, document-expiry reminders, nearby requests |
| `/provider/jobs` — ProviderJobsPage (shell tab) | — | **Empty state only** — no provider-scoped job execution UI (see gaps) |
| `/provider/earnings` — EarningsPage (shell tab) | PR-21, PR-22 (partial) | Available/pending/lifetime, paginated history; withdrawal via tools page |
| `/provider/profile` — ProfilePage (shell tab, shared) | SH-05, SH-08, SH-31 (partial) | Same shared profile surface as customer mode |
| `/provider/tools` — ProviderToolsPage | PR-22 (instant payout), PR-24, PR-25, PR-26 | Availability editor, earnings goal, heatmap as intensity-colored zone list (no map SDK), insights tiles |
| `/provider/org` — OrganizationPage | BU-01, BU-03, BU-04 (partial), BU-06, BU-07, BU-08, BU-10 (partial) | Business console: overview, member invite/roles, vehicle registry, dispatch; per-worker earnings redacted by role |

## Web customer (`apps/web-customer`, `/[locale]/…`)

| Route / screen | Story IDs | Notes |
|---|---|---|
| `/` (root) | — | Redirect to `/en` |
| `(app)/` — dashboard | WB-08 (hub) | Card grid linking to main sections |
| `(app)/requests` | CU-03 (drafts), CU-09 (partial), WB-03 | Request list |
| `(app)/requests/new` | CU-03–CU-08, WB-03 | Form; drag-and-drop photo upload |
| `(app)/concierge` | CU-01, CU-07, WB-03 | Text concierge only; voice is app-only per WB-03 |
| `(app)/requests/[id]` | CU-09–CU-15, CU-18, CU-21, CU-24, CU-25, SH-30, WB-04 | OffersBoard, HandoverPinCard, CancelRequestButton, DisputeSection, RatingSheet |
| `(app)/requests/[id]/pay` | CU-16, CU-17, WB-05 | Hosted-checkout redirect; return reconciles from server (mock seam) |
| `(app)/requests/[id]/track` | CU-19, SH-24, SH-26, WB-06 | Tracking + trip share + SOS affordances |
| `(app)/requests/[id]/chat` | SH-10, SH-11, WB-06 | Job chat |
| `(app)/messages` | SH-10, SH-17 (partial), WB-06 | Conversation list |
| `(app)/verify` | WB-02, SH-06, SH-07 | Browser KYC flow; vendor web SDK is a mock seam |
| `(app)/wallet` | SH-18, SH-19, SH-23, WB-08 | WithdrawalModal |
| `(app)/referrals` | SH-20, SH-21, SH-23, WB-08 | |
| `(app)/promos` | CU-29, WB-08 | |
| `(app)/disputes` | CU-26, CU-28 (partial), WB-08 | |
| `(app)/support` + `(app)/support/[id]` | CU-27, WB-08 | Ticket list + thread |
| `(app)/settings` | SH-16, SH-25, SH-32, SH-36, SH-37, WB-08 | |

## Web marketing (`apps/web-marketing`, `/[locale]/…`)

| Route / screen | Story IDs | Notes |
|---|---|---|
| `/` (root) | — | Redirect to `/en` |
| `/` (locale home) | MK-01 | |
| `/how-it-works` | MK-01 | Customer + provider flows |
| `/safety` | MK-01 | Safety and verification explained |
| `/services` | MK-01 | Category overview |
| `/become-a-provider` | MK-02 | Requirements per country, deep-link CTA |
| `/businesses` | MK-02 (adjacent) | Business/fleet pitch; no dedicated PRD story |
| `/cities/[city]` | MK-03 (partial) | City landing pages; **no country-level page** |
| `/faq` + `/contact` | MK-04 | Contact form with Turnstile seam |
| `/legal/terms` + `/legal/privacy` | MK-06, SH-39 (display) | Versioned per country; cookie consent per MK-06 |
| `/referrals` | MK-07, SH-20 | Referral landing with store links / deferred deep link |

## Web admin (`apps/web-admin`)

| Route / screen | Story IDs | Notes |
|---|---|---|
| `/sign-in` | AD-01 | Email + MFA step; any-password mock + `switchPersona` are M9 seams |
| `(console)/` — overview | AD-24 (partial) | Per-country KPI cards (GMV, funds held, open disputes/SOS) |
| `(console)/directory` | AD-03, AD-04 | 5 entity tabs, search, detail drawer, suspend/unsuspend with reason |
| `(console)/verification` | AD-05, AD-06, AD-07, AD-09 | 5 queue kinds (id, facial, police, vehicle, business), claim/approve/reject, 60s document view token; no AD-08 expiry view |
| `(console)/jobs` + `/jobs/[id]` | AD-10 | Timeline + SVG route plot; JobAdminView carries agreedPrice only (open need) |
| `(console)/payments` | AD-13, AD-14 | Tabs: holds / settlements / payouts / withdrawals; reauth + two-person approval flows |
| `(console)/promos` | AD-16 | CRUD, pause/resume |
| `(console)/referrals` | AD-17 | Attributions, flagged-case review, campaign create/pause/resume |
| `(console)/disputes` + `/disputes/[id]` | AD-18, AD-19 | Quote-first resolution (server-computed Money rows), reauth |
| `(console)/support` + `/support/[id]` | AD-20 | Assign, thread, close |
| `(console)/sos` | AD-21 | Live banner + trail, acknowledge/resolve |
| `(console)/risk` | AD-17 (fraud signals), AD-02 (partial) | Signals, review/escalate |
| `(console)/config` | AD-22 (partial) | Flags / country packs / commissions + two-person pending changes; **no service-taxonomy/price-guardrail editor (AD-11)** |
| `(console)/analytics` | AD-24 | SVG series + read-only AI admin assistant with deep-link action cards |
| `(console)/audit` | AD-02 | Live tail, filters |
| `(console)/admin-users` | AD-01, AD-02 | Invite, role change, deactivate, enforce MFA (super_admin only) |

## Gap analysis

### a) PRD stories with no screen anywhere

Surface per the PRD's own assignment. "Post-launch/gated" notes come from the PRD text itself.

**Shared (SH)**
- SH-13 — Receive a call when the app is closed (CallKit/PushKit, full-screen intent). Device capability, not a screen; PRD-gated on S-03 device lab. M9.
- SH-27 — Block someone. No block UI on any surface.
- SH-28 — Report someone or something. No report UI on any surface.
- SH-38 — Devices/sessions list + remote sign-out. Backend exists (HANDOFF 2026-09-17); no UI.
- SH-39 — Accept terms per country (in-app acceptance prompt). Legal *display* exists on marketing; no acceptance-recording screen.
- SH-33 (accessibility) and SH-34 (offline/low-data) are cross-cutting qualities, not screens; partially exercised (demo offline toggle, startup-error page) but not fully testable until M9.

**Customer (CU)**
- CU-20 — Replace a provider who doesn't start. No reassignment UI.
- CU-22 — Review an item-float receipt. Float shows as an amount only; no receipt-approval screen.
- CU-30 — Tip the provider. No tip UI (RatingSheet has no tip step).
- CU-31 — Favourite and rebook a provider. No favourites UI anywhere.
- CU-32 — Book a scheduled errand. Schedule field exists in the create form (CU-08), but no scheduled-errands list with edit/cancel. (Recurrence is PRD-marked **Later**.)
- CU-23 (auto-confirmation) is server-driven; customer notification/display only partial.

**Provider (PR)**
- PR-09 — Selfie check before going online. Only the `ERR_SELFIE_CHECK_REQUIRED` label exists; no capture screen.
- PR-12 — Make an offer with payout estimate. No provider offer UI (mock repo has the methods).
- PR-13 — Counter or withdraw an offer. Same gap.
- PR-15, PR-16, PR-17, PR-18, PR-19, PR-20 — Provider job execution (start, navigate/status, PIN entry, proof, float receipt, cancel). `/provider/jobs` is an **empty-state stub**; nothing references `verifyHandoverPin`/`submitProof`/`setJobStatus` in `apps/mobile/lib`.
- PR-23 — Change payout account safely. No payout-account management screen.
- PR-27 — Provider trust-level view. Only an average-rating tile in tools insights; no trust-level/progress screen.

**Business (BU)**
- BU-05 — Bid as the organisation. Blocked by the same missing offer UI as PR-12/PR-13.
- BU-09 — Zone-rule explanation ("why a request isn't shown"). Heatmap shows zones; no per-request exclusion messaging.
- BU-02/BU-04 partially covered (worker KYC via the individual flow; owner visibility of worker verification status partial).

**Web (WB)**
- WB-01 — Sign in on the web. Header has a stub button (`TODO(M9)`); no OTP flow screens.
- WB-07 — Call from the browser. No call page in web-customer.

**Marketing (MK)**
- MK-03 — Country landing pages missing (only `/cities/[city]` exists).
- MK-05 — SEO/Lighthouse budgets: non-screen; CI concern, not verifiable here.

**Admin (AD)**
- AD-08 — Expiry and re-verification monitoring view. Verification page has queues by kind, no expiry/re-verification list.
- AD-11 — Service taxonomy + price-guardrail management. Config covers flags/packs/commissions only.
- AD-12 — Moderation queue. No page.
- AD-15 — Daily reconciliation view. Payments tabs are holds/settlements/payouts/withdrawals; no reconciliation screen.
- AD-23 — Notification templates and broadcasts. No page.

### b) Screens with no matching story

| Screen | Nearest story | Note |
|---|---|---|
| `/splash`, `/startup-error` (mobile) | SH-35 (partial) | Bootstrap infrastructure; SH-35 covers force update but not generic bootstrap failure |
| `/` root redirects (web-customer, web-marketing) | — | Locale redirects, plumbing only |
| `(app)/` dashboard (web-customer) | WB-08 (hub) | Navigation hub; no dedicated story |
| `/businesses` (web-marketing) | MK-02 (adjacent) | Business-provider marketing page; PRD has no business-marketing story |
| `(console)/risk` (web-admin) | AD-17 (partial) | Risk-signal review goes beyond AD-17's referral-fraud queue; arguably its own surface |
| `/provider/jobs` (mobile) | PR-15…PR-20 | Inverse case: the story exists, the screen is a stub (listed in gaps above) |

## Known mock seams (to close at M9)

Gleaned from HANDOFF.md entries (read-only reference):

- **Payments**: mock `initializePayment` + simulated webhook flips payment HELD → PAID_HELD (or FAILED). Real path: signature-verified gateway webhook + server verify only; client must never mark a payment successful. Web checkout return reconciles from the server.
- **KYC vendor SDK**: customer verification (SH-06/WB-02) and provider KYC steps (PR-02…PR-08) simulate consent → liveness → outcome. Real vendor SDK + webhook outcomes at M9; nothing cached on device.
- **Calls/voice**: LiveKit not integrated — job calls (SH-12) and voice concierge (CU-02) are simulated; pcm voice refused by mock. Masked PSTN fallback (SH-14) has no contracted telephony partner. Incoming-call-when-closed (SH-13) needs CallKit/PushKit + FCM.
- **Maps SDK**: none in mock builds — tracking is a canvas plot, heatmap is an intensity-colored zone list.
- **Push**: no push pipeline; notifications are in-app/polled. Support tickets poll `watchTickets` instead of realtime.
- **SOS partner**: no contracted security/emergency partner; acknowledgement is simulated but recorded as a seam.
- **Trip share**: mock `TripShare.url` format to be replaced by the tokenised, hashed-token link.
- **Web-customer auth**: sign-in button is a stub pending `@supabase/ssr`; admin sign-in is any-password + `switchPersona`.
- **Support tickets**: realtime delivery missing (polling on mocks).
