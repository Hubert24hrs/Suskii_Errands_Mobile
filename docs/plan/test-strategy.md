# Test strategy and device/network matrix

| | |
|---|---|
| Owner | Claude Code (backend, services, integration, load, security; the overall strategy). Kimi Code owns app and web tests (spec `agent_kimi_code.testing`) and is summarised here so the two halves meet |
| Date | 2026-09-16 |
| Status | Phase 1 draft |
| Inputs | spec `agent_claude_code.testing`, `agent_kimi_code.testing`, `performance_targets`, `definition_of_done`; [rls-policy-matrix.md](rls-policy-matrix.md) pgTAP obligations; [state-machines/](state-machines/); [money-flows.md](money-flows.md); spikes S-03…S-14; [ai-design.md](ai-design.md) §8; [infra-cicd.md](infra-cicd.md) §5 |

## 1. Principles

1. **Test the rule where it lives.** Permissions, state and money live in Postgres, so their tests are pgTAP against a real database — not mocks in a service layer. A UI test that "can't tap Accept twice" proves nothing about double acceptance.
2. **Every allow has a deny.** The RLS matrix is tested cell by cell in both directions, asserting the SQLSTATE (S-13 method).
3. **Invariants over examples for money.** The 17 verified postings in `money-flows.md` are fixtures, and property-based tests generate thousands more, all asserting zero-sum, single currency and correct rounding (S-14).
4. **Concurrency is tested with real concurrency.** Parallel sessions against a real database, not sequential calls (S-10).
5. **The physical device is the test for what the OS decides.** Incoming calls with the app killed, background location on aggressive battery managers and liveness on 2 GB RAM cannot be proven in an emulator (S-03, S-04, S-05).
6. **Failure paths are first-class.** Every vendor integration has tests for signature failure, duplicate, reordering, delay, timeout and outage — the spec calls out webhook retries explicitly.
7. **Synthetic data only** outside production; no production copy ever reaches staging.

## 2. Layers

| # | Layer | Tool | Location | Runs | Owner |
|---|---|---|---|---|---|
| 1 | **Database: RLS, grants, functions, state machines, ledger** | pgTAP on the Supabase CLI local stack | `supabase/tests/` | Every PR touching `supabase/` | Claude |
| 2 | **Concurrency and idempotency** | pytest + `asyncpg` with N parallel connections (the S-10 harness, ported) | `supabase/tests/concurrency/` | Every PR touching `supabase/` | Claude |
| 3 | **Money properties** | pytest + Hypothesis driving posting functions on the local stack | `supabase/tests/properties/` | Every PR touching ledger, pricing or payments; nightly long run | Claude |
| 4 | **Edge Functions** | `deno test`, vendors mocked at the HTTP boundary | `supabase/functions/**/*_test.ts` | Every PR | Claude |
| 5 | **Contract tests** | Schema validation of fixtures; provider-side tests of every endpoint against OpenAPI; breaking-change diff | `contracts/`, function tests | Every PR | Claude (provider side), Kimi (mocks built from the same fixtures) |
| 6 | **AI service** | pytest with a fake LLM gateway; allowlist test; eval suites | `services/ai/tests`, `services/ai/evals` | PR (fast subset), nightly (full) | Claude |
| 7 | **API integration** | pytest scenario runner acting as several users through `supabase-py`/PostgREST against the local stack, vendors faked | `tests/integration/` | Every PR touching backend paths | Claude |
| 8 | **Sandbox end-to-end** | Same runner against **staging** with gateway, KYC and SMS sandboxes, including failures and webhook retries | `tests/e2e-sandbox/` | Nightly + before prod approval | Claude |
| 9 | **Load** | k6 | `tests/load/` | Weekly on staging; target-scale run in Phase 10 | Claude |
| 10 | **Security** | CodeQL, Semgrep, gitleaks, osv-scanner, OWASP ZAP; RLS enumeration test; external pen test | CI + Phase 10 | PR / nightly / pre-launch | Claude |
| 11 | **Resilience** | Fault injection in integration and staging: vendor down, slow, duplicate webhooks; Realtime disconnects; restore drills | `tests/resilience/` | Nightly (automated subset), per release (manual) | Claude |
| 12 | **Flutter** | Unit, widget and golden (light/dark, text scale, RTL), Patrol integration | `apps/mobile`, `packages/*` | Kimi's CI | Kimi |
| 13 | **Web** | Vitest + React Testing Library; Playwright E2E for customer web and admin incl. role permissions; Lighthouse budgets for marketing | `apps/web-*` | Kimi's CI | Kimi |
| 14 | **Device and network** | Physical device lab + field tests | §6, §7 | Spikes, each milestone, release | Kimi + Claude |

