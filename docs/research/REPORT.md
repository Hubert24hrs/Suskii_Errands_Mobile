# Suskii Errands — Phase 0 Deep Research Report

| | |
|---|---|
| Author | Claude Code (backend agent) |
| Date | 2026-09-15 |
| Spec | `docs/spec/SUSKII_BUILD_PROMPT.json` v3.1.0 |
| Phase | 0 — Deep Research (documents only, no application code) |
| Companion files | [vendor-decision-matrix.md](vendor-decision-matrix.md) · [country-packs/](country-packs/) · [compliance-checklist-and-dpia.md](compliance-checklist-and-dpia.md) · [risk-register.md](risk-register.md) · [cost-model.md](cost-model.md) · [spike-plan.md](spike-plan.md) · [CHECKPOINT-PHASE-0.md](CHECKPOINT-PHASE-0.md) |

## Evidence legend

Every material claim carries a tag. Nothing tagged `[A]` may be implemented as fact; it becomes a spike, a vendor question or a counsel question.

| Tag | Meaning |
|---|---|
| **[V]** | Verified this session against an official/primary source (vendor docs, pricing page, regulator, official registry API). |
| **[S]** | Secondary source (press, law-firm briefing, analyst blog). Directionally reliable; confirm before contracts or code. |
| **[A]** | Assumption or background knowledge, not re-verified this session. Must be confirmed in the listed spike or with the vendor/counsel. |

