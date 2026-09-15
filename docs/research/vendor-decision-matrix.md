# Vendor Decision Matrix — Phase 0

Date 2026-09-15 · Evidence tags and source IDs refer to [REPORT.md](REPORT.md#evidence-legend).

## Scoring method

Each vendor gets a score from 1 (poor) to 5 (excellent) on six weighted criteria. The weighted total is out of 5.00.

| Criterion | Weight | What it measures |
|---|---|---|
| **Cov** — coverage | 25% | Countries, rails, ID types or languages we need in wave 1 (NG, KE, GH, ZA, UG) |
| **Fit** — technical fit | 20% | APIs/SDKs for Flutter + web + server, webhooks, sandbox, matches spec rules |
| **Mat** — maturity | 15% | Production track record, SDK health, documented limits |
| **Cost** | 15% | Unit price at our volumes (see [cost-model.md](cost-model.md)) |
| **Comp** — compliance | 15% | DPA terms, data location, certifications, regulator standing |
| **Exit** — lock-in | 10% | How hard it is to swap behind our abstraction |

Scores are engineering judgement built on the evidence in REPORT.md. Totals are exact weighted sums. Where a recommendation doesn't follow the top total, the row says why (client decision, single-vendor risk, or a spike still pending). Items marked `[A]` in the evidence column need a vendor call before contract signature. **Rec** = the recommendation: **P** = primary, **S** = secondary/fallback, **—** = not recommended now.

---

## 1. Backend platform region (Supabase — platform fixed by client)

| Option | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `eu-west-2` London | 4 | 5 | 5 | 4 | 3 | 4 | **4.20** | **P (provisional)** | West Africa cables (MainOne, Equiano, 2Africa) land in Portugal/UK; good for Lagos and Accra [A]. Needs S-01 |
| `eu-west-3` Paris | 4 | 5 | 5 | 4 | 3 | 4 | **4.20** | S | Close to Marseille, the East Africa cable hub (SEACOM, PEACE, 2Africa); may beat London for Nairobi and Kampala [A] |
| `eu-central-1` Frankfurt | 3 | 5 | 5 | 4 | 3 | 4 | 3.95 | — | Longer path to West Africa [A] |
| `ap-south-1` Mumbai | 2 | 5 | 5 | 4 | 3 | 4 | 3.70 | — | Only interesting for East Africa; bad for Lagos |
| Self-hosted Supabase in `af-south-1` (Cape Town) or GCP `africa-south1` | 5 | 3 | 3 | 2 | 5 | 3 | 3.65 | Contingency (OD-15) | In-Africa residency; we'd run Postgres, Realtime and Auth ourselves. Only if KE/GH counsel requires in-country copies |

**Fallback:** if S-01 shows p95 RTT > 180 ms from Nairobi to London, split the traffic: keep a single primary, move Nairobi-heavy read paths to a read replica in the better region, and accept the write latency. Don't shard at launch.

## 2. Payment collection — Africa

| Vendor | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec (per country) | Evidence / notes |
|---|---|---|---|---|---|---|---|---|---|
| **Flutterwave** (v3 GA; v4 beta) | 5 | 4 | 4 | 3 | 3 | 4 | **3.95** | **P**: NG, KE, GH, UG, ZA | Cards, bank transfer, USSD, momo across NG, KE, GH, UG, ZA, RW, TZ, CI, SN, CM, ZM [V][P8][P11]. Escrow only in v2 docs [V][P9]. Default fee bearer is the customer, so it must be switched [V][P11]. Fees: NG 2% uncapped; KE cards 3.2% / M-Pesa 2.9%; UG cards 4.8% |
| **Paystack** (Stripe) | 3 | 4 | 5 | 4 | 4 | 4 | **3.90** | **S**: NG, GH, KE, ZA (+CI) | Extended network in NG, KE, GH, ZA, CI [V][P7]. NG 1.5% + ₦100, capped at ₦2,000 [S][P42b]. Split subaccounts must be same-country [V][P43]. No UG. Could be primary for NG by cost; that's a client call (OD-11) |
| Safaricom Daraja (direct M-Pesa) | 2 | 3 | 5 | 5 | 4 | 3 | 3.50 | Later (KE optimisation) | Direct STK push would cut the 2.9% gateway fee [A]. Only KE. Adds reconciliation work |
| Stripe Connect | 1 | 2 | 5 | 3 | 5 | 4 | 3.00 | **—** in Africa; **P** for the global phase | No payouts to African connected accounts [V][P5] |

Flutterwave edges Paystack on coverage; Uganda and the wider momo networks are the deciding factors, together with the client's choice of Flutterwave. Paystack wins on NG unit cost and maturity.

**Routing default (country pack):**
- NG: Flutterwave primary with Paystack failover. Evaluate Paystack-primary for tickets above ₦100k.
- KE: Flutterwave (M-Pesa) with Paystack failover.
- GH: Flutterwave, then Paystack.
- ZA: Flutterwave, then Paystack.
- UG: Flutterwave only. Single-vendor risk; UG enters `beta` only.

## 3. Payouts (provider earnings + referral withdrawals)

| Vendor | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **Flutterwave Transfers** | 5 | 4 | 4 | 4 | 3 | 4 | **4.10** | **P** | Bank + momo in wave-1 countries; ZA bank only. Fees ₦10–50, KSh 100, UGX 1,000 / 1.2%, GH₵10 / 1.5% [V][P11]. Async, webhook-driven |
| **Paystack Transfers** | 3 | 4 | 5 | 4 | 4 | 4 | 3.90 | S (NG, GH, KE, ZA) | ₦50 stamp duty on transfers ≥₦10k from Feb 2026 [S][P42b] |
| Stripe Global Payouts | 2 | 4 | 4 | 3 | 3 | 4 | 3.20 | — | US/UK platform only; we'd need our own licensing [V][P6] |

## 4. Identity verification / liveness / face match

| Vendor | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **Smile ID** | 5 | 4 | 4 | 3 | 4 | 3 | **4.00** | **P** (all wave-1) | Gov-ID lookup in NG, KE, GH, ZA, UG (+CI, ZM, ZW) [S][P19]. Fime ISO 30107-3 Level 2 PAD [S][P20]. Smile Secure 1:N dedupe [S][P20b]. Flutter v11 `smile_id` + new v12 `usesmileid`; web `@smileid/web-sdk` [V][P60]. Price sales-quoted [S][P20c] |
| Youverify | 3 | 3 | 4 | 3 | 4 | 4 | 3.40 | S (NG server-side NIN/BVN) | Nigeria-heavy; KYC/KYB/AML [S][P20d]. SDK health not checked [A] |
| Dojah | 3 | 3 | 3 | 4 | 3 | 4 | 3.25 | S (NG) | Flutter SDK has low adoption (2 likes, ~440 downloads/30 days) [V][P60] |
| QoreID | 2 | 3 | 3 | 4 | 3 | 4 | 3.00 | — | NG records focus [S][P20d] |
| Prembly | 3 | 2 | 3 | 4 | 3 | 4 | 3.05 | — | Flutter package tagged web-only, negligible adoption [V][P60] |
| Veriff / Onfido / Persona | 3 | 4 | 5 | 2 | 5 | 3 | 3.65 | Global phase | Veriff iBeta Level 2 [S]. Weaker African gov-ID lookups [A] |

**Contract must-haves (Smile ID):**
- PAD confirmation letter;
- Smile Secure scope and whether results come back per partner account;
- data location and sub-processors;
- template retention and deletion SLA;
- SmartSelfie Authentication unit price (it drives OD-13);
- SLA and status page;
- outage fallback: queue verifications, and never auto-approve.

## 5. Police-clearance verification

There is no vendor with API verification across the wave-1 countries. Only Kenya has an official online verify page, `dci.ecitizen.go.ke/verify` [V][P22].

| Approach | Rec | Notes |
|---|---|---|
| Verification Officer review of the uploaded certificate + OCR + QR decode where present (NG POSSAP QR, KE QR) | **P** (all) | Certificate numbers stored encrypted; view actions audit-logged (spec) |
| Kenya DCI online verify, done manually by an officer at launch | P (KE) | No API. Don't scrape; ask about a partner API [A] |
| Accredited background-check bureaus (ZA) | Evaluate | May offer SAPS-linked verification with consent [A] |

## 6. In-app voice calls

| Vendor | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **LiveKit Cloud** | 3 | 5 | 4 | 5 | 4 | 5 | **4.20** | **P** (client choice) | Flutter 2.13.0 + JS SDKs healthy [V][P60]. Ship $50 / Scale $500 plans [S][P24b]. African PoPs unconfirmed → S-01. Open source, so self-hosting is an exit |
| Self-hosted LiveKit (e.g. `af-south-1`) | 4 | 4 | 3 | 3 | 5 | 5 | 3.95 | Contingency | If African media latency is poor from LiveKit Cloud edges. Lower Fit/Mat because we'd run TURN, scaling and upgrades ourselves |
| Agora | 4 | 4 | 5 | 3 | 3 | 2 | 3.65 | — | Proprietary; wider PoPs [A] |

Native call UI: **`flutter_callkit_incoming` 3.1.5** (P) [V][P60]. Push: FCM data messages (high priority) + APNs VoIP.

## 7. AI voice concierge

| Option | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **LiveKit Agents + Gemini Live (`gemini-3.8-live`, Vertex)** | 3 | 4 | 3 | 4 | 4 | 4 | **3.60** | **P (English)** | Native audio, async tools on 3.8 [V][P16]. Plugin tested docs on 2.5/3.1 [V][P18]. **No Pidgin on the Live language list** [V][P16] |
| LiveKit Agents cascade: Gemini 3.5 Transcribe / Chirp 3 STT → Gemini Flash → Gemini TTS / Chirp 3 HD | 4 | 4 | 3 | 4 | 4 | 5 | **3.95** | **P (Pidgin, if it passes S-08)** / S (English) | More latency (+300–500 ms) [S], but each stage can be swapped. Pidgin STT accuracy unknown [A] |
| African-language speech vendors (e.g. local Nigerian ASR startups) | 4 | 2 | 2 | 3 | 3 | 4 | 3.00 | Evaluate in S-08 | Not verified this session [A] |

The cascade scores higher because it degrades gracefully and every stage can be swapped. Gemini Live stays primary for English only because the voice experience depends on latency and naturalness, which this matrix doesn't weight. S-08 decides: if the cascade's p95 turn latency is within 1.5 s, the cascade may become primary for both languages.

## 8. PSTN masked-call fallback

| Vendor | Cov | Fit | Mat | Cost | Comp | Exit | **Total** | Rec | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **Infobip Number Masking** | 4 | 5 | 5 | 3 | 4 | 3 | **4.10** | **P** | Purpose-built masking API [V][P25c]; confirm NG, KE, GH, ZA, UG number supply [A] |
| **Africa's Talking Voice** | 4 | 3 | 4 | 4 | 4 | 4 | **3.80** | **S** | Voice in KE, GH, NG, RW, ZA, UG, TZ, ZM; KE number KSh 5,000 + 2,000/month [S][P25b]. Masking built from transfer/bridge |
| Twilio | 2 | 4 | 5 | 2 | 4 | 3 | 3.25 | — | Proxy closed to new customers [S][P25]; African DID supply limited [A] |

## 9. SMS / OTP (via Supabase Send SMS Hook)

| Vendor | NG | KE | GH | ZA | UG | Rec | Notes |
|---|---|---|---|---|---|---|---|
| **Termii** | **P** | S | S | — | — | NG primary | DND route + WhatsApp OTP [S][P24d] |
| **Africa's Talking** | S | **P** | P | P | **P** | East Africa primary | KE ~KSh 0.80/SMS [S][P24e] |
| **Infobip** | S | S | S | P | S | Global fallback | [A] |
| WhatsApp OTP (Meta auth templates via Termii/Infobip) | opt-in | opt-in | opt-in | opt-in | opt-in | User choice | Lower cost at scale [A] |

Final pick per country after the S-09 delivery test (≥95% delivered in <30 s on every MNO).

## 10. SOS partners

| City / country | Partner | Rec | Integration | Evidence |
|---|---|---|---|---|
| Johannesburg, Cape Town, Durban (ZA) | **AURA** | P | API / SDK / dispatch portal | [S][P26] |
| Nairobi (KE) | **AURA** (security) + **Rescue.co** (medical) | P + P | API | [S][P26][P27] |
| Accra (GH) | **AURA** | P | API | [S][P37] |
| Kampala (UG) | **Rescue.co** | P | API | [S][P27] |
| Lagos, Abuja (NG) | Halogen / Emergency Response Africa (SIGNAL) → RFP | P (contract), phone-bridge first | Dispatch console + phone escalation; API later | [S][P28] |

## 11. LLM (Gemini via Vertex — client choice)

| Workload | Model (config) | Fallback | Notes |
|---|---|---|---|
| Concierge (text) | `gemini-3.8-flash` (promo pricing until 31 Dec 2026), then re-evaluate vs `gemini-3.5-flash` | `gemini-3.1-pro` on escalation | [V][P14][P17] |
| Admin assistant | `gemini-3.1-pro` | `gemini-3.8-flash` | Predefined tools only |
| Moderation, classification, triage | `gemini-3.1-flash-lite` | `gemini-3.5-flash-lite` | |
| Receipts (vision) | `gemini-3.5-flash` | `gemini-3.8-flash` | |
| Embeddings | `gemini-embedding-001` → Embedding 2 when GA on Vertex | — | pgvector dimension fixed per model; re-embed on change |
| Voice | `gemini-3.8-live` | Cascade (§7) | |

## 12. Maps, places and routing

| Option | Rec | Notes |
|---|---|---|
| Google Maps SDK (mobile dynamic maps: unlimited free under Mar 2025 pricing) | **P** (mobile maps) | [S][P66] |
| Google Places (Autocomplete + Details) | **P** (address search) | Best POI/landmark coverage in African cities [A]; 10k free Essentials events/SKU/month, then paid |
| Google Routes | S | ~$5/1k; costly for frequent ETA refresh |
| Self-hosted OSRM/Valhalla on OpenStreetMap (Cloud Run) | **P** (ETA refresh, matching distances) | Cuts the ~$27k/month Routes/Places line at 1M MAU (cost model) [A] |
| MapLibre (`maplibre_gl` 0.27.1) + OSM tiles | S (web / low-data mode) | [V][P60] |

## 13. Other platform services

| Need | Primary | Secondary | Notes |
|---|---|---|---|
| Push | FCM (Android/web) + APNs (iOS, VoIP) | — | Free |
| Email | Amazon SES | Resend / Postmark | Transactional only on this sender |
| Errors / crashes | Sentry | Firebase Crashlytics | `sentry_flutter` 9.30.0, `@sentry/nextjs` 10.74.0 [V][P60] |
| Product analytics | PostHog (EU cloud) | Firebase Analytics | EU hosting fits OD-15; no PII in events |
| BI | BigQuery + Looker Studio | Metabase | Spec |
| WAF / bot | Cloudflare (Pro → Business → Enterprise) | — | Turnstile for signup/OTP CAPTCHA |
| RASP | freeRASP 8.2.2 (free tier) | Talsec commercial (AppiCrypt) | Check the fair-usage terms of the free tier at scale [A] |
| Device integrity | Play Integrity + App Attest via a thin platform channel | — | `app_device_integrity` stale [V][P60]. Play Integrity's default daily quota needs a raise before launch [A] |
| Background location | `flutter_foreground_task` 11.0.3 + `geolocator` 14.0.3 | `flutter_background_geolocation` 5.7.0 (paid licence) | Decide after S-04 on Transsion devices |

---

## Packages

Registry snapshot 2026-09-15 (pub.dev / npm / PyPI APIs) [V][P60]. "Pts" = pub points out of 160; "DL30" = downloads in the last 30 days.

### Flutter (pub.dev)

| Package | Version | Published | Publisher | Pts | Likes | DL30 | Licence | Verdict |
|---|---|---|---|---|---|---|---|---|
| supabase_flutter | 2.17.2 | 2026-08-14 | supabase.io | 150 | 977 | 968k | MIT | ✅ |
| livekit_client | 2.13.0 | 2026-09-15 | livekit.io | 150 | 270 | 159k | Apache-2.0 | ✅ |
| flutter_callkit_incoming | 3.1.5 | 2026-08-11 | hiennv.com | 160 | 514 | 115k | MIT | ✅ |
| firebase_messaging | 16.7.0 | 2026-09-14 | firebase.google.com | 160 | 3,947 | 3.18M | BSD-3 | ✅ |
| flutter_local_notifications | 22.3.1 | 2026-09-13 | dexterx.dev | 150 | 7,345 | 2.77M | BSD-3 | ✅ |
| geolocator | 14.0.3 | 2026-06-12 | baseflow.com | 160 | 6,127 | 2.27M | MIT | ✅ |
| google_maps_flutter | 2.18.0 | 2026-07-23 | flutter.dev | 150 | 4,628 | 900k | BSD-3 | ✅ |
| flutter_background_geolocation | 5.7.0 | 2026-09-04 | transistorsoft.com | 160 | 844 | 52k | Apache-2.0 + **paid release licence** | ⚠️ cost |
| flutter_foreground_task | 11.0.3 | 2026-09-07 | pravera.me | 150 | 583 | 201k | MIT | ✅ |
| smile_id (v11) | 11.2.13 | 2026-09-10 | smileidentity.com | 130 | 13 | 11k | MIT | ✅ / compare |
| usesmileid (v12) | 12.1.1 | 2026-09-08 | smileidentity.com | — | — | — | — | ⚠️ brand new → S-05 |
| freerasp | 8.2.2 | 2026-08-26 | talsec.app | 160 | 610 | 46k | MIT | ✅ |
| local_auth | 3.0.2 | 2026-07-09 | flutter.dev | 160 | 3,376 | 1.34M | BSD-3 | ✅ |
| app_links | 7.2.1 | 2026-07-09 | cow-level.ovh | 160 | 1,319 | 2.60M | Apache-2.0 | ✅ |
| camera | 0.12.1 | 2026-09-03 | flutter.dev | 160 | 2,599 | 588k | BSD-3 | ✅ |
| image_picker | 1.2.3 | 2026-06-30 | flutter.dev | 160 | 7,762 | 4.28M | Apache/BSD | ✅ |
| flutter_image_compress | 2.5.1 | 2026-07-25 | fluttercandies.com | 150 | 1,821 | 1.02M | MIT | ✅ |
| sentry_flutter | 9.30.0 | 2026-09-10 | sentry.io | 140 | 1,084 | 1.55M | MIT | ✅ |
| widgetbook | 3.25.0 | 2026-06-25 | widgetbook.io | 160 | 797 | 506k | MIT | ✅ |
| patrol | 4.10.0 | 2026-09-15 | leancode.co | 150 | 723 | 587k | Apache-2.0 | ✅ |
| flutter_secure_storage | 11.1.1 | 2026-09-11 | steenbakker.dev | 160 | 4,488 | 4.16M | BSD-3 | ✅ |
| drift | 2.35.0 | 2026-09-09 | simonbinder.eu | 160 | 2,466 | 1.26M | MIT | ✅ |
| riverpod / flutter_riverpod | 3.4.3 | 2026-09-03 | dash-overflow.net | 160/140 | 4,030/2,908 | 3.2M | MIT | ✅ |
| go_router | 18.0.1 | 2026-09-02 | flutter.dev | 150 | 5,780 | 4.11M | BSD-3 | ✅ |
| freezed | 4.0.1 | 2026-08-29 | dash-overflow.net | 160 | 4,522 | 2.71M | MIT | ✅ |
| json_serializable | 6.14.1 | 2026-07-30 | google.dev | 160 | 3,954 | 3.56M | BSD-3 | ✅ |
| connectivity_plus | 7.3.1 | 2026-07-23 | fluttercommunity.dev | 160 | 4,093 | 3.45M | BSD-3 | ✅ |
| screen_protector | 1.5.3 | 2026-07-14 | inteniquetic.com | 150 | 324 | 111k | Apache-2.0 | ✅ (screenshot/app-switcher blur) |
| no_screenshot | 2.0.1 | 2026-08-08 | flutterplaza.com | 160 | 289 | 115k | BSD-3 | ✅ alt |
| safe_device | 1.4.1 | 2026-07-07 | ufuksahin.dev | 140 | 382 | 149k | MIT | Supplement only (mock-location signal) |
| detect_fake_location | 2.3.2 | 2026-01-25 | zeexan.com | 140 | 41 | 3k | BSD-3 | Low adoption; prefer a native `isMock` check |
| flutter_stripe | 14.0.0 | 2026-08-14 | flutterstripe.io | 160 | 1,533 | 269k | MIT | Global phase only |
| maplibre_gl | 0.27.1 | 2026-09-10 | maplibre.org | 160 | 128 | 106k | BSD-3 | ✅ (low-data mode) |
| flutterwave_standard | 1.1.0 | 2025-04-11 | *(none)* | 140 | 68 | 3k | MIT | ❌ use hosted checkout link |
| dojah_kyc_sdk_flutter | 0.1.17 | 2026-09-11 | dojah.io | 130 | 2 | 438 | MIT | ⚠️ low adoption |
| prembly_identity_kyc | 0.0.6 | 2026-09-15 | *(none)* | 130 | 0 | 32 | MIT | ❌ |
| app_device_integrity | 1.1.0 | 2024-12-11 | bubotech.co | 150 | 36 | 1.6k | MIT | ❌ stale |
| background_locator_2 | 2.0.6 | 2023-03-08 | *(none)* | 120 | 146 | 427 | MIT | ❌ abandoned |

### npm and PyPI

| Package | Version | Published | Licence | Verdict |
|---|---|---|---|---|
| @supabase/supabase-js | 2.116.0 | 2026-09-07 | MIT | ✅ |
| @supabase/ssr | 0.12.7 | 2026-09-08 | MIT | ✅ (still 0.x → pin exact) |
| livekit-client | 2.22.3 | 2026-09-07 | Apache-2.0 | ✅ |
| @livekit/components-react | 2.9.24 | 2026-08-11 | Apache-2.0 | ✅ |
| livekit-server-sdk | 2.19.0 | 2026-09-09 | Apache-2.0 | ✅ (token minting in Edge Functions) |
| @livekit/agents / -plugin-google | 1.9.0 | 2026-09-15 | Apache-2.0 | ✅ |
| livekit-agents / livekit-plugins-google (PyPI) | 1.8.2 | — | Apache-2.0 | ✅ (voice worker is Python per spec) |
| @smileid/web-sdk | 12.0.4 | 2026-09-15 | — | ✅ (confirm licence) |
| @smileid/web-components | 11.6.2 | 2026-07-23 | — | Alt |
| smile-identity-core | 3.2.1 | 2026-06-24 | MIT | ✅ (server) |
| flutterwave-node-v3 | 1.4.1 | 2026-06-17 | MIT | Optional; a thin typed REST client is preferable in Deno |
| stripe / @stripe/stripe-js | 22.6.2 / 9.16.0 | 2026-09-09 | MIT | Global phase |
| next | 16.3.5 | 2026-09-11 | MIT | ✅ |
| @tanstack/react-query | 5.102.8 | 2026-08-27 | MIT | ✅ |
| zod | 4.6.5 | 2026-09-13 | MIT | ✅ |
| standardwebhooks | 1.1.1 | 2026-08-28 | MIT | ✅ (Send SMS Hook signature) |
| @sentry/nextjs | 10.74.0 | 2026-09-09 | MIT | ✅ |
| posthog-js | 1.433.5 | 2026-09-15 | Apache-2.0 + MIT | ✅ |
| google-genai (PyPI) | 2.23.0 | — | Apache-2.0 [A] | ✅ (AI service) |
| fastapi (PyPI) | 0.141.1 | — | MIT | ✅ |
