# Threat model — STRIDE per component

| | |
|---|---|
| Owner | Claude Code |
| Date | 2026-09-16 |
| Status | Phase 1 draft — reviewed again before the Phase 10 penetration test |
| Standards | OWASP MASVS, ASVS L2, API Security Top 10, Top 10 for LLM Applications (spec `security.standards`) |
| Inputs | [architecture-c4.md](architecture-c4.md) (component boundaries), [rls-policy-matrix.md](rls-policy-matrix.md), spikes S-10, S-13, S-14, risk register |

**STRIDE:** **S**poofing · **T**ampering · **R**epudiation · **I**nformation disclosure · **D**enial of service · **E**levation of privilege.

**Residual risk** after listed controls: **H** high, **M** medium, **L** low. Every H must have an owner and a date before launch.

This model concentrates on threats specific to *this* platform — a paid-upfront marketplace handling biometrics, criminal records and live location across African markets — rather than restating generic web checklists, which the standards above already cover.

## Assets, ranked by harm if compromised

| # | Asset | Why it ranks here |
|---|---|---|
| 1 | Held customer funds and provider earnings | Direct theft; regulatory exposure per country (OD-12) |
| 2 | Biometric data and criminal-record documents | Special-category data; irreversible harm; prior authorisation in ZA (POPIA) |
| 3 | Live and historical location of customers and providers | Physical safety: stalking, robbery, targeting at a known address |
| 4 | Government ID numbers and payout accounts | Identity theft, payout redirection |
| 5 | Account sessions | Gateway to all of the above |
| 6 | Trust signals (ratings, verification level, referral earnings) | Fraud economics: fake providers, farmed referrals |
| 7 | Platform availability | Stuck paid jobs, SOS unavailable during an emergency |

---

## 1. Mobile app (untrusted client)

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | Account renting or sharing: a verified provider lets an unverified person work under their account | Selfie check before going online plus random checks (OD-13); device binding; selfie re-verification on device change | M |
| **S** | SIM swap takes over the phone-OTP account | After a phone-number change: withdrawals and payout-account changes blocked for a cooling-off period and require face re-verification; alert to the old email | M |
| **T** | Repackaged or hooked app (Frida) forges requests or skips client checks | Nothing client-side is authoritative; freeRASP signals to the risk engine; Play Integrity / App Attest tokens verified server-side on login, KYC, payouts, withdrawals, referral actions (spec) | L |
| **T** | GPS spoofing to fake arrival, completion or location-based fraud | Mock-location flag on every ping; server plausibility checks (speed between samples, geofence dwell); PIN + photo proof required, not position alone | M |
| **R** | Customer denies confirming, or provider denies accepting | `job_events` with actor, device, server timestamp and idempotency key; append-only | L |
| **I** | Sensitive data left on device (KYC captures, chat cache, tokens) | Tokens in Keychain/Keystore; KYC images uploaded and deleted, never cached; encrypted local store for chat; screenshot protection on KYC, wallet, PIN, payout screens (spec) | L |
| **I** | Traffic interception on hostile networks | TLS with public-key pinning and backup pins (spec); cleartext disabled | L |
| **D** | Client floods RPCs or offers | Per-user, per-device and per-IP rate limits at the edge and in functions | L |
| **E** | Direct table writes to status, money or verification columns | Column grants + RLS + functions — proven by spike S-13 | L |

## 2. Customer web app and marketing site

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | Session theft via XSS | Strict CSP, HttpOnly/Secure/SameSite cookies through `@supabase/ssr`, no tokens in `localStorage` | L |
| **T** | CSRF on state-changing actions | SameSite cookies + CSRF tokens on server actions; all writes are authenticated RPCs | L |
| **I** | Server components leak another user's data through caching | No shared caching of authenticated responses; server code uses the user's session, **never the service role** (spec web rule) | M |
| **I** | Marketing site becomes a phishing vector (fake "verify your account" pages under our brand) | HSTS preload, strict domains, DMARC/SPF/DKIM on mail; no credential entry on the marketing site | M |
| **D** | Bot traffic on public pages | Cloudflare WAF and bot management (spec) | L |

## 3. Admin dashboard (highest-privilege surface)

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | Phished staff credentials | Cloudflare Access (zero trust) in front; SSO; **MFA mandatory, enforced as `aal2` in the database**, not only in the UI (RLS matrix) | M |
| **T** | Insider changes commission, country pack or payout destination | Four-eyes approvals with a table `CHECK (approved_by <> requested_by)`; every change in the hash-chained audit log | L |
| **R** | Staff member denies an action | Hash-chained `audit.log`; no role, including `service_role`, can update or delete it | L |
| **I** | Bulk exfiltration of users, KYC documents or locations | Per-role scopes (country, assignment); KYC documents only via ≤5-minute signed URLs, each view logged in `audit.kyc_access`; no bulk export without approval; nobody reads live provider location directly | M |
| **I** | Support browses private chats | Conversations readable only when a ticket references them (RLS matrix §8) | L |
| **E** | Support agent reaches finance functions | Role checks in every function re-read `admin_users`; the JWT claim alone is never trusted | L |

