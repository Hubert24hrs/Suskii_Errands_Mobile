# PRD — Customer web app and marketing site

Conventions in [README.md](README.md) §4. Both are Next.js apps built by Kimi Code. The customer web app reuses the customer stories in [customer.md](customer.md) and [shared.md](shared.md); the stories below cover what is **different on the web**.

## Customer web app (`WB`)

Scope from the spec: post requests, negotiate, pay, track, chat, call. Customer mode only — there is no provider mode on the web.

### WB-01 — Sign in on the web
*As a customer on a laptop, I want to sign in with my phone or email, so that I can use Suskii without the app.*
- Same sign-in methods as SH-02…SH-04; a Turnstile challenge precedes OTP.
- Sessions use secure, HTTP-only cookies via the Supabase SSR helpers; no token is stored in local storage.
- The same account works on web and mobile; mode stays customer on the web.

### WB-02 — Verify my identity on the web
*As a customer, I want to complete facial verification in the browser, so that I can publish and pay.*
- Uses the KYC vendor's web SDK with camera permission; same consent, outcome and privacy rules as SH-06.
- Works in Chrome on the low-end Android device W1 (S-05 web test, **Gated**); unsupported browsers are told to use the app.

### WB-03 — Create a request on the web
*As a customer, I want to post a request with the form or the text concierge, so that I can hire from my desk.*
- CU-01 (text concierge), CU-03…CU-08 apply. Voice concierge is app-only at launch [A — confirm with client].
- Drag-and-drop photo upload with client-side compression.

### WB-04 — Handle offers on the web
*As a customer, I want to receive, compare, counter and accept offers in the browser, so that negotiation isn't tied to my phone.*
- CU-10…CU-15 apply; realtime updates without reload; a background tab still shows a title badge for new offers.

### WB-05 — Pay on the web
*As a customer, I want to pay in the browser, so that I can use my card or bank transfer from my desk.*
- CU-16, CU-17 apply; the gateway's hosted checkout in a redirect or overlay; the return page always reconciles from the server.

### WB-06 — Track and chat on the web
*As a customer, I want to track the provider and chat in the browser, so that I can follow the job.*
- CU-18…CU-21 and SH-10, SH-11 apply; SOS (SH-24) and trip share (SH-26) are available on every active-job page.

### WB-07 — Call from the browser
*As a customer, I want to call the provider from the web app, so that I don't need my phone.*
- In-browser calls with the LiveKit JS SDK under SH-12 rules; incoming calls ring while the tab is open, with a browser notification if permitted, and fall back to the app or PSTN (SH-14) otherwise.

### WB-08 — Manage my account on the web
*As a customer, I want wallet, referrals, disputes, settings and account deletion on the web, so that I can do everything there.*
- SH-18…SH-23, SH-32…SH-39, CU-24…CU-31 apply.
- Responsive from 360 px phones to desktop; keyboard-operable; WCAG AA.
- Playwright E2E covers the core flow and role permissions (test-strategy layer 13).

## Marketing site (`MK`)

### MK-01 — Understand Suskii quickly
*As a visitor, I want a clear home page and "How it works", so that I know what Suskii does and whether I can trust it.*
- Home, How it works (customer and provider), safety and verification explained, categories, download and web-app links.
- Held-funds wording follows ADR-0002; no "escrow".
- Placeholder brand values come from design tokens and swap without code changes (client decision).

### MK-02 — Become a provider
*As a potential provider, I want to learn what's required and start, so that I can decide to join.*
- Requirements page per country: documents, police clearance, vehicle papers, commission, how payouts work.
- A call to action deep-links into provider onboarding in the app, or the store if not installed.

### MK-03 — Find my country and city
*As a visitor, I want a page for my country and city, so that I see local services, prices and payment methods.*
- Country and city landing pages generated from country packs; `live` pages are indexable, `beta` pages say so, `disabled` countries are not published (OD-07, OD-14).

### MK-04 — Get answers and contact support
*As a visitor, I want an FAQ, help and contact options, so that I can resolve questions before signing up.*
- FAQ, help articles shared with the in-app help centre, contact form with Turnstile, support hours per country.

### MK-05 — Be found and load fast
*As Suskii, I want the site to rank and load quickly on slow networks, so that people find and use it.*
- SEO: server-rendered pages, metadata, sitemap, structured data, hreflang for launch languages.
- Lighthouse budgets enforced in CI (spec web testing); pages usable on network profile N3.

### MK-06 — Read legal pages and control cookies
*As a visitor, I want to read the terms and privacy policy and choose cookies, so that I know how my data is used.*
- Terms and privacy policy per country and version (SH-39).
- Cookie consent with non-essential cookies off by default; analytics (PostHog EU) only after consent where required.

### MK-07 — Land from a referral link
*As someone who got a referral link, I want it to work whether or not I have the app, so that my referrer gets credit.*
- The referral URL opens the app if installed, otherwise shows a landing page with store links; deferred deep linking preserves attribution through install (SH-20).
- Attribution cannot be forged by editing the URL into a reward; the server validates code, window and anti-fraud checks (audit checklist).
