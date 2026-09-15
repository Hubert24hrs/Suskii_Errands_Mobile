# Monthly Running-Cost Model — 1k / 10k / 100k / 1M MAU

Date 2026-09-15 · All figures in **USD per month**, rounded.

## Scope and scenarios

**What is included:** infrastructure and per-usage vendor costs.

**What is excluded:**
- people (engineering, ops, Verification Officers, support);
- marketing;
- legal and licensing;
- one-offs (pen test, store fees);
- payment processing fees, which are passed through to providers per the spec (shown separately in §4).

**Two scenarios:**

| Scenario | Selfie checks | Concierge model |
|---|---|---|
| **Optimised** (recommended) | OD-13 applied: vendor check weekly + on-device daily | Flash-first routing with context caching |
| **Spec as written** | Vendor selfie authentication every online day | Pro concierge without caching |

Prices come from the sources in [REPORT.md](REPORT.md). Tags: `[V]` official price page, `[S]` secondary, `[A]` assumption to confirm with the vendor. The arithmetic was run by a scratch calculator kept outside the repo (research artefact, not application code); every assumption it used is listed below.

## 1. Usage assumptions

| Driver | Value | Basis |
|---|---|---|
| Active providers | 10% of MAU | [A] marketplace norm |
| Completed jobs / MAU / month | 1.35 (90% customers × 1.5 jobs) | [A]; calibrate in beta |
| Average agreed amount (AOV) | $8.00 | [A] Lagos/Nairobi errand band $2–15 |
| Platform commission | 12.5% of gross | spec |
| Referral commission | 2.5% of net on 25% of jobs | spec rate; share [A] |
| New sign-ups / month | 15% of MAU | [A] growth + churn |
| Customers completing facial KYC | 70% of new customers | [A] (only before the first publish/pay) |
| Customer KYC price | $0.60 | [A] within the $0.50–2.00 industry range [S] |
| Provider onboarding KYC (Biometric KYC + document) | $2.00 | [A] |
| Vendor selfie authentication | $0.10 per check | [A] **get a Smile ID quote** |
| Provider online days / month | 20 | [A] |
| SMS (OTP + critical fallback) | 0.5 per MAU at $0.015 | Termii ~$0.0107 NG, AT ~KSh 0.80 KE [S] |
| Realtime peak concurrency | 6% of MAU | [A] providers online + customers with active jobs |
| Realtime messages / job | ~1,100 (≈960 tracking at 5 s pings for 40 min, counted sent + received, plus offers, status, chat, typing) | [A] |
| Edge Function calls | 30 per job + 5 per MAU | [A] |
| Egress | 30 MB / MAU | [A] compressed images, JSON |
| Storage | 1.25 MB per job (photos) + 3 MB per new user (KYC), 12-month accumulation | [A] |
| In-app calls | 0.6 calls per job × 2 min × 2 participants | [A] |
| PSTN fallback | 5% of calls, $0.04 per leg-minute, plus a number pool | [A] |
| Voice concierge | 10% of jobs × 3 min | [A] |
| Gemini Live cost | $0.005/min audio in + 40% talk time × $0.018/min audio out ≈ $0.0122/min | [V] Gemini 3.8 Live pricing |
| AI text per job (optimised) | $0.025 | [A] see §3 |
| AI text per job (Pro, no caching) | $0.042 | [A] see §3 |
| Maps (Places + routing) | $0.02 per job after free caps | [S] Maps pricing; OSRM for ETAs reduces this |
| Email | 5 per MAU at $0.0001 | SES [A] |

## 2. Results

### 2.1 Totals

| | **1k MAU** | **10k MAU** | **100k MAU** | **1M MAU** |
|---|---:|---:|---:|---:|
| Jobs / month | 1,350 | 13,500 | 135,000 | 1,350,000 |
| GMV | $10,800 | $108,000 | $1.08M | $10.8M |
| Platform net revenue (12.5% − referrals) | $1,291 | $12,909 | $129,094 | $1,290,938 |
| **Total running cost — optimised** | **$650** | **$2,953** | **$25,752** | **$241,525** |
| Cost per MAU (optimised) | $0.65 | $0.30 | $0.26 | $0.24 |
| Cost as % of net revenue (optimised) | 50% | 23% | 20% | 19% |
| **Total running cost — spec as written** | **$833** | **$4,783** | **$44,047** | **$424,475** |
| Cost as % of net revenue (spec as written) | 65% | 37% | 34% | 33% |