## 4. Authentication (Supabase Auth, Send SMS Hook)

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | OTP brute force | Short OTP expiry, attempt limits, lockout; `ERR_OTP_RATE_LIMITED` already in Kimi's M2 draft | L |
| **D** | **SMS pumping / toll fraud** — bots trigger OTPs to premium or international numbers and the platform pays per SMS | Turnstile CAPTCHA before OTP (spec); per-number, per-IP and per-device limits; **phone numbers restricted to live and beta country prefixes**; alert on OTP spend per hour; provider-side fraud protection where the SMS vendor offers it | M |
| **S** | Forged Send SMS Hook calls to exfiltrate OTPs or send spam | Standard Webhooks signature verification (REPORT §7) | L |
| **E** | Custom Access Token Hook adds a role claim that is then trusted | Claims are hints for the UI; sensitive functions re-check the database (spec) | L |

## 5. Data API and RPC functions

| | Threat | Controls | Residual |
|---|---|---|---|
| **T** | Mass assignment: updating columns the UI never exposes | Column-level grants — S-13 finding 1 | L |
| **I** | IDOR: reading another user's request, offer or job by id | RLS on every table; functions check `auth.uid()` against ownership; deny tests per role | L |
| **I** | A provider enumerates all open requests or rivals' offer amounts | No table select for providers — the feed is a matching function; offers limited to the provider's own thread (RLS matrix §5) | L |
| **E** | `SECURITY DEFINER` function hijacked through `search_path` | `SET search_path = ''` and schema-qualified names everywhere (spec); lint in CI | L |
| **E** | SQL injection in dynamic SQL | No dynamic SQL with user input; `format()` with `%L`/`%I` where unavoidable | L |
| **T** | Race conditions: double acceptance, double payout, budget overspend | Row locks, idempotency keys, unique constraints — S-10: 0 double acceptances in 750 concurrent attempts | L |
| **D** | Expensive queries (unbounded search, huge pages) | Page-size caps in every list function; statement timeouts per role | L |

## 6. Realtime

| | Threat | Controls | Residual |
|---|---|---|---|
| **I** | Subscribing to another job's channel to watch someone's location | Private channels only, authorised by RLS on `realtime.messages`; participant check per topic | L |
| **S** | A client broadcasts fake location on a job channel | Only the assigned provider may broadcast on `job:{id}`; persisted samples carry plausibility checks; **position alone never completes a job** | M |
| **I** | Location keeps flowing after the job ends | Channel access ends at completion; the client stops the foreground service; the server rejects late joins | L |
| **D** | Connection or join floods | Supabase quotas; per-user connection caps; Enterprise quota planned at scale (cost model) | M |

## 7. Storage

| | Threat | Controls | Residual |
|---|---|---|---|
| **I** | Reading KYC documents | `kyc-docs` has **no read policy for any client role** (spec); officer access only via signed, logged URLs | L |
| **I** | EXIF GPS in proof photos reveals a home address | EXIF stripped on the display rendition; original kept for dispute evidence only | L |
| **T** | Malware or polyglot files uploaded | Size and MIME limits per bucket; malware scan and image re-encode before the object becomes readable (spec) | M |
| **T** | Path manipulation writing into another user's folder | Server-generated object paths in signed upload URLs; clients never choose paths | L |