## 3. Backend test catalogue

### 3.1 pgTAP (layer 1)

| Suite | Content | Source of cases | Size estimate |
|---|---|---|---|
| `rls/` | For every exposed table: one **allow** test per non-empty matrix cell and one **deny** per empty cell, by SQLSTATE; the 12 named deny tests | RLS matrix | Several hundred; generated from a machine-readable copy of the matrix so the doc and tests cannot diverge |
| `grants/` | Column-level `UPDATE`/`INSERT` grants exactly match the matrix's writable columns; `private`, `ledger`, `kyc`, `audit` schemas not exposed and not usable by `anon`/`authenticated` | RLS matrix, S-13 finding 1 | One per table |
| `functions/` | Every `SECURITY DEFINER` function: `search_path = ''` (catalog query over `pg_proc.proconfig`), unauthenticated call → `28000`, wrong role or mode → `42501`, invalid input → `22023` | S-13 findings 2 and 3 | One block per function |
| `state_machines/` | Each of the **31 job transitions**: allowed from its source state by its actor with its guard; **every other source state rejected**; exactly one event and one outbox row; timeouts via a controllable clock | job-lifecycle.md | ≈ 31 × 20 source-state checks, generated |
| `offers/` | Offer states and rounds: counter limits per category, TTL expiry, withdraw, accept on an expired or countered offer rejected | offer-negotiation.md | ~60 |
| `ledger/` | The 17 postings from `money-flows.md` reproduced **exactly** (scenarios 1a–9); zero-sum per transaction; single currency; `round_half_even` edge cases; UGX exponent 0; balances derived equal to sum of entries; posting rejects before writing when unbalanced | money-flows.md, S-14 | ~80 |
| `schema/` | Required extensions present, partitions exist ahead for the next 3 months, no `float`/`real`/`double precision`/`numeric` money columns (catalog query), every public table has RLS **enabled and forced** | ERD, S-13 | ~20 |
| `audit/` | Hash chain continuity; `service_role` cannot update or delete audit rows | RLS matrix | ~10 |

### 3.2 Concurrency and idempotency (layer 2)

| Scenario | Assertion |
|---|---|
| 50 parallel `accept_offer` on one request with different offers | Exactly one succeeds; one `AGREED` transition event; losers get the "already agreed" code (S-10) |
| Parallel `accept_offer` with the **same** idempotency key | One execution; every caller receives the same result (S-10) |
| Provider `withdraw_offer` racing customer `accept_offer` | Either withdraw or accept wins; never both |
| Duplicate payment webhook delivered concurrently | One ledger posting (`UNIQUE (gateway, gateway_reference)`) |
| Parallel withdrawals exceeding available balance | Sum of successful withdrawals ≤ balance; wallet never negative |
| `cancel_job` racing `set_job_status(EN_ROUTE)` | Serialized by row lock; resulting state is legal and fee matches the winner |
| Referral campaign budget near its cap with parallel accruals | Cap never exceeded (spec: caps enforced transactionally) |
| Idempotency key reused with **different** parameters | Rejected with a specific error, not replayed |

### 3.3 Money properties (layer 3)

Hypothesis generates job histories — random amounts per currency (including UGX), commission bps, referral combinations (OD-01, OD-03 defaults), tips, item floats with partial use, cancellations at every state, partial and full refunds, disputes, chargebacks, clawbacks — and runs them through the posting functions. Properties:

1. Every transaction sums to zero in minor units.
2. No transaction mixes currencies.
3. Customer paid = provider earnings + platform revenue + referral expense + gateway fees + refunds, per job, exactly.
4. No wallet or held-funds account goes negative.
5. Commission computed with `round_half_even` on the exponent-correct amount; never off by more than one minor unit from the exact rational value.
6. Replaying any posting with its idempotency key changes nothing.

### 3.4 Edge Functions (layer 4)

Every vendor-facing function has this minimum set:

| Case | Expected |
|---|---|
| Valid signature, new event | Stored raw → de-duplicated → **verified server-side with the vendor API** → processed |
| Invalid or missing signature | 401, stored as rejected, nothing processed |
| Duplicate delivery | 200, no second effect |
| Out-of-order events (e.g. refund before charge success) | Parked and retried; final state correct |
| Delayed event after payment TTL expired | Handled per job lifecycle (late payment → refund path) |
| Amount or currency differs from the expected payment | Not credited; flagged for ops (RB-02) |
| Vendor verify call times out | Retried with backoff through the queue; no credit until verified |
| Vendor 5xx on outbound (payout, KYC start, SMS) | Retry policy + failover where configured (SMS), idempotent |

Plus: LiveKit token minting only for participants of the job; Send SMS Hook signature verification (Standard Webhooks) and per-country routing; Custom Access Token Hook adds only the allowed claims.

### 3.5 Integration scenarios (layers 7 and 8)

Written once as actor scripts; run against the local stack with fakes (layer 7) and against staging with sandboxes (layer 8).

| # | Scenario |
|---|---|
| I-01 | Happy path: sign in → verify → draft → publish → offer → counter → accept → pay → assign → en route → arrive (PIN) → complete → confirm → settle → payout |
| I-02 | Unverified customer: concierge drafts; `publish_request` returns `ERR_VERIFICATION_REQUIRED` |
| I-03 | Payment TTL expires → job back to negotiating/expired per lifecycle; late webhook refunds |
| I-04 | Customer cancels before assignment, after en route, after arrival — fees per OD-08/OD-19 |
| I-05 | Provider cancels after payment → full refund, provider reliability penalty |
| I-06 | Dispute opened after completion → funds frozen → partial refund → `partially_refunded` |
| I-07 | Item float: receipt below float → unused refunded (money flows 3a–3c); receipt **above** float → never charged automatically. The overspend rule is not yet defined — added to OD-04 follow-ups |
| I-08 | Tip after confirmation; referral commissions accrue, hold, become available, clawed back on refund |
| I-09 | Provider KYC: all steps → officer review → approve; police clearance expiry → auto-suspension → cannot go online |
| I-10 | Go online blocked by expired KYC, selfie check required, busy as customer |
| I-11 | SOS during an active trip → incident, ops queue, partner dispatch (fake), trusted-contact link |
| I-12 | Chat with moderation hold; off-platform payment message flagged |
| I-13 | Withdrawal to a newly changed payout account after a phone change → cooling-off enforced (R-32) |
| I-14 | Business account: dispatcher assigns worker; worker cannot see business finance |
| I-15 | Every admin role against every admin function: allowed set only; `aal1` denied |
| I-16 | Account deletion: personal data removed or anonymised; financial records retained per policy |
| I-17 | Offline provider replays queued status changes with their original idempotency keys → applied once, in order |
| I-18 | Client clock skewed ±10 min → countdowns correct via `server_time`; server rejects nothing because of client time |

### 3.6 AI (layer 6)

Defined in [ai-design.md](ai-design.md) §8: golden sets in English and Pidgin, red-team set at 100%, redaction recall ≥ 0.99, receipts with zero float-parse errors, cost and latency regression. Plus unit tests: validator rejects model-written money fields; tool allowlist; placeholder rehydration only into `save_request_draft`; JWT expiry handling.

## 4. Test data

