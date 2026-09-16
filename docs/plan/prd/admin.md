# PRD — Admin dashboard

Conventions in [README.md](README.md) §4. Next.js app built by Kimi Code; every permission is enforced in RLS and functions ([rls-policy-matrix.md](../rls-policy-matrix.md)), never only in the UI. Refs: JL = [job-lifecycle.md](../state-machines/job-lifecycle.md), MF = [money-flows.md](../money-flows.md), AI = [ai-design.md](../ai-design.md).

**Roles (client decision):** Super Admin (SA), Verification Officer (VO), Support Agent (SU), Finance Officer (FO), Dispute Officer (DO).

## Access and audit

### AD-01 — Sign in as staff
*As a staff member, I want a secure sign-in, so that only authorised people reach the dashboard.*
- The dashboard sits behind Cloudflare Access; staff sign in with SSO and **mandatory MFA**; database admin functions require `aal2` and refuse `aal1` (RLS named test).
- Staff accounts are separate from customer/provider accounts.
- Idle sessions expire; sign-ins are audit-logged with device and IP.

### AD-02 — See only what my role allows, with every action audited
*As a Super Admin, I want roles scoped to their work and a complete audit trail, so that access is least-privilege and accountable.*
- Navigation and data follow the role matrix; a hidden page is also refused by the database.
- Every admin read of classes B, C, G, L and every write is recorded in the hash-chained audit log with actor, role, target and reason where required (DF rule 7).
- SA manages staff roles; role changes need a second SA approval and are audited.
- Audit log is searchable by SA; no role can edit or delete entries.

## Users and verification

### AD-03 — Find and view a user
*As support or a Super Admin, I want to search users and see their account, so that I can help them.*
- Search by id, phone (exact match), email, name; results show masked phone and email by default, unmasked with a reason that is audited.
- Profile shows verification status, trust level, jobs, disputes, reports, devices and risk flags; roles see only their fields (e.g. SU sees no KYC documents).

### AD-04 — Suspend, ban or restore an account
*As a Super Admin or support lead, I want to restrict accounts with a reason, so that harmful users are stopped fairly.*
- Actions: warn, suspend (time-boxed), ban, restore, each with a reason key and note; the user is notified with the reason key and appeal route.
- Suspension blocks going online, publishing and withdrawals; active jobs are routed to support for handling.
- Bans add the verified identity and face template reference to the duplicate-registration block (spec).

### AD-05 — Work the verification queue
*As a Verification Officer, I want a queue of pending KYC reviews, so that providers are reviewed in order and on time.*
- Queue by country, step type and age, with SLA timers; claiming an item prevents two officers reviewing it simultaneously.
- Shows vendor outcomes, reference ids, dates, certificate numbers (decrypted only for the officer, audited) and the provider's submitted fields.

### AD-06 — View KYC documents securely
*As a Verification Officer, I want to view uploaded documents, so that I can check them.*
- Documents open via short-lived signed URLs (≤ 5 min); every view writes `audit.kyc_access` (DF flow 6).
- Documents cannot be downloaded in bulk; the viewer discourages saving (watermark with officer id).
- Only VO and SA can view; no other role, including support, can open them.

### AD-07 — Approve or reject a step
*As a Verification Officer, I want to approve or reject each step with a reason, so that providers know what to fix.*
- Decisions use reason keys only; **there is no free-text field for criminal-history details** (spec).
- Final approval moves the provider to `VERIFIED`; officers cannot approve their own account or a relative's flagged account.
- KYC vendor outage: nothing is auto-approved (RB-05).

### AD-08 — Monitor expiry and re-verification
*As a Verification Officer, I want to see documents expiring and re-verification triggers, so that nobody works on lapsed papers.*
- Lists of documents expiring in 30/14/3 days and expired; automatic suspension of job acceptance on expiry (PR-14).
- Re-verification triggers (profile photo, device, payout account change, large withdrawal, failed selfie checks) are listed with outcome.

### AD-09 — Review a business
*As a Verification Officer, I want to review business registrations and owners, so that only real businesses operate.*
- Business documents per country pack, owner KYC status, member list and vehicle registry in one view; approve or reject with reason keys.

## Marketplace operations

### AD-10 — Inspect requests, offers and jobs
*As support or a Dispute Officer, I want a job's full timeline, so that I can understand what happened.*
- Timeline of every state transition (from the append-only event log), offers and counters, payments, PIN attempts, proof, chat (only when a ticket or dispute is linked, RLS data minimisation), call metadata and location trail.
- Admins cannot change job state directly; only defined admin functions (dispute resolution, forced cancellation with reason) exist, each audited.

### AD-11 — Manage services and price guardrails
*As a Super Admin, I want to manage the service taxonomy and price limits, so that categories and guardrails match each market.*
- Categories with labels per language, required fields, proof requirements, offer TTL, counter rounds, float allowed, vehicle requirements.
- Price guardrails (soft and hard) per category, city and urgency.
- Changes are versioned and take effect for new requests only.