### 2.2 Line items (optimised scenario)

| Line item | 1k | 10k | 100k | 1M | Price basis |
|---|---:|---:|---:|---:|---|
| Supabase (prod + staging + dev) | 210 | 339 | 1,923 | 15,234 | [V] pricing page. 1k/10k Pro; 100k Team; 1M Enterprise estimate [A] |
| LiveKit Cloud (calls + agent minutes) | 0 | 50 | 492 | 4,920 | [S] Build / Ship / Ship / Scale |
| Gemini Live (voice concierge audio) | 5 | 49 | 494 | 4,941 | [V] |
| PSTN masked fallback | 56 | 165 | 898 | 7,080 | [A] |
| Gemini text (concierge, moderation, receipts, compare, triage, admin) | 54 | 388 | 3,575 | 34,550 | [V] prices, [A] volumes |
| Cloud Run (AI service, workers) | 60 | 150 | 800 | 5,000 | [A] |
| KYC onboarding (customers + providers) | 87 | 867 | 8,670 | 86,700 | [A] |
| Ongoing selfie checks (weekly vendor check) | 40 | 400 | 4,000 | 40,000 | [A] |
| SMS / OTP | 8 | 75 | 750 | 7,500 | [S] |
| Maps / Places / routing | 0 | 170 | 2,600 | 26,900 | [S] |
| Email | 0 | 5 | 50 | 500 | [A] |
| Observability (Sentry, PostHog, uptime) | 50 | 150 | 800 | 4,000 | [A] |
| Cloudflare | 25 | 25 | 250 | 2,000 | [A] Pro → Business → Enterprise |
| BigQuery | 5 | 20 | 150 | 1,200 | [A] |
| Misc. GCP / tooling | 50 | 100 | 300 | 1,000 | [A] |
| **Total** | **650** | **2,953** | **25,752** | **241,525** | |

### 2.3 Supabase breakdown

| Component | 1k | 10k | 100k | 1M | Note |
|---|---:|---:|---:|---:|---|
| Plan | 25 | 25 | 599 | 2,500 | Team gives the SOC 2 report + 14-day backups; 1M is Enterprise [A] |
| Compute (prod primary + replicas + staging + dev, minus $10 credit) | 25 | 120 | 335 | 1,845 | 1k: Small; 10k: Large; 100k: XL + Large replica; 1M: 4XL + 2 × 2XL replicas [A] |
| Auth MAU overage ($0.00325 above 100k) | 0 | 0 | 0 | **2,925** | [V] |
| Realtime peak connections ($10 / 1,000 above 500) | 0 | 1 | 55 | 595 | 60k peak at 1M **exceeds Team's 10k limit → Enterprise quota** |
| Realtime messages ($2.50 / M above 5M) | 0 | 25 | 359 | **3,700** | 1.49B messages/month at 1M, mostly tracking |
| Edge Functions ($2 / M above 2M) | 0 | 0 | 5 | 87 | |
| Egress ($0.09 / GB above 250 GB) | 0 | 4 | 248 | 2,678 | Serve images through the Storage CDN to cut this |
| Storage ($0.0213 / GB above 100 GB) | 0 | 3 | 53 | 544 | 12-month accumulation with lifecycle deletion |
| PITR (7 days → 14 days at scale) | 100 | 100 | 200 | 200 | Spec requires PITR |
| Log drains | 60 | 61 | 70 | 160 | |

### 2.4 What the spec-as-written scenario adds

| | 1k | 10k | 100k | 1M |
|---|---:|---:|---:|---:|
| Daily vendor selfie checks (replaces the weekly line) | 200 | 2,000 | 20,000 | **200,000** |
| Pro concierge without caching (replaces the optimised AI text line) | 77 | 617 | 5,870 | 57,500 |

## 3. AI text cost derivation

Concierge conversation: 6 turns × (~3k input tokens incl. system prompt, tools and history + ~300 output tokens). It runs on 60% of jobs.

