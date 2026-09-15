# Spike Plan — technical de-risking before and during Phase 1

Date 2026-09-15.

**What a spike is:** a time-boxed experiment that answers one question with measurements. Spike code is **throwaway**. It lives on `spike/*` branches under a top-level `spikes/` folder, never in `apps/`, `supabase/` or `services/`, and is deleted after the results are recorded. Results go to `docs/research/spikes/S-xx-results.md` and feed the Phase 1 ADRs.

**Owner codes:** CC = Claude Code, KC = Kimi Code, CL = client.

The six spikes required by the spec are **S-03, S-04, S-05, S-06, S-10 and S-11**. The other six come from Phase 0 findings.

## Summary and order

| ID | Spike | Answers | Owner | Effort | Blocks | Priority |
|---|---|---|---|---|---|---|
| S-01 | Region and media latency from African cities | Supabase region; LiveKit edge quality | CC | 3 d | ERD region, OD-15 | P0 |
| S-02 | Supabase capability check on the target plan | Extensions, hooks, Queues, Realtime auth | CC | 2 d | Phase 2 | P0 |
| S-03 | **VoIP incoming call with the app killed** (iOS + Android) | Can calls ring reliably? | KC + CC | 5 d | M4 calls | P0 |
| S-04 | **Provider background location on low-end Android** (Tecno/Infinix/itel) | Can we track reliably and cheaply? | KC | 5 d | Plugin choice (paid vs free) | P0 |
| S-05 | **Liveness SDK on 2 GB RAM devices** (Smile ID v11 vs v12) | Which SDK and version; crash/latency profile | KC + CC | 3 d | M2 KYC | P0 |
| S-06 | **PostGIS nearest-provider query at 100k providers** | Index and table design for p95 ≤ 50 ms | CC | 3 d | ERD | P1 |
| S-07 | Gemini eval harness (Vertex) | Model IDs, region, tool use, Pidgin text, cost | CC | 4 d | AI design | P1 |
| S-08 | Voice concierge: Gemini Live vs cascade, English + Pidgin | OD-17 gate | CC | 5 d | Voice scope | P1 |
| S-09 | SMS/OTP delivery per country and MNO | Provider routing | CC + CL | 3 d (+ sender-ID wait) | Auth | P1 |
| S-10 | **Concurrent offer acceptance** | Zero double-booking under contention | CC | 2 d | Negotiation functions | P1 |
| S-11 | **Realtime load for location broadcast** | Channel design, quotas, cost | CC | 3 d | Tracking design | P1 |
| S-12 | Payment hold → payout end-to-end in sandboxes | Flutterwave/Paystack flows, webhooks, refunds | CC | 4 d | Money design | P0 |

**Device matrix for S-03, S-04 and S-05** (buy or rent; OEM builds matter more than OS version):
- **Tecno Spark** (2–3 GB);
- **Infinix Hot/Smart** (2–3 GB);
- **itel A-series** (2 GB, Android Go);
- Samsung Galaxy A0x/A1x;
- Pixel (reference);
- iPhone SE 2nd gen / iPhone 11 (older) + a current iPhone.

Test on real MTN, Airtel, Safaricom and Glo SIMs in 3G and throttled-4G conditions.

---

## S-01 — Region and media latency

- **Question:**
  1. Which Supabase region (London `eu-west-2`, Paris `eu-west-3`, Frankfurt `eu-central-1`, Ireland `eu-west-1`, Mumbai `ap-south-1`) gives the best p95 RTT and RPC latency from Lagos, Accra, Nairobi, Kampala and Johannesburg (plus Cairo, per the spec)?
  2. How does LiveKit Cloud perform from the same cities?
- **Setup:** free-tier Supabase projects in each candidate region, each with one trivial RPC and one PostGIS query. Test clients:
  - cloud VMs in Lagos/Johannesburg where available;
  - residential/mobile vantage points (RIPE Atlas probes, or testers on real mobile SIMs with a small probe app);
  - a LiveKit Cloud project with an audio-only room.
- **Method:**
  - 1,000 HTTPS RPC calls per region per vantage point at different times of day;
  - Realtime broadcast round trip;
  - LiveKit: join time, RTT, jitter and packet loss via `ConnectionCheck`/stats, on Wi-Fi and 4G.
- **Pass criteria:**
  - chosen region: RPC p95 ≤ 250 ms from Lagos and Nairobi on 4G;
  - realtime broadcast p95 ≤ 600 ms;
  - LiveKit jitter < 30 ms and loss < 3% on 4G.
- **Output:** region ADR; update to vendor matrix §1; LiveKit go / self-host decision.

## S-02 — Supabase capability check