### AD-12 — Moderate content
*As support, I want a moderation queue, so that flagged requests, messages, reviews and media are handled.*
- Items flagged by rules, AI or user reports, with labels and severity; actions: allow, remove, warn user, escalate.
- Off-platform payment and prohibited-item flags are prioritised.
- AI moderation never bans; people decide (AI §6.3).

## Money

### AD-13 — View payments and issue refunds
*As a Finance Officer, I want to see payments and issue refunds within policy, so that money problems are fixed.*
- Payments with gateway references, status, fees, webhook history and ledger postings for the job.
- Manual refunds only through the refund function with a reason; above a threshold a second approver is required; the ledger stays zero-sum (MF).
- Stuck payments are surfaced per RB-02.

### AD-14 — Approve payouts and withdrawals
*As a Finance Officer, I want to approve large withdrawals with four-eyes control, so that big payouts are checked.*
- Withdrawals above the configured threshold need FO approval; above the higher threshold a second, different approver (spec); an approver cannot approve their own request (RLS named test).
- Shows payout account name-match result, account age, recent phone or device changes and risk flags (R-32).
- Failed and reversed payouts listed with retry and notify actions (RB-04).

### AD-15 — Reconcile daily
*As a Finance Officer, I want a daily reconciliation view, so that ledger and gateway settlements always agree.*
- Daily comparison of ledger totals against gateway settlement reports per gateway, currency and country; mismatches alert and open a case (spec; RB-03).
- Ledger health: unbalanced transactions (must be zero), held funds by age, refunds payable.

### AD-16 — Manage promo codes
*As a Super Admin or Finance Officer, I want to create promo codes with budgets, so that marketing spend is controlled.*
- Code, country, currency, discount, validity, usage limits, budget cap, stacking rules with referrals; platform-funded only (CU-29).
- Spend against budget in real time; codes pause automatically at the cap.

### AD-17 — Run referral campaigns and review referral fraud
*As a Super Admin or Finance Officer, I want boosted campaigns and a fraud queue, so that referrals grow users without abuse.*
- Time-boxed boosted-rate campaigns per country with a budget cap enforced transactionally (spec).
- Flagged commissions (self-referral signals, collusion, wash trading, velocity, tampered devices) go to a review queue; actions: release, reverse, ban; all audited (spec anti-fraud).

## Disputes, support, safety

### AD-18 — Work the dispute queue
*As a Dispute Officer, I want disputes with their evidence and SLA timers, so that I resolve them fairly and on time.*
- Queue by age and SLA; evidence bundle: chat, photos, GPS trail, PIN logs, call metadata, receipts, both parties' statements (spec).
- Request more information from either party with a deadline; payouts stay frozen while open.

### AD-19 — Resolve a dispute
*As a Dispute Officer, I want to decide the outcome, so that money goes where it should.*
- Outcomes: provider's favour (settlement resumes, JL #28), full refund or partial refund with amount (JL #29), each with a reason key and a note visible to both parties.
- Partial refunds above a threshold need a second approver (Finance Officer or SA).
- Resolution posts ledger entries and referral reversals automatically; officers never edit balances.

### AD-20 — Handle support tickets
*As a Support Agent, I want tickets triaged with context, so that I can respond quickly.*
- AI triage suggests queue, priority and macros (AI §5.4); agents can override; safety tickets always route to the safety queue.
- Ticket shows linked user, job and payment summaries within the agent's role; chat is visible only for the linked job.
- Macros and replies are localized; SLAs per priority.

### AD-21 — Run the SOS ops console
*As an operations agent, I want a real-time SOS queue, so that every emergency gets a response.*
- Live queue with location, job details, parties, trusted-contact notifications and partner acknowledgement state (spec).
- Escalation if the partner hasn't acknowledged within the configured time; notes and resolution status; every step timestamped (RB-06).
- An audible and visual alert for new SOS; cannot be dismissed without an action.

## Configuration, notifications, analytics

### AD-22 — Configure countries, commissions and features
*As a Super Admin, I want to manage country packs, rates and feature flags, so that markets are configured as data, not code.*
- Edit country pack fields (spec list); a country goes `live` only when its pack is complete and approved (RB-08).
- Commission and referral rate changes, gateway routing, withdrawal thresholds and fee rules require four-eyes approval and apply to new jobs only (rates are snapshotted per job).
- Feature flags, kill switches, forced-update version and AI model routes (RB-11, RB-13), all versioned and audited.

### AD-23 — Send notifications and manage templates
*As a Super Admin, I want to manage notification templates and send announcements, so that users get consistent, localized messages.*
- Templates per channel and language with variables; transactional templates cannot be used for marketing.
- Broadcasts respect marketing consent and quiet hours and can target country, mode and segment.

### AD-24 — See analytics and ask the AI admin assistant
*As a Super Admin or ops lead, I want dashboards and to ask questions in plain language, so that I understand the business quickly.*
- Dashboards: funnel (publish → offer → agree → pay → complete), GMV per currency, supply and demand by hour, verification queue, disputes, payouts, referral spend, AI cost.
- The AI admin assistant answers using **only predefined, parameterised analytics functions on a read replica — never free-form SQL**, cites the functions behind each number, returns aggregates only, and suppresses cells below the threshold (spec; AI §4.4).
- Each role sees only the functions and countries in its scope.