| Model | Per turn | Per conversation | Notes |
|---|---:|---:|---|
| `gemini-3.1-pro`, no caching ($2 / $12 per 1M) | $0.0096 | $0.058 | |
| `gemini-3.1-pro`, 70% of input cached ($0.20) | $0.0058 | $0.035 | |
| `gemini-3.5-flash`, 70% of input cached ($1.50 / $9, cached $0.15) | $0.0044 | $0.026 | |
| `gemini-3.8-flash`, 70% of input cached (promo $0.75 / $3.75, cached $0.075, until 31 Dec 2026) | ~$0.0020 | ~$0.012 | |

- Other AI per job adds ≈ $0.007: moderation on Flash-Lite (~$0.0002 per message × 20), receipts (10% of jobs × $0.006), offer comparison (30% × $0.005), support triage (5% × $0.02).
- **Blended per job:** optimised ≈ $0.025; Pro without caching ≈ $0.042.
- The optimised baseline assumes 3.5 Flash-level pricing with caching, so the 3.8 Flash promo is upside, not baseline.
- **Insight:** because 3.5 Flash is priced close to 3.1 Pro, the big lever is **context caching and prompt compaction**, not tier choice. Tier choice matters only while the 3.8 Flash promo lasts or if Flash-Lite passes the evals.

## 4. Pass-through and decision-dependent money (not in the totals)

| Item | 1M MAU estimate | Who bears |
|---|---:|---|
| Collection fees on GMV (blended ~2.2% incl. VAT, NG-heavy) | ~$238,000 | Provider (spec: gateway fees borne by provider); customer for the item float (OD-04) |
| Payout transfer fees (1 payout per provider per week; ~$0.05 average) | ~$20,000 | **OD-10** (proposed: provider) |
| Referral payouts (already deducted in the net-revenue line) | ~$59,000 | Platform (OD-01 default) |
| Non-refundable gateway fees on cancellations | depends on cancellation rate | OD-08 |

## 5. Sensitivities (1M MAU, optimised)

| Change | Monthly impact |
|---|---:|
| Selfie checks daily instead of weekly (spec as written) | **+$160,000** |
| Customer KYC at $1.00 instead of $0.60 | +$37,800 |
| Tracking pings every 10 s instead of 5 s | −$1,600 (Realtime messages) |
| OSRM/Valhalla for all ETAs (Places only on Google) | −$10,000 to −$15,000 [A] |
| Concierge on `gemini-3.8-flash` at promo pricing (valid until 31 Dec 2026) instead of 3.5 Flash | −$10,500 |
| Egress via the Storage CDN at the cached rate | −$900 to −$1,500 [A] |
| AOV $12 instead of $8 | revenue +50%; costs ~flat → cost share drops to ~13% |

## 6. Operational staffing drivers (not costed; plan with the client)

| Function | Driver at 1M MAU | Rough load [A] |
|---|---|---|
| Verification Officers | ~15k new providers/month × ~10 min manual police-clearance and document review | ~2,500 h/month ≈ 15–16 FTE |
| Support agents | 1.35M jobs × 3% ticket rate × 8 min after AI triage | ~5,400 h/month ≈ 33 FTE |
| SOS / ops console | 24/7 coverage per launch city cluster | ≥ 5 FTE per 24/7 seat |
| Dispute officers | 0.5% of jobs disputed × 20 min | ~2,250 h/month ≈ 14 FTE |

## 7. Recommendations from the model

1. **Adopt OD-13** (on-device daily liveness, vendor check weekly and on triggers). It is the single biggest saving.
2. **Negotiate Smile ID volume pricing now**, including the SmartSelfie Authentication unit price. KYC is the largest unavoidable line.
3. **Mandate context caching** and prompt budgets per feature; add cost alerts per feature (spec guardrail).
4. **Plan the Supabase Enterprise conversation at ~100k MAU**: Realtime connections above 10k and Auth MAU overage.
5. **Self-host OSRM/Valhalla** for ETA refresh; keep Google for Places search.
6. Recompute this model at the end of Phase 1 with real vendor quotes and Kimi's fixture-derived request mix.
