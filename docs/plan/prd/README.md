# PRD — Suskii Errands

| | |
|---|---|
| Owner | Claude Code (technical lead). Product owner sign-off: **client** |
| Date | 2026-09-16 |
| Status | Phase 1 draft (deliverable #12). Reconciled with Kimi's UI inventory at M8.5 (Stage B) |
| Inputs | spec `master_spec` (product summary, baseline features, client decisions, money rules, gateways, referral, KYC, business accounts, communication, safety, added features, country packs, job lifecycle, store readiness, performance targets, definition of done); every document in `docs/plan/` |

## 1. Product in one paragraph

An inDrive-style two-sided marketplace for **any errand or service**. A customer describes a need in their own words (or to the AI concierge), sets a preferred price, receives offers and counter-offers from verified providers, negotiates, picks one, **pays upfront into funds held by Suskii**, tracks the job live, confirms completion, and both sides rate each other. One Flutter app with a Customer/Provider mode switch, a customer web app, a marketing site and an admin dashboard. Launch languages English and Nigerian Pidgin; Nigeria first (OD-07, OD-14). **No cash anywhere.** Ship everything in one release (client decision).

## 2. Files

| File | Surface | Story prefix |
|---|---|---|
| [shared.md](shared.md) | Both app modes and web: accounts, verification (customer), chat, calls, notifications, safety, ratings, wallet and referrals, settings, accessibility, localization, account lifecycle | `SH` |
| [customer.md](customer.md) | Customer mode: requests, AI concierge, offers and negotiation, payment, tracking, completion, disputes, promos, tips, favourites | `CU` |
| [provider.md](provider.md) | Provider mode: onboarding and KYC, going online, nearby requests, offers, job execution, proof, earnings, withdrawals, tools | `PR` |
| [business.md](business.md) | Business providers and fleets: organisation verification, members, dispatch, vehicles, zones, reports | `BU` |
| [web.md](web.md) | Customer web app and marketing site | `WB`, `MK` |
| [admin.md](admin.md) | Admin dashboard for the five admin roles, ops consoles, AI admin assistant | `AD` |

## 3. Personas

| Persona | Who | What they need most |
|---|---|---|
| **Ada — busy customer** (Lagos, mid-range Android, good 4G at home, patchy outside) | Sends errands: groceries, documents, a plumber | Speed, a fair price, knowing who is coming, not losing money |
| **Mama Chinedu — first-time customer** (low-end Android, prefers Pidgin, voice over typing) | Needs help moving or cleaning | Being understood without typing; trust before paying |
| **Tunde — independent provider** (motorcycle, itel/Tecno 2–3 GB, prepaid data) | Wants steady jobs | Enough jobs nearby, predictable payout, battery and data that last a shift |
| **Grace — business owner** (cleaning company, 12 workers, 3 vans) | Wants jobs for her team | Dispatch, per-worker reporting, one payout account |
| **Worker under a business** | Does the jobs Grace assigns | Clear assignment, navigation, proof capture |
| **Verification Officer, Support Agent, Finance Officer, Dispute Officer, Super Admin** | Suskii staff | Queues with SLAs, evidence in one place, no access beyond their role |
| **Trusted contact** (no account) | A customer's or provider's family member | A link that shows the live trip, only while it is active |

## 4. Conventions

- **Story format:** `ID — title` · *As a …, I want …, so that …* · acceptance criteria (AC) as testable statements · refs.
- **"Server-enforced"** in an AC means the rule is in a database function or Edge Function and is covered by pgTAP or Deno tests ([test-strategy.md](../test-strategy.md)); the UI may mirror it but is never the control.
- **Defaults** quoted in ACs (TTLs, windows, limits) are configuration per country and category, taken from [job-lifecycle.md](../state-machines/job-lifecycle.md) and the country packs. A value tagged `[A]` is a proposal awaiting client confirmation.
- **Priority.** The release is "everything at once", so every story here is **Launch** unless marked **Later** (post-launch, spec-named) or **Gated** (ships only if a spike or open decision allows, named inline).
- **Money** in every AC is integer minor units with a currency code, and every amount a user sees is server-computed.
- **Copy:** held funds are "held by Suskii", never "escrow" (ADR-0002).

## 5. Epics and counts

| Epic | Stories | File |
|---|---:|---|
| Accounts, sign-in, customer verification, mode switch | 9 | shared |
| Chat, calls, notifications | 8 | shared |
| Wallet and referrals | 6 | shared |
| Safety: SOS, trusted contacts, trip share, block and report, prohibited items | 6 | shared |
| Ratings and reputation | 2 | shared |
| Settings, accessibility, localization, offline, account lifecycle, app integrity | 8 | shared |
| Requests and AI concierge | 9 | customer |
| Offers and negotiation | 6 | customer |
| Payment, tracking, completion | 8 | customer |
| Cancellation, disputes, support | 5 | customer |
| Promos, tips, favourites, scheduled errands | 4 | customer |
| Provider onboarding and KYC | 8 | provider |
| Going online and finding work | 6 | provider |
| Job execution and proof | 6 | provider |
| Earnings, withdrawals, provider tools | 7 | provider |
| Business and fleets | 10 | business |
| Customer web app | 8 | web |
| Marketing site | 7 | web |
| Admin dashboard | 24 | admin |
| **Total** | **147** | |

## 6. Non-functional requirements

These apply to every story. Sources: spec `performance_targets`, `definition_of_done`, `store_readiness`, `security`.

| # | Requirement | Target | Verified by |
|---|---|---|---|
| N-01 | RPC latency | p95 ≤ 300 ms | k6, SLO alert ([infra-cicd.md](../infra-cicd.md) §7) |
| N-02 | Nearest-provider query | p95 ≤ 50 ms | k6 at 100k providers (S-06) |
| N-03 | Realtime event delivery | p95 ≤ 1 s | Synthetic pair, k6 |
| N-04 | Cold start on a 2–3 GB Android | ≤ 3 s | Device lab A1, A2 |
| N-05 | App download size | ≤ 35 MB per ABI | Build check |
| N-06 | Crash-free sessions | ≥ 99.5% | Staged rollout gate |
| N-07 | Core-flow availability | 99.9% monthly | Synthetic journey |
| N-08 | Low-end devices on slow networks | Core flows usable on network profiles N1–N5 | Network matrix ([test-strategy.md](../test-strategy.md) §7) |
| N-09 | Accessibility | Screen readers, text scaling to 200%, WCAG AA contrast on core flows, dark mode | Golden tests, device checks |
| N-10 | Security | No critical or high findings open at release; RLS allow/deny tests for every exposed table | Audit, pgTAP, pen test |
| N-11 | Privacy | Data classes handled per [data-flow.md](../data-flow.md); consent recorded and versioned | DPIA, integration tests |
| N-12 | Observability | Every feature has logs, metrics, alerts, a feature flag and a rollback path | Definition of done |
| N-13 | Store compliance | Apple: account deletion, privacy labels, Sign in with Apple alongside Google, VoIP push only for calls, location justification. Google Play: Data safety, FGS types, full-screen intent, location and financial-features declarations | Store readiness checklist (Phase 10) |

## 7. Out of scope at launch

| Item | When | Source |
|---|---|---|
| Yoruba, Igbo, Hausa | V1.1 | Client decision |
| Swahili, French, Arabic (RTL), Portuguese | Roadmap; RTL layout ready now | Spec localization flag; OD-16 |
| Recurring scheduled errands | Later — the data model supports recurrence now | Spec added features |
| Cross-currency jobs | Not planned | Spec money rules |
| Cash payments | Never | Client decision |
| Call recording | Never | Client decision |
| Stripe Connect payouts in Africa | Only where a Suskii entity qualifies | OD-11 |
| Insurance cover | Hooks only; claims inside disputes | OD-05 |
| Learning-to-rank matching, GBM price model | After enough volume, shadow first | [ai-design.md](../ai-design.md) §9 |
| Multi-level referrals | Never | Spec: single level only |

## 8. Open decisions that change stories

Every one of these has a default the stories implement until answered ([OPEN-DECISIONS.md](../../OPEN-DECISIONS.md)):

| OD | Stories affected |
|---|---|
| OD-01, OD-02, OD-03 referral funding, duration, double referral | SH-22 |
| OD-04 item float (incl. receipt above float) | CU-05, CU-22, PR-19 |
| OD-05 insurance | CU-05 |
| OD-06 commission rate | PR-12, PR-21 |
| OD-07, OD-14 launch countries | SH-01, MK-03 |
| OD-08 gateway fee on refunds, OD-19 cancellation-fee recipient | CU-24 |
| OD-09 police-clearance recency | PR-05 |
| OD-10 payout transfer fees | PR-22 |
| OD-11 Stripe's role | CU-16 |
| OD-12 funds-holding model | CU-16 and held-funds copy everywhere |
| OD-13 selfie-check frequency | PR-09 |
| OD-15 hosting and residency | SH-37 |
| OD-17 Pidgin voice | CU-02 |
| OD-18 tax on referral payouts | SH-23 |
| OD-20 Pidgin evaluation data | CU-01, CU-02 |
| OD-21 moderation outage behaviour | SH-11, CU-07 |

## 9. Traceability

Each story will carry, by the end of Stage B, the contract entries it uses and the tests that prove it. Until then the refs point to the plan documents. At M8.5, Kimi's screen inventory is mapped onto story IDs; any screen without a story, or story without a screen, is a finding in the UI change list.