## 8. Edge Functions — payments and webhooks

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | Forged "payment succeeded" webhook | Signature verification **and** a server-side verify call to the gateway before any state change (spec; job lifecycle #8) | L |
| **T** | Replayed webhook re-triggers payment or payout | Raw event stored and de-duplicated on `(gateway, gateway_event_id)`; state machine idempotent | L |
| **T** | Payout redirected to an attacker's account | Payout account must name-match the verified identity; changes require face re-verification and biometric/PIN confirmation; cooling-off before the first payout to a new account (spec + §1 SIM swap control) | M |
| **R** | Dispute over whether money moved | Ledger + stored raw webhooks + gateway references; daily reconciliation (money flows) | L |
| **I** | Secrets in logs or error reports | Secrets only in Vault / Secret Manager; log redaction; Sentry scrubbing | L |
| **E** | Service role key leaks into a client bundle | Never in client code or repo (spec); CI check scans build artefacts for the key pattern | L |

## 9. Ledger and money logic

| | Threat | Controls | Residual |
|---|---|---|---|
| **T** | Unbalanced or mixed-currency postings | Validation in the posting function + deferred zero-sum constraint (S-14) | L |
| **T** | Rounding exploitation (repeated tiny transactions) | `round_half_even` computed once per amount; minimum amounts per category; money snapshot written once on `jobs` | L |
| **T** | Negative-balance exploitation: withdraw, then trigger a clawback | Withdrawals only from `available` commissions after hold periods; negative balances block withdrawal and offset future earnings (spec) | L |
| **T** | Promo or campaign budget overspend under concurrency | Budget updated under row lock, transactionally (spec) | L |
| **R** | Finance cannot explain a balance | Balances derived from entries; materialised balances reconciled nightly (ADR-0011) | L |

## 10. AI service and voice agent (OWASP Top 10 for LLM)

| | Threat | Controls | Residual |
|---|---|---|---|
| **E** | **Prompt injection** through request text, chat, offer messages or receipt images makes the concierge act beyond the user's rights | **Tools act with the user's own JWT, so RLS contains the blast radius (ADR-0012)**; tool allowlist excludes money, verification and dispute functions; structured outputs validated before execution; red-team eval cases per tool | M |
| **T** | Model output treated as authoritative (a price, an approval) | Spec guardrail enforced in code: the AI never sets prices, approves verification, moves money or resolves disputes; price bands are advisory | L |
| **I** | Personal data sent to the model or leaked into another user's answer | PII redaction before model calls; no cross-user context; only redacted transcripts stored, 90-day retention (ERD) | M |
| **I** | Insecure output handling: model returns a link or markup rendered as trusted | Model text rendered as plain text; links not auto-opened; no HTML rendering of model output | L |
| **D** | Cost exhaustion: a user or bot drives thousands of LLM calls | Per-user rate limits and token budgets; cost tracked per feature with alerts (spec); cost model assumes context caching | M |
| **S** | Voice social engineering ("I'm the provider — read me the PIN") | The agent never reads out PINs, access notes, contact details or payout data; those tools do not exist in its allowlist | L |

## 11. Calls and telephony

| | Threat | Controls | Residual |
|---|---|---|---|
| **I** | Phone numbers harvested for off-platform contact | Numbers never exposed; masked PSTN only in the job window (spec) | L |
| **S** | Joining another job's call | LiveKit tokens minted server-side, room-scoped, short-lived, participants only (spec) | L |
| **D** | Harassment after the job ends | Call window closes 24 h after completion (spec); block and report | L |
| **D** | Toll fraud through PSTN fallback | Fallback only for participants of an active job, capped minutes per job, per-user limits | M |

## 12. Safety and SOS

| | Threat | Controls | Residual |
|---|---|---|---|
| **D** | SOS unavailable in an emergency (partner or platform outage) | Local emergency numbers always shown from the country pack; ops console as first line; partner acknowledgement tracked with escalation (spec) | M |
| **T** | False SOS used to harass or to trigger an armed response to an address | Ops verification step before partner dispatch where the country allows; rate limits; abuse reviewed and actioned | M |
| **I** | Trip-share link forwarded and used to stalk | Tokens hashed, expiring, revocable; the viewer sees only the active trip, never history or home address | L |
| **S** | Forged partner acknowledgement | Signed partner API calls; secrets in Vault | L |

## 13. Fraud and trust signals

| | Threat | Controls | Residual |
|---|---|---|---|
| **S** | Self-referral and referral farms | Single-level only; de-duplication by device, phone, email, face (vendor), ID hash, payout account and card fingerprint; velocity limits; 72 h hold (spec) | M |
| **T** | Collusive fake jobs to farm referral commission or ratings | Risk rules for pairs transacting mainly with each other; PIN + proof + payment required for completion; flagged commissions go to review (spec) | M |
| **S** | Banned user re-registers | Duplicate-face detection within our tenant (Smile Secure), ID-number blind-index uniqueness (ERD) | M |
| **T** | Off-platform cash deals bypass all protections (R-05) | Chat moderation for numbers and account details; on-platform-only safety value (SOS, dispute cover, PIN proof); repeat-pair cancellation signals | **H** — a business risk as much as a technical one |

## 14. Supply chain and delivery

| | Threat | Controls | Residual |
|---|---|---|---|
| **T** | Compromised or abandoned dependency | ADR-0010 exclusions; dependency and licence scanning in CI; pinned versions and lockfiles | M |
| **I** | Secret committed to the repository | Secret scanning in pre-commit and CI; rotation plan | L |
| **T** | Malicious migration or function deployed to production | Migrations applied to staging automatically, production by manual approval (spec); protected branches | L |

---

## High and medium residuals needing an owner before launch

| Threat | Residual | Owner | Linked risk |
|---|---|---|---|
| Off-platform cash deals | H | Client + Claude Code | R-05 |
| SMS pumping / toll fraud | M | Claude Code | **R-31 (new)** |
| Prompt injection | M | Claude Code | R-19 |
| Payout redirection after account takeover | M | Claude Code + Kimi Code | **R-32 (new)** |
| GPS spoofing | M | Claude Code + Kimi Code | — |
| Account renting | M | Claude Code | — (control cost is OD-13 / R-04) |
| Admin credential phishing | M | Client (Access/SSO setup) | — |
| Malware in uploads | M | Claude Code | — |
| False or unavailable SOS | M | Client + Claude Code | R-20 |

Two threats above were not in the risk register and are added with this document: SMS pumping (R-31) and payout redirection after account takeover (R-32).