- **Question:** Does the chosen plan give us everything the spec assumes?
- **Checklist:**
  - Extensions enabled: `postgis`, `vector`, `pg_cron`, `pgmq` (Queues), `pgtap`, `pg_partman`, `pg_net`, `supabase_vault`.
  - Auth hooks: Send SMS Hook (HTTP) and Custom Access Token Hook.
  - TOTP MFA; CAPTCHA (Turnstile).
  - Realtime Authorization with `realtime.broadcast_changes()` on a private channel.
  - Storage: signed upload URLs with no read policy for `kyc-docs`.
  - Read-replica availability in the chosen region.
  - Log drains; security and performance advisors via CLI in CI.
  - Point-in-time recovery restore drill.
- **Pass criteria:** every item works, or has a documented workaround. **pgsodium is not used** (pending deprecation) [V].
- **Output:** ADR "Supabase platform baseline"; migration conventions.

## S-03 — VoIP incoming call with the app killed

- **Question:** Do incoming calls ring natively with the app killed, backgrounded or locked, on iOS and on the Android device matrix?
- **Setup:** a minimal Flutter app with `livekit_client` 2.13.0 + `flutter_callkit_incoming` 3.1.5, a PushKit VoIP certificate or token, FCM high-priority data messages, and an Edge-Function-style token minting stub.
- **Method:** 50 calls per device per state (killed, background, locked, Doze after 1 h idle, battery saver on). Measure:
  - ring rate;
  - time from push to ring;
  - time from answer to audio;
  - behaviour when the full-screen-intent permission is denied (Android 14+).
- **Pass criteria:**
  - iOS ring rate ≥ 99%, with every VoIP push reported to CallKit;
  - Android ring rate ≥ 95% on the matrix, with a heads-up fallback when FSI is denied;
  - answer-to-audio ≤ 2 s on 4G.
- **Output:** calls implementation notes for Kimi; PSTN-fallback trigger thresholds; the Play FSI declaration text.

## S-04 — Provider background location on low-end Android

- **Question:** Can an online provider stream location for 8 h on Tecno, Infinix and itel without being killed, within an acceptable battery budget?
- **Variants:**
  - (a) `flutter_foreground_task` 11.0.3 + `geolocator` 14.0.3 (free);
  - (b) `flutter_background_geolocation` 5.7.0 (paid licence; motion-activity based);
  - (c) a small native FGS.
- **Method:** 8 h shifts with a scripted route and idle periods. Measure:
  - gap distribution (> 60 s, > 120 s);
  - battery % per hour;
  - data usage;
  - behaviour after the OEM "auto-launch/background" settings are applied via the guided screen;
  - mock-location detection (`isMock`).
- **Pass criteria:**
  - gaps > 120 s in < 1% of intervals while en route;
  - battery ≤ 6%/h en route and ≤ 2%/h idle;
  - data ≤ 5 MB/h.
- **Output:** plugin decision (budget the licence if (b) wins); adaptive interval policy; OEM settings guide content.

## S-05 — Liveness SDK on 2 GB RAM devices

- **Question:** Which Smile ID Flutter SDK (v11 `smile_id` 11.2.13 vs v12 `usesmileid` 12.1.1) is stable and fast on itel/Tecno 2 GB devices? What does each add to APK size?
- **Method:** 30 SmartSelfie enrolments + 30 authentications + 10 document captures per device, in poor light and on a slow network. Measure:
  - crash/ANR/OOM;
  - time to result;
  - retries;
  - memory peak (`adb shell dumpsys meminfo`);
  - per-ABI download size delta.
  - Also test the web flow with `@smileid/web-sdk` 12.0.4 on low-end Android Chrome.
- **Pass criteria:**
  - zero OOM;
  - p90 capture-to-submit ≤ 20 s;
  - APK delta ≤ 8 MB per ABI (we hold a 35 MB budget);
  - pass rate ≥ 90% for genuine users.
- **Output:** SDK version ADR; vendor questions (PAD letter, Smile Secure scope, auth price).

## S-06 — PostGIS nearest-provider query at 100k providers

- **Question:** What design returns the top-N eligible providers within radius R with p95 ≤ 50 ms at 100k providers (30k online)?
- **Variants:**
  - (a) `geography(Point)` + GiST + partial index `WHERE online`;
  - (b) a separate hot `provider_live_location` table (UNLOGGED vs logged) updated by the heartbeat RPC;
  - (c) an H3/geohash bucket column + B-tree prefilter, then exact distance;
  - (d) SP-GiST.
- **Method:** synthetic providers clustered to match Lagos and Nairobi density; filters on service type, vehicle type, trust level and not-blocked; pgbench at 200 concurrent queries while 30k heartbeats/min write. Test on the planned compute size.
- **Pass criteria:** p95 ≤ 50 ms and p99 ≤ 120 ms with concurrent writes; no autovacuum stalls.
- **Output:** schema and index ADR; heartbeat interval.

## S-07 — Gemini eval harness (Vertex)

- **Questions:**
  1. Exact Vertex model IDs and availability in `europe-west*` and `africa-south1`.
  2. Tool-calling accuracy on our concierge tools (create draft request, classify, estimate price band, find providers, compare offers, check job status).
  3. English and Pidgin *text* understanding.
  4. Latency and cost per turn with context caching.
  5. Prompt-injection resistance.
