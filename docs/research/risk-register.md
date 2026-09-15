# Risk Register — Phase 0

Date 2026-09-15 · Maintained by Claude Code; review at every phase checkpoint.

## How to read this register

- **Score = L × I.** L (likelihood) and I (impact) are each rated 1–5.

| Score | Band |
|---|---|
| ≥ 15 | 🔴 Critical |
| 8–14 | 🟠 High |
| 4–7 | 🟡 Medium |
| ≤ 3 | 🟢 Low |

- **Owner codes:** CC = Claude Code, KC = Kimi Code, CL = client, LG = counsel, FO = finance/ops.
- **Link** points to a spike in [spike-plan.md](spike-plan.md) (S-xx) or an open decision (OD-xx) in [CHECKPOINT-PHASE-0.md](CHECKPOINT-PHASE-0.md).

## Summary

| Band | Count | IDs |
|---|---|---|
| 🔴 Critical | 8 | R-01 – R-07, R-12 |
| 🟠 High | 16 | R-08 – R-11, R-13 – R-24 |
| 🟡 Medium | 6 | R-25 – R-30 |

## Register

| ID | Risk | Cat. | L | I | Score | Owner | Mitigation | Early indicator | Link |
|---|---|---|---|---|---|---|---|---|---|
| R-01 | **Regulatory block on holding customer funds** in a country (CBN, CBK, BoG, BoU, SARB/PASA), forcing a redesign of paid-upfront | Legal / money | 3 | 5 | 🔴 15 | CL + LG | Counsel opinion per country before go-live; gateway merchant balance + collection-agent terms; ZA TPPP registration; ledger designed so the "hold" can move to a bank-partner account without app changes | Counsel flags; gateway KYB questions | OD-12 |
| R-02 | **Stripe can't serve African payouts**; the client expects "Stripe" in the stack | Vendor / money | 5 | 3 | 🔴 15 | CL + CC | Paystack (Stripe-owned) as the second African rail; Stripe Connect only for global markets; `PaymentProvider` abstraction | Client decision on OD-11 | OD-11 |
| R-03 | **Pidgin voice concierge fails quality** (Live API doesn't list `pcm`) | AI | 4 | 4 | 🔴 16 | CC | Eval gate S-08; cascade STT → LLM → TTS; ship Pidgin text + English voice if the gate fails | WER/intent accuracy below threshold in S-08 | S-08, OD-17 |
| R-04 | **KYC and ongoing selfie-check costs** exceed unit economics (daily vendor checks ≈ 15% of revenue at 1M MAU) | Cost | 4 | 4 | 🔴 16 | CL + CC | OD-13 on-device daily + weekly vendor check; volume commit with Smile ID; verify customers only before first publish/pay (spec) | Quote > $0.05/auth | OD-13, cost model |
| R-05 | **Off-platform leakage** (cash "offline trips"; no-cash rule) erodes GMV and removes safety cover | Market | 4 | 4 | 🔴 16 | CL + CC + KC | Moderation of numbers/accounts in chat; masked calls; safety value only on-platform; provider tiers and rewards; risk rule for repeat customer–provider pairs with cancellations | Cancellation-after-chat rate; repeat pairs with no jobs | — |
| R-06 | **Latency from Africa to EU-hosted Supabase** breaks the RPC p95 300 ms and realtime 1 s targets | Architecture | 3 | 5 | 🔴 15 | CC | S-01 region choice; one round trip per user action (RPC composes server-side); Broadcast for location; edge caching of read-mostly config; optimistic UI with server reconciliation | S-01 p95 > 180 ms RTT | S-01 |
| R-07 | **Data-residency requirement** (KE local copy; GH biometric localisation bill) conflicts with no Supabase Africa region | Legal / arch | 3 | 5 | 🔴 15 | LG + CC | Vendor-side biometrics; encrypted KYC files; costed self-host fallback in `af-south-1`/`africa-south1`; country go-live gate G3 | Counsel opinion; GH Bill passage | OD-15 |
| R-08 | Incoming VoIP calls fail with the app killed (iOS PushKit/CallKit, Android OEM restrictions) | Mobile | 3 | 4 | 🟠 12 | KC + CC | Spike S-03 on the device matrix; PSTN masked fallback; missed-call push + chat message | Answer rate < 90% in S-03 | S-03 |
| R-09 | Provider background location killed by Transsion (Tecno/Infinix/itel, ~48% of African handsets) battery management | Mobile | 4 | 3 | 🟠 12 | KC | FGS with `location` type; guided OEM settings screen; server staleness detection → prompt; S-04 | Ping gaps > 2 min on test devices | S-04 |
| R-10 | Liveness SDK crashes or is slow on 2 GB RAM devices (Smile ID v12 is days old) | Mobile / KYC | 3 | 4 | 🟠 12 | KC + CC | S-05 benchmark v11 vs v12; web fallback for customers; retry UX | OOM/ANR in S-05 | S-05 |
| R-11 | PostGIS nearest-provider query misses 50 ms p95 at 100k providers | Backend | 2 | 4 | 🟠 8 | CC | GiST/SP-GiST on geography, H3/geohash pre-bucketing, partial index on online providers; separate hot table for live positions | S-06 p95 | S-06 |
| R-12 | Race conditions in offer acceptance → double booking or double charge | Backend | 3 | 5 | 🔴 15 | CC | Row lock on the request, idempotency keys, single-transaction accept; pgTAP concurrency tests | S-10 duplicate count > 0 | S-10 |
| R-13 | Realtime quotas: at 1M MAU ~60k peak connections vs 10k Team limit; message costs from tracking | Scale / cost | 4 | 3 | 🟠 12 | CC | Enterprise quota negotiation at 100k MAU; channel design (one channel per job, not per user); sparse pings when idle; S-11 load test | Peak connections > 5k | S-11 |
| R-14 | Webhook spoofing/replay or missed webhooks → false "paid" or stuck jobs | Security / money | 2 | 5 | 🟠 10 | CC | Signature verify + store raw + dedupe + server verify call + reconciliation; payment TTL watchdog | Reconciliation mismatches | — |
| R-15 | Referral fraud rings (fake accounts, collusion, self-referral) drain the platform | Fraud | 4 | 3 | 🟠 12 | CC | Single-level only; 72 h hold; device/face/payout/card de-dupe; velocity limits; review queue; campaign budget caps | Referral earnings per referrer outliers | — |
| R-16 | Police-clearance cost and validity (NG ₦30k, 3 months) choke provider supply | Supply | 4 | 3 | 🟠 12 | CL | OD-09 recency/renewal policy; partner with a police-clearance agent for bulk processing [A]; show status tracker | Onboarding drop-off at the PCC step | OD-09 |
| R-17 | OTP delivery failures (NG DND, sender-ID approval delays) block sign-up | Messaging | 3 | 4 | 🟠 12 | CC + CL | Start sender-ID/DND registration in Phase 1; multi-provider failover in the Send SMS Hook; WhatsApp OTP | Delivery < 95% in S-09 | S-09 |
| R-18 | Gemini model churn/deprecation (2-week notice) or promo price expiry (3.7/3.8 Flash on 31 Dec 2026) raises cost or breaks prompts | AI | 4 | 3 | 🟠 12 | CC | Model IDs in remote config; eval suite gates every model swap; cost alerts per feature | Deprecation notice; spend spike | S-07 |
| R-19 | Prompt injection via user content makes the concierge take unauthorised actions | AI security | 3 | 4 | 🟠 12 | CC | Tools authorised server-side per user; user content as data; structured outputs validated; red-team suite in CI | Red-team failures | S-07 |
| R-20 | SOS partner unavailable in Nigeria at launch (no API partner confirmed) | Safety | 3 | 4 | 🟠 12 | CL + CC | Ops console as the always-on first line; contracted dispatch with phone escalation; show local emergency numbers | No signed partner by Phase 6 | — |
| R-21 | Flutterwave single-vendor dependency in Uganda (no Paystack) | Vendor | 3 | 3 | 🟠 9 | CC | UG stays in beta; evaluate a direct MTN/Airtel MoMo API or another aggregator | FW incidents | — |
| R-22 | Payment gateway outage during peak → PAYMENT_PENDING TTL expiries and lost jobs | Vendor | 3 | 3 | 🟠 9 | CC | Dual gateway routing with failover (NG/KE/GH/ZA); extend TTL on known incidents via remote config | Gateway status page | — |
| R-23 | Provider classification as employees (ZA proposal; future elsewhere) | Legal | 2 | 5 | 🟠 10 | LG | Provider terms reviewed; avoid control indicators (no forced acceptance, providers set prices by negotiation) | Bill progress | — |
| R-24 | App-store rejection (FSI, FGS video, background location, precise-location declaration due 27 Jan 2027, VoIP misuse) | Release | 3 | 4 | 🟠 12 | KC + CC | Compliance checklist A1–A9; prepare demo videos early; review mode with demo accounts | Pre-review feedback | — |
| R-25 | Currency volatility (NGN) makes quotes stale between offer and payment | Money | 3 | 2 | 🟡 6 | CC | Short offer and payment TTLs; single-currency jobs; no FX at launch | — | — |
| R-26 | KYC vendor outage blocks onboarding | Vendor | 2 | 3 | 🟡 6 | CC | Queue and retry; never auto-approve; NG server-API fallback (Youverify/Dojah) | Vendor status | — |
| R-27 | Package risk: paid licence (`flutter_background_geolocation`), stale packages (`flutterwave_standard`, `app_device_integrity`) | Supply chain | 3 | 2 | 🟡 6 | KC | Use the alternatives listed in the vendor matrix; licence scan in CI | — | — |
| R-28 | Maps/Places cost at scale (~$27k/month at 1M MAU) | Cost | 3 | 2 | 🟡 6 | CC | Self-hosted OSRM/Valhalla for ETAs; cache geocodes; session tokens for Autocomplete | Monthly bill | — |
| R-29 | LiveKit Cloud has no African edge → poor call quality | Voice | 2 | 3 | 🟡 6 | CC | S-01 media RTT test; self-hosted LiveKit in `af-south-1` as an exit (open source) | Jitter > 30 ms, loss > 3% | S-01 |
| R-30 | Kimi's mock-first UI embeds client-side business logic that must move server-side, delaying integration | Delivery | 3 | 2 | 🟡 6 | CC + KC | Phase 1 review of `contracts/draft/`; UI change list in HANDOFF.md; audit checklist | Draft contains price calculations | — |
