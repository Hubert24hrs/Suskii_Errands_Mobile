# Open Decisions Register

Canonical list of decisions the client (or counsel) still owes the build. The spec requires these to be listed in **every phase checkpoint** until they are resolved, with the stated default implemented behind admin configuration in the meantime.

**Keep this file updated.** When a decision is resolved: set Status to `Resolved`, record the date and the answer, and link the ADR that implements it. Never delete a row.

Legend — **Status:** `Open` (awaiting an answer) · `Proposed` (Claude Code recommends the default; silence means we build the default) · `Resolved`. **Needed by:** the phase that cannot proceed correctly without it.

## From the spec (OD-01 … OD-08)

| ID | Topic | Default we are building | Status | Owner | Needed by |
|---|---|---|---|---|---|
| OD-01 | Who funds the 2.5% referral commission | Platform funds it from its 12.5%, so provider earnings are unaffected. **Built 2026-09-22** as money-flows 1c's `platform_referral_expense` line: the provider's 84.60 is identical with or without a referral, and `35_referrals_test.sql` asserts it. Answering the alternative means changing one posting | Open | Client | Phase 5 (money) |
| OD-02 | Referral commission duration | Lifetime of the referred account, with an admin-configurable cap per country and campaign. **Built 2026-09-22** as `referrals.expires_at` plus the `referral.duration_months` and `referral.max_earned_minor` remote-config keys, both defaulting to no cap. An answer is an UPDATE, not a migration | Open | Client | Phase 5 |
| OD-03 | Both sides of a job were referred by different people | Each referrer earns 2.5% of net, max 5% per job. **Built 2026-09-22** as `referral.max_referrers_per_job`, default 2 | Open | Client | Phase 5 |
| OD-04 | Shopping errands: item cost handling | Prepaid item float as a separate non-commissionable line, released against a receipt; gateway fee passed to the customer. **Sub-question (2026-09-16):** receipt total above the float — proposed: never charged automatically; the provider requests a top-up the customer approves in-app, otherwise the difference goes to the dispute path | Open | Client | Phase 3 (requests), Phase 5 |
| OD-05 | Insurance / damage and loss cover | No insurer at launch; declared value, claims inside disputes, insurer-ready hooks | Open | Client | Phase 4 |
| OD-06 | Commission rate | 12.5%, configurable per country | Open | Client | Phase 5 |
| OD-07 | Countries live on launch day | Nigeria first; others as their packs are verified | Open | Client | Phase 1 (contracts), Phase 10 |
| OD-08 | Gateway fee on refunds | Platform absorbs it for fault-free cancellations; deducted for late customer cancellations | Open | Client | Phase 5 |

## Raised by Phase 0 research and Phase 1 planning (OD-09 … OD-25)