| Asset | Contents | Where |
|---|---|---|
| Personas | Customers (unverified, verified, suspended), providers (individual; business owner, dispatcher, worker; online, offline, KYC-expired), one user per admin role (Super Admin, Verification Officer, Support Agent, Finance Officer, Dispute Officer) | `supabase/seed/`, fixtures |
| Countries and currencies | NG/NGN, KE/KES, GH/GHS, ZA/ZAR, UG/**UGX** (exponent 0) country packs | Seed from `docs/research/country-packs` once verified |
| Geography | Synthetic providers around real Lagos, Nairobi and Accra coordinates; the S-06 generator for 100k providers at load scale | Seed + load scripts |
| Phone numbers | Supabase Auth test OTP numbers per environment [VERIFY-IN-RESEARCH: config key], never real subscribers | `config.toml` (dev/staging only) |
| Vendor sandboxes | Flutterwave and Paystack test cards and test mobile-money numbers; Smile ID sandbox; SMS vendor test mode | Staging secrets |
| Fixtures | Contract fixtures shared with Kimi's mocks (Stage B) | `contracts/fixtures/` |

## 5. Load and performance

Targets come from spec `performance_targets`; volumes from the cost model's usage assumptions. The weekly run uses launch scale; the **target-scale** run (spec Phase 10) uses a temporarily upsized staging project matching production.

| k6 scenario | Launch-scale profile [A] | Target-scale profile [A] | Pass |
|---|---|---|---|
| Publish request + matching fan-out | 5 req/s sustained, 20 req/s burst | 10× launch | RPC p95 ≤ 300 ms; notification fan-out p95 ≤ 2 s |
| Offers and counters | 20 offers/s | 10× | RPC p95 ≤ 300 ms; zero double acceptances |
| Nearest-provider query | 50 q/s over 10k online providers | 500 q/s over 100k providers with heartbeats at 814 writes/s (S-06 calibrated) | p95 ≤ 50 ms; dead-tuple ratio < 20% (ADR-0009) |
| Chat | 2k concurrent conversations, 1 msg/10 s each | 10× | Realtime delivery p95 ≤ 1 s |
| Location broadcast | 2k active trips, 1 ping / 4 s | 20k active trips | Delivery p95 ≤ 1 s; within Realtime message quota (S-11) |
| Payment webhooks | 10/s with 5% duplicates and 2% out of order | 100/s | 99% processed ≤ 60 s; exactly-once ledger |
| Soak | Mixed profile, 8 h | — | No memory growth, no connection leaks, no partition or vacuum debt |

Spike S-11 (Realtime load) must run before these profiles are trusted, and its quotas feed RB-12.

## 6. Device matrix

The spec's device floor is low-end Android with 2–3 GB RAM on slow networks, with minimum OS versions set in planning. Proposed floor below; **Kimi confirms**, since build settings are Kimi's.

**Minimum OS [A — proposal]:** Android 8.0 (API 26), iOS 15 (already Kimi's `IPHONEOS_DEPLOYMENT_TARGET`). Revisit once Play Console device-catalogue data for Nigerian installs is available, and against the Smile ID SDK floor chosen in S-05 (v11 requires iOS 13+ [V]).

| Tier | Class | Example candidates to buy [A — confirm the 2–3 GB RAM variant is sold at purchase time] | Why this device | Used for |
|---|---|---|---|---|
| A1 | **itel**, 2 GB RAM, Android Go edition | Current itel A-series entry model | Harshest memory and battery management; the floor | S-04, S-05, cold start ≤ 3 s, release sign-off |
| A2 | **Tecno**, 3 GB RAM | Current Tecno Spark or Pop entry model | HiOS battery manager kills background work | S-03, S-04, release sign-off |
| A3 | **Infinix**, 3–4 GB RAM | Current Infinix Hot or Smart entry model | XOS background restrictions | S-03, S-04, release sign-off |
| A4 | **Samsung** mid-range | Current Galaxy A-series mid model | One UI "deep sleeping apps"; the most common mid-tier | S-03, S-04, release sign-off |
| A5 | **Pixel** | A recent Pixel "a" model on the newest Android | Reference Android; first to get new platform restrictions (Android 17 location button, REPORT §10) | Regression reference, store policy checks |
| A6 | Android at the OS floor | Any cheap device on Android 8–9 | Oldest supported API behaviour | Smoke per milestone |
| I1 | **Older iPhone** | Oldest iPhone that runs iOS 15-era current support, with 2–3 GB RAM | Memory and CallKit behaviour on old hardware | S-03, S-05, release sign-off |
| I2 | **Current iPhone** | Current generation, latest iOS | New iOS restrictions | Release sign-off |
| W1 | Low-end Android Chrome | Device A1 in Chrome | Customer web app and Smile ID web SDK (S-05) | Web E2E on device |

**Emulators and device clouds** (Firebase Test Lab or similar [S]) broaden smoke coverage and Patrol runs across screen sizes, but they **do not** count for S-03, S-04, S-05, VoIP, background location, battery, camera liveness or cold-start sign-off.

**Per-device release checks:**

| Check | Target | Devices |
|---|---|---|
| Cold start | ≤ 3 s (spec) | A1, A2 |
| Download size | ≤ 35 MB per ABI (spec) | Build output |
| Incoming call, app killed / background / locked / Doze / battery saver | iOS ≥ 99%, Android ≥ 95% ring rate (S-03) | A2–A5, I1, I2 |
| Background location over an 8 h shift | S-04 pass criteria | A1–A4 |
| Liveness enrolment and authentication | ≥ 90% genuine pass rate, no OOM (S-05) | A1, A2, I1, W1 |
| Crash-free sessions in staged rollout | ≥ 99.5% (spec) | Field |
| Accessibility: large text, TalkBack/VoiceOver on core flows | No blocked flow | A4, I2 |

## 7. Network matrix

Lab profiles applied with a network shaper (device-side proxy or router shaping) for devices, and Chrome DevTools/Playwright throttling for web. Values are proposals [A] modelled on common throttling presets, to be replaced with measurements from the Lagos field test.

| Profile | Down / up | RTT | Loss | Represents |
|---|---|---|---|---|
| N1 Good 4G | 10 / 3 Mbps | 80 ms + EU hosting RTT | 0% | Urban good signal |
| N2 Congested 4G | 2 / 0.5 Mbps | 150 ms | 1% | Evening peak, Lagos |
| N3 3G | 750 / 250 kbps | 300 ms | 2% | Fallback coverage |
| N4 Edge / 2G | 240 / 60 kbps | 600 ms | 3% | Peri-urban, lifts, markets |
| N5 Flapping | Alternate N2 ↔ offline every 20–60 s | — | — | Moving provider |
| N6 Offline | 0 | — | 100% | Tunnels, data exhausted |
| N7 Captive / DNS failure | TCP OK, TLS or DNS failing | — | — | Public Wi-Fi portals |

**What must hold on each profile:**

| Flow | N1–N3 | N4 | N5 | N6 |
|---|---|---|---|---|
| Sign in with OTP | Works | Works; SMS autofill | Resumes | Clear offline state |
| Publish request with 3 photos | Works; images compressed | Works with progress and retry | Resumes upload, **one** request created (idempotency) | Queued draft, not published |
| Receive and accept offer | Realtime ≤ 1 s p95 on N1–N2 | Falls back to polling | Missed events recovered on reconnect | Clear offline state |
| Pay | Hosted checkout completes | Completes or times out cleanly; webhook decides the truth | Return to app reconciles from server | Blocked with message |
| Provider status updates | Immediate | Immediate or queued | Queued and replayed once, in order (I-17) | Queued |
| Live tracking | Smooth | Degrades to sampled positions | Gaps interpolated, no fake positions | Last known position labelled stale |
| In-app call | Clear | Audio-only degraded; PSTN fallback offered | Reconnects or falls back | PSTN fallback |
| Voice concierge | Latency targets (ai-design §7) | Offer text concierge | Session resumes from slot state | Text form |
| SOS | Works | **Must work**; SMS fallback path [A — define in Phase 4] | **Must work** | Shows emergency numbers from the cached country pack |

**Field test:** before release, a one-week field run in Lagos with the A-tier devices on each major mobile network (MTN, Airtel, Glo, 9mobile), riding real routes for background location and calls; repeat abbreviated in Nairobi and Accra before those packs go live (RB-08).

## 8. Quality gates

| Gate | Requires |
|---|---|
| **PR** | All blocking CI jobs for touched paths ([infra-cicd.md](infra-cicd.md) §5); new function or table ships with its pgTAP allow **and** deny tests; new endpoint ships with contract test and fixture |
| **Merge to main → staging** | PR gate + migrations apply from zero and on top of the current staging schema |
| **Staging → production approval** | Smoke and synthetic journey green on staging; nightly sandbox E2E green within 24 h; no open critical or high security findings; eval gate for any AI change |
| **Milestone (Kimi integration)** | Audit per `docs/audit/README.md`; device checks on A1, A2, I1 for the flows the milestone touches |
| **Release** | Spec definition of done: acceptance criteria on physical low-end and high-end devices; all CI suites green; no critical/high findings; contracts consumed without drift; logging, metrics, alerts; feature flag and rollback path; admin tooling; docs and runbooks. Plus: target-scale load run passed, external pen test findings fixed, restore drill within RTO, field test done |

Defect severity follows the audit scale (Critical / High / Medium / Low): critical and high block the gate they are found at.

## 9. Open items

| # | Item | Owner | Needed by |
|---|---|---|---|
| T-1 | **Buy the device lab** (§6, ~9 devices) — also unblocks S-03, S-04, S-05 | Client | Now (spikes are P0) |
| T-2 | Confirm minimum OS versions (§6) | Kimi + client | M3 |
| T-3 | Field testers and SIMs in Lagos (then Nairobi, Accra) | Client | Before release |
| T-4 | External penetration test vendor and date | Client | Phase 10 |
| T-5 | Supabase Auth test phone numbers configuration [VERIFY-IN-RESEARCH] | Claude | Phase 2 |
| T-6 | SOS delivery path when data is unavailable (SMS or USSD fallback) | Claude + client | Phase 4 |
