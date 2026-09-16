# PHASE 0 CHECKPOINT — Deep Research

| | |
|---|---|
| Agent | Claude Code (backend) |
| Date | 2026-09-15 |
| Spec | `docs/spec/SUSKII_BUILD_PROMPT.json` v3.1.0 |
| Mode | Run in parallel with Kimi Code's frontend build (per user instruction). No application code written; `apps/` untouched |

## Objective

Confirm every `VERIFY-IN-RESEARCH` item in `master_spec` against current sources. Pick vendors per category and country. Draft country packs. Size costs and risks. Define the spikes that de-risk Phase 1.

## 1. Delivered

| Deliverable (spec `phases[0].deliverables`) | File |
|---|---|
| Research report with sources | [REPORT.md](REPORT.md) |
| Vendor decision matrix (score, recommendation, fallback), per category and country | [vendor-decision-matrix.md](vendor-decision-matrix.md) |
| Country pack drafts for candidate countries | [country-packs/](country-packs/) (NG, KE, GH, ZA, UG) |
| Compliance checklist and DPIA outline | [compliance-checklist-and-dpia.md](compliance-checklist-and-dpia.md) |
| Risk register | [risk-register.md](risk-register.md) (30 risks: 8 critical, 16 high, 6 medium) |
| Monthly running-cost model at 1k / 10k / 100k / 1M MAU | [cost-model.md](cost-model.md) |
| Spike plan (VoIP killed-app, background location on Transsion devices, liveness on 2 GB, PostGIS at 100k, concurrent offer acceptance, Realtime load, plus 6 more) | [spike-plan.md](spike-plan.md) |

All 13 Phase 0 research tasks are covered in REPORT.md §1–§13, and every material claim is tagged `[V]` verified / `[S]` secondary / `[A]` assumption.

## 2. Decisions made

These are recommendations within the backend lead's remit. Each is now written up as an ADR ([docs/adr/](../adr/README.md), ADR-0001 to ADR-0010); those depending on a client answer or a spike are marked Proposed. The client can overturn any of them.

| # | Decision | Basis |
|---|---|---|
| D-01 | **Wave-1 candidates: NG (live first), KE, GH, ZA, UG** | Anglophone; FW + Smile ID coverage; SOS partners (REPORT §2) |
| D-02 | **Hold model: collect to the gateway merchant balance → hold in our ledger → release via Transfers.** No dependency on gateway escrow (v2-only) | REPORT §3.1 |
| D-03 | **Flutterwave fee bearer = merchant**; the gateway fee is allocated to the provider in the ledger | FW default is customer-bears |
| D-04 | Build the payment adapter on **Flutterwave v3**; v4 waits until GA | v4 is public beta |
| D-05 | **Smile ID primary** for KYC, with the Flutter SDK version (v11 vs v12) chosen by S-05; Youverify/Dojah as NG server-side fallback | REPORT §4 |
| D-06 | **Model IDs live in remote config** behind the LLM gateway; routing chosen by evals, not tier names | Model churn; promo expiry 31 Dec 2026 |
| D-07 | **No pgsodium.** Vault + application-level envelope encryption with blind indexes | pgsodium pending deprecation |
| D-08 | **Supabase region: London `eu-west-2` provisional**, confirmed by S-01 | No Africa region |
| D-09 | Location: Realtime Broadcast for live pings; sparse DB heartbeat for matching; sampled trail per job | Cost model + spec |
| D-10 | Avoid `flutterwave_standard`, `app_device_integrity`, `background_locator_2` and `prembly_identity_kyc`; use hosted checkout links and thin native channels | Package due diligence |

## 3. Open decisions (client)

> Canonical register: [docs/OPEN-DECISIONS.md](../OPEN-DECISIONS.md). Update that file when an answer arrives; this checkpoint is a snapshot.

The spec defaults stay configurable and are implemented as stated until the client resolves them.

| ID | Topic | Current default | Status |
|---|---|---|---|
| OD-01 | Who funds the 2.5% referral | Platform, from its 12.5% | Open (spec) |
| OD-02 | Referral duration | Lifetime with admin cap per country/campaign | Open (spec) |
| OD-03 | Both sides referred | Each referrer 2.5% (max 5% of net) | Open (spec) |
| OD-04 | Shopping item float | Separate non-commissionable float; receipt-approved; fees to customer | Open (spec) |
| OD-05 | Insurance | No insurer at launch; claims workflow + hooks | Open (spec). Note Chowdeck's rider cover precedent |
| OD-06 | Commission rate | 12.5%, per-country configurable | Open (spec) |
| OD-07 | Launch-day countries | Nigeria first | Open (spec); research supports it |
| OD-08 | Gateway fee on refunds | Platform absorbs fault-free; deducted for late customer cancellations | Open (spec) |

**New decisions proposed by this research:**