| ID | Topic | Proposed default | Status | Owner | Needed by | Evidence |
|---|---|---|---|---|---|---|
| OD-09 | Police-clearance recency and renewal | Accept certificates issued within 6 months; re-verify every 12 months; per-country override | Proposed | Client + counsel | Phase 4 | REPORT §5 — Nigeria costs ₦30,000 and is valid 3 months |
| OD-10 | Who pays payout transfer fees | Provider, shown in the withdrawal preview; platform absorbs small referral payouts | Proposed | Client | Phase 5 | REPORT §3.1 — ₦10–50, KSh 100, GH₵10 per transfer |
| OD-11 | Role of Stripe | Africa: Flutterwave primary + Paystack secondary. Stripe Connect only where a Suskii entity is in US/UK/EEA/CA/CH | Proposed | Client | **Phase 1 (contracts)** | REPORT §3.3 — Stripe cannot pay African connected accounts |
| OD-12 | Operating entity and funds-holding model per country | Gateway merchant balance + limited payment-collection-agent terms; ZA TPPP registration; counsel sign-off before `live` | Proposed | Client + counsel | **Phase 1**, blocking Phase 5 | REPORT §3.4; ADR-0002 |
| OD-13 | Ongoing selfie-check frequency | On-device liveness daily; vendor 1:1 check weekly and on risk triggers | Proposed | Client | **Phase 1**, blocking Phase 4 | cost-model.md — ~$200k/month at 1M MAU if vendor-daily |
| OD-14 | Wave-1 countries | NG live; KE, GH, ZA, UG beta | Proposed | Client | Phase 1 | ADR-0001 |
| OD-15 | Hosting and data residency | Supabase EU (London provisional) + vendor-side biometrics; costed African self-host fallback | Proposed | Client + counsel | Phase 2 | ADR-0008; REPORT §10, §11 |
| OD-16 | Swahili / Luganda for KE and UG | English only at launch in KE/UG; Swahili in V1.2 | Proposed | Client | Phase 1 (l10n scope) | REPORT §2 |
| OD-17 | Nigerian Pidgin voice concierge | Ship Pidgin voice only if it passes the S-08 eval gate; otherwise Pidgin text + English voice | Proposed | Client | Phase 7 | REPORT §6.2 — Live API does not list `pcm` |
| OD-18 | Tax on referral payouts | Ledger supports per-country withholding and annual statements; tax counsel rules per country | Proposed | Client + counsel | Phase 5 | REPORT §3.5 |
| OD-19 | Who receives a cancellation fee | Provider, net of commission, when the customer cancels after the provider committed or travelled; platform keeps nothing extra. The spec says fees depend on state and time but not who receives them | Proposed | Client | Phase 5 (money) | [money-flows.md](plan/money-flows.md) scenario 5a |
| OD-20 | Pidgin evaluation data | Client recruits and pays native Nigerian Pidgin speakers (with recorded consent) to write and review 150 text conversations and record 40 voice tasks across 10+ speakers; Suskii owns the data | Proposed | Client | Phase 7 (blocks S-07 Pidgin half and S-08) | [ai-design.md](plan/ai-design.md) §8.1; R-03 |
| OD-21 | AI moderation outage behaviour | Fail open with deterministic rules still enforced: requests and reviews publish into an async review queue, chat delivers; alert after 5 minutes. Alternative is fail closed (publishing blocked while moderation is down). **Built to this default in Phase 4 (2026-09-21)**, earlier than planned, because the deterministic half of it is what the moderation rules are: a `block`-severity term refuses a request, everything else publishes and queues. Reversing it to fail closed is a change to `private.moderate_text` and its three triggers, not a configuration flip | Proposed | Client | Phase 7 | [ai-design.md](plan/ai-design.md) §6.6 |
| OD-22 | Session lifetime | Customers and providers: no time-box, inactivity timeout 30 days (re-verification for money actions is handled per action, SH-38). Admin console: time-box 12 hours, inactivity 30 minutes (spec: admin session timeouts; PRD AD idle expiry). Supabase applies one setting per project and only on Pro plans and up, so the admin limits need a separate check in the admin app or a separate project | Proposed | Client | Phase 2 (before the first shared environment) | supabase.com/docs/guides/auth/sessions (checked 2026-09-17) |
| OD-23 | Price guardrails per country and category | The country packs' `pricing.guardrails` as they stand, which the packs themselves mark as placeholders: NG only, five categories, hard maximum enforced server-side on every offer and counter, soft band advisory in the app. A category with **no** row has no hard cap, so today seven of Nigeria's twelve categories are uncapped and the other four countries are uncapped entirely. Calibrate with pilot data before launch; a hard cap is a fraud control, not a pricing opinion | Proposed | Client | Phase 3 (built), before the first live country | `docs/research/country-packs/NG.yaml` `pricing.guardrails` (`_status`: assumption); offer state machine, pricing guardrails |
| OD-24 | Restricted items and prohibited services — counsel sign-off | The union of the five country packs' `restricted.*` lists, as `prohibited_items` rows: a `block` action only where the term cannot mean anything else (firearms, explosives, named narcotics, human remains, ivory, trade in identity documents, sex work, exam impersonation, forgery, armed security), a `hold` for everything ambiguous. Every pack tags `restricted: assumption`, so **every rule is `[A]`** and none has been read by a lawyer. The terms themselves are ops-editable data, not code | Open | Counsel | Before the first live country | `docs/research/country-packs/*.yaml` `restricted.*` (`_status`: assumption); [ai-design.md](plan/ai-design.md) §6 and §8 |
| OD-25 | What follows a confirmed fraud flag | Nothing automatic. The risk engine raises flags and a reviewer confirms or clears them; suspension, payout holds and account closure stay separate, explicit, audited decisions. The alternative — automatic suspension above a score — is faster and costs somebody their week's income for a coincidence of device fingerprints. Thresholds are in `remote_config` (`risk_*`) and are ours to tune; the enforcement policy is the client's | Proposed | Client | Phase 5 (money makes the consequences real) | Spec, "Rule-based risk engine"; [threat-model.md](plan/threat-model.md) rows 37, 38, 159; [erd.md](plan/erd.md) §7 |

## Resolved

_None yet._

| ID | Answer | Date | Implemented by |
|---|---|---|---|
| | | | |