Source IDs like `[P3]` point to the [Sources](#sources) list at the end.

---

## 0. Executive summary — findings that change the plan

These are the findings that contradict or materially sharpen `master_spec`. Each is carried into the risk register and the Phase 0 checkpoint.

1. **Stripe cannot pay African providers.** Stripe Connect cross-border payouts only work between platforms and connected accounts in the US, UK, EEA, Canada and Switzerland; there is no self-serve payout to African countries. Global Payouts requires a US or UK platform and puts licensing on the platform [V][P5][P6]. Stripe's own African presence is Paystack's "extended network" in Nigeria, Kenya, Ghana, South Africa and Côte d'Ivoire [V][P7]. **Implication:** the "Flutterwave and Stripe" decision should become *Flutterwave (primary) + Paystack (Stripe-owned, secondary) for Africa; Stripe Connect only for markets where a Suskii entity is based in US/UK/EEA/CA/CH*. Proposed as **OD-11**.
2. **Supabase has no African region.** Available regions are in the Americas, Europe and APAC; Cape Town (`afs1`) is not offered for new projects [V][P1][P2]. All candidate-country users will cross a submarine cable for every RPC. The 300 ms RPC p95 target is feasible only if each user action is one round trip. The region choice (London vs Paris vs Frankfurt) must be decided by a latency spike (S-01). Kenyan and draft Ghanaian data-localisation rules become a real constraint (item 7).
3. **Flutterwave "escrow" is a legacy v2 feature.** Escrow payments (`/transactions/escrow/settle`) appear only in the v2 docs [V][P9]; v3 is the GA API and v4 is in public beta [S][P10]. **Implication:** design the hold as *collect to the platform's merchant balance → release through the Transfers API after confirmation*, never depend on gateway escrow, and never say "escrow" in UI copy (the spec already requires this). Nigerian law has no escrow licence; only licensed entities (e.g. MMOs) may hold customer funds, and others hold them through bank partnerships [S][P40]. South Africa requires TPPP registration with PASA through a sponsoring bank when collecting on behalf of others [V][P41]. Proposed as **OD-12** (operating entity and licensing model per country).
4. **Gemini Live does not list Nigerian Pidgin (or Igbo) as a supported language.** The Live API lists 97 languages including Yoruba, Hausa and Swahili, but not `pcm` or Igbo [V][P16]. The English + Pidgin voice concierge is therefore an **evaluation risk**, not a configuration setting. The fallback cascade STT → Gemini text → TTS must be designed in from day one (spike S-08). Proposed as **OD-17**.
5. **Gemini model names moved on.** Current GA IDs include `gemini-3.8-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`, and `gemini-3.8-live` (the default Live model). The Pro flagship is `gemini-3.1-pro-preview` on the Gemini API and is listed as GA on Vertex [V][P13][P14]. Gemini 3.5 Pro has not shipped [S][P15]. The 3.7/3.8 Flash prices are promotional **until 31 Dec 2026** [V][P17]. **Implication:** model IDs live in remote config behind the LLM gateway; routing is chosen by eval results, not by tier name.
6. **The daily provider selfie check is the biggest avoidable running cost.** At 1M MAU, a vendor-side SmartSelfie authentication every online day costs about **$200k/month (~15% of platform revenue)** at an assumed $0.10/check [A]. Onboarding KYC for every customer is the largest *unavoidable* cost (~$87k/month at 1M MAU) [A]. See [cost-model.md](cost-model.md). Proposed as **OD-13**: on-device liveness daily, with a vendor 1:1 check weekly and on risk triggers.
7. **Data-residency constraints.** Kenya requires a DPIA for high-risk transfers and has local-storage expectations for some processing [S][P44]. Ghana's Data Protection Bill 2025 (not yet passed as of March 2026) proposes mandatory localisation of biometric data [S][P45]. Nigeria's GAID 2025 took effect on 19 Sep 2025 (NDPC registration tiers, 72 h breach notice) [S][P42]. POPIA needs prior authorisation for some processing of criminal-behaviour information and unique identifiers [S][P46]. With no Supabase Africa region, **biometric templates must stay vendor-side** (the spec already prefers this) and a self-hosted African-region fallback must be costed. Proposed as **OD-15**.
8. **Market timing is favourable, and off-platform leakage is the threat.** Uber left Nigeria and Uganda on 2 Sep 2026 (Tanzania in Jan/Feb 2026, Côte d'Ivoire in 2025), citing economics; drivers blame 25–30% commissions [S][P30]. inDrive (~10% take rate, negotiation) and Bolt (15–25%) absorb the demand [S][P30][P32]. Nigerian drivers are taking cash "offline trips" to escape fees [S][P31]. Suskii's 12.5% take rate is competitive. The no-cash rule makes **anti-leakage** (moderation, incentives, safety value, cancellation-abuse detection) a core product requirement.
9. **Kenya's 18% ride-hailing commission cap was suspended** by the High Court on 3 Sep 2026, along with the NTSA three-year data-sharing rule; government has 12 months to rework it [S][P33]. Commission rates must stay per-country config with an audit trail. The spec already does this.
10. **Store-policy deadlines that land during the build:** Google Play's precise-location declaration (available Nov 2026, enforced **27 Jan 2027**) and the location-button requirement for transactional precise location on Android 17+ [V][P53]. Also the FGS-type declarations with demo videos and the full-screen-intent declaration (default grant only for calling/alarm apps) [V][P51][P52]. Apple still terminates apps that don't report VoIP pushes to CallKit [S][P55].
11. **Client-side package traps:**
    - `flutter_background_geolocation` needs a **paid licence for release builds** [V][P60].
    - `flutterwave_standard` has no verified publisher and was last released in April 2025 [V][P60].
    - Smile ID shipped a new **v12 Flutter SDK (`usesmileid`)** with on-device ML in Sep 2026, alongside the older v11 `smile_id` [V][P60].
    - Twilio Proxy is closed to new customers [S][P25].

---

## 1. Competitor teardown

Scope from the spec: inDrive, Bolt, Uber, Glovo, Chowdeck, Gokada, SafeBoda, Yango, TaskRabbit, Thumbtack, Urban Company. Focus: negotiation UX, trust and safety, onboarding, pricing, referrals.

| Player | Model | Take rate / pricing | Negotiation | Trust & safety | African status (Sep 2026) | Lesson for Suskii |
|---|---|---|---|---|---|---|
| **inDrive** | Rides, couriers, "Services" (handymen, since 2024), freight | ~10% globally; ~6% stated for Africa; promotional zero-commission launches [S][P30][P34] | Customer proposes a fare; drivers accept, counter or decline; customer picks from offers | ID checks, SOS, trip share | 48 countries / 888 cities [S][P35]; SA, KE, TZ, GH, NG and others; gaining from Uber's exit | The closest analogue. Copy the offer board and fast counters; beat it on verification depth, PIN proof and paid-upfront protection |
| **Bolt** | Rides, (Food exited NG) | NG 15–25% driver commission; KE 18% + 16% VAT [S][P32][P31] | None; algorithmic price | SOS with Namola (ZA → SAPS), Red Cross first-aid training (NG) [S][P37] | Market leader in NG/KE/ZA | Commission anger drives leakage; safety partnerships are table stakes |
| **Uber** | Rides; acquiring Delivery Hero (Glovo, Talabat) for €14.8bn (Jul 2026) [S][P36] | 25–30% in NG/UG [S][P30] | None | AURA emergency button (ZA, GH) [S][P37] | Exited NG and UG (2 Sep 2026), TZ, CI; remains in EG, GH, KE, ZA [S][P30][P36] | High take rates are unsustainable in naira/shilling economies; AURA is proven as an SOS partner |
| **Glovo** | Quick commerce / food | 20–30% restaurant commission (typical) [S] | None | Courier ID | KE, NG, MA, CI, TN, UG → moving to Uber [S][P36] | Consolidation means incumbents may retreat from low-margin cities |
| **Chowdeck** | Food and market delivery (NG) | ~24% blended take rate [S][P38] | None | Rider accident insurance via MyCoverGenius (Mar 2026) [S][P38] | ~20k riders; fast-growing | Insurance for riders is a trust signal; relevant to OD-05 |
| **Gokada** | Lagos logistics (pivoted from okada rides after the Lagos ban) | — | — | — | No 2026 data found [A] | Zone-based vehicle bans (Lagos okada/keke) shape supply; our `zone_rules` design is right |
| **SafeBoda** | UG super-app (boda rides, delivery, payments) | — | None | Rider training, helmets | Exited KE and NG; strong in UG [S][P36] | Boda/tricycle supply dominates East African errands |
| **Yango** | Rides, delivery, super-app | — | None | — | CI, SN, CM, ZM, DRC, NA, BW, MZ, AO; $150M push into 10 new African markets in 2026 [S][P39] | A well-funded new entrant in Francophone/Southern Africa; relevant if we expand there |
| **TaskRabbit** | Tasks (US/EU) | Client pays ~15% service fee plus a trust & support fee; Taskers set rates [S][P47] | Rate set by provider | Background checks, Happiness Pledge | Not in Africa | Showing a transparent trust fee to the customer is accepted |
| **Thumbtack** | Lead marketplace (US) | Pros pay per lead ($15–80 typical) [S][P48] | Quote-based | Reviews, background checks | Not in Africa | Pay-per-lead would clash with our no-off-platform rule; avoid |
| **Urban Company** | Managed home services (IN, UAE, SG) | 20–30% commission [S][P49] | Fixed menu pricing | Training, standardised kits, insurance | Not in Africa | Credentialled trades (plumbing, electrical) need certification and quality programs, not just negotiation |

### UX patterns to adopt (to Kimi via the Phase 1 UI change list)

- **Offer board:** live cards sorted by the server score; one-tap counter with server-provided increments; an expiry countdown per offer; "AI compare" is advisory.
- **Price anchoring:** show the server P25–P75 band next to the customer's price input. inDrive riders often under-bid, and a band cuts dead requests.
- **Paid-upfront messaging:** "Your payment is held by Suskii until you confirm." Say "held", never "escrow" (spec money rule).
- **Leakage deterrents:** on-platform-only protections are made visible (SOS, dispute cover, PIN proof). Chat moderation flags phone numbers and account numbers (the spec already includes this).

### Referral programs observed

Ride-hailing referrals in Africa are mostly one-time bonuses. A **lifetime 2.5% cash commission** is unusual and generous, and it attracts fraud rings. The spec's single-level rule, device/face/payout de-duplication and hold periods are essential. Keep OD-02's cap configurable.

---

## 2. Market analysis — first five candidate countries

**Recommended wave-1 candidates:** Nigeria (reference pack, OD-07), Kenya, Ghana, South Africa and Uganda. They are Anglophone (fit the English launch language), covered by Flutterwave collections and payouts [V][P8][P11], covered by Smile ID government-ID lookup [S][P19], and have an SOS partner option (AURA in ZA/KE/GH; Rescue.co in KE/UG) [S][P26][P27]. Egypt, Côte d'Ivoire, Rwanda and Tanzania are next-wave candidates (see §2.2).

| | Nigeria | Kenya | Ghana | South Africa | Uganda |
|---|---|---|---|---|---|
| Currency (ISO exponent) | NGN (2) | KES (2) | GHS (2) | ZAR (2) | **UGX (0)** |
| FX, mid-Sep 2026 | ~₦1,326/USD official; ₦1,385–1,410 parallel [S][P62] | ~KSh 129.4/USD; CPI 6.6% (Aug) [S][P62] | ~GH₵11.5–12.2/USD [S][P62] | — | — |
| Account ownership (Findex 2025) | ~63% (up from 45% in 2021) [S][P61] | ~90% [S][P61] | ~81% [S][P61] | ~81% [S][P61] | growing, mobile-money-led [S][P61] |
| Dominant payment habits | Bank transfer (NIP), cards, USSD, OPay/Moniepoint wallets; no single dominant rail [S][P63] | M-Pesa | Mobile money (MTN, Telecel, AirtelTigo), cards | Cards, EFT / instant EFT | Mobile money (MTN, Airtel) |
| Flutterwave local collection fee | 2.0% all local methods (from 11 Apr 2025) + 7.5% VAT on fees [V][P11] | Cards 3.2%, M-Pesa 2.9% [V][P11] | Cards 2.6%, momo/bank 2% [V][P11] | Cards 2.9% + R1, EFT 2.5% [V][P11] | Cards 4.8%, momo 3% [V][P11] |
| VAT (standard) | 7.5% (unchanged in NTA 2025) [S][P58] | 16% [S][P32] | 20% effective (15% + NHIL 2.5% + GETFund 2.5%) from 1 Jan 2026 [S][P59] | 15% (planned rise reversed) [S][P57] | 18% [A] |
| Ride/delivery competition | Bolt, inDrive, Rida, LagRide; Uber gone [S][P30] | Bolt, Uber, inDrive, Glovo | Bolt, Uber, Yango? [A] | Bolt, Uber, inDrive | SafeBoda, Bolt, inDrive, Faras, Yango; Uber gone [S][P36] |
| Handset reality | Transsion (Tecno/Infinix/itel) ~51% of NG market [S][P64] | Transsion ~47–48% of the African market overall; Samsung second [S][P64] | ← | ← | ← |
| Trust barriers | Fraud fears; "offline" cash trips [S][P31]; security incidents on rides | Commission disputes; regulatory churn [S][P33] | — | Violent-crime concerns → strong SOS demand (AURA scale) [S][P26] | Boda safety |
| Language at launch | English + Pidgin ✔ | English ✔ (Swahili gap) | English ✔ (Twi later) | English ✔ | English ✔ (Luganda/Swahili gap) |

**Demand and pricing norms [A]:** errand and delivery tickets in Lagos and Nairobi typically fall in the USD 2–15 equivalent range, and moving/trades in USD 15–100. The cost model uses a USD 8 blended AOV. Validate with Kimi's mock fixtures and early pilot data. Price guardrails and urgency multipliers stay per-city config.

### 2.1 Why Nigeria first (confirming OD-07)

Largest population and the Pidgin launch language. Uber's exit leaves a gap. Both Flutterwave and Paystack are strongest here, and Smile ID has the deepest ID coverage (NIN, BVN, voter ID, bank account) [S][P19].

Risks:
- Naira volatility, which argues for integer minor units and short quote validity.
- Police clearance costs **₦30,000** and is valid for about 3 months [S][P21], a real barrier for low-income providers (see OD-09).
- DND/sender-ID bureaucracy for OTP [S][P24].

### 2.2 Next-wave notes

| Country | Why it's attractive | What's missing |
|---|---|---|
| **Côte d'Ivoire** | Flutterwave momo (MTN, Orange, Moov, Wave) [V][P8]; Paystack extended network [V][P7] | French |
| **Egypt** | Large market; Uber and Talabat present | Arabic RTL; not in Stripe's extended network [V][P7]; Flutterwave coverage to verify |
| **Rwanda** | Flutterwave momo [V][P8]; Stripe Global Payouts bank support added Jan 2026 [V][P6] | Small market |
| **Tanzania** | Flutterwave momo [V][P8] | Swahili; Uber exited |

---

## 3. Payments

### 3.1 Flutterwave

| Topic | Finding |
|---|---|
| API generations | v3 is the documented GA API; v4 is in **public beta** (OAuth 2.0, dedicated sandbox, "orchestrator" charge and transfer flows) [S][P10]. **Recommendation:** build the `PaymentProvider` adapter on v3 with a v4 migration path; keep v4 out of launch until GA. |
| Hold mechanism | Escrow is documented only in v2 (`/transactions/escrow/settle`, `/v2/gpx/transactions/escrow/refund`) [V][P9]. The v3 settlement docs cover settlement to a bank or F4B wallet balance, 1–5 business-day schedules and minimum-threshold batching [V][P12]. **Design:** collect to the merchant balance and hold in our ledger (`held_funds`). On `SETTLED`, pay the provider via the Transfers API. Refunds go through the refunds API. Split/subaccounts are optional and don't give us conditional release. |
| Who pays fees by default | **The customer bears charges by default**; merchants change this in the dashboard (Business Preferences → Fee Settings) [V][P11]. **Must set "merchant bears"** so the customer pays exactly the agreed amount. The gateway fee is then allocated to the provider in the ledger (spec: gateway fees borne by provider). Exception: OD-04 item float, where the fee is passed to the customer. |
| Local collection fees (ex-VAT) | NG 2.0% all local NGN methods (1.4% + 0.6% platform fee since 11 Apr 2025), international cards 4.8%, VAT 7.5% on fees, stamp duty ₦50 above ₦10k. KE cards 3.2%, momo 2.9%. GH cards 2.6%, momo 2%. ZA cards 2.9% + R1, EFT 2.5%. UG cards 4.8%, momo 3%. RW cards 4.8%, momo 3.5% [V][P11] |
| Payout (transfer) fees | NG ₦10 / ₦25 / ₦50 (≤5k / ≤50k / >50k). KE KSh 100 bank or M-Pesa. GH bank GH₵10, momo 1.5%. UG bank USh 5,000, momo USh 1,000 (<125k) or 1.2%. ZA bank R10 (no momo). CI momo 2%, bank XOF 1,500 [V][P11] |
| Mobile-money payout networks | CM (MTN, Orange), CI (MTN, Orange, Moov, Wave), ET, GH (MTN, AirtelTigo, Telecel), KE (M-Pesa), RW (MTN), SN (Orange, Wave), TZ (Airtel, Halopesa, Tigo, Vodacom), UG (MTN, Airtel), ZM [V][P8]. M-Pesa payouts require the sender's name, country and mobile number in `meta`; amounts must be integers; transfers start as `NEW` and resolve by webhook or poll [V][P8] |

**Webhooks:** the adapter must verify signatures, store the raw event, de-duplicate on the event ID, and call the verify endpoint before any ledger movement (spec rule). Transfers can complete asynchronously hours later. Model payouts as a state machine: `REQUESTED → SUBMITTED → PENDING → SUCCEEDED | FAILED | REVERSED`.

### 3.2 Paystack (Stripe-owned) — recommended secondary African rail

- Present in NG, GH, KE, ZA and CI as Stripe's "extended network" [V][P7].
- **Nigeria local card pricing: 1.5% + ₦100, capped at ₦2,000, flat fee waived at ≤₦2,500** [S][P42b]. That is cheaper than Flutterwave's uncapped 2% for tickets above roughly ₦100k.
- A ₦50 stamp duty applies to transfers of ≥₦10,000 (from 18 Feb 2026) [S][P42b].
- Split payments need subaccounts in the **same country and currency** as the Paystack business [V][P43].
- Routing policy (country pack): route by method and amount band. Failover between Flutterwave and Paystack on outage.

### 3.3 Stripe

- **Connect cross-border payouts:** only platforms and connected accounts in US/UK/EEA/CA/CH; no self-serve beyond that. Supported flows are separate charges and transfers without `on_behalf_of`, top-ups, and destination charges without OBO. Not available for recipient service agreements [V][P5].
- **Global Payouts:** platform must be in the US or UK; 160+ countries; recipients need no Stripe account; the platform handles its own licensing if it is in the flow of funds [V][P6]. The Jan 2026 changelog added bank payouts to Rwanda, Gambia and Madagascar among 15 countries [V][P6b].
- **Conclusion:** Stripe applies only when Suskii has (a) a US/UK/EEA/CA/CH operating entity and (b) providers in those regions, i.e. the "global next" phase. Keep the adapter interface; don't build Stripe Connect for launch unless the client names a non-African launch market. **OD-11.**

### 3.4 Legal position on holding customer funds (counsel required per country)

| Country | Finding | Tag |
|---|---|---|
| Nigeria | No specific escrow licence. Only licensed entities (e.g. MMOs) may hold customer funds; others run escrow through bank partnerships in dedicated accounts. PSP-framework capital requirements apply to licensed models | [S][P40] |
| South Africa | Collecting or paying on behalf of third parties requires **TPPP registration with PASA via a sponsoring bank** (SARB Directive 1 of 2007); no PASA fee | [V][P41] |
| Kenya | National Payment System Act / CBK authorisation for holding funds of others | [A] |
| Ghana | Payment Systems and Services Act 2019 (Act 987), Bank of Ghana | [A] |
| Uganda | National Payment Systems Act 2020, Bank of Uganda | [A] |

**Recommendation:** at launch, rely on the licensed gateway's merchant balance plus contractual "commercial agent" terms (provider appoints Suskii as limited payment-collection agent). This is common marketplace practice, but counsel must confirm it per country. Budget for a ZA TPPP registration. **OD-12.**

### 3.5 Tax touchpoints for money flows

| Country | Finding | Tag |
|---|---|---|
| Nigeria | Nigeria Tax Act 2025 in force 1 Jan 2026. VAT stays 7.5%; digital platforms may be appointed VAT collection agents [S][P58]. WHT Regulations 2024 (in force 1 Jan 2025): brokerage 5% resident; small-company exemption (≤₦25m turnover) [S][P58b]. Whether WHT applies to referral commissions paid to individuals is a **tax-counsel question** | [S] |
| Kenya | Finance Act 2023 introduced 15% WHT on digital content monetisation. The Finance Bill 2024 proposed **5% (resident) / 20% (non-resident) WHT on digital marketplace payments** and replacing DST with a Significant Economic Presence Tax. Enacted status must be confirmed | [S][P56] |
| Ghana | VAT Act 2025 (Act 1151): effective 20% from 1 Jan 2026; COVID levy repealed | [S][P59] |
| South Africa | 2026 Budget proposes shifting VAT liability for electronic services supplied through platforms to the platform operator by default | [S][P57] |

→ Referral income is likely taxable. The ledger must support per-country withholding lines and annual earnings statements (spec `tax_note`).

---

## 4. KYC / identity verification

| Topic | Finding |
|---|---|
| Smile ID coverage | Government-authority-backed verification in CI, GH, KE, NG, ZA, UG, ZM and ZW; Nigeria supports bank account, BVN, NIN v2, NIN slip and voter's ID; 8,500+ document types across 226 countries for document verification [S][P19] (docs site blocks automated fetch; confirm the ID-type matrix with Smile ID) |
| Liveness certification | Enhanced SmartSelfie passed a **Fime** ISO/IEC 30107-3 **Level 2** PAD evaluation (Jan 2025), 0% false accept in that test [S][P20]. This is Fime, not iBeta; ask Smile ID for the confirmation letter |
| Duplicate faces | "Smile Secure" 1:N search against faces previously enrolled **on our own partner account** [S][P20b]. It meets the spec's de-duplication and re-registration-ban need. It does not search other companies' users |
| Flutter SDKs | `smile_id` 11.2.13 (10 Sep 2026, MIT, verified publisher, Android/iOS only, iOS 13+) and a **new v12 `usesmileid` 12.1.1 (8 Sep 2026)** with on-device ML face/document modules (ML Kit, Vision, Huawei variants) [V][P60]. **v12 is days old** → spike S-05 on 2 GB devices decides the version |
| Web SDK | `@smileid/web-sdk` 12.0.4 (15 Sep 2026) and `@smileid/web-components` 11.6.2; the older `@smile_identity/smart-camera-web` is superseded [V][P60]. Server submission via `smile-identity-core` 3.2.1 [V][P60]. Web customer facial verification is feasible (spec asked to VERIFY) |
| Pricing | Not public; sales-quoted. Commitment plans recommended above 5k verifications/month; industry estimate USD 0.50–2.00 per onboarding [S][P20c]. **Get a quote that covers SmartSelfie authentication (re-checks), since daily checks dominate cost** |
| Alternatives (NG-heavy) | Dojah (`dojah_kyc_sdk_flutter` 0.1.17: 2 likes, ~440 downloads/30 days, so thin adoption), Prembly (`prembly_identity_kyc` 0.0.6, tagged web-only, 32 downloads/30 days), Youverify, QoreID (100M+ Nigerian records) [V][P60][S][P20d]. Treat them as **server-API fallbacks** for NIN/BVN lookup, not SDK replacements |
| Global | Onfido/Entrust, Veriff (iBeta Level 2) [S], Persona. Evaluate in the global phase |

**Recommendation:**
- Smile ID primary behind `IdentityVerificationProvider`, with Youverify or Dojah as a server-side NIN/BVN fallback for Nigeria.
- Store only job IDs, result codes and reference IDs; keep biometric templates vendor-side (spec).
- Contract must include DPA terms, sub-processor list, data location, retention/deletion SLAs, PAD letters and Smile Secure scope.

---

## 5. Police clearance per candidate country

| Country | Document / issuer | How obtained | Validity | Verification channel | Tag |
|---|---|---|---|---|---|
| Nigeria | **Police Character Certificate**, Nigeria Police Force via **POSSAP** (possap.gov.ng) | Online application + biometric capture; ₦30,000 (diaspora ~$75); 3–7 working days after biometrics | 3 months from issue | QR validation code and digital registrar stamp; third-party online verification not documented | [S][P21] |
| Kenya | **Certificate of Good Conduct / Police Clearance Certificate**, Directorate of Criminal Investigations (DCI) | dci.ecitizen.go.ke; fingerprints at Huduma Centres or DCI HQ; PDF download | No statutory expiry; employers typically accept 3–6 months | **Online verify at dci.ecitizen.go.ke/verify**; SMS "DCI" to 21546, then *512#; QR on certificate | [V][P22] / [S] |
| Ghana | **Police Clearance Certificate/Report**, CID Criminal Data Services Bureau | eservices.police.gov.gh; fee via Ghana.Gov; ~10 working days | Not published | None found; Verification Officer review | [S][P23] |
| South Africa | **SAPS Police Clearance Certificate**, Criminal Record Centre (CRC) | Fingerprints in person (no fully online route); 7–21 working days | No formal validity; <6 months commonly required | None online; apostille for foreign use; Verification Officer review. Accredited background-check bureaus may offer vendor verification [A] | [S][P23b] |
| Uganda | **Certificate of Good Conduct**, Interpol NCB Kampala (Directorate of Interpol & International Relations) | service.upf.go.ug + fingerprint appointment; 5–14 working days | 6 months | None found; Verification Officer review | [S][P23c] |

**Implications:**
- Only Kenya offers a public online verification channel. In all other countries the workflow is document upload → OCR → **Verification Officer check** (spec fallback path). Store the certificate number encrypted, plus issue date, expiry and reviewer ID.
- Short validities (NG 3 months, UG 6 months) conflict with "block job acceptance on expiry": Nigerian providers would pay ₦30,000 four times a year. **Proposed OD-09:** accept certificates issued within N months at onboarding (default 6) and require renewal every 12 months, configurable per country. Expiry reminders at 30/14/3 days stay.
- In South Africa, POPIA treats criminal-behaviour information as special personal information; prior authorisation may be required (see §11). Counsel must approve before the ZA pack goes live.

---

## 6. Voice: in-app calls, AI voice concierge, PSTN fallback

### 6.1 LiveKit Cloud

| Topic | Finding |
|---|---|
| Pricing | Build (free): 5k WebRTC participant-min, 1k agent-min. **Ship $50/mo:** 150k participant-min, 5k agent-min. **Scale $500/mo:** 1.5M participant-min, 50k agent-min. Overage ≈ $0.0004–0.0005 per participant-min and $0.01 per agent session-min [S][P24b]. livekit.com was unreachable from our fetcher; confirm on the pricing page before contracting |
| Regions | Region pinning and an EU data-residency option are documented [V][P24c]. **African edge PoPs not confirmed** → spike S-01 measures RTT and jitter from Lagos, Nairobi and Johannesburg |
| Flutter SDK | `livekit_client` 2.13.0 (15 Sep 2026, Apache-2.0, verified publisher, 150 points, all platforms, certificate pinning for WSS/HTTPS) [V][P60] |
| Web SDK | `livekit-client` 2.22.3, `@livekit/components-react` 2.9.24; server `livekit-server-sdk` 2.19.0 [V][P60] |
| Native incoming-call UI | `flutter_callkit_incoming` 3.1.5 (Aug 2026, MIT, 160 points, PushKit support, Android 14 FSI permission flow) [V][P60] |

### 6.2 AI voice concierge (LiveKit Agents + Gemini)

- The LiveKit Google plugin supports the Gemini Live API through Vertex (`GOOGLE_APPLICATION_CREDENTIALS`) or an API key [V][P18].
- The docs name `gemini-2.5-flash-native-audio-preview-12-2025` (default) and `gemini-3.1-flash-live-preview`.
- Known limits on 3.1 [V][P18]:
  - no affective dialog or proactive audio;
  - **no async function calling** (the model waits for tool results);
  - half-cascade (Gemini text + separate TTS) works only with non-native-audio models.
- Package versions: `livekit-agents` 1.8.2 / `livekit-plugins-google` 1.8.2 (PyPI); `@livekit/agents-plugin-google` 1.9.0 (npm) [V][P60].
- Gemini API side: `gemini-3.8-live` is the default Live model and supports **non-blocking (async) function calling**. Audio-only sessions are limited to 15 min (extendable via session management); context is 128k for native-audio models [V][P16]. Whether the LiveKit plugin passes `gemini-3.8-live` through cleanly is part of spike S-08.
- **Languages:** Pidgin (`pcm`) and Igbo are **not** on the Live API list; Yoruba, Hausa and Swahili are [V][P16]. A secondary source claims Gemini "supports" Pidgin generally [S][P16b]; treat that as unproven for speech.
- **Plan:** English via Gemini Live native audio. Pidgin through an evaluation gate, with a cascade fallback: `gemini-3.5-transcribe` or Chirp 3 STT → Gemini Flash text → `gemini-3.1-flash-tts-preview` or Chirp 3 HD voices. If Pidgin speech quality fails the gate, launch Pidgin in **text** concierge and English in voice (OD-17).
- **Costs (Gemini API list):** 3.8 Live audio in ~$0.005/min, audio out ~$0.018/min; 3.5 Transcribe ~$0.003/min in [V][P17].

### 6.3 PSTN masked-number fallback

| Option | Finding | Tag |
|---|---|---|
| Africa's Talking | Voice API in KE, GH, NG, RW, ZA, UG, TZ and ZM; call transfer/bridging; KE voice number KSh 5,000 setup + KSh 2,000/month (rate card 17 Jul 2026) | [S][P25b] |
| Infobip Number Masking | Purpose-built for ride-share masking (webhook-driven target resolution, masked-call reports); per-country number availability to confirm with sales | [V][P25c] |
| Twilio Proxy | **Closed to new customers**; Twilio points to Programmable Voice/Conversations | [S][P25] |
| LiveKit SIP | Could bridge a LiveKit room to a SIP trunk from a local carrier | [A] |

**Recommendation:** Infobip (NG, KE, GH, ZA coverage to confirm) primary, Africa's Talking secondary, behind a `TelephonyProvider` interface. The server allocates a proxy number for the pair for the job window only.

---

## 7. SMS / OTP

| Topic | Finding |
|---|---|
| Supabase Send SMS Hook | Replaces built-in SMS. HTTP hook (Standard Webhooks signature) or Postgres hook. Payload carries `user` and `sms.otp` (6 digits). Documented use cases: regional provider, WhatsApp channel, provider failover [V][P3]. Timeouts and retry limits are not documented → implement app-level failover inside the Edge Function |
| Nigeria rules | OTP is transactional (24/7). Alphanumeric sender IDs must be registered with all four MNOs; **DND-route whitelisting needs a CAC certificate, address, samples and a website, and takes weeks**. >100M numbers are on DND [S][P24] → **start sender-ID registration in Phase 1** |
| Termii (NG) | Direct Nigerian carrier routes and DND expertise; SMS from ~$0.0107; WhatsApp OTP ~$0.0566 [S][P24d] |
| Africa's Talking | KE, UG, RW, GH, NG and others; Kenya ~KSh 0.80/SMS [S][P24e] |
| Global fallback | Infobip / Twilio Verify [A] |

**Recommendation:**
- Per-country routing in the country pack: NG → Termii (fallback Africa's Talking); KE/UG → Africa's Talking (fallback Infobip); GH/ZA → Africa's Talking or Infobip after a delivery test (spike S-09).
- Add WhatsApp OTP as a user-selectable channel.
- Measure delivery rate and p95 latency per MNO before go-live.

---

## 8. SOS partners

| Market | Partner | Integration | Evidence |
|---|---|---|---|
| South Africa | **AURA** (1M+ MAU; responders in ZA, KE, GH, UK, US; Uber partner) | REST API, SDK components, web dispatch portal, white-label | [S][P26] |
| Kenya | **AURA**; **Rescue.co (Flare)** for medical/ambulance, API for SOS buttons, KE/UG/TZ | API | [S][P26][P27] |
| Ghana | **AURA** (listed market; Uber GH uses the AURA button) | API | [S][P37] |
| Uganda | **Rescue.co (Flare)** | API | [S][P27] |
| Nigeria | No API-first partner confirmed. **Halogen + Emergency Response Africa "SIGNAL"** consumer app; N-Alert API into government response (NISPSAS); LASEMA/112 | Partnership talks; fallback is the ops console + phone bridge to the partner's dispatch | [S][P28] |

**Recommendation:** `SosPartner` adapter per city with an acknowledgement callback, and Suskii ops as the always-on first line. Nigeria at launch: contract Halogen or ERA (or similar) for dispatch-console access, with named escalation phone numbers; build API integration when available. Pricing is unknown (per member, per activation or retainer) → include in RFPs.

---

## 9. Gemini on Vertex AI

| Topic | Finding |
|---|---|
| Branding | Vertex AI docs now sit under **"Gemini Enterprise Agent Platform"** [V][P13] |
| Current models (Gemini API IDs) | GA: `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`, `gemini-2.5-flash(-lite)`, `gemini-2.5-pro`; Live: `gemini-3.8-live`, `gemini-3.8-live-extended-thinking`; transcription: `gemini-3.5-transcribe(-live)`; embeddings: `gemini-embedding-2-preview`, `gemini-embedding-001`. Preview: `gemini-3.1-pro-preview`, `gemini-3.1-flash-live-preview`, `gemini-3.1-flash-tts-preview`. Shut down: `gemini-2.0-flash(-lite)`. At least 2 weeks' notice before deprecations [V][P14] |
| Vertex listing | 3.1 Pro (GA), 3.5–3.8 Flash (GA), 3.5 / 3.1 Flash-Lite (GA), Gemini Embedding 2 (GA), 2.5 Flash Live API (GA) [V][P13]. Vertex model IDs can differ from API IDs → confirm in the S-07 eval harness |
| Prices (per 1M tokens, paid tier) | 3.1 Pro $2 / $12 (≤200k ctx), batch 50% off, cached input $0.20. 3.8 & 3.7 Flash **$0.75 / $3.75 until 31 Dec 2026**. 3.5 Flash $1.50 / $9. 3.5 Flash-Lite $0.30 / $2.50. 3.1 Flash-Lite $0.25 / $1.50. Embedding 2 text $0.20 [V][P17] |
| Region / residency | `africa-south1` (Johannesburg) is a GCP region and appears among ML-service locations [S][P19b]. **Per-model availability in africa-south1 was not confirmed** (the docs page didn't render for our fetcher) → S-07. Vertex keeps customer data in the chosen region for GA generative features [S][P19b] |
| Pidgin | Not officially listed for Live audio (see §6.2). Text understanding is probably decent (English-lexified creole) but unproven → the English/Pidgin golden set in S-07 |

**Routing recommendation (config, not code):**

| Workload | Model tier |
|---|---|
| Concierge | Flash tier by default (3.8 Flash while the promo lasts, then re-evaluate against 3.5 Flash); escalate to 3.1 Pro on tool-plan failure or eval-flagged intents |
| Moderation / classification | 3.1 Flash-Lite |
| Receipts (vision) | Flash |
| Admin assistant | 3.1 Pro with predefined analytics tools on a read replica |
| Embeddings | Embedding 2 once GA on Vertex, else `gemini-embedding-001` |

The spec's "Pro for concierge" becomes "Pro where evals show it's needed". Context caching of the system prompt and tool schemas is mandatory for cost.

---

## 10. Supabase

| Topic | Finding |
|---|---|
| Regions | No Africa region. Nearest: `eu-west-2` London, `eu-west-3` Paris, `eu-west-1` Ireland, `eu-central-1` Frankfurt, `ap-south-1` Mumbai (candidate for Nairobi). "General regions" are not supported for read replicas [V][P1] |
| Plans (Sep 2026) | Pro $25 (+$10 compute credit), Team $599 (SOC 2 report; HIPAA add-on). Compute: Micro $10 (1 GB) … XL $210 (16 GB) … 4XL $960 (64 GB) … 8XL $1,870 (128 GB) [V][P4] |
| Metered pricing | 100k MAU included, then $0.00325/MAU. DB 8 GB, then $0.125/GB. Egress 250 GB, then $0.09/GB. Storage 100 GB, then $0.0213/GB. Realtime 500 peak connections, then $10 per 1,000; 5M messages, then $2.50/M. Edge Function invocations 2M, then $2/M. PITR $100/mo per 7 days. Log drains $60 + $0.20/M events. Backups 7 days (Pro), 14 days (Team) [V][P4] |
| Realtime limits | Pro (spend cap on): 500 connections, 500 msg/s. **Pro (no spend cap) / Team: 10,000 connections, 2,500 msg/s, 2,500 joins/s, 100 channels per connection, 1,000 presence msg/s, 3 MB broadcast payload.** Enterprise is configurable [V][P2b]. At 1M MAU we project ~60k peak connections → **Enterprise quota needed** |
| Edge Functions | 256 MB memory; wall clock 150 s (free) / 400 s (paid); **CPU 2 s per request**; 150 s idle timeout; 20 MB bundle; 1,000 functions per project on Pro [V][P2c]. Heavy work (receipt OCR orchestration, payouts batch) → queues + Cloud Run |
| Read replicas | SELECT only; Auth, Storage and Realtime can't use them; geo-routing load balancer since Apr 2025; async lag [V][P2d]. Fits the AI Admin Assistant on a replica |
| Realtime authorisation | Private channels enforced by RLS on `realtime.messages`. `realtime.send()` and `realtime.broadcast_changes()` (private by default); binary broadcast via `realtime.send_binary()` [S][P2e] |
| Extensions | `pg_partman` documented, with a TimescaleDB→pg_partman migration guide [V][P2f]. **Supabase Queues is built on pgmq** (exactly-once within the visibility window, archive, RLS-controlled access) [V][P2g]. **pgsodium is pending deprecation → use Vault** for secrets and envelope encryption with app-held keys; don't build on pgsodium TCE [V][P2h]. PostGIS, pgvector, pg_cron and pgTAP are standard Supabase extensions [A] (confirm in the dashboard on the chosen plan; spike S-02) |
| Compliance | SOC 2 report on Team+; HIPAA add-on; region selection is "a data-location control, not a compliance guarantee" [V][P1][P4] |

---

## 11. Data protection, consumer protection, tax and platform-work regulation

| Country | Data protection | Key obligations for Suskii | Tag |
|---|---|---|---|
| Nigeria | Nigeria Data Protection Act 2023 + **GAID 2025** (issued 20 Mar 2025, effective 19 Sep 2025) | Register with NDPC as a Data Controller of Major Importance (UHL/EHL/OHL tiers: ₦250k / ₦100k / ₦10k); annual Compliance Audit Returns for UHL/EHL; DPIA template in the GAID schedule; **72 h breach notice** to NDPC; data subjects notified immediately if high risk | [S][P42] |
| Kenya | Data Protection Act 2019 + General Regulations 2021 | ODPC registration (turnover > KSh 5M, >10 employees, or a mandatory sector); biometrics are sensitive data; DPIA for high-risk transfers; ODPC 2026 cross-border guidance with standard clauses; local-copy expectations for some processing (counsel to confirm scope); 72 h breach notice [A] | [S][P44] |
| Ghana | Data Protection Act 2012 (Act 843) | **Register with the DPC before processing.** The 2025 Bill (still in development, March 2026) would create a Data Protection Authority, widen personal data to biometrics and location, and **mandate localisation of biometric data** | [S][P45] |
| South Africa | POPIA | Register an Information Officer. Biometrics and criminal behaviour are *special personal information*; **prior authorisation** for some processing of criminal-behaviour information and unique identifiers, and for transfers of special PI to inadequate countries. Breach reports via the Information Regulator **eServices portal since 1 Apr 2025** | [S][P46] |
| Uganda | Data Protection and Privacy Act 2019 | **Annual registration with the PDPO** (offence if not); applies to offshore entities; no per-transfer approval, but keep records of the legal basis and safeguards for cross-border transfers | [S][P46b] |
| EU (global phase) | GDPR | Standard | [A] |

**Platform-work regulation:**
- Kenya: the High Court suspended the 18% commission cap and the 3-year data-sharing rule; the framework must be rebuilt within 12 months [S][P33].
- South Africa: a proposed employment-law amendment would presume that a person providing services is an employee unless proven otherwise, with major classification risk for platforms [S][P57b].
- Nigeria: no platform-worker statute found [A].

**Consumer protection [A]:** Nigeria FCCPA 2018 (FCCPC; it has fined platforms over data and consumer issues), Kenya Consumer Protection Act 2012, ZA Consumer Protection Act 2008 (cooling-off, fair terms), Ghana and Uganda statutes. Refund, cancellation-fee and dispute rules must be disclosed pre-contract per country. Counsel to confirm.

→ Details, actions and the DPIA outline are in [compliance-checklist-and-dpia.md](compliance-checklist-and-dpia.md).

---

## 12. App Store and Google Play policy

| Area | Requirement | Tag |
|---|---|---|
| Play: full-screen intent | Since 22 Jan 2025, only apps whose core function is calling or alarms get `USE_FULL_SCREEN_INTENT` by default (Android 14+). Others must ask the user and degrade gracefully. Declare on App content | [V][P51] |
| Play: foreground services | Android 14+ target: declare each FGS type (location, phoneCall, microphone, dataSync) with a description and a **demo video link** | [V][P51] |
| Play: location | April 2026 policy: location button recommended as minimum scope; geofencing removed as an FGS use case. **Precise-location declaration available Nov 2026, enforced 27 Jan 2027**; persistent fine location allowed for live tracking/navigation as core function; `onlyForLocationButton` for transactional precise location when targeting Android 17 (API 37) | [V][P52][P53] |
| Play: background location | Separate "location in the background" declaration and review; an FGS can't start from the background without `ACCESS_BACKGROUND_LOCATION` | [S][P53] |
| Play: contacts | New Contact Picker policy (Apr 2026). Use the picker for trusted contacts; never request `READ_CONTACTS` | [V][P52] |
| Play: financial features | Financial Features declaration expected for wallet and withdrawals | [A] |
| Apple 4.8 | If third-party login (Google) is offered, also offer an equivalent login that limits data to name and email, allows email hiding and has no ad tracking. Sign in with Apple satisfies this | [V][P54] |
| Apple 5.1.1(v) | In-app account deletion (with SIWA token revocation) | [V][P54] |
| Apple 1.2 | UGC apps need filtering, reporting, blocking and published contact info | [V][P54] |
| Apple 3.1.3(e) | Physical goods and services consumed outside the app **must not** use IAP. Our card/momo flows are correct; tips to providers for real-world services fall under the same rule [A] | [V][P54] |
| Apple 2.5.4 | Background modes only for intended purposes (VoIP, location, audio) | [V][P54] |
| iOS VoIP | Since the iOS 13 SDK, every PushKit VoIP push must be reported to CallKit before the handler returns, or the app is terminated and VoIP delivery may stop | [S][P55] |

---

## 13. Flutter and npm package due diligence

Registry snapshot taken 2026-09-15 via the pub.dev, npm and PyPI APIs [V][P60]. Full table: [vendor-decision-matrix.md §Packages](vendor-decision-matrix.md#packages).

| Verdict | Packages |
|---|---|
| Healthy (verified publisher, 140–160 points, recent release) | `supabase_flutter` 2.17.2, `livekit_client` 2.13.0, `flutter_callkit_incoming` 3.1.5, `firebase_messaging` 16.7.0, `flutter_local_notifications` 22.3.1, `geolocator` 14.0.3, `google_maps_flutter` 2.18.0, `freerasp` 8.2.2, `local_auth` 3.0.2, `app_links` 7.2.1, `camera` 0.12.1, `image_picker` 1.2.3, `flutter_image_compress` 2.5.1, `sentry_flutter` 9.30.0, `widgetbook` 3.25.0, `patrol` 4.10.0, `flutter_secure_storage` 11.1.1, `drift` 2.35.0, `riverpod`/`flutter_riverpod` 3.4.3, `go_router` 18.0.1, `freezed` 4.0.1, `json_serializable` 6.14.1, `flutter_foreground_task` 11.0.3, `connectivity_plus` 7.3.1 |
| Paid licence | `flutter_background_geolocation` 5.7.0: code Apache-2.0, but **release builds need a paid licence**; v4 keys don't work on v5 |
| Avoid / replace | `flutterwave_standard` 1.1.0 (no verified publisher, last release Apr 2025) → use a server-created hosted checkout link opened in a Custom Tab / SFSafariViewController. `background_locator_2` (abandoned 2023). `app_device_integrity` 1.1.0 (stale since Dec 2024) → thin platform channel to Play Integrity / App Attest. `prembly_identity_kyc` (web-only tag, negligible adoption) |
| Watch | `smile_id` v11 vs `usesmileid` v12 (new); `dojah_kyc_sdk_flutter` (low adoption) |
| npm healthy | `@supabase/supabase-js` 2.116.0, `@supabase/ssr` 0.12.7, `livekit-client` 2.22.3, `livekit-server-sdk` 2.19.0, `@livekit/agents` 1.9.0, `@smileid/web-sdk` 12.0.4, `smile-identity-core` 3.2.1, `flutterwave-node-v3` 1.4.1, `stripe` 22.6.2, `next` 16.3.5, `@tanstack/react-query` 5.102.8, `zod` 4.6.5, `standardwebhooks` 1.1.1, `@sentry/nextjs` 10.74.0, `posthog-js` 1.433.5 |
| Python | `livekit-agents` 1.8.2, `livekit-plugins-google` 1.8.2, `google-genai` 2.23.0, `fastapi` 0.141.1 |

All licences seen are permissive (MIT, BSD-3, Apache-2.0). A copyleft/licence scan runs in CI (spec).

---

## 14. Proposed spec changes and new open decisions

| ID | Topic | Proposed default | Why |
|---|---|---|---|
| **OD-09** | Police-clearance recency and renewal | Accept certificates issued ≤6 months before submission; re-verify every 12 months; per-country override | NG validity 3 months at ₦30k; UG 6 months; ZA none (§5) |
| **OD-10** | Who pays payout transfer fees | Provider (consistent with "gateway fees borne by provider"), shown in the withdrawal preview; platform absorbs for referral payouts below a threshold | Not covered by the spec; ₦10–50 / KSh 100 / GH₵10 per transfer (§3.1) |
| **OD-11** | Role of Stripe | Africa: Flutterwave primary + Paystack (Stripe-owned) secondary. Stripe Connect only for markets where a Suskii entity is in US/UK/EEA/CA/CH | Stripe can't pay African connected accounts (§3.3) |
| **OD-12** | Operating entity and funds-holding model per country | Gateway merchant balance + limited-payment-collection-agent terms; ZA TPPP registration; counsel sign-off per country before `live` | §3.4 |
| **OD-13** | Ongoing selfie-check frequency | On-device liveness + face match against the enrolled template daily; vendor 1:1 authentication weekly and on risk triggers (device change, payout change, large withdrawal, random 5%) | ~$200k/month at 1M MAU if vendor-daily (§cost model) |
| **OD-14** | Wave-1 countries | NG live first; KE, GH, ZA, UG in beta as packs pass the go-live checklist | §2 |
| **OD-15** | Hosting and data residency | Supabase EU region (London provisional) + vendor-side biometrics + encrypted KYC files; costed fallback: self-hosted Supabase on AWS `af-south-1` or GCP `africa-south1` if KE/GH counsel requires in-country copies | §10, §11 |
| **OD-16** | Swahili / Luganda for KE/UG | English-only at launch in KE/UG (urban English is common); Swahili in V1.2 | Launch languages cover NG best |
| **OD-17** | Pidgin voice | Pidgin voice ships only if it passes the S-08 eval gate; otherwise Pidgin text concierge + English voice | Live API doesn't list `pcm` (§6.2) |
| **OD-18** | Tax on referral payouts | Ledger supports per-country withholding and annual statements; tax counsel rules per country | §3.5 |

**Spec text corrections (for the Phase 1 ADRs):**

- `payment_gateways.stripe`: note that Connect cross-border works only between US/UK/EEA/CA/CH, and add Paystack as the Stripe-family African rail.
- `ai_layer.model_routing`: "Pro-tier for concierge" → "eval-selected; Flash default, Pro escalation".
- `architecture.components.postgres`: replace any pgsodium reliance with Vault + app-level envelope encryption.
- `verification_kyc.ongoing_checks`: adopt OD-13.

---

## Sources

All accessed 2026-09-15.

**Platform**
- [P1] Supabase — Available regions: https://supabase.com/docs/guides/platform/regions
- [P2] Supabase GitHub discussion #34614 (South Africa region): https://github.com/orgs/supabase/discussions/34614
- [P2b] Supabase — Realtime limits: https://supabase.com/docs/guides/realtime/limits
- [P2c] Supabase — Edge Function limits: https://supabase.com/docs/guides/functions/limits
- [P2d] Supabase — Read replicas: https://supabase.com/docs/guides/platform/read-replicas
- [P2e] Supabase — Realtime Authorization / Broadcast: https://supabase.com/docs/guides/realtime/authorization · https://supabase.com/docs/guides/realtime/broadcast
- [P2f] Supabase — pg_partman: https://supabase.com/docs/guides/database/extensions/pg_partman
- [P2g] Supabase — Queues: https://supabase.com/docs/guides/queues
- [P2h] Supabase — pgsodium (pending deprecation): https://supabase.com/docs/guides/database/extensions/pgsodium
- [P3] Supabase — Send SMS Hook: https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook
- [P4] Supabase — Pricing: https://supabase.com/pricing

**Payments**
- [P5] Stripe — Cross-border payouts: https://docs.stripe.com/connect/cross-border-payouts
- [P6] Stripe — Global Payouts: https://docs.stripe.com/global-payouts
- [P6b] Stripe changelog 2026-01-28 (15 new countries): https://docs.stripe.com/changelog/clover/2026-01-28/cross-border-payouts-new-countries
- [P7] Stripe — Global availability: https://stripe.com/global
- [P8] Flutterwave — Mobile money (v3): https://developer.flutterwave.com/docs/mobile-money
- [P9] Flutterwave — Escrow payments (v2): https://developer.flutterwave.com/v2.0/docs/escrow-payments
- [P10] Flutterwave — v4 public beta: https://dev.to/flutterwaveeng/introducing-the-flutterwave-v4-api-faster-safer-easier-to-integrate-2dc9
- [P11] Flutterwave pricing: https://flutterwave.com/ng/pricing · /ke/pricing · /gh/pricing · /za/pricing · /ug/pricing · /rw/pricing · https://flutterwave.com/ke/support/pricing/pricing-for-transfers-and-payouts · https://flutterwave.com/mu/support/pricing/fee-increase-for-local-ngn-payments
- [P12] Flutterwave — Settlements: https://developer.flutterwave.com/docs/settlements
- [P42b] Paystack — Transactions pricing / stamp duty: https://support.paystack.com/en/articles/2130306 · https://support.paystack.com/en/articles/7573314 · https://afrotools.com/blog/paystack-fees-explained/
- [P43] Paystack — Split payments: https://paystack.com/docs/payments/split-payments/

**AI**
- [P13] Google Cloud — Google models (Gemini Enterprise Agent Platform): https://docs.cloud.google.com/vertex-ai/generative-ai/docs/models
- [P14] Gemini API — Models: https://ai.google.dev/gemini-api/docs/models
- [P15] OrcaRouter — Gemini 3.5 Pro release status: https://www.orcarouter.ai/blog/gemini-3-5-pro-release-date
- [P16] Gemini API — Live API guide (languages, sessions, function calling): https://ai.google.dev/gemini-api/docs/live-guide
- [P16b] Addis Insight — Gemini language support: https://addisinsight.net/2025/08/27/googles-latest-ai-update-brings-amharic-into-gemini-powered-live-translation/
- [P17] Gemini API — Pricing: https://ai.google.dev/gemini-api/docs/pricing
- [P18] LiveKit — Gemini Live API plugin: https://docs.livekit.io/agents/models/realtime/plugins/gemini/
- [P19b] Google Cloud — africa-south1 region / ML locations: https://cloud.google.com/blog/products/infrastructure/heita-south-africa-new-cloud-region · https://docs.cloud.google.com/gemini-enterprise-agent-platform/machine-learning/general/locations

**KYC and police clearance**
- [P19] Smile ID — Supported countries / ID types: https://docs.usesmileid.com/supported-id-types/for-individuals-kyc/backed-by-id-authority/supported-countries
- [P20] Biometric Update — Smile ID Fime Level 2 PAD (Jan 2025): https://www.biometricupdate.com/202501/smile-id-updates-selfie-biometrics-software-and-aces-fime-level-2-pad-assessment
- [P20b] Smile ID — Biometric authentication / Smile Secure: https://usesmileid.com/solutions/biometric-authentication/
- [P20c] Smile ID pricing (sales-quoted) and estimate: https://usesmileid.com/pricing/ · https://helloduty.com/blogs/what-is-smile-identity-and-how-its-revolutionizing-business-practices
- [P20d] Dojah — African IDV comparison 2026: https://dojah.io/blog/best-identity-verification-api-africa-2026
- [P21] Pulse Nigeria — Police Character Certificate 2026 (POSSAP): https://www.pulse.ng/story/how-to-get-police-character-certificate-nigeria-2026-2026080405535678230
- [P22] Kenya DCI — Police Clearance Certificate: https://www.dci.go.ke/police-clearance-certificate
- [P23] Pulse Ghana — Police clearance guide 2026: https://www.pulse.com.gh/story/ghana-police-clearance-certificate-guide-2026080416044931142 · https://eservices.police.gov.gh/
- [P23b] SAPS PCC guides: https://idchecker.co.za/police-clearance-certificate-south-africa/ · https://apostil.co.za/police-clearance-saps/
- [P23c] Uganda Police / Interpol: https://upf.go.ug/certificate-of-good-conduct-application-made-easy/ · https://ugandann.com/how-to-obtain-a-certificate-of-good-conduct-police-clearance-certificate-or-interpol-letter/

**Messaging, voice and SOS**
- [P24] SMS compliance Nigeria (DND, sender IDs): https://www.messagecentral.com/blog/otp-sms-compliance-nigeria · https://www.bulksmsnigeria.com/resources/dnd-delivery-guide
- [P24b] LiveKit pricing (secondary): https://trtc.io/blog/details/livekit-pricing-2026 · https://www.cekura.ai/blogs/livekit-pricing
- [P24c] LiveKit — Regions: https://docs.livekit.io/deploy/admin/regions/
- [P24d] Termii pricing: https://www.buildstudio.com.ng/apis/termii-api
- [P24e] Africa's Talking pricing: https://africastalking.com/pricing · https://helloduty.com/blogs/top-sms-systems-in-kenya
- [P25] Twilio Proxy (closed to new customers): https://www.twilio.com/docs/proxy
- [P25b] Africa's Talking Voice: https://africastalking.com/voice
- [P25c] Infobip Number Masking: https://www.infobip.com/docs/voice-and-video/number-masking
- [P26] AURA — Integrations / Kenya: https://www.aurasos.com/en-za/technology/integrations · https://www.aurasos.com/en-ke
- [P27] Rescue.co: https://www.rescue.co/ · https://tech-ish.com/2024/12/04/rescue-co-africa-emergency-support/
- [P28] Daily Trust — Halogen/ERA SIGNAL app; N-Alert: https://dailytrust.com/emergency-response-app-launched-in-nigeria/ · https://play.google.com/store/apps/details?id=com.a2tocsolutions.nispsasapp

**Market and competitors**
- [P30] Al Jazeera — Why is Uber pulling out of African markets (11 Sep 2026): https://www.aljazeera.com/news/2026/9/11/why-is-uber-pulling-out-of-some-african-markets
- [P31] WeeTracker — Lagos "offline trips" (May 2026): https://weetracker.com/2026/05/14/e-hailing-offline-trips-lagos-nigeria-cash-rides/
- [P32] Bolt driver commissions (KE) and coverage: https://bolt.eu/en-ke/driver/guide/commissions/ · https://ridetransport.com.ng/how-to-become-a-bolt-driver-in-nigeria-complete-2026-guide/
- [P33] Techweez — Kenya High Court blocks 18% cap (3 Sep 2026): https://techweez.com/2026/09/03/kenya-uber-ride-hailing-commission-cap-court-ruling/
- [P34] Africa Briefing — inDrive commission-free expansion: https://africabriefing.com/indrives-commission-free-expansion-reshapes-african-ride-hailing/
- [P35] inDrive (Wikipedia; 48 countries / 888 cities): https://en.wikipedia.org/wiki/InDrive
- [P36] The Africa Report / Monitor — Uber exits; Delivery Hero deal: https://www.theafricareport.com/429763/uber-quits-nigeria-and-uganda-as-bolt-and-indrive-eye-market-share/ · https://www.monitor.co.ug/uganda/news/national/end-of-an-era-uber-exits-uganda-nigeria-after-decade-in-market-5581500
- [P37] Uber/Bolt SOS partners: https://www.ewn.co.za/uber-rolls-out-enhanced-safety-features-in-south-africa/ · https://www.uber.com/en-GH/blog/introducing-the-emergency-button-in-ghana · https://www.itweb.co.za/article/bolt-boosts-e-hailing-safety-with-passenger-sos-button/raYAyMod45QqJ38N · https://businessday.ng/technology/article/bolt-bets-on-drivers-as-first-responders-in-nigerias-road-emergencies/
- [P38] Chowdeck: https://techcabal.com/2026/03/02/chowdeck-provides-insurance-for-riders/ · https://afridigest.com/chowdeck-plans-succeed-jumia-food-failed/
- [P39] Yango Africa expansion: https://techcabal.com/2026/06/23/yango-group-africa-thesis/ · https://www.bloomberg.com/news/articles/2026-05-19/yango-targets-10-new-african-markets-in-150-million-push
- [P47] TaskRabbit service fee: https://support.taskrabbit.com/hc/en-us/articles/46260411872155-What-s-the-Taskrabbit-Service-Fee
- [P48] Thumbtack lead pricing: https://help.thumbtack.com/article/set-lead-prices
- [P49] Urban Company model: https://investorrelations.urbancompany.com/announcements-and-highlights/service-professional-enablement
- [P61] World Bank Global Findex 2025 (SSA): https://www.worldbank.org/en/publication/globalfindex/brief/financial-inclusion-in-sub-saharan-africa-overview · https://africanenda.org/the-global-findex-2025-could-instant-payments-be-driving-financial-inclusion-in-africa/
- [P62] FX, Sep 2026: https://www.vanguardngr.com/2026/09/dollar-to-naira-exchange-rate-today-september-15-2026/ · https://www.hubzmedia.africa/kenya-shilling-holds-steady-as-cbk-releases-daily-exchange-rates-for-9-september-2026/ · https://www.ghanamma.com/2026/09/11/september-11-cedi-sells-at-ghs12-15-on-forex-market-ghs11-46-on-bog-interbank/
- [P63] Nigeria payment methods: https://payatlas.com/countries/nigeria-ng · https://docs.ebanx.com/docs/pay-in/processing/payment-methods/country-specific/nigeria/nigeria-country-overview
- [P64] Transsion share: https://www.gizmochina.com/2026/02/25/transsion-captures-48-as-africa-smartphone-market-grows-13-in-2025/ · https://intelpoint.co/blogs/mobile-phone-market-share-in-africa-by-region/

**Law and regulation**
- [P40] Mondaq — Escrow payments in Nigerian e-commerce: https://www.mondaq.com/nigeria/financial-services/1474486/the-emergence-of-escrow-payments-in-e-commerce-transactions-in-nigeria
- [P41] PASA — TPPP registration; SARB Directive 1 of 2007: https://authorisation.pasa.org.za/so-and-tppp/tppp-registration/ · https://authorisation.pasa.org.za/wp-content/uploads/2024/07/SARB-Directive-1-of-2007-Third-Party-Payments-Providers.pdf
- [P42] NDPC GAID 2025: https://ndpc.gov.ng/wp-content/uploads/2025/07/NDP-ACT-GAID-2025-MARCH-20TH.pdf · https://privacymatters.dlapiper.com/2025/06/nigeria-ndpc-issues-gaid-key-compliance-insights/
- [P44] Kenya DPA / ODPC: https://www.dlapiperdataprotection.com/index.html?t=law&c=KE · https://captaincompliance.com/education/kenyas-odpc-issues-2026-cross-border-transfer-guidance-complete-with-its-own-standard-clauses/
- [P45] Ghana Data Protection Bill 2025 vs Act 843: https://thebftonline.com/2025/12/02/comparative-analysis-of-data-protection-bill-2025-and-data-protection-act-2012-act-843-changes-and-additions/ · https://sustineriattorneys.com/2026/04/01/comparative-analysis-of-ghanas-data-protection-bill-2025-and-the-data-protection-act-2012-act-843-changes-and-additions/
- [P46] POPIA special PI / prior authorisation / eServices: https://inforegulator.org.za/popia/ · https://www.insideprivacy.com/data-security/data-breaches/south-africa-introduces-mandatory-e-portal-reporting-for-data-breaches/
- [P46b] Uganda PDPO registration and offshore entities: https://privacymatters.dlapiper.com/2025/08/uganda-data-protection-regulator-clarifies-compliance-requirements-for-offshore-entities/ · https://www.cliffedekkerhofmeyr.com/en/news/publications/2025/Sectors/Technology-Communications/technology-and-communications-alert-13-august-to-register-or-not-to-register-the-ugandan-personal-data-protection-offices-decision-on-the-registration-of-data-controllers
- [P56] Kenya digital marketplace WHT / SEP tax: https://bowmanslaw.com/insights/kenya-the-finance-bill-2024/ · https://www.ey.com/en_gl/technical/tax-alerts/kenya-enacts-tax-changes-under-finance-act--2023
- [P57] South Africa VAT / platforms: https://www.bdo.global/en-gb/insights/tax/indirect-tax/south-africa-2026-budget-includes-vat-measures-affecting-sezs-and-digital-platform-operators
- [P57b] SA gig-worker labour reform: https://theconversation.com/south-africas-gig-economy-workers-set-to-get-more-protection-under-planned-labour-law-reforms-277858
- [P58] Nigeria Tax Act 2025: https://www.ey.com/en_gl/technical/tax-alerts/nigeria-tax-act-2025-has-been-signed-highlights · https://topeadebayolp.com/vat-under-the-nta-2025-what-digital-platforms-and-fintechs-need-to-know/
- [P58b] Nigeria WHT Regulations 2024: https://www.grantthornton.com.ng/insights/Withholding-Tax-Regulation-2024/
- [P59] Ghana VAT reform 2026: https://kpmg.com/us/en/taxnewsflash/news/2026/02/ghana-vat-measures-2026-budget-enacted.html

**Store policy**
- [P51] Play Console — Foreground service and full-screen intent requirements: https://support.google.com/googleplay/android-developer/answer/13392821
- [P52] Play Console — Policy announcement 15 Apr 2026: https://support.google.com/googleplay/android-developer/answer/16926792
- [P53] Play Console — Minimum scope / location button: https://support.google.com/googleplay/android-developer/answer/17033915 · https://support.google.com/googleplay/android-developer/answer/9799150
- [P54] Apple — App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- [P55] Apple — Responding to VoIP notifications from PushKit: https://developer.apple.com/documentation/PushKit/responding-to-voip-notifications-from-pushkit

**Packages and devices**
- [P60] Registry APIs: https://pub.dev/api/packages/<name> · https://registry.npmjs.org/<name> · https://pypi.org/pypi/<name>/json (snapshot in [vendor-decision-matrix.md](vendor-decision-matrix.md#packages))
- [P65] Don't Kill My App (Tecno ranked #15): https://dontkillmyapp.com/
- [P66] Google Maps Platform pricing changes (Mar 2025 free caps): https://developers.google.com/maps/billing-and-pricing/faq