| ID | Topic | Proposed default |
|---|---|---|
| **OD-09** | Police-clearance recency and renewal | Accept if issued ≤ 6 months ago; re-verify every 12 months; per-country override |
| **OD-10** | Who pays payout transfer fees | Provider, shown in the withdrawal preview |
| **OD-11** | Role of Stripe | Africa: Flutterwave + Paystack (Stripe-owned). Stripe Connect only for markets with a US/UK/EEA/CA/CH entity |
| **OD-12** | Operating entity and funds-holding model per country | Merchant balance + collection-agent terms; ZA TPPP registration; counsel sign-off |
| **OD-13** | Ongoing selfie-check frequency | On-device daily; vendor check weekly + on risk triggers |
| **OD-14** | Wave-1 countries | NG live; KE, GH, ZA, UG beta |
| **OD-15** | Hosting and residency | Supabase EU + vendor-side biometrics; costed African self-host fallback |
| **OD-16** | Swahili / Luganda | English-only in KE/UG at launch; Swahili in V1.2 |
| **OD-17** | Pidgin voice | Ship only if it passes the S-08 gate; otherwise Pidgin text + English voice |
| **OD-18** | Tax on referral payouts | Per-country withholding support; tax-counsel ruling |

## 4. Top risks

Full list in [risk-register.md](risk-register.md).

| ID | Risk | Score |
|---|---|---|
| R-03 | Pidgin voice quality — `pcm` isn't on the Gemini Live language list | 16 |
| R-04 | KYC and daily selfie-check cost (~15% of revenue at 1M MAU if vendor-daily) | 16 |
| R-05 | Off-platform cash leakage under a no-cash rule | 16 |
| R-01 | Regulatory position on holding customer funds per country | 15 |
| R-02 | Stripe unable to pay African providers | 15 |
| R-06 | Africa → EU latency against the 300 ms RPC target | 15 |
| R-07 | Data-residency rules (KE, GH bill) with no Supabase Africa region | 15 |
| R-12 | Offer-acceptance race conditions | 15 |

## 5. Next steps

**Claude Code:**
1. Run the P0 spikes (S-01, S-02, S-03 with Kimi, S-04 with Kimi, S-05 with Kimi, S-12). They don't depend on Kimi's hand-off. Spike code stays on `spike/*` branches, outside `apps/`.
2. When Kimi reaches M8.5, start **Phase 1**: review `contracts/draft/ui-data-requirements.md` and the UI, publish contracts v1, and write the UI change list, ERD, state machines, threat model and ADRs (including D-01…D-10).
3. Include these Phase 0 findings in the UI change list:
   - "held by Suskii", never "escrow";
   - hosted checkout instead of `flutterwave_standard`;
   - Contact Picker for trusted contacts;
   - precise-location and FGS declaration flows;
   - server-provided payout estimates only.

**Client:**
1. Decide OD-11, OD-12, OD-13 and OD-09 first; they change Phase 1 contracts.
2. Engage counsel in NG, KE, GH, ZA and UG (scope: [compliance checklist §2](compliance-checklist-and-dpia.md#2-registrations-and-authorisations-per-country)).
3. Start the **Nigerian sender-ID and DND whitelisting** (weeks of lead time).
4. Open sales conversations: Smile ID (volume + auth pricing), Flutterwave and Paystack (merchant accounts, KYB), Infobip / Africa's Talking (number masking), AURA / Rescue.co / a Nigerian SOS partner, LiveKit (Cloud plan + African edges).

**Kimi Code (for awareness):**
- Nothing blocks the current mock-first build.
- Please avoid the packages flagged in D-10.
- Keep all money, fee and status values coming from server-style quote objects (spec).

## 6. HANDOFF.md entry

Kimi Code created `HANDOFF.md` during M1. A fuller version of this entry was added at the top of it on 2026-09-16 (newest-first). The short copy below stays here in case the shared file is rewritten:

> **[2026-09-15] Claude Code — Phase 0 (Deep Research) complete, run in parallel with Kimi M1.**
> - Delivered `docs/research/` (REPORT, vendor matrix, country packs NG/KE/GH/ZA/UG, compliance + DPIA outline, risk register, cost model, spike plan, checkpoint).
> - Key findings:
>   - Stripe can't pay African providers → Paystack as second rail (OD-11).
>   - No Supabase Africa region (London provisional).
>   - Gemini Live doesn't list Pidgin (OD-17).
>   - Flutterwave escrow is v2-only → hold in ledger + Transfers.
>   - Daily vendor selfie checks too costly (OD-13).
> - For Kimi:
>   - don't use `flutterwave_standard`, `app_device_integrity`, `background_locator_2`, `prembly_identity_kyc`;
>   - never label held funds "escrow";
>   - use the Contact Picker for trusted contacts;
>   - `flutter_background_geolocation` needs a paid licence (pending S-04).
> - Open decisions OD-01…OD-18 are listed in `docs/research/CHECKPOINT-PHASE-0.md`.
> - Next: spikes S-01/02/03/04/05/12, then Phase 1 on Kimi's M8.5 hand-off.
