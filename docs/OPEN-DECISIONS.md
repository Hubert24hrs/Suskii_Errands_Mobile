# Open Decisions Register

Canonical list of decisions the client (or counsel) still owes the build. The spec requires these to be listed in **every phase checkpoint** until they are resolved, with the stated default implemented behind admin configuration in the meantime.

**Keep this file updated.** When a decision is resolved: set Status to `Resolved`, record the date and the answer, and link the ADR that implements it. Never delete a row.

Legend — **Status:** `Open` (awaiting an answer) · `Proposed` (Claude Code recommends the default; silence means we build the default) · `Resolved`. **Needed by:** the phase that cannot proceed correctly without it.

## From the spec (OD-01 … OD-08)

| ID | Topic | Default we are building | Status | Owner | Needed by |
|---|---|---|---|---|---|
| OD-01 | Who funds the 2.5% referral commission | Platform funds it from its 12.5%, so provider earnings are unaffected | Open | Client | Phase 5 (money) |
| OD-02 | Referral commission duration | Lifetime of the referred account, with an admin-configurable cap per country and campaign | Open | Client | Phase 5 |
| OD-03 | Both sides of a job were referred by different people | Each referrer earns 2.5% of net, max 5% per job | Open | Client | Phase 5 |
| OD-04 | Shopping errands: item cost handling | Prepaid item float as a separate non-commissionable line, released against a receipt; gateway fee passed to the customer | Open | Client | Phase 3 (requests), Phase 5 |
| OD-05 | Insurance / damage and loss cover | No insurer at launch; declared value, claims inside disputes, insurer-ready hooks | Open | Client | Phase 4 |
| OD-06 | Commission rate | 12.5%, configurable per country | Open | Client | Phase 5 |
| OD-07 | Countries live on launch day | Nigeria first; others as their packs are verified | Open | Client | Phase 1 (contracts), Phase 10 |
| OD-08 | Gateway fee on refunds | Platform absorbs it for fault-free cancellations; deducted for late customer cancellations | Open | Client | Phase 5 |

## Raised by Phase 0 research (OD-09 … OD-18)

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

## Resolved

_None yet._

| ID | Answer | Date | Implemented by |
|---|---|---|---|
| | | | |