- **Method:** a golden set of 150 conversations (75 English, 75 Pidgin, written or reviewed by native speakers), 50 red-team prompts, and a Lagos/Nairobi address and landmark set. Run each candidate model: `gemini-3.8-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`, `gemini-3.1-pro`.
- **Pass criteria:**
  - task success ≥ 90% in English and ≥ 85% in Pidgin;
  - zero unauthorised tool calls;
  - p95 first token ≤ 1.5 s from the EU region;
  - cost within the cost-model budget.
- **Output:** model routing table (remote config defaults); eval suite checked into CI in Phase 7.

## S-08 — Voice concierge: Gemini Live vs cascade (English + Pidgin)

- **Question:** Does `gemini-3.8-live` through LiveKit Agents (`livekit-agents` 1.8.2, Vertex auth) understand and speak Nigerian Pidgin well enough? If not, does the cascade (`gemini-3.5-transcribe` or Chirp 3 → Flash → `gemini-3.1-flash-tts` or Chirp 3 HD) do better?
- **Method:**
  - 40 scripted voice tasks per language recorded by 10+ speakers (Lagos, Port Harcourt, Kano and Abuja accents);
  - noisy-street and low-bitrate variants;
  - measure WER (with a human-scored Pidgin transcript), intent/slot accuracy, turn latency (end of speech → first audio), naturalness MOS from native listeners, and cost per minute;
  - check that the plugin accepts the 3.8 Live model ID and async tools.
- **Pass (gate for OD-17):**
  - Pidgin slot accuracy ≥ 85%;
  - turn latency p95 ≤ 1.5 s (Live) or ≤ 2.2 s (cascade);
  - MOS ≥ 3.5.
- **Output:** voice architecture ADR; OD-17 recommendation.

## S-09 — SMS/OTP delivery

- **Question:** Which provider delivers OTPs fastest and most reliably per country and MNO?
- **Pre-work (start now — takes weeks):** Nigeria sender-ID registration + DND-route whitelisting (CAC certificate, address, samples, website) [S].
- **Method:** 200 OTPs per MNO per provider at peak and off-peak, including DND-registered NG numbers, sent through a prototype Send SMS Hook with failover. Also test WhatsApp OTP.
- **Pass criteria:** ≥ 95% delivered within 30 s; ≥ 99% within 120 s including failover.
- **Output:** `otp_routing` per country pack.

## S-10 — Concurrent offer acceptance

- **Question:** Does the accept-offer transaction guarantee exactly one accepted offer and one payment intent under contention and retries?
- **Method:**
  - pgTAP + a parallel harness: 500 races with the customer double-tapping, two devices, network retries using the same idempotency key, a provider withdrawing the offer at the same moment, and offer TTL expiring mid-transaction;
  - `SELECT … FOR UPDATE` on the request row versus optimistic version checks;
  - check the emitted realtime events.
- **Pass criteria:**
  - zero double accepts;
  - idempotent replays return the same result;
  - other offers expired in the same transaction;
  - events emitted exactly once, via the outbox.
- **Output:** negotiation function design; the test becomes a permanent CI test in Phase 3.

## S-11 — Realtime load for location broadcast

- **Question:** Can Supabase Realtime Broadcast carry live tracking for 10k concurrent active jobs, and what is the cost per job?
- **Method:**
  - k6 with a WebSocket extension (or the Realtime client in Node workers) simulating providers publishing to private `job:{id}` channels every 5 s, and customers subscribed;
  - authorization via RLS on `realtime.messages`;
  - measure delivery p95, drop rate, reconnect storms after a simulated network flap, joins per second, and message count against billing;
  - compare with a persisted-sample-every-30 s write path.
- **Pass criteria:**
  - delivery p95 ≤ 1 s (spec);
  - < 0.5% drops;
  - reconnect storm of 10k clients recovers in < 60 s within the join-rate quota.
- **Output:** channel naming and authorization contract (`realtime-events`); ping cadence; the Enterprise quota request trigger.

## S-12 — Payment hold → payout end to end

- **Question:** Does "collect to merchant balance → hold in ledger → transfer to provider / refund to customer" work end to end in the Flutterwave v3 and Paystack sandboxes, with correct fees and webhooks?
- **Method:**
  - card, M-Pesa (KE), MTN MoMo (GH/UG) and NG bank-transfer collections with the fee bearer set to merchant;
  - verify endpoint after webhook; webhook replay and out-of-order delivery; duplicate event IDs;
  - partial refund; transfer to bank and momo; transfer failure and reversal;
  - a reconciliation report pull;
  - extract the actual fee from the gateway response for `gateway_fee`;
  - also confirm whether v2-style escrow exists in v3 for our account (ask the account manager).
- **Pass criteria:** every flow produces balanced ledger entries (sum = 0 per transaction), and the gateway fee field is captured.
- **Output:** PaymentProvider contract; payout state machine; OD-10 input.
