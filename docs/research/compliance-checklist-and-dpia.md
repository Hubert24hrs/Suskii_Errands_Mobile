# Compliance Checklist and DPIA Outline — Phase 0

Date 2026-09-15 · Evidence tags and source IDs: see [REPORT.md](REPORT.md#evidence-legend).

> **This is not legal advice.** It is an engineering-led inventory of obligations found in research, meant to scope the work of qualified counsel in each country. Every item marked *Counsel* needs a written opinion before the related country pack can be set to `live`.

**Owner codes:**

| Code | Owner |
|---|---|
| **CC** | Claude Code |
| **KC** | Kimi Code |
| **CL** | Client / business |
| **LG** | Legal counsel (per country) |
| **FO** | Finance/ops |

---

## 1. Cross-cutting checklist

### 1.1 Security standards (spec `master_spec.security.standards`)

| # | Item | Owner | Phase | Evidence of done |
|---|---|---|---|---|
| S1 | OWASP MASVS L2 control mapping for the Flutter app (storage, crypto, auth, network, platform, code, resilience) | CC + KC | 1 (map), 9 (verify) | Control matrix in `docs/audit/` |
| S2 | OWASP ASVS L2 mapping for Edge Functions, Cloud Run and web | CC | 1, 9 | Control matrix |
| S3 | OWASP API Top 10 threat review per endpoint in the contracts | CC | 1 | STRIDE sheet per component |
| S4 | OWASP Top 10 for LLM Applications: prompt injection, insecure output handling, excessive agency, sensitive-info disclosure | CC | 1, 7 | AI design doc + red-team suite in CI |
| S5 | PCI DSS scope minimisation: hosted checkout (Flutterwave/Paystack) only; no PAN touches our systems (target SAQ A) | CC | 1 | Data flow diagram; gateway attestation |
| S6 | RLS default-deny on every exposed table with pgTAP allow/deny tests per role | CC | 2–8 | CI report |
| S7 | Admin MFA mandatory; SSO/IP allowlist; four-eyes approval for payouts, commissions and country-pack changes | CC + KC | 8 | Tests + audit log |
| S8 | Hash-chained, append-only audit log (KYC views, money, settings) | CC | 2 | Chain verification job |
| S9 | Independent penetration test before launch | CL | 10 | Report + fixes |

### 1.2 Payments and money

| # | Item | Owner | Phase | Status |
|---|---|---|---|---|
| P1 | Set Flutterwave fee bearer to **merchant** in every country dashboard (the default is customer) [V][P11] | FO | 5 | Open |
| P2 | Counsel opinion per country on holding customer funds (commercial agent vs licence vs bank-partner account) — **OD-12** [S][P40] | LG | 1 | Open |
| P3 | **South Africa: TPPP registration with PASA via a sponsoring bank** (SARB Directive 1 of 2007) [V][P41] | CL + LG | before ZA live | Open |
| P4 | UI copy never says "escrow" unless a licensed escrow partner is used (spec) | KC | 1 (UI change list) | Open |
| P5 | Refund, cancellation-fee and dispute terms disclosed pre-contract per consumer law | LG + KC | 1 | Open |
| P6 | Daily reconciliation, ledger vs gateway settlement reports | CC | 5 | Open |
| P7 | Tax registrations: VAT per country; NG NRS possible collection-agent appointment; KE WHT/SEP; ZA platform VAT liability proposal [S][P56–P59] | LG + FO | 1 | Open |
| P8 | Referral payouts: withholding and annual statements per country — **OD-18** | LG + FO | 5 | Open |
| P9 | AML/CFT: sanctions/PEP screening for providers and businesses above payout thresholds (ask Smile ID/Youverify for AML add-ons) [A] | CC + LG | 4 | Open |

### 1.3 Privacy (spec `master_spec.security.privacy`)

| # | Item | Owner | Phase |
|---|---|---|---|
| D1 | DPIA completed and signed before launch (outline in §4) | CC + LG | 1 → 10 |
| D2 | **Separate** consents: location, biometrics, criminal-record check, marketing, (voice-agent audio processing) | KC (UI) + CC (records) | 2 |
| D3 | Consent ledger: versioned text, timestamp, device, withdrawal | CC | 2 |
| D4 | Data subject requests: access, correction, deletion, export, with SLA tracking in admin | CC + KC | 8 |
| D5 | Retention schedule enforced by jobs (§5) with legal-hold override | CC | 2–8 |
| D6 | Processor DPAs signed: Supabase, Google Cloud (Vertex), Smile ID, Flutterwave, Paystack, LiveKit, Infobip, Africa's Talking, Termii, AURA / Rescue.co, Sentry, PostHog, Cloudflare | CL + LG | 1–10 |
| D7 | Cross-border transfer basis per country (hosting is in the EU, see OD-15) | LG | 1 |
| D8 | Vendor-side biometric templates only; no raw biometric data in our DB (spec) | CC | 4 |
| D9 | PII redaction in logs, analytics and LLM prompts | CC + KC | 2–7 |
| D10 | Breach runbooks per country with regulator timelines (NG 72 h; KE 72 h [A]; ZA "as soon as reasonably possible" via eServices; GH/UG counsel) | CC + LG | 10 |

### 1.4 App stores

| # | Item | Owner | Deadline |
|---|---|---|---|
| A1 | Play FGS declarations (location, phoneCall, microphone, dataSync) with demo videos [V][P51] | KC | First Play submission |
| A2 | Play full-screen-intent declaration as a calling app; handle denial [V][P51] | KC | First Play submission |
| A3 | Play precise-location declaration (continuous tracking = core function); `onlyForLocationButton` for transactional precise location on API 37 targets [V][P53] | KC | **Declarations open Nov 2026; enforced 27 Jan 2027** |
| A4 | Play background-location declaration and review [S][P53] | KC | First Play submission |
| A5 | Use Contact Picker for trusted contacts, not `READ_CONTACTS` [V][P52] | KC | Now |
| A6 | Play Data safety form; Financial Features declaration [A] | KC + CC | Submission |
| A7 | Apple: Sign in with Apple (4.8), in-app deletion with SIWA token revocation (5.1.1(v)), UGC controls (1.2), no IAP for real-world services (3.1.3(e)), background modes justified (2.5.4) [V][P54] | KC + CC | Submission |
| A8 | iOS VoIP: every PushKit push reported to CallKit; never used for non-call events [S][P55] | KC | M4 |
| A9 | Privacy nutrition labels match the actual SDKs (Sentry, PostHog, Smile ID, Firebase) | KC + CC | Submission |

---

## 2. Registrations and authorisations per country

| Country | Data protection registration | Special-category approvals | Payments | Messaging | Other |
|---|---|---|---|---|---|
| **Nigeria** | NDPC registration as DCPMI (tier by data-subject volume; ₦250k / ₦100k / ₦10k), annual CAR for UHL/EHL [S][P42] | DPIA per GAID schedule for biometric and criminal-record processing | CBN position on funds holding (OD-12) [S][P40] | NCC sender-ID registration with all 4 MNOs + DND whitelisting [S][P24] | CAC registration of the local entity; FCCPA consumer terms [A] |
| **Kenya** | ODPC registration (thresholds met) [S][P44] | DPIA for high-risk / cross-border processing; confirm local-copy scope | CBK / NPS Act for funds holding [A] | Sender-ID with Safaricom/Airtel via aggregator [A] | Watch TNC regulation rework (12 months from 3 Sep 2026) [S][P33] |
| **Ghana** | DPC registration **before** processing [S][P45] | Watch the 2025 Bill (biometric localisation) | Bank of Ghana, Act 987 [A] | NCA sender-ID rules [A] | ORC registration; TIN |
| **South Africa** | Information Officer registration with the Information Regulator [S][P46] | **Prior authorisation** for criminal-behaviour information / unique identifiers; transfers of special PI [S][P46] | **PASA TPPP registration** [V][P41] | WASPA code for SMS [A] | PAIA manual; CPA terms; labour-classification watch [S][P57b] |
| **Uganda** | PDPO registration, **renewed annually** [S][P46b] | Records of transfer safeguards [S][P46b] | Bank of Uganda, NPS Act 2020 [A] | UCC sender-ID [A] | URSB registration; TIN |

---

## 3. Country go-live checklist

A country pack moves `beta → live` only when all rows are ✅ or explicitly waived by the Super Admin **and** the client, both recorded in the four-eyes approval log.

| # | Gate | Evidence |
|---|---|---|
| G1 | Local legal entity or cross-border model confirmed by counsel | Opinion letter |
| G2 | Data-protection registration done (§2) | Certificate / receipt |
| G3 | DPIA addendum for the country signed | Signed PDF in the compliance store |
| G4 | Funds-holding model approved (OD-12); gateway accounts KYB-approved; fee bearer = merchant | Counsel + dashboard screenshots |
| G5 | Payment sandbox → live: collection, refund, payout, webhook replay and daily reconciliation tested end to end | Test report |
| G6 | KYC: ID types confirmed with the vendor; Biometric KYC pass rate ≥ 90% on a pilot cohort; officer review SLA staffed | Pilot report |
| G7 | Police-clearance workflow and officer playbook for this country's document | Playbook |
| G8 | SMS/OTP: sender ID approved; delivery ≥ 95% in < 30 s on every MNO (S-09) | Test report |
| G9 | SOS partner contract signed; acknowledgement drill passed in each launch city | Drill log |
| G10 | Emergency numbers, prohibited items and legal documents localised and versioned | Pack diff |
| G11 | Tax registrations and invoice/receipt format | Accountant sign-off |
| G12 | Price guardrails calibrated from ≥ 2 weeks of beta data | Pricing memo |
| G13 | Support and ops staffed for the time zone; runbooks updated | Roster |

---

## 4. DPIA outline

Structure aligned with the NDPC GAID DPIA template and GDPR Art. 35 practice. It is completed in Phase 1 (draft) and Phase 10 (final), with country addenda.

### 4.1 Description of processing

- **Controller(s):** the Suskii operating entity per country (OD-12). **Processors:** listed in D6.
- **Purposes:**
  1. account and authentication;
  2. identity and facial verification;
  3. provider vetting (police clearance, documents, guarantor, address);
  4. marketplace matching and negotiation;
  5. payments, payouts, ledger, tax;
  6. live tracking and proof of completion;
  7. communication (chat, calls, masked PSTN, notifications);
  8. safety (SOS, trip share, trusted contacts);
  9. trust and safety (moderation, risk engine, disputes);
  10. AI concierge and voice agent;
  11. analytics and ML (price intelligence, matching);
  12. referrals and anti-fraud;
  13. support.
- **Scale:** projected 1k → 1M MAU; wave-1 countries NG, KE, GH, ZA, UG; hosting in the EU (Supabase region per S-01); GCP (Vertex, Cloud Run, BigQuery) region per S-07.

### 4.2 Data inventory and classification

| Class | Examples | Where stored | Sensitivity |
|---|---|---|---|
| Identity | Name, phone, email, DOB, gov-ID number (encrypted + blind index) | Postgres `kyc` schema | High |
| **Biometric** | Selfie/liveness frames, face templates | **Vendor-side** (Smile ID); our DB holds job ID and result only | **Special** |
| **Criminal record** | Police-clearance file, certificate number (encrypted), issue/expiry dates, officer decision; **no free-text criminal notes** (spec) | `kyc-docs` bucket (write-only for clients) + `kyc` schema | **Special** |
| Financial | Payout account (encrypted), transaction amounts, ledger, withdrawal history | `ledger` schema; gateway | High |
| Location | Live pings (Realtime only, not persisted), sampled trail per job, saved places, gate/access notes (encrypted) | Postgres (partitioned) | High |
| Communications | Chat text/images/voice notes, call metadata (no recordings) | Postgres + `chat-media` bucket | Medium–High |
| Device and security | Device IDs, integrity verdicts, RASP signals, IP | Postgres `private`/`audit` | Medium |
| AI interactions | Concierge transcripts (redacted), voice-agent transcripts (no audio kept) | Postgres + BigQuery (pseudonymised) | Medium |
| Referral | Codes, attribution, earnings | `ledger` + `public` (own rows only) | Medium |

### 4.3 Lawful bases (to be confirmed per country by LG)

| Purpose | Proposed basis |
|---|---|
| Account, payments, service delivery | Contract |
| Identity and biometric verification | **Explicit consent** (biometrics) + legal obligation where AML applies |
| Criminal-record check | **Explicit consent** + legitimate interest in user safety. ZA: prior authorisation. Minimum necessary |
| Live location during an active job | Contract. Provider background location while online: consent + contract |
| Fraud / risk engine | Legitimate interest (balancing test documented) |
| Marketing | Consent (separate, withdrawable) |
| AI concierge | Contract (feature use) with a disclosure notice. Voice: consent to audio processing |
| Analytics / ML training | Legitimate interest on pseudonymised data; opt-out honoured |

### 4.4 Necessity and proportionality

- Customer facial verification is required by client decision. Record the justification: fraud and safety in a paid-upfront marketplace where the provider enters homes. Assess less intrusive alternatives (phone + card only) and record why they were rejected.
- Police clearance for every provider: justified for in-home and valuables-handling services. Minimise: store the outcome and dates; restrict file access to Verification Officers via short-lived signed URLs; log every view.
- Daily selfie checks (OD-13): the on-device first approach reduces biometric transfers to vendors.
- Retention per §5; no raw location history beyond 90 days unless disputed.

### 4.5 Risks to data subjects

1. KYC document or biometric breach → identity theft.
2. Criminal-record data misuse or leakage → discrimination and reputational harm.
3. Location exposure → stalking or physical harm (trip-share links, access notes).
4. Account takeover → financial loss.
5. Function creep (e.g. using KYC selfies for marketing or model training).
6. Cross-border transfer to the EU and US sub-processors without an adequate basis.
7. Automated decisions: risk-engine blocks, AI moderation, matching exclusion, without human review.
8. Discrimination in matching or pricing (by area, name or language).
9. Over-retention.
10. Vendor lock-in blocking deletion requests (templates held by the vendor).
11. Children: minors signing up (set minimum age 18 for all roles [A]).
12. Chat and voice content exposure to LLM providers.

### 4.6 Mitigations (map each to a spec control)

| Risk | Controls |
|---|---|
| 1, 2 | Private buckets with no client read; short-lived signed URLs; field encryption with blind indexes; hash-chained access audit; officer role separation; vendor-side templates |
| 3 | Broadcast-only live pings; expiring trip-share tokens; access notes visible to the assigned provider only during the job |
| 4 | OTP + CAPTCHA + device binding; MFA; biometric/PIN for withdrawals; integrity tokens |
| 5 | Purpose limitation encoded in data-access functions; separate consents |
| 6 | Processor DPAs; transfer basis per country; EU hosting; Vertex regional endpoint |
| 7 | Human review for account-level adverse actions; appeal flow; AI never decides verification, money or disputes (spec guardrail) |
| 8 | Fairness checks in matching/pricing evals; no protected attributes as features |
| 9 | Retention jobs + legal hold |
| 10 | Vendor deletion API/SLA in the contract; periodic deletion reconciliation |
| 11 | Age gate + ID DOB check |
| 12 | PII redaction before LLM calls; no training on customer data per the Vertex terms (confirm in contract) |

### 4.7 Residual risk, consultation and sign-off

Residual risk rating per risk. Consult the regulator where residual risk stays high (e.g. ZA prior authorisation; NDPC DPIA vetting). Sign-off: DPO / Information Officer per country, CL and LG. Review annually and on material change (new vendor, new country, new data class).

---

## 5. Draft retention schedule (defaults; counsel to confirm per country)

| Data | Default retention | Trigger | Notes |
|---|---|---|---|
| KYC files (ID images, police clearance) | 5 years after account closure | Closure | AML-style retention; legal hold overrides |
| KYC outcomes and reference IDs | Life of account + 5 years | Closure | |
| Biometric templates (vendor-side) | Delete on closure unless a ban-evasion list is legally allowed | Closure | Keep a *hash/reference* for banned users only if counsel approves |
| Ledger and payment records | 7 years | Transaction | Tax/accounting |
| Chat messages and media | 12 months | Job closed | Longer under dispute hold |
| Location samples (per job) | 90 days | Job closed | Dispute hold |
| Call metadata | 12 months | Call end | No recordings exist |
| Proof photos | 24 months | Job closed | EXIF stripped for display |
| AI transcripts | 90 days raw (redacted); pseudonymised eval sets kept longer | Conversation end | |
| Audit logs | 7 years | Event | Hash-chained |
| Marketing consent records | Life of consent + 3 years | Withdrawal | |

---

## 6. Consumer-protection and platform-work watchlist

| Country | Item | Status |
|---|---|---|
| Kenya | TNC regulations: commission cap and 3-year data-sharing rule suspended (3 Sep 2026); rework due within 12 months [S][P33] | Monitor |
| South Africa | Proposed presumption of employment for service providers [S][P57b] | Monitor; counsel on provider terms |
| Nigeria | FCCPA 2018 consumer rules; FCCPC enforcement on data/consumer issues [A] | Counsel review of terms |
| All | Cancellation fees must be disclosed before booking and applied by the server per state/time (spec) | Built into state machine |
