# Suskii Meet v5: final design and build plan

| | |
|---|---|
| Status | **Proposed.** The build plan the team executes PR by PR. ADR-0026, ADR-0027, ADR-0028 and ADR-0029 will record it |
| Author | Claude Code (lead architect) |
| Date | 2026-11-25 |
| Base | `origin/main` @ `73f9e99` (2026-11-21). Newest migration: `20261121120100_ng_legal_documents.sql`. Newest pgTAP file: `71_direct_payment_test.sql`. Contracts: 2.5.0 published, with the direct-payment MINOR under `[Unreleased]` |
| Inputs | Owner's spec v5 with the binding decisions of 2026-11-25; the seven-area research map; the six InMessage reference screens; three candidate designs and two judges' verdicts |
| Winner | Design 1 (safety, privacy and Play policy first), chosen by both judges. Engineering corrections come from the repo-fit judge and policy corrections from the safety judge. Every listed graft is taken (§1.7) |

---

## 1. Summary and decisions

### 1.1 What we are building

Suskii Meet v5 is an opt-in social layer for adults inside `com.suskiierrands.app`. It sits beside errands, not in place of them. Spec §1 calls it "discreet like WhatsApp, built for meeting people you have not met yet": profiles are discoverable, while behaviour stays private.

- **Shell and layout.** It opens as a third shell with five tabs in the InMessage layout (owner decision 1): **Discover**, **Chats** (unread badge), **Nearby** (People by distance band, plus Events), **Likes** (activity) and **Me**. The visual language is a dark photo UI built from Suskii brand tokens.
- **Meet-ups.** Today's group meet-ups (ADR-0020) become the Events half of the Nearby tab. Their backend is not renamed.

The work splits into a decisions step and three milestones. Each milestone can be shipped on its own and is switched off by server flags:

- **M0: decisions and tooling.** ADRs, open decisions, spikes, authored fixtures, and fixes to the contract generator and parity checker.
- **M1: the social core, with no money.**
  - The 18+ gate, profiles and photos, a daily discovery set, and Nearby by distance band.
  - Likes, passes, winks and super interest; matches with a 24-hour timer.
  - Private 1:1 chat with a fail-closed contact filter, 24-hour statuses and icebreaker games.
  - Reports and blocks, the Events tab, notifications, photo verification, and the admin moderation console.
- **M2: the economy.**
  - Cowries sold as Play consumables, with server verification and RTDN-plus-sweep clawback.
  - A spend menu, the VIP Play subscription and the card ladder.
  - XP levels, streaks, missions, the free daily surprise (the spec's "spin"; perks only), status-only gifts, badge-locked profiles, reach requests and boosts.
- **M3: calls, analytics and polish.**
  - Voice calls billed per 10-minute block by a server sweep that can disconnect a call. Video is a separate flagged PR.
  - Meet analytics.
  - Meet-ups v2: the 18+ gate, host approve/decline and Captain events, once the forced update has passed 1.4.0.
  - An app lock, data-saver tuning, and the Age Signals seam.

The public app 1.4.0 (build 25) keeps working throughout. It never calls a Meet v5 RPC. No existing RPC, table, enum or error code changes name or shape. Every shared function that is restated keeps its behaviour, and pgTAP tests 23, 25, 46 and 59 re-prove it in each PR that touches them.

### 1.2 The owner's binding decisions and how the plan honours them

| # | Decision (2026-11-25) | What the build does |
|---|---|---|
| 1 | InMessage layout patterns in Suskii branding | §6 takes over InMessage's component specs: full-bleed photo cards with a gradient scrim, name + age + blue tick, interest chips, a right-hand action rail (add, chat, big white heart, X), a top bar (Boost rocket left, "Today" centre, filters right), intent chips, an "It's a Match!" screen with two tilted cards, a pink send button and emoji quick replies, perforated ticket cards for events, and a five-tab nav with an unread badge. Three things are deliberately not copied: exact-location map pins (Nearby uses distance bands), "Online now" (presence is never shown), and InMessage's name, logo, icons and imagery |
| 2 | Gifts give status, not cash. Cowries are spend-only. No Earnings. Never frame gifts as payment for attention, company or meetings | Cowries never leave a person's own balance. There is no earnings account, withdrawal path, naira posting, conversion, or function that moves Cowries between users. Gifts confer popularity, XP and card progress only, and only when attached to a status, photo, prompt, profile or reach request, never to a 1:1 chat thread (§5.12, D8) |
| 3 | Group meet-ups stay as one tab; the meetup backend is not renamed | `meetups`, `meetup_attendees`, `meetup_topic`, `meetup_status`, the eight RPCs and the `ERR_MEETUP_*` codes are untouched in M1 and M2. M3's meet-ups v2 changes are additive (new columns and RPCs) and are switched on only after `min_supported_app_version.android` passes 1.4.0 (D12) |
| 4 | Build Google Play Billing now: packs are consumables, VIP is a subscription, server verification, RTDN plus voided-purchase clawback, all behind a server flag that stays OFF | §5.4 covers it end to end. Starting a purchase is gated by `meet.purchases`/`meet.vip`, and those flags cannot be switched on until a readiness record is complete (D23). Verifying a token that has already been paid is never gated, so no paid token is ever stranded |
| 5 | Personal Play account, Supabase Free with no backups, Nigeria in direct-payment mode. Cowries must not touch `public.payments` or the errands ledger | Cowries live in a sealed `meet_econ` schema (D22). There is no `ledger.post`, no row in `public.currencies`, no `Money` type and no `payments` row. A Supabase plan upgrade and working backups are hard readiness items, both before `meet.v5` goes beyond testers and before purchases (D23) |

### 1.3 Design decisions

Where the spec, the owner's parity rule or a candidate design conflicted with safety, this plan chose safety. Every deviation is listed here and carries an open decision for the owner or counsel to confirm or reverse.

| ID | Decision | Why | OD |
|---|---|---|---|
| D1 | **Discovery, photos, chat, statuses, games and the Cowrie economy are Android-app-only.** The website keeps meet-ups, the Meet privacy controls (pause, discoverable, delete Meet profile, blocked list) and Meet notification settings | Spec §3/§13 say "inside the app only… never web". Restrict Minor Access and `FLAG_SECURE` cannot apply in a browser, and purchases need Play Billing. Parity is met through written repository-level `PLATFORM` exemptions | OD-39 |
| D2 | **The Meet contact filter fails closed.** It blocks before delivery and never delivers on hold. Any error in the screen aborts the send | Off-platform migration is the main route for romance and advance-fee scams. This is an explicit exception to OD-21 for Meet only. Errands moderation is unchanged | OD-40 |
| D3 | **Every photo is approved by a person before anyone else sees it** (profile photos and photo statuses) | No image-moderation or CSAM-hash vendor exists. Fail-open does not work for dating images | OD-41 |
| D4 | **No media in Meet chat** in M1–M3: no images, voice notes or links. Chat images are possible later only behind their own flag, with pre-moderation | Removes an unmoderated sextortion and CSAM path | — |
| D5 | **"Show me" (seeking) is optional**, stored apart from the profile, applied one way only (it filters what I see, never who sees me), never displayed, never readable by staff and never in analytics. A `meet_sensitive_data` consent row is recorded the first time gender or seeking is set. Gender is optional (woman or man) and hidden by default. There are no orientation labels or intents | Nigeria's Same Sex Marriage (Prohibition) Act 2013 [S]; entrapment and extortion through dating apps [S] | OD-38 |
| D6 | **Safety controls are free for everyone**: block, report, pause, "hide me from errand contacts", hide gender, read-receipt toggle, the M3 app lock. Platinum's "privacy suite" becomes conveniences only: incognito browsing, hiding last-active, hiding the distance band | Safety must never be paywalled | — |
| D7 | **The daily surprise (the spec's "spin") is free, once a day, for everyone.** No VIP, Cowrie or mission route gives more. Prizes are non-giftable, non-transferable perks, never Cowries. There is no wheel, slot or roulette visual. Odds are published next to it, and the rules are at `/legal/meet-daily-reward-rules` | Real-Money Gambling and loot-box rules; the IARC "random items" answer stays "no" | — |
| D8 | **Gift rules.** Targets are a status, photo, prompt, profile or reach request, **never a 1:1 chat**. Gift notes are canned keys only. Receivers never see a price. There are no leaderboards, wishlists, gift requests, "top gifter" or "sponsor" badges. Accounts that share a device confer nothing. When content is removed for policy, its gifts are refunded to the senders and its popularity is reversed. Every gender is treated identically | Play's sugar-dating clause names gifts | — |
| D9 | VIP "unlimited" winks and reactions cost no Cowries but sit under an anti-spam ceiling | Prevents mass contact | — |
| D10 | Missions reward quality (complete a prompt, reply to a match, finish a game), never volume of contact | Prevents spam incentives | — |
| D11 | **Voice calls first (M3).** Video is a separate flag, needs both people photo-verified and a match at least 72 hours old, and changes the `CAMERA` manifest deliberately in its own PR | Sextortion risk [S]; `mobile-native.yaml` denies `CAMERA` | OD-47 |
| D12 | **The meetup backend is untouched until M3 meet-ups v2.** The eligibility gate, host approval and Captain events are restated only in the PR that can switch them on, after the forced update past 1.4.0 | Restating eight RPCs early adds regression risk to test 59 with no benefit (repo-fit correction) | — |
| D13 | **Statuses are never a feed.** The audience is `matches` or `matches_and_admirers` (people who liked the poster and were not passed). The spec's "followers" maps to admirers, so there is no follow graph. Photo statuses need photo verification and pre-moderation | Spec §9 says "no public feed" | OD-48 |
| D14 | "Who viewed you" shows only a daily count, never identities | Stalking vector | — |
| D15 | **A separate Meet identity.** An opaque `meet_profiles.id` is the only person id any client sees, and also the storage folder. Meet has its own first name and photos. "Hide me from people I've done errands with" is on by default. **No auth uid appears in any object path a viewer can read** | A Meet persona cannot be joined to an errands identity, such as through `get_provider_card(uid)` | — |
| D16 | An `underage` or `child_safety` report puts the subject on an immediate **discovery hold**, a reversible visibility hold that is not a sanction. Suspensions stay human decisions (OD-25) | Child-safety SLA | OD-49 |
| D17 | VIP grants perks only, never a recurring Cowrie bundle | Subscriptions policy | — |
| D18 | **Price check on every spend.** Each spend RPC carries `p_expected_cost`. If the price has changed, the spend is refused (`ERR_MEET_PRICE_CHANGED`) before anything is written | No hidden charges (spec §4) | — |
| D19 | Account deletion is never blocked by a Cowrie balance, and forfeiture is disclosed. An active VIP subscription is cancelled at Play by the worker | Erasure rights | OD-44 |
| D20 | **No presence signals.** No "online now", no online dots, no "Active now". Activity shows only as "Active today" or "Active this week" | Stalking vector (safety judge) | — |
| D21 | **Nearby people are shown as distance-band sections** behind `meet.nearby`. They are ordered by activity, never by distance, with no map of people. The smallest band equals the stored cell (about 5 km), and the number shown per day is capped | Owner decision 1, without trilateration risk | — |
| D22 | **Cowries sit in a sealed `meet_econ` schema** that no client role, and not even `service_role`, can reach. Only SECURITY DEFINER functions touch it. It uses its own wallet plus an append-only entries table whose CHECK constraints encode the posting rules | Owner decision 5. It keeps Cowries out of `ledger.post`, `public.currencies`, `analytics.ledger_daily`, the unpruned `ledger.posted` outbox, and every withdrawal CHECK | — |
| D23 | **Readiness gates enforced in the database.** A trigger on `feature_flags` refuses to enable `meet.v5` for anyone other than testers until the M1 checklist is complete (Play declarations, CSAE page, moderators, **Supabase plan and backups**, counsel answers). It refuses `meet.purchases`/`meet.vip` until the M2 checklist is complete. Disabling is never refused | Engineering judge graft; the safety lens | OD-53 |
| D24 | **Any refusal that records something returns a status; it never raises.** This covers the under-18 refusal, device refusals and contact-filter strikes. A RAISE would roll the record back (the S.2 raise-after-record class) | Repo-fit correction | — |
| D25 | **Dating trust and safety is its own world.** A separate `meet_reports` table, `meet_*` moderation kinds readable only by a new `meet_moderator` admin role and `super_admin` (in country scope), and Meet admin queues that support agents cannot read | The DPIA principle that support sees only what a ticket needs (audit S.1) | OD-41 |

### 1.4 Conflicts resolved

| Conflict | Resolution | Recorded in |
|---|---|---|
| Owner's 2026-10-24 web-parity rule vs spec §3/§13 "never web" | App-only for 18+ surfaces (D1). `check_screen_parity.py` gains repository-level `PLATFORM_REPOSITORIES` with reasons and its own test | ADR-0026, OD-39 |
| Separate Cowrie books (design 1) vs `ledger.post` with XCW (design 3, research map) | Sealed `meet_econ` (D22). The research verdict assumed naira Earnings, and decision 2 removed them | ADR-0027 |
| Nearby dropped (design 1) vs map-like Nearby (designs 2 and 3) | Bands only, behind `meet.nearby`, capped, no presence (D20, D21) | ADR-0026 |
| Chat filter that masks and delivers (designs 2 and 3) vs blocks (design 1) | Block before delivery (spec §13 allows either). Profile text is refused outright | ADR-0026, OD-40 |
| Gifts into chat (designs 2 and 3) vs reactions to content (design 1) | Never in chat (D8). Chat gets free emoji reactions only | ADR-0027 |
| `meet.allow_test_purchases` false (design 2) vs accept (design 1) | Accept and flag `is_test`, because testers' purchases happen on production (decision 5). Test units are excluded from revenue analytics, card spend paths and VIP-day accrual (§5.4.9) | ADR-0028 |
| Restating the meetup RPCs in M1 (design 1) | Deferred to M3 meet-ups v2, after the forced update (D12) | ADR-0026 |
| Report storage in shared `public.reports` (design 1) vs a separate table | Separate `public.meet_reports`. Restating `reports_read_own` (20260922120700) would risk the errands trust console and leave dating reports one policy edit away from support staff (D25) | ADR-0026 |
| Verification selfies in `kyc-docs` (design 1) vs erasable | A new write-only `meet-verify` bucket. `kyc-docs` keeps its legal-retention, never-erasable rule; the selfie can be purged after 30 days through `storage.erase_object` | ADR-0026 |
| Signed URLs (design 1) vs authenticated reads (design 3) | The app reads Meet media **per request through the authenticated object endpoint**, so no shareable link exists and a block takes effect on the next fetch. Staff in the console get signed URLs of at most 300 s | ADR-0026 |
| Silver by play (designs 2 and 3) vs VIP only (design 1, spec §10) | Silver means an active VIP, so VIP keeps recurring value. Gold and above have pay and play paths | ADR-0027, OD-45 |
| XP curve | `total_xp(L) = 25·L²` with a 300/day cap, so play-path timing matches the 3-, 6- and 12-month VIP landmarks (§5.8) | OD-45 |
| Welcome bonus at activation (design 2) | No Cowries at activation. The quick win is XP plus three free-wink perks. A 20-Cowrie welcome grant comes only after photo approval and 72 hours, and counts under the daily free cap | OD-46 |
| Contract skeleton stubs vs `plpgsql_check` unused-parameter warnings | Each stub passes every parameter into `private.meet_not_built(p_fn, p_args jsonb)`, so every parameter is referenced. Lint is run locally before relying on it | §9 rules |
| Version labels (design 1 said 2.6.0) | M1 → **2.7.0**, M2 → **2.8.0**, M3 → **2.9.0**, or the next free MINOR at merge time. 2.6.0 belongs to the unreleased direct-payment MINOR | CHANGELOG |

### 1.5 Milestones at a glance

| Milestone | Scope | Contracts | App | Ships dark behind | Switched on when |
|---|---|---|---|---|---|
| M0 | ADRs, OD-37…OD-53, spikes S-15/S-16/S-17, fixtures, generator and parity-checker fixes, outbox pruning | PATCH (generator fix regenerates `enums.json`) | — | — | Merge |
| M1 | Social core, no money | 2.7.0 | 1.5.0 | `meet.v5` (testers-only payload first) and `meet.discovery`, `meet.nearby`, `meet.chat`, `meet.statuses`, `meet.games`, `meet.photo_verification` | M1 readiness complete (D23) |
| M2 | Economy and Play Billing | 2.8.0 | 1.6.0 | `meet.economy`, `meet.gifts`, `meet.progression`, `meet.spin`, `meet.boosts`, `meet.badge_lock`, `meet.reach`, `meet.vip`, `meet.purchases` | Earned-Cowrie economy first; purchases after M2 readiness and spike S-15 |
| M3 | Calls, analytics, polish, meet-ups v2 | 2.9.0 | 1.7.0 | `meet.calls.voice`, `meet.calls.video`, `meet.meetups_v2` | S-16 passed; forced update past 1.4.0 for meet-ups v2 |

### 1.6 Numbering and ownership

**Numbering**

| Item | Range | Notes |
|---|---|---|
| ADRs | ADR-0026 to ADR-0029 | 0026 Meet v5 social layer, extends ADR-0020. 0027 Cowries, a sealed spend-only economy. 0028 Play Billing verification, RTDN and clawback. 0029 Meet calls billed per block |
| Open decisions | OD-37 to OD-53 | §10.2 |
| Runbooks | RB-17 to RB-19 | RB-16 is field-encryption-keys. **RB-17** Meet moderation and child safety. **RB-18** Play Billing, RTDN, clawback and monthly reconciliation. **RB-19** Meet call billing and disconnect |
| Spikes | S-15 to S-17 | **S-15** Play Billing end to end with license testers. **S-16** LiveKit server-side disconnect and webhook. **S-17** `image_picker` EXIF behaviour and Play Age Signals availability in Nigeria |
| pgTAP | 72 to 89 | 65 stays unused |

**Ownership**

- **Claude Code owns:** `supabase/`, `contracts/` (not `draft/`), `services/`, `infra/`, the `backend-*` workflows, `docs/adr`, `docs/runbooks`, `docs/research`, `docs/audit`, `docs/OPEN-DECISIONS.md` and `docs/store`.
- **Kimi owns** everything under `apps/` and `packages/`, including `apps/web-marketing` legal pages. HANDOFF part 26 records the owner asking Claude Code to build screens for that brief (2026-11-03). **Decided 2026-11-26 (owner): Claude Code builds every Meet v5 PR, frontend included** (app, website and admin), logging each in `HANDOFF.md`. Either way it is logged in `HANDOFF.md` and committed from a throwaway worktree off `origin/main`, never by switching branches in the shared tree.
- **Never build on the stale `.gemini` clone at `f48ff01`.**

### 1.7 Judges' corrections and grafts: where each lands

| Item | Lands in |
|---|---|
| `generate_v1.py` replays `ALTER TYPE … ADD VALUE [IF NOT EXISTS] 'v' [BEFORE|AFTER 'w']`, with a unit test; the regenerated `notification_kind` gains `call_incoming`/`call_missed` | M0-PR2 |
| Contract skeleton migrations at the start of each milestone | M1-PR2, M2-PR3 |
| M0 decisions PR; authored `contracts/v1/fixtures/meet/*.json` | M0-PR1 |
| Nearby & Events tab with distance bands only | D21, §3.2.4, §6 |
| Reuse `public.webhook_events` and `private.ingest_webhook` for RTDN (gateway CHECK widened to `google_play`) | M2-PR5 |
| `private.prune_outbox()` plus cron | M0-PR3 |
| Infrastructure hard gate (plan and backups) | D23, readiness items |
| Canned gift and flirt notes | §5.12 |
| Free-Cowrie farming controls (72 h, approved photo, daily cap; premium gifts blocked under 24 h) | §5.14 |
| Consent kinds `meet_terms`, `meet_sensitive_data` | M1-PR1 |
| Report evidence copied as a content snapshot | §3.2.3 `meet_report_evidence` |
| Authenticated per-request media reads; staff signed URLs of at most 300 s | §2.7 |
| Health check for purchases unconsumed or unacknowledged after 24 h | §5.4.10 |
| InMessage component specs as the client contract; brand-token `MeetColors`; the Meet shell always dark | §6.4 |
| Seamless spend: the wallet in every spend result, an inline "Send Rose · 20" button, store opened at the shortfall, then a replay with the same idempotency key | §5.3, §6 |
| First-session quick win; newcomer spotlight; ladder preview in onboarding | §6.3 |
| Coalesced social notifications | §2.8 |
| 1.4.0 inbox and push: pushes only to devices on 1.5.0 or later | §2.8 |
| Birthday edge cases (29 February, time-zone boundary); call ring timeout from remote config; store screenshots from licensed imagery only | Tests 73, 87; §8.10 |
| Mock store simulating purchased, pending, canceled and `billingUnavailable`; pair advisory lock in swipes | §6.6, §4.2 |
| Call heartbeats, stale sweep, block-1 refund under 60 s, 60 s low-balance warning | §5.13, M3 |
| S-17 spike; iOS StoreKit plan | M0, M3-PR8 |
| `partition_health` and lint lists cover `meet_econ`; `00_structure_test` schema arrays | M2-PR4 |
| Partitioned unique keys include the partition column; spend idempotency anchored in `idempotency_claim` and the bought object's PK | §3, §5.3 |
| No auth uid in viewer-readable paths | D15 |
| `storage.erase_object` event with an allowlist and Deno tests; `kyc-docs` untouched | M1-PR3 |
| `invoke_edge_worker` restated in each migration that adds a worker | M1-PR3, M2-PR6, M3-PR4 |
| `raise_fraud_flag(kind, id, rule_key, score smallint, details)` and `admin_may_read_user(user, roles[])` used with their real signatures | §4 |
| `ERR_INVALID_STATE` and `ERR_IDEMPOTENCY_KEY_IN_PROGRESS` are not in the catalogue, so they are not used | §4.1 |
| `moderation_cases_read` restated: `meet_*` cases are readable only by `meet_moderator`/`super_admin` in scope | M1-PR4 |
| Meet screen runs before `moderate_text`; only certain hold categories open chat cases | §8.2 |
| Concurrency tests as e2e shell scripts beside `ai_quota_e2e.sh` | M1-PR5, M2-PR4 |
| `meet_moderator` widens `is_any_admin()` (14 uses): tested, plus RLS-matrix role column and web-admin role | M1-PR1, M1-PR13 |
| RLS-matrix rows land in the same PR as the objects they name | §9 rules |
| IARC location sharing answered "yes" | §8.10 |
| OD-29 reconciled: decision 4 supersedes it for in-app digital goods only; financial features stay "none" | ADR-0028, OD-51 |
| `blob:` is already in `img-src`, so the CSP is not changed for it | §7 |
| `raise_sos` reused unchanged in the safety centre | §8.4 |
| W10 admin coordination | §7.5 |
| Permanent bans for child safety, underage and ban evasion, with two-person approval | §3.2.3, §4.3 |
| No presence | D20 |
| No "wallet" wording; copy-rule CI grep | §8.12 |

---

## 2. Architecture

### 2.1 Shape

```
                   ┌───────────────────── apps/mobile (Android, 1.5.0+) ─────────────────────┐
                   │ MeetShell (5 tabs) · features/meet/* · StorePurchaseCoordinator (M2)    │
                   │ suskii_domain (entities, Meet repositories) · suskii_data (mock|supabase) │
                   └───────┬──────────────────────────┬───────────────────────────┬─────────┘
             RPC (meet_*)  │      Storage (authenticated │ GET, INSERT to inbox)    │ Edge: meet-purchase-verify (M2)
                           ▼                          ▼                           ▼ meet-call-token (M3)
┌──────────────────────────────────────── Supabase (Postgres 17 + PostGIS) ─────────────────────────────────────────┐
│ public.meet_*  (RLS ENABLE+FORCE, no client grants; SECURITY DEFINER projections + verbs)                         │
│   identity · safety · discovery · chat (partitioned) · statuses · games · progression · gifts (M2) · calls (M3)   │
│ meet_econ.*    (sealed: wallets, entries (partitioned), packs, play_purchases, play_subscriptions, adjustments)   │
│ private.meet_* helpers: meet_flag_on, meet_require_access, meet_may_view, meet_screen_text, meet_spend, …        │
│ shared, restated whole: may_join_topic, notification_channels, collect_personal_data, erase_account,             │
│   invoke_edge_worker, moderation_queue, decide_moderation_case, moderation_cases_read, partition_health (M2)      │
│ outbox aggregates: meet_media → meet-media-worker · storage → storage-worker · meet_billing → meet-billing-worker │
│ webhook_events (gateway 'google_play') ← play-rtdn                                                                │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ Pub/Sub push (OIDC)                ▲ androidpublisher v3                 ▲ LiveKit RoomService (M3, S-16)
   Google Play RTDN ──────────────► play-rtdn       meet-billing-worker / verify          meet-call-worker
web-customer: /meet landing, Events, Meet account controls (no 18+ content)
web-admin: Meet moderation, reports, verifications, readiness and testers (M1); economy, purchases, adjustments (M2); analytics (M3)
```

### 2.2 Access model

1. **Functions are the only way in.** No `meet_*` table and nothing in `meet_econ` is granted to `anon` or `authenticated`. This follows the meetups and `get_provider_card` pattern.
   - Every read is a SECURITY DEFINER projection that returns exactly what one screen draws.
   - Every write is a keyed verb.
2. **Set-based, not row-by-row.** Discovery, nearby, conversations and status rings are each one query against partial indexes. The `private.meetup_rows` trap, a non-inlinable per-row definer function, is not copied.
3. **One visibility vocabulary:**
   - `private.meet_discoverable_to(viewer_profile, target_profile)` is the discovery predicate. The target must be eligible, active, discoverable, not paused, not on hold and not suspended. Both must be in the same country, not blocked either way, and within the viewer's distance and two-way age preferences. The viewer's seeking filter is applied one way. Errand contacts are excluded unless both have switched "hide me from errand contacts" off.
   - `private.meet_connected(a, b)` is true for an open conversation or a pending or active match where neither side has blocked the other.
   - `private.meet_may_view(viewer, target)` is: discoverable to the viewer, OR connected, OR the target is in the viewer's daily set, nearby list or revealed likers for today. Blocks, holds and suspensions are re-checked at read time.
4. **No oracle.** Blocked, hidden, held, suspended and missing profiles all return `ERR_MEET_PROFILE_NOT_FOUND`.
5. **Staff reads go only through `admin_meet_*` functions.** Each requires aal2 and calls `private.audit_write` before returning anything. Each restates country scope with `private.admin_may_read_user(p_user_id, p_roles admin_role[])`, or `private.moderation_subject_countries(kind, id, author_id)` for cases.

### 2.3 Feature gating, testers and readiness

- **`private.meet_flag_on(p_key text, p_user uuid, p_country char(2)) → boolean`** follows the `concierge_enabled` pattern:
  - a country row wins over the global row;
  - the flag is evaluated with `private.flag_on_for(key, rollout_pct, user)`;
  - **except** when `feature_flags.payload ->> 'testers_only' = 'true'`, in which case only users in `private.meet_testers` pass.
  - Every sub-flag also requires `meet.v5`.
- **`private.meet_require_access(p_user, p_feature text, p_need_profile boolean)`** runs at the top of every client RPC. It checks, in order:
  1. the flag (`ERR_FEATURE_UNAVAILABLE`);
  2. the profile country (`ERR_COUNTRY_NOT_SET`);
  3. eligibility (`ERR_MEET_ELIGIBILITY_REQUIRED`; a refused or banned device gives `ERR_MEET_UNAVAILABLE`);
  4. the current guidelines version (`ERR_MEET_GUIDELINES_OUTDATED`);
  5. suspension (`ERR_MEET_SUSPENDED`);
  6. when needed, an active profile (`ERR_MEET_PROFILE_INCOMPLETE`).

  It also updates `last_active_on`. All of these are pure checks, so raising is safe.
- **Testers:** `private.meet_testers(user_id uuid PK → auth.users ON DELETE CASCADE, note text ≤200, added_by uuid, added_at)`. They are managed by `admin_meet_set_tester` (super_admin, MFA, audited).
- **Readiness:** `private.meet_readiness(item text PK ~'^[a-z0-9_]{3,60}$', milestone text CHECK IN ('m1','m2','m2_testers'), done boolean DEFAULT false, auto boolean DEFAULT false, note text ≤500, set_by uuid, set_at timestamptz)`. It is seeded in migrations:

  | Milestone | Items |
  |---|---|
  | **m1** | `play_restrict_minor_access`, `play_child_safety_standards`, `play_content_rating`, `play_data_safety`, `play_listing_meet_copy`, `csae_page_live`, `childsafety_contact_live`, `meet_guidelines_page_live`, `supabase_plan_upgraded`, `backups_running`, `counsel_od37_od38_od42`, `owner_od39_od40_od41`, `meet_moderators_staffed` (auto: at least two `meet_moderator` admins with MFA enrolled) |
  | **m2_testers** | `payments_profile_ok`, `products_created`, `billing_secret_set`, `rtdn_test_received` (auto, set by `play-rtdn` on `testNotification`) |
  | **m2** | The m2_testers items plus `merchant_bank_tax_done`, `license_tests_passed` (S-15), `counsel_cowrie_terms` (OD-44), `owner_od51_revenue`, `supabase_plan_upgraded`, `backups_running` |

- **Guard trigger:** `feature_flags_meet_readiness` runs BEFORE INSERT OR UPDATE ON `public.feature_flags` FOR EACH ROW WHEN `NEW.key IN ('meet.v5','meet.purchases','meet.vip') AND NEW.enabled`, calling `private.meet_flag_readiness_guard()`.
  - `meet.v5`: allowed when `testers_only`, else every m1 item must be done.
  - `meet.purchases`/`meet.vip`: with `testers_only` the m2_testers items must be done, else every m2 item.
  - A refusal raises a catchable `P0001 'ERR_MEET_NOT_READY'` with DETAIL listing the missing items, so a `review_config_change` apply aborts and the proposal stays pending.
  - **Disabling is never checked**, so the RB-13 kill switch always works.
- **As built (rev. 2026-11-26, M1-PR2, `20261126120100_meet_v5_contract`).** Four refinements, each tested in pgTAP 72:
  - The guard is an **AFTER** row trigger, not BEFORE. `apply_config_change` writes flags with `INSERT … ON CONFLICT DO UPDATE`, and a BEFORE INSERT trigger fires on the insert row even when the conflict turns it into an update. A proposal of `{"enabled": true}` builds that row with an empty payload, so a BEFORE guard refused the release step "switch `meet.v5` on, testers-only". An AFTER row trigger sees only what was written and still raises inside the statement.
  - `meet_readiness` gains `gates text[]`: the enables an item holds back (`m1`, `m2_testers`, `m2`). The plan upgrade and backups are `m1` items gating `m1` and `m2`, which the table above says in words.
  - `meet.v5` is seeded at `rollout_pct` 0. Testers pass whatever the percentage, and leaving testers takes a deliberate one.
  - `meet_require_access` answers the flag and the country, then refuses everybody with `ERR_MEET_ELIGIBILITY_REQUIRED` until M1-PR3 restates it with the eligibility record, so it fails closed if called early.

### 2.4 Edge Functions and workers

| Function | Auth | Called by | Milestone | Purpose |
|---|---|---|---|---|
| `meet-media-worker` | worker key, `verify_jwt=false` | cron through `invoke_edge_worker` | M1 | Claims the `meet_media` aggregate. Checks the inbox object's magic bytes, size and dimensions; strips metadata byte by byte; hashes with SHA-256; writes `meet-media`; deletes the inbox object; calls `gateway_meet_media_ingested`/`…_failed` |
| `storage-worker` (existing) | worker key | cron | M1 change | `ERASABLE_BUCKETS += meet-inbox, meet-media, meet-verify`; new event `storage.erase_object` |
| `notifications-worker` (existing) | worker key | cron | M1 change | Uses `dispatch_push_targets_for_kind(user, kind)` so `meet_*` pushes reach only devices on `meet.min_client_version` (1.5.0) or later |
| `kyc-document-url` (existing) | user JWT | admin console | M1 change | Gains body `subject: 'meet_verification'`. It then calls `admin_meet_verification_access` and signs from `meet-verify` (300 s) |
| `meet-purchase-verify` | user JWT | app | M2 | **The only new app-callable function in M2** |
| `play-rtdn` | `verify_jwt=false`; Pub/Sub OIDC checked in code | Google Pub/Sub push | M2 | Stores raw → de-duplicates → re-reads the state from the API → grants, syncs or voids |
| `meet-billing-worker` | worker key | cron | M2 | Retries verify, consume and acknowledge; runs the voided sweep and subscription resync; handles refunds and revokes for rejected tokens; cancels subscriptions on erasure |
| `meet-call-token` | user JWT | app | M3 | Starts or answers a call; mints a LiveKit token (identity = profile id, microphone only unless video is on) |
| `meet-call-worker` | worker key | cron | M3 | Bills due blocks; force-ends unpaid or stale calls; disconnects through LiveKit RoomService (S-16) |
| `livekit-webhook` | `verify_jwt=false`; LiveKit signature | LiveKit | M3, optional after S-16 | `room_finished`/`participant_left` backstop |

`private.invoke_edge_worker`'s fixed allowlist (`notifications-worker`, `storage-worker`, `payments-worker` in 20261026120000) is **restated whole** in the migration that adds each worker:

| Migration | Adds |
|---|---|
| M1 identity | `meet-media-worker` |
| M2 wallet/billing | `meet-billing-worker` |
| M3 calls | `meet-call-worker` |

### 2.5 Cron jobs

| Job | Schedule | Work | Milestone |
|---|---|---|---|
| `meet-sweeps` | `*/5 * * * *` | `meet_expire_matches`, `meet_match_reminders`, `meet_expire_statuses` (emits `storage.erase_object`), `meet_expire_rounds`, `meet_lift_restrictions`, `meet_release_holds_expired` | M1 |
| `meet-daily` | `10 2 * * *` | Purges past `purge_after`; drops safety-event partitions older than 3 months; daily-set and view-count retention; daily nudges | M1 |
| `meet-messages-partitions`, `meet-safety-partitions` | `33 3 * * *` | `private.ensure_monthly_partitions(…, 3)` | M1 |
| `meet-media-dispatch` | `* * * * *` | `invoke_edge_worker('meet-media-worker')` | M1 |
| `outbox-prune` | `47 3 * * *` | `private.prune_outbox()` | M0 |
| `meet-health` | `*/15 * * * *` | `meet_moderation_sla`, `meet_media_backlog` health checks | M1 |
| `meet-billing` | `*/10 * * * *` | `invoke_edge_worker('meet-billing-worker')` (hourly voided sweep and daily resync are decided inside) | M2 |
| `meet-econ-partitions` | `35 3 * * *` | `ensure_monthly_partitions('meet_econ.entries', 3)` | M2 |
| `meet-popularity` | `17 * * * *` | Recompute `score_30d` | M2 |
| `meet-progress-daily` | `15 0 * * *` | VIP-day accrual, card recompute, streak-reminder candidates | M2 |
| `meet-cards-monthly` | `0 23 L * *` UTC | Captain upkeep review (7-day warning first) | M2 |
| `meet-reconcile` | `40 2 * * *` | `private.meet_reconcile()` → `record_health_check('meet_wallets')`; `meet_billing_unacknowledged` check | M2 |
| `meet-calls` | `* * * * *` | `private.meet_bill_calls()`, `meet_expire_calls()`, `invoke_edge_worker('meet-call-worker')` | M3 |

### 2.6 Realtime

**Topic `meet:{conversation_id}`** is added to `private.may_join_topic`, restated whole from 20260918120600 with all five existing branches kept and asserted. Only the conversation's two members may join.

| Event | Payload | From |
|---|---|---|
| `meet.message` | `{conversation_id, message_id}` | server |
| `meet.read` | `{profile_id, message_id}` | server |
| `meet.reaction` | `{message_id}` | server |
| `meet.game` | `{round_id}` | server |
| `meet.closed` | `{}` | server |
| `meet.call` | `{call_id, state}` | server (M3) |
| `meet.call.low_balance` | `{call_id, seconds}` | server (M3) |
| `meet.typing` | `{profile_id}` | client; authored in `contracts/v1/realtime-events/client-events.json` |

**Topic `user:{uid}`** gains `meet.inbox {kind}` and, from M2, `meet.wallet {version}`.

- Broadcasts use the literal `'meet:'` prefix, so `generate_v1.py realtime_topics()` sees them.
- Broadcasts carry ids only. Every read re-checks membership through RPCs, so privacy holds even though realtime authorisation is unverified (S-02).

### 2.7 Storage buckets and the media pipeline

| Bucket | Limits | Client access |
|---|---|---|
| `meet-inbox` | private, 8 MB; jpeg, png, webp | INSERT only, by a Meet-eligible caller, into `(storage.foldername(name))[1] = auth.uid()::text`. No SELECT, UPDATE or DELETE. Never readable by anyone but the worker, so a uid here leaks nothing |
| `meet-media` | private, 5 MB; same types | No client writes. SELECT through policy `meet_media_read USING ((SELECT private.meet_media_visible_to(name, auth.uid())))`. Paths: `<profile_id>/p/<photo_id>.<ext>`, `<profile_id>/pt/<photo_id>.<ext>` (320 px thumb), `<profile_id>/s/<status_id>.<ext>` |
| `meet-verify` | private, 5 MB; jpeg | INSERT only into the caller's own `<uid>/` folder. No client SELECT. Staff read through `kyc-document-url` (subject `meet_verification`). Purged 30 days after decision |

**`private.meet_media_visible_to(name, viewer)`** uses index lookups only and admits:

- the owner, including pending media;
- a viewer for whom `meet_may_view` holds, for **approved** media. In M2, positions ≥ 1 of a locked profile are excluded unless the viewer's card meets the lock or an unlock is active;
- a live status within its audience;
- `meet_moderator` or `super_admin` in country scope.

**How the app reads media.** The app fetches `GET /storage/v1/object/authenticated/meet-media/<path>` with the session bearer, through a path-keyed `ImageProvider`. RLS is evaluated per fetch, so a block applies immediately and there is no shareable URL. The admin console uses `createSignedUrls` with at most a 300 s TTL under the staff branch of the policy.

**Pipeline:**

1. The client picks a photo with the system picker (no `CAMERA` or `READ_MEDIA` permission). It produces a 1080 px JPEG at quality 80 and a 320 px thumb, then uploads both to `meet-inbox`.
2. `meet_submit_photo` validates both inbox paths and emits outbox `('meet_media', profile_id, 'meet.media.ingest', {kind:'photo', id})`.
3. `meet-media-worker` strips metadata in `_shared/media/strip_metadata.ts`:
   - JPEG: APP1–APP15 and COM segments;
   - PNG: tEXt, iTXt, zTXt, eXIf and tIME chunks;
   - WebP: EXIF and XMP chunks, clearing the VP8X flags.
4. It checks the magic bytes, the size and the dimensions (main 320–4096 px, thumb 160–480 px), and computes SHA-256.
5. It writes both files to `meet-media` and deletes the inbox objects.
6. `gateway_meet_media_ingested` sets the photo to `pending_review`, opens a `meet_photo` case and raises `photo_reuse` when the hash matches another user's photo.
7. A person approves or rejects it (`admin_meet_decide_photo`).

**Erasure:** storage-worker gains event `storage.erase_object` with payload `{bucket, path}`. It is accepted only when:

- `bucket` is in `ERASABLE_BUCKETS`;
- `path` starts with `${aggregate_id}/`;
- `path` matches `^[0-9a-f-]{36}/(p|pt|s)/[0-9a-f-]{36}\.(jpg|png|webp)$` for `meet-media`, `^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$` for `meet-inbox`, or `^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$` for `meet-verify`.

Whole-folder erasure keeps using `storage.erase_prefix`. `kyc-docs` stays non-erasable.

### 2.8 Notifications

**New kinds**, each `ALTER TYPE … ADD VALUE` in its own migration:

| Milestone | Kinds |
|---|---|
| M1 | `meet_like`, `meet_match`, `meet_message`, `meet_reminder`, `meet_account` |
| M2 | `meet_gift`, `meet_request`, `meet_progress` |
| M3 | `meet_call_incoming`, `meet_call_missed` |

None is added to `private.notification_is_urgent`, so quiet hours always apply, including to Meet calls.

**Categories:**

- `notification_preferences.category` CHECK widens to add `'social'` and `'social_nudges'`.
- New `private.notification_category(kind) → text`:

  | Kinds | Category |
  |---|---|
  | `meet_like`, `meet_match`, `meet_message`, `meet_gift`, `meet_request`, `meet_call_*` | `social` |
  | `meet_reminder`, `meet_progress` | `social_nudges` |
  | `meet_account` and every existing kind | `transactional` |

- `private.notification_channels` (20260921120600) is **restated whole** to read the preference row for `notification_category(kind)`. The result for every existing kind is identical.

**Coalescing.** `private.meet_notify(p_user, p_kind, p_title_key, p_body_key, p_params, p_deep_link, p_coalesce_key, p_window)` wraps `private.notify`. It:

- skips when `public.notifications` already holds the same user, kind and coalesce key inside the window. Windows: likes and winks 3 h; messages 10 min per conversation; views once a day;
- caps social pushes at `meet.notify.max_social_per_hour` (6);
- keeps params to ids only.

Title keys are generic ("Someone likes you", "You have a new match", "New message", "Your photo has been reviewed", "A gift arrived"). Never a name, amount or gift name.

**Payload rule.** `FORBIDDEN_IN_PUSH` in `_shared/notifications/sender.ts` gains `"cowries"`, `"units"`, `"first_name"` and `"gift_key"`. The test uses `payloadIsSafe`.

**1.4.0 compatibility:**

- New `public.dispatch_push_targets_for_kind(p_user_id uuid, p_kind notification_kind)`, for `service_role` only, is the existing function plus `app_version >= remote_config('meet.min_client_version')` for `meet_*` kinds. `notifications-worker` switches to it, and the old function stays.
- Inbox rows still appear on any 1.4.0 install a Meet user also owns. 1.4.0 may render the unknown title key raw. That is cosmetic, affects Meet users only, and is accepted and verified in RB-17.

### 2.9 Shared objects restated or widened

Each is restated **whole** from the latest version named here, in the PR shown, with regression tests rerun.

| Object | Latest on main | Change | PR |
|---|---|---|---|
| `contracts/tools/generate_v1.py` `declared_enums()` | — | Replays `ALTER TYPE … ADD VALUE` | M0-PR2 |
| `contracts/tools/check_screen_parity.py` | — | `PLATFORM_REPOSITORIES` dict plus test | M0-PR2 |
| `private.invoke_edge_worker` | 20261026120000 | Adds each new worker | M1-PR3, M2-PR6, M3-PR4 |
| `storage-worker/handler.ts` | — | Buckets plus `storage.erase_object` | M1-PR3 |
| `legal_documents_type_check` | 20260916120500 | Adds `meet_guidelines`, `meet_terms`, `meet_reward_rules`, `child_safety` | M1-PR3 |
| `moderation_cases_subject_kind_check` | 20261024120100 | Adds `meet_profile`, `meet_prompt`, `meet_photo`, `meet_status`, `meet_message`, `meet_game_answer`, then `meet_reach_note` (M2) | M1-PR4, M2-PR8 |
| `moderation_cases_read` policy | 20260922121000 | Authors can no longer read their own `meet_*` cases; those are readable only by `meet_moderator` and `super_admin` in scope | M1-PR4 |
| `public.moderation_queue` | 20260922121000 | Excludes `meet_*` | M1-PR4 |
| `public.decide_moderation_case` | 20260921120200 | Refuses `meet_*` (`ERR_MODERATION_CASE_NOT_FOUND`) | M1-PR4 |
| `public.blocks` | 20260918120700 | ADD `source text NOT NULL DEFAULT 'errands' CHECK IN ('errands','meet')`. `is_blocked_pair` is unchanged, so a block applies everywhere (OD-52) | M1-PR4 |
| `private.run_risk_rules` | 20260921120300 | Adds Meet rules (flags only) | M1-PR4, M2-PR8 |
| `notification_preferences` category CHECK | 20260916120600 | Adds `social`, `social_nudges` | M1-PR5 |
| `private.notification_channels` | 20260921120600 | Reads the category | M1-PR5 |
| `private.may_join_topic` | 20260918120600 | Adds `meet:` | M1-PR6 |
| `private.collect_personal_data` | 20261024120100 | Meet tables | M1-PR8, M2-PR9 |
| `private.erase_account` | 20261026190000_concierge | Meet tables | M1-PR8, M2-PR9 |
| `private.partition_health` | 20260922120400 | Scans `('public','private','audit','meet_econ')`; `record_partition_health` is unchanged | M2-PR4 |
| `webhook_events` gateway CHECK | 20260921121000 | Adds `google_play` | M2-PR5 |
| `private.config_change_levels` | 20260922120100 | `meet.spend_costs`, `meet.cards`, `meet.spin.prizes`, `meet.gifts.caps`, `meet.billing`, `meet.xp` require two signatures | M2-PR5 |
| `private.approval_subject_country` | 20260922121400 | `meet_ban` and `meet_cowrie_adjustment` branches | M1-PR4, M2-PR5 |
| `_shared/notifications/sender.ts` `FORBIDDEN_IN_PUSH` | — | Meet keys | M1-PR5 |
| `backend-db.yaml` lint `--schema`, `supabase/README.md` | — | Add `meet_econ` | M2-PR4 |
| `00_structure_test.sql` schema arrays and allowlists | — | Add `meet_econ`, every new function | Each backend PR |
| `supabase/tools/check_production_reference.sql` | — | Asserts `public.meet_profiles` is empty on a migrations-only database (no seeded people in production) | M1-PR3 |

### 2.10 Keeping 1.4.0 working

- No meetup object is renamed or reshaped (MINOR contracts only).
- `get_bootstrap` is not restated. New `feature_flags` rows appear in its map and are ignored by 1.4.0.
- 1.4.0's `routeForPushLink` maps `/meet/<x>` only when `x` matches `^[0-9a-fA-F-]{8,64}$`. Every new link shape (`/meet/chats/…`, `/meet/matches/…`, `/meet/likes`, `/meet/me…`) fails that test and falls back to `/meet`, the meet-ups page, which is harmless. Legacy `/meet/<uuid>` links keep working in new builds through a redirect.
- Meet pushes go only to devices on 1.5.0 or later (§2.8).
- Restated shared functions are proven by rerunning tests 23 (moderation), 25 (calls), 46 (account lifecycle), 59 (meet-ups) and the realtime assertions.

### 2.11 Performance and Free-plan capacity

- **Indexes:**
  - discovery pool partial index `meet_profiles_pool ON (country_code, area_geohash) WHERE status='active' AND discoverable AND paused_at IS NULL AND hold_reason IS NULL`;
  - GiST on `area_point` (cell centroid) with the same predicate;
  - `meet_swipes (to_profile_id) WHERE action='like'`;
  - `meet_messages (conversation_id, id DESC)` per partition.
- **Plans:** `77_meet_discovery_test` asserts with EXPLAIN that the pool index is used. M3 benches 100k synthetic profiles in a throwaway database.
- **Free plan:** one profile is about 6 × (≈250 KB + 25 KB), roughly 1.7 MB, so 1 GB of storage holds about 600 profiles, and egress runs out faster still. That is why the plan upgrade and backups are m1 readiness items before `meet.v5` leaves testers. Chat and safety events are partitioned with retention, and `prune_outbox` removes dead rows.

---

## 3. Data model

**Conventions for every Meet table:**

- RLS ENABLE plus FORCE, and `REVOKE ALL … FROM PUBLIC, anon, authenticated`, with no client policies.
- `service_role` is granted only where a worker needs it.
- Text CHECKs are used instead of new enums. The exceptions are values added to existing enums: `notification_kind`, `admin_role`, `consent_kind`.
- Every personal table is added to `collect_personal_data` and `erase_account`.
- Every table and function gets a "Meet v5" row in `docs/plan/rls-policy-matrix.md` **in the same PR** as the objects. Client cells are "— (functions only)" and staff cells "R:scope via `admin_meet_*`". Divergences go in `supabase/tools/rls-matrix-waivers.json` with a reason.
- Reference data (interest keys, prompt keys, text rules, game prompts, gift catalogue, packs, missions, levels, flags, config, readiness items) **ships in migrations, not seed**.
- Partitioned tables put the partition column in every PK and UNIQUE.

### 3.1 M1 migrations

Placeholder stamps; each PR takes the next free stamp after `origin/main`'s newest.

1. `20261125120000_prune_outbox.sql` (M0-PR3)
2. `20261126120000_meet_v5_enum_values.sql`. Additions only:
   - `notification_kind`: `meet_like`, `meet_match`, `meet_message`, `meet_reminder`, `meet_account`;
   - `admin_role`: `meet_moderator`;
   - `consent_kind`: `meet_terms`, `meet_sensitive_data`.
3. `20261126120100_meet_v5_contract.sql`: skeleton, gating, readiness, testers, flags, config.
4. `…120200_meet_v5_identity.sql`
5. `…120300_meet_v5_safety.sql`
6. `…120400_meet_v5_discovery.sql`
7. `…120500_meet_v5_chat.sql`
8. `…120600_meet_v5_statuses_games.sql`
9. `…120700_meet_v5_lifecycle.sql`
10. `…120800_meet_v5_verification.sql`

### 3.2 M1 tables

#### 3.2.1 Identity

**`public.meet_eligibility`**, one row per account, which survives deletion of the Meet profile.

| Column | Definition |
|---|---|
| `user_id` | uuid PK → auth.users ON DELETE CASCADE |
| `status` | text NOT NULL CHECK IN ('eligible','refused_minor','revoked') |
| `birth_date` | date, with CHECK `((status='eligible') = (birth_date IS NOT NULL))`. **A minor's birth date is never stored** |
| `method` | text NOT NULL DEFAULT 'self_declared' CHECK IN ('self_declared','support_corrected','age_signal') |
| `age_signal` | jsonb NULL; seam for the Play Age Signals API (VERIFY-IN-RESEARCH, S-17) |
| `guidelines_version` | int NOT NULL |
| `guidelines_accepted_at` | timestamptz NOT NULL |
| `attested_at`, `updated_at` | timestamptz |
| `revoked_reason` | text ≤200 |

**`public.meet_age_refusal_devices`**: `device_fingerprint_hash bytea PK`, `refused_at`, `expires_at` (now + `meet.retention.age_refusal_device_days`, 365). No user id and no birth date.

**`public.meet_profiles`**

| Column | Definition |
|---|---|
| `id` | uuid PK DEFAULT gen_random_uuid(). **The only person id a client sees, and the storage folder** |
| `user_id` | uuid NOT NULL UNIQUE → auth.users ON DELETE CASCADE |
| `country_code` | char(2) NOT NULL → countries |
| `first_name` | text NOT NULL CHECK `first_name ~ '^[[:alpha:]][[:alpha:] ''-]{0,29}$'` (no digits, @, _ or dots, so no handle fits) |
| `bio` | text CHECK length ≤ 300 |
| `intent` | text NOT NULL DEFAULT 'open' CHECK IN ('love','friendship','hangout','open') |
| `gender` | text NULL CHECK IN ('woman','man') |
| `show_gender` | bool NOT NULL DEFAULT false |
| `interests` | text[] NOT NULL DEFAULT '{}' CHECK cardinality ≤ 8; every element in `meet_interest_keys` (trigger) |
| `area_geohash` | text CHECK `~ '^[0-9b-hjkmnp-z]{5}$'`; `ST_GeoHash(point,5)` ≈ 4.9 km cell |
| `area_point` | geography(Point,4326); the **cell centroid** (`ST_PointFromGeoHash`), never the raw point |
| `area_city_code` | text; with `country_code` → `public.cities` (nearest service-area city, for the label) |
| `area_set_at` | timestamptz |
| `status` | text NOT NULL DEFAULT 'draft' CHECK IN ('draft','pending_review','active','removed') |
| `text_moderation` | text NOT NULL DEFAULT 'clean' CHECK IN ('clean','held') |
| `discoverable` | bool NOT NULL DEFAULT false |
| `paused_at` | timestamptz |
| `hold_reason` | text NULL CHECK IN ('child_safety_report','underage_report','moderation') ; `hold_at` |
| `hide_from_errand_contacts` | bool NOT NULL DEFAULT true |
| `read_receipts` | bool NOT NULL DEFAULT true |
| `photo_verified_at` | timestamptz |
| `newcomer_until` | timestamptz (approval + 24 h; spotlight weight) |
| `last_active_on` | date (day granularity only) |
| `version` | int NOT NULL DEFAULT 1 |
| `created_at`, `updated_at` | timestamptz (`private.touch_updated_at`) |

- **Indexes:** `meet_profiles_pool` (above), GiST `(area_point)` with the same predicate, and `(country_code, last_active_on DESC)`.
- **Trigger** `meet_profiles_screen`: BEFORE INSERT OR UPDATE OF `first_name, bio`. It runs `private.meet_screen_text` (surface `first_name`/`bio`); a contact or solicitation hit raises `ERR_MEET_CONTACT_NOT_ALLOWED` or `ERR_MEET_SOLICITATION_NOT_ALLOWED`. It then runs `private.moderate_text`; a block raises `ERR_CONTENT_NOT_ALLOWED`, and a hold sets `text_moderation='held'` and opens a `meet_profile` case. The trigger writes nothing before a raise.

**`public.meet_discovery_prefs`**. Read only by the owner's own functions. It never appears in an admin function, analytics view, staff export or a partner's export.

| Column | Definition |
|---|---|
| `user_id` | uuid PK → auth.users ON DELETE CASCADE |
| `seeking` | text NOT NULL DEFAULT 'everyone' CHECK IN ('women','men','everyone') |
| `age_min` | smallint NOT NULL DEFAULT 18 CHECK BETWEEN 18 AND 99 |
| `age_max` | smallint NOT NULL DEFAULT 60 CHECK (age_max BETWEEN age_min AND 99) |
| `max_band_km` | smallint NOT NULL DEFAULT 50 CHECK IN (5,10,25,50,100) |
| `intents` | text[] NOT NULL DEFAULT '{}' |
| `updated_at` | timestamptz |

**Reference data:** `public.meet_interest_keys (key text PK ~ '^[a-z_]{2,30}$', active bool, sort smallint)` with about 30 keys, and `public.meet_prompt_keys (key text PK, active bool, sort smallint)` with about 20 keys. Labels are l10n keys.

**`public.meet_photos`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `profile_id` | uuid NOT NULL → meet_profiles ON DELETE CASCADE |
| `position` | smallint NOT NULL CHECK 0..5 |
| `inbox_path`, `thumb_inbox_path` | text; NULL after ingest; never returned to others |
| `media_path`, `thumb_path` | text; `meet-media` paths |
| `sha256` | bytea |
| `width`, `height` | int |
| `mime` | text CHECK IN ('image/jpeg','image/png','image/webp') |
| `status` | text NOT NULL CHECK IN ('processing','pending_review','approved','rejected','removed','failed') |
| `reason_code` | text CHECK IN ('not_a_person','not_you','explicit','underage_appearance','contact_details','violence','low_quality','reused','other') |
| `reviewed_by`, `reviewed_at`, `created_at` | |

`UNIQUE (profile_id, position) WHERE status IN ('processing','pending_review','approved')`; index `(sha256)`.

**`public.meet_prompts`**: `id uuid PK`, `profile_id → CASCADE`, `prompt_key → meet_prompt_keys`, `answer text CHECK length 1..150`, `position smallint CHECK 0..2`, `moderation text CHECK IN ('clean','held','removed')`, `created_at`. `UNIQUE (profile_id, position)`. Screened like a bio.

#### 3.2.2 Gating (in the contract migration)

These are `private.meet_testers` and `private.meet_readiness` (§2.3), plus `private.meet_not_built(p_fn text, p_args jsonb)`, which raises `ERR_FEATURE_UNAVAILABLE` and is used only by skeleton stubs.

#### 3.2.3 Safety

**`public.meet_text_rules`**. Meet-only; `prohibited_items` and `moderate_text` are not touched.

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `country_code` | char(2) NULL |
| `key` | text CHECK `~ '^[a-z0-9_]{2,60}$'` |
| `category` | text CHECK IN ('contact','solicitation','sexual','underage','scam','harassment','platform') |
| `match_terms` | text[]; each `~ '^[a-z0-9 -]+$'` (no regex, as `prohibited_items`) |
| `action` | text CHECK IN ('block','hold') |
| `surfaces` | text[] ⊆ {message, bio, first_name, prompt, status, game_answer, reach_note} |
| `active` | bool |

`UNIQUE (coalesce(country_code,'**'), key)`. Seeded as `[A]` (OD-24, OD-50).

**`public.meet_safety_events`**, PARTITION BY RANGE (created_at), monthly. **No content.**

| Column | Definition |
|---|---|
| `id` | bigint identity |
| `user_id` | uuid |
| `kind` | text CHECK IN ('contact_blocked','solicitation_blocked','platform_mention','rate_limited','age_refused','device_refused','restricted') |
| `surface` | text |
| `rule_keys` | text[] |
| `created_at` | timestamptz |

PK `(id, created_at)`. Partitions older than 3 months are dropped.

**`public.meet_restrictions`**: `id uuid PK`, `user_id`, `scope text CHECK IN ('messages','new_conversations','likes','statuses','reach','all')`, `source text CHECK IN ('auto_contact','auto_rate','moderator')`, `reason_code`, `starts_at`, `ends_at timestamptz NOT NULL`, `lifted_at`, `created_by uuid NULL`.

**`public.meet_suspensions`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `user_id` | uuid → auth.users ON DELETE CASCADE |
| `reason_code` | text CHECK IN ('harassment','scam','solicitation','sexual_content','underage','child_safety','fake_profile','ban_evasion','other') |
| `starts_at`, `ends_at` | timestamptz; `ends_at` NULL only when `reason_code IN ('child_safety','underage','ban_evasion')` (CHECK) |
| `approval_id` | uuid NULL → public.approvals; **required for `ends_at IS NULL`** (two-person rule) |
| `decided_by` | uuid NOT NULL |
| `note` | ≤500 |
| `lifted_at`, `lifted_by`, `lift_note` | |

**`public.meet_banned_devices`**: `device_fingerprint_hash bytea PK`, `suspension_id → meet_suspensions`, `expires_at NULL`.

**`public.meet_reports`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `reporter_user_id`, `reporter_profile_id` | uuid NULL (NULL after erasure) |
| `subject_user_id`, `subject_profile_id` | uuid NULL |
| `subject_kind` | text NOT NULL CHECK IN ('meet_profile','meet_photo','meet_prompt','meet_message','meet_status','meet_game_answer','meet_reach','none') (`none` for a child-safety concern with no subject) |
| `subject_id` | text ≤100 |
| `reason_code` | text NOT NULL CHECK IN ('underage','child_safety','fake_or_impersonation','scam_or_money_request','asking_for_gifts','sexual_content','harassment','hate','threat_or_violence','contact_sharing','spam','offline_safety','other') |
| `details` | text ≤2000 |
| `priority` | smallint 1..5 (1 = child safety or underage) |
| `status` | text CHECK IN ('open','reviewing','actioned','dismissed','escalated') DEFAULT 'open' |
| `outcome` | text CHECK IN ('dismissed','content_removed','warned','restricted','suspended','escalated') |
| `case_id` | uuid NULL → moderation_cases |
| `sla_due_at`, `resolved_by`, `resolved_at`, `resolution_note`, `created_at` | |

Index `(status, priority, sla_due_at)`.

**`public.meet_report_evidence`**. A **content snapshot** copied at report time, so erasure cannot remove what a moderator must review.

| Column | Definition |
|---|---|
| `report_id` | uuid PK → meet_reports ON DELETE CASCADE |
| `snapshot` | jsonb: up to 41 messages (the reported one ± 20) as `{id, side:'reporter'|'subject', kind, body, at}`, or the profile text, status text, game answer, or photo `media_path` plus a copied object reference |
| `media_copies` | text[]: copies made under `meet-media/<subject_profile_id>/e/<report_id>/…` by the worker; excluded from `erase_prefix` sweeps until `retain_until` |
| `captured_at` | timestamptz |
| `retain_until` | timestamptz = case closed + 90 days, purged by `meet-daily` |

#### 3.2.4 Discovery and matches

**`public.meet_daily_sets`**

| Column | Definition |
|---|---|
| `user_id` | uuid |
| `set_date` | date (caller's local day, `private.user_timezone`) |
| `candidates` | uuid[] NOT NULL (≤ 40 profile ids) |
| `spotlight` | uuid[] DEFAULT '{}' (M2 boosts) |
| `nearby` | uuid[] DEFAULT '{}' (profiles shown in Nearby today) |
| `acted` | uuid[] DEFAULT '{}' |
| `generated_at` | timestamptz |

PK `(user_id, set_date)`. Purged after 7 days.

**`public.meet_swipes`**

| Column | Definition |
|---|---|
| `from_profile_id`, `to_profile_id` | uuid → meet_profiles ON DELETE CASCADE |
| `action` | text CHECK IN ('like','pass') |
| `like_kind` | text CHECK IN ('like','super_interest'); CHECK `((action='like') = (like_kind IS NOT NULL))` |
| `pass_until` | timestamptz (`'infinity'` after an unmatch) |
| `source` | text CHECK IN ('set','nearby','likes','profile') |
| `seen_by_target_at`, `created_at` | |

PK `(from_profile_id, to_profile_id)`; index `(to_profile_id, created_at DESC) WHERE action='like'`.

**`public.meet_signals`**: `id bigint identity PK`, `from_profile_id`, `to_profile_id`, `kind text CHECK IN ('wink','poke')`, `cost_cowries int DEFAULT 0`, `entry_id bigint NULL` (M2), `created_on date`, `created_at`, `seen_at`. `UNIQUE (from_profile_id, to_profile_id, kind, created_on)`.

**`public.meet_daily_counters`**: `user_id`, `day date`, `likes`, `super_interests`, `winks`, `pokes`, `new_conversations`, `reports`, `nearby_seen` (all int), `msg_minute_bucket timestamptz`, `msg_minute_count int`, `vip_free_actions int` (M2). PK `(user_id, day)`. Locked FOR UPDATE to serialise limits, as `ai_usage` is.

**`public.meet_matches`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `profile_low`, `profile_high` | uuid → meet_profiles ON DELETE CASCADE; CHECK low < high |
| `origin` | text CHECK IN ('mutual_like','reach_accepted') |
| `matched_at` | timestamptz |
| `expires_at` | timestamptz = matched_at + `meet.match.ttl_hours` |
| `engaged_at` | timestamptz |
| `status` | text CHECK IN ('pending','active','expired','unmatched','closed_block','closed_moderation') |
| `reminded_at`, `closed_at`, `closed_by_profile` | |

Partial `UNIQUE (profile_low, profile_high) WHERE status IN ('pending','active')`; index `(expires_at) WHERE status='pending'`.

**`public.meet_profile_view_counts`**: `profile_id`, `day`, `views int`. PK `(profile_id, day)`. 30-day retention. **No viewer identity.**

#### 3.2.5 Chat

**`public.meet_conversations`**: `id uuid PK`, `profile_low`, `profile_high` (CHECK low < high; `UNIQUE (profile_low, profile_high)`, one per pair, reopened on a rematch), `match_id uuid NULL → meet_matches`, `origin text CHECK IN ('match','reach')`, `status text CHECK IN ('open','closed')`, `closed_reason text CHECK IN ('unmatched','blocked','expired','declined','moderation','erased')`, `opened_at`, `closed_at`, `purge_after`, `last_message_id bigint`, `last_message_at`.

**`public.meet_conversation_members`**: `conversation_id → CASCADE`, `profile_id`, `user_id`, `last_read_message_id bigint`, `muted bool`, `messages_sent int DEFAULT 0`, `digit_tail text CHECK ~ '^[0-9]{0,12}$'`, `digit_tail_at timestamptz`. PK `(conversation_id, profile_id)`; index `(user_id)`.

**`public.meet_messages`**, PARTITION BY RANGE (created_at), monthly.

| Column | Definition |
|---|---|
| `id` | bigint GENERATED ALWAYS AS IDENTITY |
| `conversation_id` | uuid NOT NULL |
| `sender_profile_id` | uuid NULL (NULL for system messages) |
| `kind` | text CHECK IN ('text','emoji','game','system','flirt','call') (`flirt` is used from M2, `call` from M3) |
| `body` | text CHECK length ≤ 1000 |
| `payload` | jsonb DEFAULT '{}' (`{round_id}` | `{flirt_key}` | `{call_id}`) |
| `hold` | bool DEFAULT false |
| `removed_at`, `created_at` | |

PK `(id, created_at)`; index `(conversation_id, id DESC)`. `private.ensure_monthly_partitions('public.meet_messages', 3)` plus cron.

**`public.meet_message_reactions`** (free): `conversation_id`, `message_id bigint`, `message_created_at`, `profile_id`, `emoji text CHECK IN ('❤️','😂','🔥','😮','😢','👍')`, `created_at`. PK `(message_id, profile_id)`.

#### 3.2.6 Statuses and games

**`public.meet_statuses`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `profile_id` | uuid → CASCADE |
| `kind` | text CHECK IN ('text','photo') |
| `body` | text ≤200 |
| `background_key` | text CHECK IN ('g1'…'g8') |
| `inbox_path`, `media_path`, `thumb_path` | text |
| `audience` | text NOT NULL DEFAULT 'matches' CHECK IN ('matches','matches_and_admirers') |
| `state` | text CHECK IN ('processing','pending_review','live','removed','expired') |
| `created_at`, `expires_at` (+ `meet.status.ttl_hours`) | |
| `boosted_until` | timestamptz (M2) |

**`public.meet_status_views`**: `status_id → CASCADE`, `viewer_profile_id`, `viewed_at`. PK `(status_id, viewer_profile_id)`.

**`public.meet_games`**: `key text PK CHECK IN ('compatibility_quiz','this_or_that','daily_question','light_truth_or_dare')`, `active`, `min_card text DEFAULT 'member'`, `min_level int DEFAULT 0`.

**`public.meet_game_prompts`**: `id uuid PK`, `game_key → meet_games`, `locale text CHECK IN ('en','pcm')`, `prompt text ≤200`, `options jsonb` (2–4 labels or `null` for free text), `active`, `reviewed_at timestamptz NOT NULL`. **Curated only. No user-written prompts or dares; nothing sexual and nothing involving money.**

**`public.meet_game_rounds`**: `id uuid PK`, `conversation_id → CASCADE`, `game_key`, `prompt_id`, `started_by_profile`, `state text CHECK IN ('waiting','revealed','expired')`, `cost_cowries int DEFAULT 0`, `entry_id bigint NULL`, `created_at`, `expires_at` (+24 h), `revealed_at`.

**`public.meet_game_answers`**: `round_id → CASCADE`, `profile_id`, `answer jsonb` (`{choice:int}` or `{text}`), `answer_text text ≤150` (screened), `moderation text`, `answered_at`. PK `(round_id, profile_id)`.

**`public.meet_daily_questions`**: `country_code`, `day`, `prompt_id`. PK `(country_code, day)`. **`public.meet_daily_question_answers`**: `user_id`, `day`, `prompt_id`, `answer jsonb`. PK `(user_id, day)`.

#### 3.2.7 Verification (`meet.photo_verification`)

**`public.meet_verifications`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `user_id` | uuid → CASCADE |
| `pose_key` | text CHECK IN ('two_fingers_left','thumb_up','hand_on_chin','touch_ear', …) |
| `pose_expires_at` | timestamptz (+10 min) |
| `selfie_path` | text in `meet-verify` `<uid>/<id>.jpg` |
| `status` | text CHECK IN ('issued','submitted','approved','rejected','expired') |
| `reason_code` | text |
| `decided_by`, `decided_at` | |
| `purge_after` | timestamptz = decided_at + 30 days |

Submitting requires `private.has_consent(uid,'biometric')`, and nobody may review their own submission.

### 3.3 M1 flags and remote config

**Flags** (inserted ON CONFLICT DO NOTHING, all `enabled=false`):

| Flag | client_visible | Payload |
|---|---|---|
| `meet.v5` | yes | `{"testers_only": true}` |
| `meet.discovery`, `meet.nearby`, `meet.chat`, `meet.statuses`, `meet.games`, `meet.photo_verification` | yes | — |

**Remote config** (client-visible unless marked "server"):

| Key | Default |
|---|---|
| `meet.min_age` | 18 (functions use `greatest(18, value)`) |
| `meet.guidelines_version` | 1 |
| `meet.min_client_version` | `"1.5.0"` |
| `meet.require_device_integrity` | true (server) |
| `meet.discovery.daily_size` | `{"member":15,"vip":25,"gold":25,"platinum":30,"captain":30}` |
| `meet.discovery.admirer_slots` | 3 |
| `meet.discovery.distance_bands_km` | `[5,10,25,50]` → labels `under_5`, `5_10`, `10_25`, `25_50`, `over_50` |
| `meet.discovery.pass_cooldown_days` | 30 |
| `meet.discovery.reshow_after_days` | 14 |
| `meet.nearby.page_size` | 24 |
| `meet.nearby.max_per_day` | 72 |
| `meet.limits.likes_per_day` | `{"member":50,"vip":200,"ceiling":300}` |
| `meet.limits.super_interest_free_per_day` | 1 |
| `meet.limits.winks_per_day` | `{"member_free":10,"vip":100,"ceiling":150}` |
| `meet.limits.pokes_per_day` | 20 |
| `meet.limits.new_conversations_per_day` | 20 (server) |
| `meet.limits.messages_per_minute` | 20 (server) |
| `meet.limits.reports_per_day` | 20 (server) |
| `meet.match.ttl_hours` | 24 |
| `meet.match.reminder_hours_before` | 3 |
| `meet.photos.max` | 6 |
| `meet.area.min_update_hours` | 6 (server) |
| `meet.contact_filter` | `{"min_digits":7,"tail_window_minutes":10,"strike_window_hours":24,"restrict_after":3,"restrict_hours":24,"review_after_7d":5}` (server) |
| `meet.status.post_min_card` | "member" (OD-48; becomes "silver" when `meet.vip` is on) |
| `meet.status.photo_requires_verified` | true |
| `meet.status.ttl_hours` | 24 |
| `meet.status.max_per_day` | 3 |
| `meet.games.round_ttl_hours` | 24 |
| `meet.games.free_rounds_per_day` | 5 |
| `meet.retention` | `{"closed_conversation_days":30,"evidence_after_close_days":90,"daily_set_days":7,"view_counter_days":30,"safety_event_months":3,"verification_selfie_days":30,"age_refusal_device_days":365}` (server) |
| `meet.notify.max_social_per_hour` | 6 (server) |
| `meet.moderation.sla_hours` | `{"child_safety":2,"photo":12,"report":24,"text":48}` (server) |

### 3.4 M2 migrations and tables

**Migrations:**

1. `20261210120000_meet_econ_enum_values.sql`: `notification_kind` adds `meet_gift`, `meet_request`, `meet_progress`.
2. `…120100_meet_econ_contract.sql`: skeleton for every M2 RPC, flags, config, error codes.
3. `…120200_meet_econ_wallet.sql`: the schema, wallet, entries, spend and grant, reconcile, `partition_health` restated, packs.
4. `…120300_meet_econ_play_billing.sql`: purchases, subscriptions, adjustments, gateway functions, `webhook_events` CHECK, `config_change_levels`, `approval_subject_country`.
5. `…120400_meet_econ_spend_surfaces.sql`: gifts, reactions, reach, reveals, unlocks, boosts, popularity, priced game rounds and flirts; moderation kind `meet_reach_note`.
6. `…120500_meet_econ_progression.sql`: XP, levels, cards, VIP entitlement, streaks, missions, daily surprise, perks.

**Schema `meet_econ`:** `CREATE SCHEMA meet_econ; REVOKE ALL ON SCHEMA meet_econ FROM PUBLIC, anon, authenticated, service_role;` Only SECURITY DEFINER functions owned by the migration role touch it.

**`meet_econ.wallets`**

| Column | Definition |
|---|---|
| `user_id` | uuid PK → auth.users ON DELETE CASCADE |
| `purchased` | bigint NOT NULL DEFAULT 0 (may go negative after a clawback) |
| `bonus` | bigint NOT NULL DEFAULT 0 CHECK (bonus ≥ 0) |
| `lifetime_purchased`, `lifetime_spent_purchased`, `lifetime_spent_bonus` | bigint NOT NULL DEFAULT 0 |
| `restricted` | text NULL CHECK IN ('negative_balance','fraud_hold') |
| `purchase_hold_until` | timestamptz |
| `test_funds` | bool NOT NULL DEFAULT false (set on the first test-purchase grant; excludes this wallet's spend from card paths) |
| `version` | bigint NOT NULL DEFAULT 0 |
| `updated_at` | timestamptz |

**`meet_econ.entries`**, PARTITION BY RANGE (created_at), monthly, append-only.

| Column | Definition |
|---|---|
| `id` | bigint identity |
| `user_id` | uuid NULL (pseudonymised on erasure) |
| `kind` | text CHECK IN ('purchase','bonus_grant','spend','spend_refund','purchase_void','admin_grant','admin_debit') |
| `delta_purchased`, `delta_bonus` | bigint NOT NULL DEFAULT 0 |
| `ref_kind` | text CHECK IN ('play_purchase','signal','reaction','gift','game_round','flirt','super_interest','reach','reveal','unlock','boost','call_block','streak','mission','welcome','admin_adjustment','moderation_refund') |
| `ref_id` | text NOT NULL |
| `reason_key` | text NOT NULL |
| `is_test` | bool NOT NULL DEFAULT false |
| `balance_after_purchased`, `balance_after_bonus` | bigint |
| `created_at` | timestamptz |

PK `(id, created_at)`; index `(user_id, id DESC)`. An UPDATE or DELETE trigger raises `ERR_PERMISSION_DENIED`. **CHECK `meet_entries_sign_rules`**:

| Kind | Rule |
|---|---|
| purchase | `delta_purchased > 0 AND delta_bonus = 0` |
| bonus_grant, admin_grant | `delta_bonus > 0 AND delta_purchased = 0` |
| spend, admin_debit | both ≤ 0 and sum < 0 |
| spend_refund | both ≥ 0 and sum > 0 |
| purchase_void | `delta_purchased < 0 AND delta_bonus = 0` |

**`meet_econ.cowrie_packs`**: `product_id text PK ~ '^[a-z0-9_.]{1,40}$'`, `units int > 0`, `label_key`, `best_value bool`, `active bool DEFAULT false`, `sort`. Seeded rows: `meet_cowries_200` (200), `meet_cowries_520` (520), `meet_cowries_1100` (1100), `meet_cowries_6000` (6000, best value).

**`meet_econ.play_purchases`**. Not partitioned, so the token is a true UNIQUE.

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `package_name` | text NOT NULL DEFAULT 'com.suskiierrands.app' (allows a future Meet package, OD-43) |
| `purchase_token` | text NOT NULL UNIQUE CHECK length 20..4096 |
| `token_sha256` | bytea UNIQUE |
| `user_id` | uuid NULL (NULL after erasure; kept for accounting) |
| `product_id` | text |
| `product_kind` | text CHECK IN ('consumable','subscription') |
| `order_id` | text NULL (promo purchases have none) |
| `obfuscated_account_id` | text |
| `binding` | text CHECK IN ('account_ref','first_claim') |
| `quantity` | int DEFAULT 1 |
| `units_granted`, `units_voided` | bigint DEFAULT 0 |
| `state` | text CHECK IN ('received','pending','verified','granted','completed','rejected','voided','partially_voided') |
| `reject_reason` | text CHECK IN ('wrong_package','unknown_product','not_purchased','account_mismatch','token_claimed','wallet_hold') |
| `is_test` | bool |
| `region_code` | text |
| `purchase_time`, `verified_at`, `granted_at`, `completed_at`, `voided_at` | timestamptz |
| `voided_reason`, `voided_source` | smallint |
| `reported_price_micros`, `reported_currency` | informational only, never trusted |
| `verification` | jsonb (trimmed API response) |
| `attempts` | int |
| `next_attempt_at` | timestamptz |
| `refund_requested_at` | timestamptz (rejected tokens and admin refunds) |
| `created_at`, `updated_at` | |

Indexes `(user_id, created_at DESC)` and `(state, next_attempt_at)`.

**`meet_econ.play_subscriptions`**: `purchase_token text PK → play_purchases(purchase_token)`, `user_id`, `product_id` ('meet_vip'), `base_plan_id` ('vip-weekly'/'vip-monthly'), `linked_purchase_token`, `superseded_by`, `state text` (the `SUBSCRIPTION_STATE_*` value), `auto_renewing bool`, `expiry_time`, `acknowledged bool`, `is_test bool`, `paid_days_counted int`, `revoked_at`, `cancel_requested_at`, `last_synced_at`, `raw jsonb`. Index `(user_id, expiry_time DESC)`.

**`meet_econ.billing_state`**: `key text PK` ('voided_cursor', 'last_resync'), `value jsonb`, `updated_at`.

**`meet_econ.adjustment_requests`**: `id uuid PK`, `user_id`, `delta_bonus bigint <> 0`, `reason text ≤300`, `requested_by`, `approval_id uuid NULL → public.approvals`, `applied_entry_id bigint`, `created_at`.

**RTDN raw storage** reuses `public.webhook_events`. Its gateway CHECK widens to `('flutterwave','paystack','stripe','google_play')`, and rows are written through `private.ingest_webhook('google_play', messageId, true, payload)`. That table is already partitioned, covered by `partition_health`, and de-duplicated across partitions.

**Public tables (function-only):**

| Table | Columns |
|---|---|
| `meet_gift_catalogue` | `key text PK`, `cost_cowries int CHECK 1..2500`, `popularity_points int`, `receiver_xp int`, `min_card text DEFAULT 'member'`, `animation_key text`, `exclusive bool`, `active`, `sort` |
| `meet_gifts` | `id uuid PK`, `sender_profile_id`, `receiver_profile_id` (CHECK sender ≠ receiver), `gift_key → catalogue`, `target_kind text CHECK IN ('status','photo','prompt','profile','reach')`, `target_id text`, `note_key text NULL CHECK IN ('note_love_this','note_great_smile','note_made_my_day','note_hello')`, `cost_cowries int`, `entry_id bigint`, `popularity_awarded int`, `xp_awarded int`, `state text CHECK IN ('delivered','refunded','reversed')`, `same_device bool`, `hidden_by_receiver bool DEFAULT false`, `seen_at`, `created_at`. Indexes `(receiver_profile_id, created_at DESC)` and `(sender_profile_id, created_at DESC)` |
| `meet_reactions` | `id uuid PK`, `sender_profile_id`, `target_kind text CHECK IN ('status','photo','prompt')`, `target_id`, `reaction_key text CHECK IN ('fire','laugh','love','wow','clap','wave')`, `cost_cowries int`, `entry_id`, `created_at` |
| `meet_popularity_events` | `id bigint identity PK`, `profile_id`, `source_kind text CHECK IN ('gift','super_interest','match','reversal')`, `source_id`, `points int <> 0`, `created_at`; 60-day retention |
| `meet_popularity` | `profile_id PK`, `score_30d int`, `popular bool`, `updated_at` |
| `meet_progress` | `user_id PK`, `xp bigint`, `level int`, `card text CHECK IN ('member','silver','gold','platinum','captain')`, `card_basis text CHECK IN ('default','vip','vip_days','spend','level')`, `card_since`, `captain_review_on date`, `captain_warned_at`, `vip_paid_days int`, `xp_today int`, `xp_day date`, `gift_xp_today int`, `free_cowries_today int`, `updated_at` |
| `meet_xp_events` | `id bigint identity PK`, `user_id`, `kind text`, `points int`, `ref_id text`, `created_at`; 90-day retention |
| `meet_levels` | `level int PK`, `reward_kind text CHECK IN ('perk','gift_unlock','game_unlock','frame','none')`, `reward_ref text`, `reward_qty int` |
| `meet_streaks` | `user_id PK`, `current int`, `best int`, `last_day date` |
| `meet_streak_claims` | `user_id`, `day`, `cowries int`, `xp int`, `entry_id`. PK `(user_id, day)` |
| `meet_mission_defs` | `key PK`, `kind text CHECK IN ('complete_prompt','reply_to_match','finish_game','post_status','add_photo','daily_question','verify_photo')`, `target smallint`, `reward_cowries smallint`, `reward_xp smallint`, `active`, `sort` |
| `meet_mission_progress` | `user_id`, `day`, `mission_key`, `progress`, `completed_at`, `claimed_at`, `entry_id`. PK `(user_id, day, mission_key)` |
| `meet_spins` | `user_id`, `spin_date`, `prize_key`, `quantity`, `rolled_at`. PK `(user_id, spin_date)` |
| `meet_perks` | `id uuid PK`, `user_id`, `perk_kind text CHECK IN ('free_wink','extra_card','free_game_round','boost_minutes','profile_frame')`, `quantity int > 0`, `used int DEFAULT 0`, `source text CHECK IN ('surprise','level','mission','onboarding')`, `granted_at`, `expires_at`. **No function moves a perk between users** |
| `meet_boosts` | `id uuid PK`, `profile_id`, `target_kind text CHECK IN ('profile','status')`, `target_id uuid NULL`, `starts_at`, `ends_at`, `source text CHECK IN ('cowries','perk','platinum_weekly')`, `entry_id` |
| `meet_profile_unlocks` | `viewer_profile_id`, `owner_profile_id`, `via text CHECK IN ('cowries','reach_accepted')`, `expires_at`, `entry_id`. PK both ids |
| `meet_like_reveals` | `user_id PK`, `revealed_until`, `entry_id` |
| `meet_reach_requests` | `id uuid PK`, `from_profile_id`, `to_profile_id`, `note text ≤200` (screened, blocked-not-held), `gift_id uuid NULL`, `cost_cowries int`, `entry_id`, `state text CHECK IN ('pending','accepted','declined','expired','closed_block')`, `created_at`, `decided_at`, `expires_at` (+7 days). Partial UNIQUE `(from_profile_id, to_profile_id) WHERE state='pending'` |

**`meet_profiles` additions:** `billing_account_ref text UNIQUE CHECK ~ '^[0-9a-f]{32}$'` (minted on first billing context; never derived from personal data), `lock_min_card text NULL CHECK IN ('silver','gold','platinum','captain')`, `reachable bool DEFAULT false`, `accept_requests bool DEFAULT true`, `frame_key text NULL`, `incognito bool DEFAULT false`, `hide_last_active bool DEFAULT false`, `hide_distance bool DEFAULT false`.

**M2 flags** (all off):

| Flag | Notes |
|---|---|
| `meet.economy` | client_visible |
| `meet.gifts`, `meet.progression`, `meet.spin`, `meet.boosts`, `meet.badge_lock`, `meet.reach` | — |
| `meet.vip`, `meet.purchases` | `{"testers_only": true}` |
| `meet.purchases_verify_paused` | server-only break-glass |

### 3.5 M3 migrations and tables

**Migrations:**

1. `20270112120000_meet_calls_enum_values.sql`: `meet_call_incoming`, `meet_call_missed`.
2. `…120100_meet_calls.sql`
3. `…120200_meet_analytics.sql`
4. `…120300_meetups_v2.sql`

**`public.meet_calls`**

| Column | Definition |
|---|---|
| `id` | uuid PK |
| `conversation_id` | uuid → meet_conversations |
| `caller_profile_id`, `callee_profile_id` | uuid |
| `media` | text CHECK IN ('audio','video') |
| `state` | text CHECK IN ('ringing','active','ended','missed','declined','failed') |
| `room_name` | text UNIQUE |
| `created_at`, `answered_at`, `ended_at` | |
| `ended_reason` | text CHECK IN ('hangup','declined','timeout','insufficient_cowries','moderation','stale','block','refunded_short') |
| `blocks_billed` | int DEFAULT 0 |
| `caller_heartbeat_at`, `callee_heartbeat_at` | timestamptz |
| `duration_s` | int |

Partial unique `meet_calls_one_live ON (conversation_id) WHERE state IN ('ringing','active')`. **No recording or transcript column**, asserted structurally as in `25_calls_test`.

**`public.meet_call_blocks`**: `call_id`, `block_no`, `due_at`, `charged_at`, `cost_cowries`, `entry_id`, `refunded_entry_id`. PK `(call_id, block_no)`.

**Meet-ups v2 (additive):** `meetups ADD requires_approval bool NOT NULL DEFAULT false, ADD min_card text NULL`; new `public.meetup_join_requests (id uuid PK, meetup_id → CASCADE, user_id, state text CHECK IN ('pending','approved','declined','withdrawn'), created_at, decided_at)`. Existing rows and the eight RPCs behave exactly as before for `requires_approval=false`.

**`analytics.meet_daily`**: aggregates by `country_code` and `day` only.

- Measures: check_ins, refusals_minor, profiles_approved, active_profiles, likes, matches, conversations_started, messages, statuses, game_rounds, reports_by_category, suspensions, purchases_live, cowries_purchased_live, cowries_spent, vip_active, calls_minutes.
- Cells under 10 are NULL. **No gender, seeking or age dimension**, asserted against `information_schema`.

**M3 flags:** `meet.calls.voice`, `meet.calls.video`, `meet.meetups_v2`.

**M3 config:** `meet.calls = {"block_minutes":10,"ring_timeout_seconds":45,"min_messages_each":3,"video_min_match_age_hours":72,"heartbeat_seconds":60,"stale_after_seconds":180,"warn_before_block_seconds":60,"refund_if_shorter_than_seconds":60}`.

---

## 4. API

### 4.1 Conventions

- Every client RPC is `SECURITY DEFINER SET search_path = ''`. It begins with `private.require_user()` and then `private.meet_require_access(uid, '<feature>', <need_profile>)`, and validates every input.
- Each is created with `REVOKE ALL … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO authenticated`. `gateway_*` and `dispatch_*` functions are granted to `service_role` only.
- In the same PR as each function:
  - add it to the `authenticated` allowlist in `00_structure_test.sql`;
  - add it to the **deny** list in `services/ai/tools/allowlist.json`, because dating data never reaches Ask Suskii;
  - add its RLS-matrix row;
  - regenerate `contracts/v1` with `generate_v1.py`;
  - add a CHANGELOG line.
- **Keys:** every create, transition and spend takes `p_idempotency_key` as its first argument and uses `private.idempotency_claim(uid, key, op, args)`. A replay returns the stored response; reuse with different arguments raises `ERR_IDEMPOTENCY_KEY_REUSED`. Monotonic overwrites take no key: `meet_mark_read`, `meet_view_status`.
- **The S.2 rule (D24):** any refusal that writes a record returns `{status: 'blocked'|'refused'|'unavailable', reason}`. It never raises.
- **Strangers are addressed by `profile_id`** (an opaque `meet_profiles.id`), never by auth uid.
- **Client call sites** pass a literal argument map (`check_frontend_calls.py`). Admin calls use `gw.rpc(...)`, not `rpcRows`.
- **Helper errors** (`meet_require_access`) are listed in `codes.json` notes, because the generated per-RPC lists omit them.

**New error codes.** Each is added to `contracts/v1/error-codes/codes.json`, `packages/suskii_core/lib/src/errors.dart`, `apps/mobile/lib/app/error_l10n.dart`, web `mocks/errors.ts` and `en.ts`/`pcm.ts`, and admin `mocks/errors.ts`/dict.

**M1 codes** (all `implemented` unless marked):

| Code | Note |
|---|---|
| `ERR_MEET_ELIGIBILITY_REQUIRED` | |
| `ERR_MEET_UNDER_AGE` | status **`client`**: produced by the apps from `meet_check_in`'s `{status:'refused'}` |
| `ERR_MEET_UNAVAILABLE` | |
| `ERR_MEET_AGE_ALREADY_SET` | |
| `ERR_MEET_GUIDELINES_OUTDATED` | |
| `ERR_MEET_SUSPENDED`, `ERR_MEET_RESTRICTED` | |
| `ERR_MEET_RATE_LIMITED`, `ERR_MEET_DAILY_LIMIT` | |
| `ERR_MEET_PROFILE_NOT_FOUND`, `ERR_MEET_PROFILE_INCOMPLETE` | |
| `ERR_MEET_PHOTO_LIMIT`, `ERR_MEET_PHOTO_NOT_FOUND` | |
| `ERR_MEET_CONTACT_NOT_ALLOWED`, `ERR_MEET_SOLICITATION_NOT_ALLOWED` | |
| `ERR_MEET_MATCH_NOT_FOUND`, `ERR_MEET_CONVERSATION_NOT_FOUND`, `ERR_MEET_CONVERSATION_CLOSED` | |
| `ERR_MEET_STATUS_NOT_FOUND`, `ERR_MEET_STATUS_LIMIT` | |
| `ERR_MEET_VERIFICATION_REQUIRED`, `ERR_MEET_VERIFICATION_NOT_FOUND` | |
| `ERR_MEET_CARD_REQUIRED` | |
| `ERR_MEET_ROUND_NOT_FOUND`, `ERR_MEET_ROUND_CLOSED` | |
| `ERR_MEET_REPORT_NOT_FOUND`, `ERR_MEET_SUSPENSION_NOT_FOUND` | |
| `ERR_MEET_NOT_READY` | |

**M2 codes:** `ERR_MEET_INSUFFICIENT_COWRIES`, `ERR_MEET_PRICE_CHANGED`, `ERR_MEET_WALLET_RESTRICTED`, `ERR_MEET_PROFILE_LOCKED`, `ERR_MEET_NOT_REACHABLE`, `ERR_MEET_REQUEST_NOT_FOUND`, `ERR_MEET_GIFT_UNAVAILABLE`, `ERR_MEET_SPIN_USED`, `ERR_MEET_ALREADY_CLAIMED`, `ERR_MEET_MISSION_INCOMPLETE`, `ERR_MEET_PURCHASE_REJECTED`, `ERR_MEET_PURCHASE_TOKEN_CLAIMED`, `ERR_MEET_PRODUCT_UNKNOWN`.

**M3 codes:** `ERR_MEET_CALL_NOT_FOUND`, `ERR_MEET_CALL_UNAVAILABLE`.

**Reused codes:** `ERR_FEATURE_UNAVAILABLE`, `ERR_INVALID_ARGUMENT`, `ERR_IDEMPOTENCY_KEY_INVALID`, `ERR_IDEMPOTENCY_KEY_REUSED`, `ERR_CONTENT_NOT_ALLOWED`, `ERR_UPLOAD_NOT_FOUND`, `ERR_COUNTRY_NOT_SET`, `ERR_CONSENT_REQUIRED`, `ERR_LOCATION_UNAVAILABLE`, `ERR_MODERATION_CASE_NOT_FOUND`, `ERR_REAUTH_REQUIRED`, `ERR_PERMISSION_DENIED`, `ERR_UNAUTHENTICATED`.

**Not used:** `ERR_INVALID_STATE` and `ERR_IDEMPOTENCY_KEY_IN_PROGRESS` (neither is catalogued).

Format below: **name(args) → returns** | key | feature/caller | errors (beyond the conventions).

### 4.2 M1 client RPCs (authenticated)

**State and eligibility**

- **`meet_get_state()` → jsonb** | read | any signed-in user; works with `meet.v5` off.
  - Returns:
    - `v5` bool;
    - `features` text[] (subset of discovery, nearby, chat, statuses, games, photo_verification, then M2 economy, gifts, progression, spin, boosts, badge_lock, reach, vip, purchases, then M3 calls_voice, calls_video);
    - `eligibility` 'none'|'eligible'|'refused'|'unavailable';
    - `guidelines` {required_version, accepted_version, url};
    - `profile` {id, status, discoverable, paused, verified, held, completeness[]} | null;
    - `restrictions` [{scope, ends_at}];
    - `suspension` {ends_at|null} | null;
    - `unread` {chats, likes, matches, requests};
    - M2: `wallet` {total, purchased, bonus, restricted} and `card` {tier, level}.
  - Errors: `ERR_COUNTRY_NOT_SET`.
- **`meet_check_in(p_idempotency_key text, p_birth_date date, p_guidelines_version int)` → jsonb `{status:'eligible'|'refused'|'unavailable', age int|null}`** | key | `meet.v5`.
  - Computes the age in `private.user_timezone(uid)`.
  - **Under 18:** inserts `meet_eligibility(status='refused_minor', birth_date NULL)`, stores every `user_devices.device_fingerprint_hash` of the caller in `meet_age_refusal_devices`, writes a safety event, and **returns** `{status:'refused'}`.
  - **A refused or banned device**, or `integrity_verdict='fail'` while `meet.require_device_integrity`: writes a safety event and **returns** `{status:'unavailable'}`.
  - **On success:** inserts the eligibility row, inserts a `consents` row (`meet_terms`, linked to the NG `meet_guidelines` legal document) and returns `{status:'eligible', age}`.
  - Errors (pure checks, no write first): `ERR_MEET_AGE_ALREADY_SET`, `ERR_MEET_GUIDELINES_OUTDATED`, `ERR_INVALID_ARGUMENT` (a future date, or age above 99).
- **`meet_accept_guidelines(p_idempotency_key, p_version int)` → void** | key | eligible.
  - Errors: `ERR_MEET_GUIDELINES_OUTDATED`.

**Profile**

- **`meet_save_profile(p_idempotency_key, p_first_name text, p_bio text, p_intent text, p_gender text, p_show_gender bool, p_interests text[], p_sensitive_consent bool)` → jsonb (own profile)** | key | eligible.
  - NULL leaves a field alone.
  - `p_sensitive_consent` must be true the first time gender is set; that records a `meet_sensitive_data` consent.
  - Errors: `ERR_INVALID_ARGUMENT`, `ERR_CONSENT_REQUIRED`, `ERR_CONTENT_NOT_ALLOWED`, `ERR_MEET_CONTACT_NOT_ALLOWED`, `ERR_MEET_SOLICITATION_NOT_ALLOWED`.
- **`meet_set_area(p_idempotency_key, p_lat double precision, p_lng double precision)` → `{area_label, city_code}`** | key | eligible.
  - Stores only `ST_GeoHash(pt,5)`, its centroid and the nearest service-area city. The raw coordinates are discarded in the function.
  - Requires the `location` consent.
  - Errors: `ERR_MEET_RATE_LIMITED` (more often than every 6 h), `ERR_LOCATION_UNAVAILABLE` (outside the caller's country), `ERR_CONSENT_REQUIRED`.
- **`meet_set_discovery_prefs(p_idempotency_key, p_seeking text, p_age_min int, p_age_max int, p_max_band_km int, p_intents text[], p_sensitive_consent bool)` → void** | key.
  - Errors: `ERR_INVALID_ARGUMENT`, `ERR_CONSENT_REQUIRED` (the first non-'everyone' seeking value).
- **`meet_get_my_profile()` → jsonb** | read. Returns `{profile, photos[{id, position, status, reason_code, media_path, thumb_path}], prompts[], prefs, privacy}`.
- **`meet_submit_photo(p_idempotency_key, p_inbox_path text, p_thumb_inbox_path text, p_position int)` → `{photo_id, status:'processing'}`** | key.
  - Both objects must exist under `meet-inbox/<uid>/`.
  - Emits `meet.media.ingest`.
  - Errors: `ERR_UPLOAD_NOT_FOUND`, `ERR_MEET_PHOTO_LIMIT`, `ERR_INVALID_ARGUMENT`.
- **`meet_remove_photo(p_idempotency_key, p_photo_id uuid)`** and **`meet_reorder_photos(p_idempotency_key, p_photo_ids uuid[])`** → void | key | owner.
  - Removal emits `storage.erase_object` for both files. Removing the last approved photo makes the profile undiscoverable.
  - Errors: `ERR_MEET_PHOTO_NOT_FOUND`.
- **`meet_save_prompt(p_idempotency_key, p_prompt_key, p_answer, p_position)` → uuid** and **`meet_remove_prompt(p_idempotency_key, p_prompt_id)` → void** | key.
  - Errors: as `meet_save_profile`.
- **`meet_set_discoverable(p_idempotency_key, p_discoverable bool)` → void** | key.
  - Turning it on needs a clean `first_name`, at least one approved photo and an area.
  - Errors: `ERR_MEET_PROFILE_INCOMPLETE`.
- **`meet_pause(p_idempotency_key, p_paused bool)` → void** | key.
- **`meet_set_privacy(p_idempotency_key, p_settings jsonb)` → jsonb** | key.
  - M1 keys: `hide_from_errand_contacts`, `show_gender`, `read_receipts`.
  - M2 adds `incognito`, `hide_last_active` and `hide_distance`, which require Platinum or above (`ERR_MEET_CARD_REQUIRED`).
- **`meet_delete_profile(p_idempotency_key)` → void** | key.
  - Erases the profile, photos (`storage.erase_prefix` on `meet-media/<profile_id>/`), prompts, prefs, swipes, signals, matches, conversations (closed and purged for both), statuses and game answers.
  - Keeps `meet_eligibility`, so the birth date stays set once, and keeps suspensions and report evidence.

**Discovery and matches**

- **`meet_daily_set()` → setof jsonb card** | read | `meet.discovery`, active profile required (no browsing without one).
  - Generated lazily on the first call of the local day, under `pg_advisory_xact_lock(hashtextextended('meet_set:'||uid,0))`.
  - Card fields:
    - `profile_id`, `first_name`, `age` (NULL if `show_age`… always shown in M1), `intent`, `interests[]`, `shared_interests[]`;
    - `distance_band` (NULL if `hide_distance`), `area_label`, `active` ('today'|'this_week'|null);
    - `photos[{photo_id, path, thumb_path, w, h}]`, `prompts[{key, answer}]`, `daily_answer`;
    - `verified`, `tags[]` ⊆ {new_here, popular, verified}, `super_interest_from_them`;
    - M2: `card`, `frame_key`, `locked {min_card, ways[]}|null`, `spotlight`.
  - Locked cards carry photo 0 only and no prompts or bio.
- **`meet_get_profile(p_profile_id uuid)` → jsonb card (full)** | read.
  - Adds 1 to the target's day view count, unless the viewer is incognito (M2).
  - Errors: `ERR_MEET_PROFILE_NOT_FOUND`.
- **`meet_nearby(p_band text DEFAULT NULL, p_limit int DEFAULT 24)` → setof jsonb card-lite** | read | `meet.nearby`.
  - Applies the discovery predicate and requires activity within 7 days.
  - Ordered by band, then `last_active_on DESC`, then a stable per-day random. Never by exact distance.
  - Appends the ids to `meet_daily_sets.nearby` and counts `nearby_seen`.
  - At `meet.nearby.max_per_day` it returns empty with a `refreshes_at` header row.
- **`meet_swipe(p_idempotency_key, p_profile_id, p_action text, p_like_kind text DEFAULT 'like', p_expected_cost int DEFAULT 0)` → `{matched, match_id, conversation_id, expires_at, wallet}`** | key.
  - The target must be in today's set or nearby list, or be a revealed liker or a super-interest sender.
  - A pair advisory lock `pg_advisory_xact_lock(hashtextextended(least(a,b)::text||greatest(a,b)::text,0))` makes simultaneous mutual likes produce exactly one match.
  - A mutual like creates a pending match, opens or reopens the conversation, and notifies both with `meet_match` (`/meet/matches/<id>`).
  - A like or super interest notifies the target with coalesced `meet_like`.
  - Errors: `ERR_MEET_PROFILE_NOT_FOUND`, `ERR_MEET_DAILY_LIMIT`, `ERR_MEET_RESTRICTED`, `ERR_INVALID_ARGUMENT`. M2 adds `ERR_MEET_INSUFFICIENT_COWRIES`, `ERR_MEET_PRICE_CHANGED`, `ERR_MEET_WALLET_RESTRICTED`.
- **`meet_send_signal(p_idempotency_key, p_profile_id, p_kind text, p_expected_cost int DEFAULT 0)` → `{remaining, wallet}`** | key.
  - `wink` goes to any profile the caller may view. `poke` goes to a match or conversation partner only.
  - The sender is visible to the receiver.
  - Errors: `ERR_MEET_PROFILE_NOT_FOUND`, `ERR_MEET_DAILY_LIMIT` (plus the M2 spend errors).
- **`meet_likes_summary()` → `{likes_count, super_interests[card-lite], winks[card-lite], views_today}`** | read.
  - M2 adds `revealed_until` and `likers[card-lite]` while revealed.
- **`meet_matches()` → setof `{match_id, conversation_id, card-lite, status, expires_at, engaged}`** | read.
- **`meet_unmatch(p_idempotency_key, p_match_id)` → void** | key.
  - Closes the conversation and sets both swipes to `pass_until='infinity'`.
  - Errors: `ERR_MEET_MATCH_NOT_FOUND`.

**Chat** (`meet.chat`)

- **`meet_conversations(p_before timestamptz DEFAULT NULL, p_limit int DEFAULT 30)` → setof `{conversation_id, card-lite, status, origin, last_message {id, from_me, kind, preview≤80, at}, unread, match_expires_at}`** | read.
- **`meet_messages(p_conversation_id, p_before_id bigint DEFAULT NULL, p_limit int DEFAULT 50)` → setof `{id, from_me, kind, body, payload, reactions jsonb, created_at, removed}` + `peer_last_read_id`** (only if the peer has read receipts on) | read.
  - Errors: `ERR_MEET_CONVERSATION_NOT_FOUND`.
- **`meet_send_message(p_idempotency_key, p_conversation_id, p_body text, p_kind text DEFAULT 'text')` → `{status:'sent'|'blocked', message_id, reason, restricted_until}`** | key.
  - The caller must be a member, the conversation open, the match not expired, and the caller not restricted.
  - Pipeline:
    1. `meet_screen_text` (surface `message`, with the digit tail). A block writes a strike and returns `blocked`.
    2. Restriction check.
    3. `moderate_text`. A hold delivers and opens a case only for the `sexual` and `underage` categories.
    4. Insert, then `meet.message` broadcast, then coalesced `meet_message`.
  - The first message engages the match.
  - Errors: `ERR_MEET_CONVERSATION_NOT_FOUND`, `ERR_MEET_CONVERSATION_CLOSED`, `ERR_MEET_RESTRICTED`, `ERR_MEET_RATE_LIMITED`, `ERR_MEET_DAILY_LIMIT` (new conversations).
- **`meet_mark_read(p_conversation_id, p_last_message_id bigint)` → void** | monotonic `greatest()`.
- **`meet_react_to_message(p_idempotency_key, p_conversation_id, p_message_id bigint, p_emoji text)` → void** | key | free; a NULL emoji removes the reaction.

**Statuses** (`meet.statuses`)

- **`meet_post_status(p_idempotency_key, p_kind, p_body, p_background_key, p_inbox_path, p_thumb_inbox_path, p_audience)` → `{status_id, state}`** | key.
  - A text status goes `live` after screening. A photo status goes to processing, then review.
  - Errors: `ERR_MEET_CARD_REQUIRED` (below `post_min_card`), `ERR_MEET_VERIFICATION_REQUIRED` (a photo without verification), `ERR_MEET_STATUS_LIMIT`, `ERR_MEET_CONTACT_NOT_ALLOWED`, `ERR_MEET_SOLICITATION_NOT_ALLOWED`, `ERR_CONTENT_NOT_ALLOWED`, `ERR_UPLOAD_NOT_FOUND`.
- **`meet_delete_status(p_idempotency_key, p_status_id)` → void** | key.
- **`meet_status_ring()` → setof `{card-lite, is_me, statuses[{id, kind, body, background_key, media_path, thumb_path, expires_at, seen}]}`** | read. Own first, then unseen, then seen. Audience-checked.
- **`meet_view_status(p_status_id)` → void** | idempotent on the PK.
- **`meet_status_viewers(p_status_id)` → setof card-lite** | poster only. Errors: `ERR_MEET_STATUS_NOT_FOUND`.

**Games** (`meet.games`)

- **`meet_game_catalogue()` → setof `{key, available, locked_reason, free_rounds_left, cost}`** | read.
- **`meet_start_game(p_idempotency_key, p_conversation_id, p_game_key, p_expected_cost int DEFAULT 0)` → `{round_id, prompt, options}`** | key.
  - Picks an unused curated prompt for the pair and inserts a `game` message.
  - Errors: `ERR_MEET_CONVERSATION_CLOSED`, `ERR_MEET_DAILY_LIMIT`, `ERR_MEET_CARD_REQUIRED` (plus the M2 spend errors).
- **`meet_answer_game(p_idempotency_key, p_round_id, p_answer jsonb)` → `{state, answers|null}`** | key.
  - Reveals the answers only once both have answered.
  - Errors: `ERR_MEET_ROUND_NOT_FOUND`, `ERR_MEET_ROUND_CLOSED`, `ERR_MEET_CONTACT_NOT_ALLOWED`.
- **`meet_get_round(p_round_id)` → jsonb** | read.
- **`meet_daily_question()` → `{prompt, options, my_answer, match_answers[]}`** | read.
- **`meet_answer_daily_question(p_idempotency_key, p_answer jsonb)` → void** | key.

**Safety** (available whenever `meet.v5` is on and the caller is eligible, including while suspended)

- **`meet_report(p_idempotency_key, p_subject_kind, p_subject_id, p_reason_code, p_details text DEFAULT NULL, p_block bool DEFAULT true)` → `{report_id}`** | key.
  - Resolves the subject on the server.
  - Copies the evidence snapshot and opens a case for content subjects.
  - `underage` or `child_safety` sets an immediate discovery hold, priority 1 and a 2 h SLA.
  - `p_block` also blocks.
  - Errors: `ERR_INVALID_ARGUMENT`, `ERR_MEET_PROFILE_NOT_FOUND`, `ERR_MEET_RATE_LIMITED`.
- **`meet_block(p_idempotency_key, p_profile_id)`** and **`meet_unblock(p_idempotency_key, p_profile_id)`** → void | key.
  - Writes `public.blocks` with `source='meet'`. Closes matches, conversations, games, statuses and (M2) pending requests. A match is never restored after an unblock.
- **`meet_blocked_profiles()` → setof `{profile_id, first_name, blocked_at}`** | read (Meet-sourced blocks only).
- **`meet_verification_pose(p_idempotency_key)` → `{verification_id, pose_key, expires_at}`** | key | `meet.photo_verification`.
- **`meet_submit_verification(p_idempotency_key, p_verification_id, p_selfie_path text)` → `{status}`** | key.
  - Errors: `ERR_CONSENT_REQUIRED` (biometric), `ERR_UPLOAD_NOT_FOUND`, `ERR_MEET_VERIFICATION_NOT_FOUND`.

### 4.3 M1 admin RPCs

All require aal2, call `private.audit_write` before returning, and restate country scope. Mutations require `private.require_recent_mfa()`.

| Function | Roles | Notes |
|---|---|---|
| `admin_meet_moderation_queue(p_kind text DEFAULT NULL, p_limit int DEFAULT 50)` → rows `{case_id, subject_kind, subject_id, priority, labels, sla_due_at, author_profile_id, content{text|media_path}, context}` | meet_moderator, super_admin | Ordered by priority, then SLA |
| `admin_meet_decide_case(p_idempotency_key, p_case_id, p_uphold bool, p_reason_code text)` | meet_moderator, super_admin | Fires `private.meet_case_decided`. Errors: `ERR_MODERATION_CASE_NOT_FOUND`, `ERR_REAUTH_REQUIRED` |
| `admin_meet_decide_photo(p_idempotency_key, p_photo_id, p_approve bool, p_reason_code)` | meet_moderator, super_admin | `underage_appearance` → discovery hold plus a priority-1 child-safety review; `reused` → fraud flag |
| `admin_meet_report_queue(p_status text DEFAULT 'open', p_limit int DEFAULT 50)` | meet_moderator, super_admin | |
| `admin_meet_report_detail(p_report_id)` | meet_moderator, super_admin | Returns the evidence snapshot; signed media at most 300 s |
| `admin_meet_resolve_report(p_idempotency_key, p_report_id, p_outcome text, p_note text)` | meet_moderator, super_admin | Outcomes: dismissed, content_removed, warned, restricted, suspended, escalated |
| `admin_meet_suspend(p_idempotency_key, p_user_id, p_until timestamptz, p_reason_code, p_note)` → `{suspension_id, approval_id|null}` | meet_moderator (≤ 30 days), super_admin (≤ 365 days) | `p_until NULL` (permanent) is allowed only for child_safety, underage or ban_evasion. It **creates an `approvals` row (`subject_kind 'meet_ban'`)**, and the ban applies on the second approver's `admin_meet_approve_ban`. It also bars the user's devices |
| `admin_meet_approve_ban(p_idempotency_key, p_approval_id)` | super_admin (four eyes via `approvals_four_eyes`) | |
| `admin_meet_lift_suspension(p_idempotency_key, p_suspension_id, p_note)` | meet_moderator (own ≤ 30-day ones), super_admin | Errors: `ERR_MEET_SUSPENSION_NOT_FOUND` |
| `admin_meet_correct_birth_date(p_idempotency_key, p_user_id, p_birth_date, p_evidence_note)` | super_admin | Sets `method='support_corrected'` |
| `admin_meet_user_summary(p_user_id)` | meet_moderator, super_admin. support_agent gets `{has_profile, status, suspended_until}` only | Returns: eligibility (age and method, **never the birth date**), profile status, photo counts by status, reports received by reason, safety events in the last 30 days by kind, restrictions, suspensions. M2 adds wallet and purchases. **Never prefs, seeking or messages** |
| `admin_meet_verification_queue(p_limit)` | verification_officer, meet_moderator, super_admin | |
| `admin_meet_decide_verification(p_idempotency_key, p_verification_id, p_approve, p_reason_code)` | same roles | No self-review |
| `admin_meet_verification_access(p_verification_id, p_reason_code)` → path | same roles | Called by `kyc-document-url`. Writes `audit.kyc_access` first; requires TOTP within 5 min |
| `admin_meet_readiness()` / `admin_meet_set_readiness(p_idempotency_key, p_item, p_done, p_note)` | super_admin | |
| `admin_meet_testers(p_limit)` / `admin_meet_set_tester(p_idempotency_key, p_user_id, p_on bool, p_note)` | super_admin | |

### 4.4 M1 gateway functions (service_role)

| Function | Purpose |
|---|---|
| `gateway_meet_media_ingested(p_kind text, p_id uuid, p_media_path, p_thumb_path, p_sha256 text, p_width int, p_height int, p_mime text)` | Item → `pending_review` and a case is opened. Raises `private.raise_fraud_flag('user', uid::text, 'meet_photo_reuse', 60::smallint, …)` on a cross-user hash match |
| `gateway_meet_media_failed(p_kind, p_id, p_reason)` | Records the failure |
| `dispatch_push_targets_for_kind(p_user_id, p_kind)` | §2.8 |
| `gateway_claim_outbox(ARRAY['meet_media'])` | Existing; used by the media worker |

### 4.5 M2 client RPCs

| Function | Key | Notes |
|---|---|---|
| `meet_billing_context()` → `{purchases_enabled, vip_enabled, billing_account_ref, packs[{product_id, units, best_value}], vip{product_id:'meet_vip', base_plans:['vip-weekly','vip-monthly']}, wallet, hold_until}` | read | Mints `billing_account_ref` on first call. `purchases_enabled` is false while the flag is off, a fraud hold is active, or the readiness tier does not cover the caller |
| `meet_cowrie_history(p_before_id bigint DEFAULT NULL, p_limit int DEFAULT 50)` → rows `{id, kind, delta, description_key, ref_kind, created_at}` | read | |
| `meet_economy_catalogue()` → `{spend_costs (effective for the caller's card and VIP), gifts[{key, cost, min_card, available, animation_key}], ladder, surprise_odds}` | read | |
| `meet_send_reaction(p_idempotency_key, p_target_kind, p_target_id, p_reaction_key, p_expected_cost)` → `{wallet}` | key | |
| `meet_send_gift(p_idempotency_key, p_receiver_profile_id, p_gift_key, p_target_kind, p_target_id, p_note_key text DEFAULT NULL, p_expected_cost)` → `{gift_id, wallet}` | key | Targets: status, photo, prompt, profile. Reach gifts go through `meet_send_reach_request`. Errors: INSUFFICIENT_COWRIES, PRICE_CHANGED, WALLET_RESTRICTED, GIFT_UNAVAILABLE, CARD_REQUIRED, PROFILE_NOT_FOUND, DAILY_LIMIT |
| `meet_gifts_received(p_before timestamptz DEFAULT NULL, p_limit int DEFAULT 30)` → rows `{gift_id, gift_key, from card-lite, target_kind, at, hidden}` | read | **No Cowrie value** |
| `meet_hide_gift(p_idempotency_key, p_gift_id, p_hidden bool)` | key | |
| `meet_gift_summary(p_profile_id)` → rows `{gift_key, count}` | read | Never senders, never values |
| `meet_send_flirt(p_idempotency_key, p_conversation_id, p_flirt_key text, p_expected_cost)` → `{message_id, wallet}` | key | Canned animated flirts or compliments in chat (`kind 'flirt'`). The sender pays the platform; **the receiver gets nothing of value and sees no price**. Free for VIP |
| `meet_send_reach_request(p_idempotency_key, p_profile_id, p_note text, p_gift_key text DEFAULT NULL, p_expected_cost)` → `{status:'sent'|'blocked', request_id, wallet}` | key | "Message before matching" (40). The target must accept requests and be viewable to the caller, or be `reachable` with a lock the caller's card meets. A screened note that is blocked costs nothing. Errors: NOT_REACHABLE, PROFILE_LOCKED, DAILY_LIMIT, plus spend errors |
| `meet_reach_requests()` → `{incoming[], outgoing[]}` | read | |
| `meet_respond_reach_request(p_idempotency_key, p_request_id, p_accept bool)` → `{conversation_id|null}` | key | Accepting opens a conversation (`origin 'reach'`) and unlocks. Declining is silent and blocks requests from that sender for 30 days. Errors: REQUEST_NOT_FOUND |
| `meet_reveal_likes(p_idempotency_key, p_expected_cost)` → `{revealed_until}` | key | 50 for 24 h; free for Gold and above |
| `meet_unlock_profile(p_idempotency_key, p_profile_id, p_expected_cost)` → `{expires_at}` | key | 50 for 30 days. `ERR_MEET_PROFILE_LOCKED` is returned only to explain a teaser |
| `meet_boost(p_idempotency_key, p_target_kind, p_target_id uuid DEFAULT NULL, p_use_perk bool DEFAULT false, p_expected_cost int DEFAULT 0)` → `{boost_id, ends_at}` | key | |
| `meet_set_profile_lock(p_idempotency_key, p_min_card text NULL)` | key | Needs active VIP or Captain |
| `meet_set_reachable(p_idempotency_key, p_reachable bool, p_accept_requests bool)` | key | `reachable` needs VIP plus photo verification |
| `meet_progress()`, `meet_ladder()`, `meet_missions()`, `meet_surprise_odds()`, `meet_perks()` | read | |
| `meet_claim_streak(p_idempotency_key)` → `{day_in_cycle, cowries, xp, streak}` | key | Errors: ALREADY_CLAIMED |
| `meet_claim_mission(p_idempotency_key, p_mission_key)` | key | Errors: MISSION_INCOMPLETE, ALREADY_CLAIMED |
| `meet_open_surprise(p_idempotency_key)` → `{prize_key, quantity, expires_at}` | key | Errors: SPIN_USED |

M2 also replaces the bodies (same signatures) of `meet_swipe` (super interest beyond the free one costs 30), `meet_send_signal` (5), `meet_start_game` (10 beyond the free allowance) and `meet_set_privacy` (Platinum keys). **The app never buys through an RPC; it calls `meet-purchase-verify`.**

### 4.6 M2 admin RPCs

| Function | Roles | Notes |
|---|---|---|
| `admin_meet_purchases(p_query text, p_limit int)` | finance_officer, super_admin | By exact order id, a token SHA-256 prefix of at least 12 hex characters, or an exact user id |
| `admin_meet_wallet(p_user_id)` | finance_officer, super_admin | Wallet, last 50 entries, purchases, subscriptions |
| `admin_meet_request_cowrie_adjustment(p_idempotency_key, p_user_id, p_delta_bonus bigint, p_reason)` | finance_officer, super_admin, MFA | Bonus only. \|delta\| ≤ 1,000 applies at once; up to 5,000 creates an `approvals` row (`meet_cowrie_adjustment`) |
| `admin_meet_approve_cowrie_adjustment(p_idempotency_key, p_approval_id)` | finance_officer, super_admin (four eyes) | |
| `admin_meet_refund_purchase(p_idempotency_key, p_purchase_id, p_reason)` | finance_officer, super_admin, MFA | Outbox `meet_billing`/`meet.refund_requested`. The worker calls `orders.refund?revoke=true` and the void path claws back |
| `admin_meet_save_gift(p_idempotency_key, p_key, p_cost, p_popularity_points, p_receiver_xp, p_min_card, p_animation_key, p_active, p_sort)` | super_admin, MFA, audited | |
| `admin_meet_save_pack(p_idempotency_key, p_product_id, p_units, p_active, p_sort)` | super_admin, MFA, audited | |

Spend costs, cards, XP, the surprise prizes, gift caps and billing settings change only through the existing `propose_config_change`/`review_config_change` on `remote_config` `meet.*` keys, with two signatures (§2.9).

### 4.7 M2 gateway functions (service_role)

| Function | Returns / behaviour |
|---|---|
| `gateway_meet_purchase_begin(p_user_id, p_purchase_token, p_product_id, p_reported_price_micros, p_reported_currency)` | `{purchase_id, state, billing_account_ref}`. The token is bound once. A token bound to another user returns `{state:'rejected', reason:'token_claimed'}` **after** recording the attempt and raising a `pair` fraud flag. It returns rather than raises (D24) |
| `gateway_meet_purchase_verified(p_purchase_token, p_verification jsonb)` | `{state, units_granted, next:'consume'|'acknowledge'|'refund'|'none'}`. Validation and grant happen in one transaction |
| `gateway_meet_purchase_completed(p_purchase_token)` | |
| `gateway_meet_purchase_failed(p_purchase_token, p_error text, p_retry_seconds int)` | |
| `gateway_meet_purchase_voided(p_purchase_token, p_voided jsonb)` | `{clawed_back, purchased_after}`. Idempotent |
| `gateway_meet_subscription_synced(p_purchase_token, p_subscription jsonb, p_user_id uuid DEFAULT NULL)` | `{entitled, expiry_time}` |
| `gateway_meet_resolve_account(p_obfuscated_account_id)` | user_id or NULL (for RTDN tokens the app never submitted) |
| `gateway_meet_rtdn_store(p_message_id, p_payload jsonb)` | `{event_id|null}` (wraps `private.ingest_webhook('google_play', …)`; NULL means a duplicate) |
| `gateway_meet_rtdn_processed(p_event_id bigint, p_error text DEFAULT NULL)` | |
| `gateway_meet_billing_work(p_limit int)` | Due purchases, unprocessed `google_play` webhook rows, subscriptions to resync, outbox `meet_billing` cancellations and refunds |
| `gateway_meet_void_cursor(p_set timestamptz DEFAULT NULL)` | |
| `gateway_meet_readiness_auto(p_item, p_done)` | Only `rtdn_test_received` |

### 4.8 M2 Edge Functions

All three use `_shared/play/client.ts`, which wraps `ServiceAccountTokens(parseServiceAccount(PLAY_BILLING_SERVICE_ACCOUNT_JSON), 'https://www.googleapis.com/auth/androidpublisher')`, and `_shared/play/oidc.ts`, which uses `jose` 6.2.12 (already in `deno.json`).

**`POST /meet-purchase-verify`** (`verify_jwt=true`; in `edge-functions.openapi.yaml` as app-callable)

- Body: `{purchase_token, product_id, reported_price_micros?, reported_currency?}`. The token is the natural idempotency key.
- 200 `{state:'granted'|'pending'|'rejected', wallet, vip?}`.
- 202 `{state:'queued'}` when Play is unreachable or `meet.purchases_verify_paused` is on; the worker retries.
- 4xx `ERR_MEET_PURCHASE_REJECTED`, `ERR_MEET_PURCHASE_TOKEN_CLAIMED`, `ERR_MEET_PRODUCT_UNKNOWN`.
- **It never checks `meet.purchases`.**

**`POST /play-rtdn`** (`verify_jwt=false`)

1. Verifies the Pub/Sub OIDC bearer against `https://www.googleapis.com/oauth2/v3/certs`: `iss` is `accounts.google.com` or `https://accounts.google.com`; `aud` is `PLAY_RTDN_AUDIENCE`; `email` is `PLAY_RTDN_PUSH_SA` with `email_verified`. A failure returns 401 and stores nothing.
2. Stores the raw message through `gateway_meet_rtdn_store`.
3. Processes it in line (§5.4.5).
4. Returns 204 once stored, so poison messages are not hot-retried; the worker retries unprocessed rows.

**`POST /meet-billing-worker`** (worker key; cron)

- Retries verification, consume and acknowledge with backoff (1 min, 5 min, 30 min, 2 h, 6 h, up to 48 h).
- Runs `voidedpurchases.list` hourly and resyncs subscriptions daily.
- Refunds and revokes rejected tokens.
- Cancels the subscriptions of erased accounts.
- Processes unprocessed RTDN rows.

**Secrets:** `PLAY_BILLING_SERVICE_ACCOUNT_JSON`, `PLAY_PACKAGE_NAMES` (`com.suskiierrands.app`), `PLAY_RTDN_AUDIENCE`, `PLAY_RTDN_PUSH_SA`.

### 4.9 M3 API

**Client RPCs** (`meet.calls.voice`/`meet.calls.video`):

- `meet_start_call(p_idempotency_key, p_conversation_id, p_media text DEFAULT 'audio', p_expected_cost int)` → `{call_id, room_name, block_cost, block_minutes}`.
  - Requires an open, engaged conversation in which both sides have sent at least 3 messages, and a balance that covers one block.
  - Video also needs both people photo-verified and a match at least 72 h old.
  - Simultaneous starts resolve into one call (the `20260921120500` precedent).
  - Errors: `ERR_MEET_CALL_UNAVAILABLE`, `ERR_MEET_CONVERSATION_CLOSED`, `ERR_MEET_INSUFFICIENT_COWRIES`, `ERR_MEET_PRICE_CHANGED`.
- `meet_answer_call(p_idempotency_key, p_call_id)` → `{room_name}`. Charges block 1 to the caller.
- `meet_decline_call(p_idempotency_key, p_call_id)`.
- `meet_end_call(p_idempotency_key, p_call_id)` → `{blocks_billed, duration_s, refunded}`.
- `meet_call_heartbeat(p_call_id)` → `{state, next_block_at, affordable_blocks}`.
- `meet_call_state(p_call_id)`.

**Gateway:** `gateway_meet_call_due_blocks(p_limit)`, `gateway_meet_call_bill_block(p_call_id, p_block_no)` → `{charged, force_end}`, `gateway_meet_calls_to_disconnect(p_limit)`, `gateway_meet_call_disconnected(p_call_id, p_reason)`.

**Edge Functions:**

- **`meet-call-token`** (JWT): `{action:'start'|'answer', conversation_id|call_id, media, idempotency_key, expected_cost}` → `{url, token, room, call_id, block_cost}`. Reuses `call-token/token.ts roomToken()`. Identity is the profile id, with no display name. `canPublishSources` is `['microphone']`, plus `camera` only for video with the flag on. TTL 600 s.
- **`meet-call-worker`**: bills, force-ends and disconnects through RoomService `RemoveParticipant`/`DeleteRoom` (Twirp paths and auth are **VERIFY-IN-RESEARCH, S-16**).

**Analytics:** `analytics_report('meet_daily', …)` through the existing door; `kpi_meet_safety(p_from, p_to, p_country_code)` (reports per 1,000 active profiles, SLA attainment, median decision time); `kpi_meet_economy` (finance_officer: live purchases, units sold, spent, outstanding purchased balance). All are aggregates, cells under 10 are NULL, and they are scoped by role and country.

**Meet-ups v2** (after the forced update; `meet.meetups_v2`):

- The eight meetup RPCs are restated with `private.meet_meetups_gate(uid)`, which does nothing while the flag is off and raises `ERR_MEET_ELIGIBILITY_REQUIRED` when it is on.
- New: `meetup_requests(p_meetup_id)` → `{request_id, first_name, verified}`, host only; `respond_meetup_request(p_idempotency_key, p_request_id, p_approve bool)`; `create_meetup` accepts `requires_approval` and `min_card` through a **new** `create_meetup_v2(...)`, so the existing signature is untouched.
- `meetup_max_active_hosted` becomes per card (Platinum 6).
- An upheld moderation case now notifies attendees (fixes the silent-cancel gap).

---

## 5. Economy

### 5.1 Principles (decisions 2 and 5)

- **Cowries are spend-only.** They are never withdrawable, transferable, exchangeable or convertible, and that applies to purchased and free Cowries alike. They buy winks, pokes, reactions, flirts, gifts, game rounds, super interests, reach requests, reveals, unlocks, boosts and call blocks, and nothing else.
- **Gifts confer status, not cash.** No earnings exist, no naira value is ever posted, and no function moves Cowries between users.
- **Structural firewall.** Cowries never touch `public.payments`, `ledger.*`, `public.currencies` or `Money`. On the client `Cowries(int units)` (Dart) and `CowrieAmount` (TypeScript) are plain integer value types.
- **Play is merchant of record.** Naira revenue appears only in Play's financial reports, which RB-18 reconciles monthly against `play_purchases`.
- **Words** (enforced by the CI grep in §8.12): the app never says "wallet", "earn", "cash", "withdraw", "sponsor", "get paid" or "pay to chat". It says "Cowries", "Get Cowries", "send a gift", "react".

### 5.2 The books (`meet_econ`)

- **Two balances.** `wallets` holds one row per person: `purchased`, which may go negative after a clawback, and `bonus`, which is never negative.
- **Entries.** Every change writes exactly one entry and one wallet update, in the same transaction, under the wallet row lock. The sign-rule CHECK means no function can credit the wrong balance whatever its bug. Admin grants are always bonus; a person can never create purchased Cowries.
- **Why not double-entry in `ledger.post`:** there is no counter-party any more. On the Free plan each 5-Cowrie wink would cost a transaction row, two entries and an unpruned `ledger.posted` outbox row. XCW in the anon-readable `currencies` table would reach clients whose `Money.exponentOf` asserts or throws. Withdrawal CHECKs reference `ledger.account_type`.
- **Reconciliation.** `private.meet_reconcile()` runs nightly and checks:
  - per wallet, `purchased = Σ delta_purchased` and `bonus = Σ delta_bonus`;
  - globally, `Σ purchase entries = Σ play_purchases.units_granted` and `Σ purchase_void = −Σ units_voided`.

  The result goes to `private.record_health_check('meet_wallets', status, detail)`, and a mismatch alerts through the existing health route (RB-18).
- **Deferred revenue.** The outstanding purchased balance (`Σ max(purchased,0)` over wallets without `test_funds`) is reported in `kpi_meet_economy` and the readiness console.

### 5.3 The spend primitive

`private.meet_spend(p_user uuid, p_action text, p_cost int, p_expected int, p_ref_kind text, p_ref_id text, p_reason_key text) RETURNS jsonb`. Callers first claim idempotency and validate the business rules, then call it.

1. If `p_cost IS DISTINCT FROM p_expected`, RAISE `ERR_MEET_PRICE_CHANGED`. Nothing has been written.
2. If `p_cost = 0` (VIP-free, a perk or the free allowance), update the ceiling counter under the `meet_daily_counters` row lock and return `{paid_with:'free'|'vip'|'perk', wallet}`.
3. `INSERT INTO meet_econ.wallets (user_id) VALUES (p_user) ON CONFLICT DO NOTHING`, then `SELECT … FOR UPDATE`. This lock serialises every spend, grant and void for the person. Gifts credit no wallet, so there are no cross-user lock cycles.
4. If `restricted` is set or `purchased < 0`, RAISE `ERR_MEET_WALLET_RESTRICTED`.
5. Bonus first: `v_bonus := least(bonus, cost)`, `v_purch := cost − v_bonus`. If `v_purch > purchased`, RAISE `ERR_MEET_INSUFFICIENT_COWRIES` with DETAIL `{"needed":cost,"total":bonus+purchased}`.
6. INSERT the entry (`spend`, −v_purch/−v_bonus, ref, `balance_after_*`, `is_test := wallet.test_funds`), UPDATE the wallet (lifetime counters, `version+1`), broadcast `user:{uid}` `meet.wallet {version}`.
7. Return `{spent_purchased, spent_bonus, paid_with:'cowries', wallet:{total, purchased, bonus, version}}`.

Every raise happens before any write, so each is a catchable P0001 (the S-14 lesson). Callers create the thing bought after `meet_spend` in the same transaction, so a refusal leaves nothing behind. Every spend RPC returns `wallet`, which lets the Cowrie pill animate "−5" with no second call.

**Free-path order** before Cowries: a matching perk (decremented, earliest expiry first), then VIP-free (for VIP-free actions, under fair use), then the daily free allowance, then Cowries.

**`private.meet_grant(p_user, p_kind, p_units, p_ref_kind, p_ref_id, p_reason_key, p_is_test bool)`** uses the same lock. A purchase credit first pays back a negative `purchased` and clears `negative_balance` once `purchased ≥ 0`. A test grant sets `test_funds`.

**Seamless spend UX.**

- Below `meet.spend.confirm_above` (default 20) there is no prompt: an inline "−5" chip shows instead.
- At or above it, the action button itself is the confirmation, reading "Send Rose · 20". The first spend of each kind in a session shows the price once.
- On `ERR_MEET_INSUFFICIENT_COWRIES`, the client opens the Get Cowries sheet scrolled to the smallest pack that covers the shortfall. After a granted purchase it **replays the same intent with the same idempotency key**.
- The balance pill is always visible in the Meet top bar.

**Concurrency test:** `supabase/tests/e2e/meet_spend_e2e.sh` (beside `ai_quota_e2e.sh`, added to `backend-db.yaml`) runs 20 parallel 30-Cowrie spends against a balance of 100. Exactly 3 must succeed and the reconcile must stay clean.

### 5.4 Google Play Billing, end to end

#### 5.4.1 Client (`apps/mobile`)

- **Dependency:** `in_app_purchase: 3.3.1`, pinned exactly. It resolves `in_app_purchase_android` 0.5.5, which is Play Billing Library 9.1.0 with minSdk 23; the app uses 24. PBL 8+ has been mandatory since 31 Aug 2026, and PBL 8 itself expires 31 Aug 2027.
  - Never strip `com.google.android.play.billingclient.version` from the merged manifest.
  - `com.android.vending.BILLING` passes the `mobile-native.yaml` denylist.
- **Interface and implementation:** the domain interface `StoreBillingService`, deliberately not called a repository because it is a platform service, has a Play implementation in `packages/suskii_data/lib/src/billing/play_billing_service.dart` and a mock `MockStoreBillingService`. The mock simulates purchased, pending, canceled, `billingUnavailable` and voided, and is used on web, dev and staging flavours and in goldens.
- **`StorePurchaseCoordinator`** (`apps/mobile/lib/app/store_purchases.dart`) is kept alive from `app.dart` while Meet economy is on. It subscribes to `InAppPurchase.instance.purchaseStream` at app start and calls `restorePurchases()` at start and on every `AppLifecycleState.resumed`.
- **Loading products:** `queryProductDetails({meet_cowries_200, meet_cowries_520, meet_cowries_1100, meet_cowries_6000, meet_vip})`, using the ids from `meet_billing_context`. Prices are shown **only as `ProductDetails.price`**; no ₦ figure is hardcoded. When `isAvailable()` is false (dev, staging, the sideloaded dev-latest APK, OEM kids mode), the sheet reads "Available in the Play Store version".
- **Packs:** `buyConsumable(purchaseParam: GooglePlayPurchaseParam(productDetails: d, applicationUserName: billingAccountRef), autoConsume: false)`. The default `autoConsume: true` would consume on the client before the server grants anything.
- **VIP:** `buyNonConsumable(purchaseParam: GooglePlayPurchaseParam(productDetails: <base plan offer>, applicationUserName: billingAccountRef, changeSubscriptionParam: <for weekly↔monthly>))`.
- **`billingAccountRef`** is 32 random hex characters minted by the server. It is never an email, phone or uid, and stays within the 64-character `obfuscatedAccountId` limit.
- **Handling purchase updates:**
  - `pending`: show "Payment pending" and grant nothing.
  - `purchased` or `restored`: POST the token to `meet-purchase-verify`, refresh the wallet, then call `completePurchase` when `pendingCompletePurchase` is set. The server has already consumed or acknowledged, and S-15 confirms the client call is then a harmless no-op.
  - `error` or `canceled`: show a message.
- **Steering:** the Android app never links, buttons or text-steers to any other way to pay. **iOS shows no purchase UI at all** (no StoreKit yet; earned Cowries still work).

#### 5.4.2 Server verification (`meet-purchase-verify`, retried by the worker)

1. Read the user from the JWT.
2. Call `gateway_meet_purchase_begin`; the token is bound once.
3. Fetch the purchase [S, confirmed by S-15]:
   - packs: `GET https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{package}/purchases/productsv2/tokens/{token}` (getproductpurchasev2);
   - VIP: `GET …/purchases/subscriptionsv2/tokens/{token}`.
4. Call `gateway_meet_purchase_verified`, which in one transaction requires:
   - `packageName ∈ PLAY_PACKAGE_NAMES`;
   - the product id equals the bound one and exists in `cowrie_packs` (active) or is `meet_vip`;
   - purchase state PURCHASED (PENDING → `pending`, no grant; CANCELLED → `rejected`);
   - `obfuscatedExternalAccountId = billing_account_ref`. If it is absent, `binding='first_claim'` and a low-severity flag is raised;
   - no `fraud_hold` or active `purchase_hold_until`;
   - `testPurchaseContext` present means `is_test = true`, accepted when `meet.billing.accept_test_purchases`.
5. On success it grants `units × quantity` to `purchased` (entry `purchase`, ref = purchase id), with state `granted`.
6. Consume or acknowledge:
   - packs: `POST …/purchases/products/{productId}/tokens/{token}:consume`;
   - VIP: `POST …/purchases/subscriptions/{subscriptionId}/tokens/{token}:acknowledge`.

   Success moves the state to `completed`. A failure keeps `granted` with `next_attempt_at`, and the worker retries well inside Play's 3-day auto-refund window. If Play auto-refunds anyway (`voidedReason 8`), the void path claws back.
7. **Rejected tokens** (wrong package, account mismatch, a claimed token, a wallet hold) are never granted. The worker refunds them explicitly with `orders.refund?revoke=true` for packs or `subscriptionsv2…:revoke` for VIP, so nobody pays for nothing. That needs the "Manage orders and subscriptions" permission.

#### 5.4.3 Flags and break-glass

- `meet.purchases` and `meet.vip` gate **starting** a purchase only (`purchases_enabled` and the store UI).
- Verifying an already-paid token **always** runs.
- `meet.purchases_verify_paused` queues tokens in `received` for up to 48 h and returns 202.

#### 5.4.4 RTDN delivery (Terraform, owner-applied)

In `infra/terraform/modules/environment/main.tf` plus a new `pubsub.tf`, for `suskii-prod`:

- enable `pubsub.googleapis.com` and `androidpublisher.googleapis.com`;
- topic `play-rtdn`, with `google-play-developer-notifications@system.gserviceaccount.com` granted `roles/pubsub.publisher`;
- push subscription to the `play-rtdn` URL with OIDC service account `play-rtdn-push@`;
- `service-<projnum>@gcp-sa-pubsub.iam.gserviceaccount.com` granted `roles/iam.serviceAccountTokenCreator` on that account.

In Play Console, choose "Get all notifications for subscriptions and one-time products".

#### 5.4.5 RTDN processing

The notification body is never trusted for state; every type re-reads from the API.

| Notification | Action |
|---|---|
| `oneTimeProductNotification` 1 (PURCHASED) | Runs the verify path. If the token is unknown because the app died before submitting, the owner is resolved through `obfuscatedExternalAccountId` (`gateway_meet_resolve_account`). This is the "no funds lost" path |
| `oneTimeProductNotification` 2 (CANCELED) | A pending purchase becomes `rejected` |
| `subscriptionNotification` (any type) | `subscriptionsv2.get` → `gateway_meet_subscription_synced` |
| `voidedPurchaseNotification` (productType 1 subscription / 2 one-time; refundType 1 full / 2 quantity-partial) | `gateway_meet_purchase_voided` |
| `testNotification` | Sets readiness `rtdn_test_received` |

**Backstop:** the worker runs `GET …/purchases/voidedpurchases?type=1&includeQuantityBasedPartialRefund=true&startTime=<cursor − 2h>` hourly, paginated. Limits: 6,000 queries a day and 30 per 30 s. Play keeps 30 days of history.

#### 5.4.6 Clawback

- **Amount:** `units_to_remove = units per item × voided quantity`, including any pack bonus. Entry `purchase_void` debits `purchased`, which may go negative.
- **Negative balance:** the wallet becomes `restricted='negative_balance'`. No spend of any kind is allowed until `purchased ≥ 0`, but **new purchases are allowed so the person can repay**, and the restriction clears itself. Free actions (likes, passes, chat with matches, free allowances) keep working.
- **Fraud reasons** (voidedReason 5 fraud, 6 friendly fraud, 7 chargeback):
  - `purchase_hold_until = now() + meet.billing.fraud_void_hold_days` (90);
  - reverse the popularity this person's gifts conferred since the voided purchase time, up to the voided units (`reversal` popularity events);
  - `raise_fraud_flag('user', uid, 'meet_purchase_voided', 70::smallint, …)`.
- **Repeat voids:** two voids within 90 days set `fraud_hold`. Lifting it is a human decision (OD-25).
- **Non-fraud voids** (remorse and the like) reverse nothing for receivers, who did nothing wrong and received status only.

#### 5.4.7 Subscriptions

- **Entitlement:** `expiry_time > now()` and the state is ACTIVE, IN_GRACE_PERIOD, or CANCELED but not yet expired.
- **Supersession:** a token whose `linkedPurchaseToken` points at an older one supersedes it, so nobody holds two entitlements.
- **Revoke or void:** ends the entitlement at once and subtracts the voided period from `vip_paid_days`, then the card is recomputed.
- **VIP-day accrual:** once per local day while entitled, and only for `is_test = false` subscriptions.

#### 5.4.8 Account deletion

- Never blocked by Cowries; forfeiture is disclosed in the Meet terms and on the deletion screen.
- With active VIP, the screen says so, and the worker calls the subscription cancel API (`purchases.subscriptions.cancel`, VERIFY-IN-RESEARCH in S-15) so it does not renew.
- `play_purchases.user_id` and `entries.user_id` are set to NULL and kept for accounting. The retention period is `[A]` (OD-44).

#### 5.4.9 Test purchases

Testers' sandbox doubles as production (decision 5), so test purchases are accepted, stored with `is_test` and credited to `purchased`. They set `wallets.test_funds`, which excludes that wallet's spend from the card spend path. They are excluded from `kpi_meet_economy`, `analytics.meet_daily` revenue measures and VIP-day accrual.

#### 5.4.10 Health and reconciliation

| Check | Condition |
|---|---|
| `meet_billing_unacknowledged` | Any `granted` row older than 24 h warns; older than 48 h fails |
| `meet_billing_rtdn_backlog` | Unprocessed `google_play` webhook rows older than 1 h |
| `meet_wallets` | Nightly reconcile |

RB-18 also defines a **monthly finance reconciliation**: download Play's earnings and sales reports and match order ids against `play_purchases` (excluding test purchases). Reports do not transfer if the app moves accounts (OD-29/OD-51).

#### 5.4.11 Secrets and owner setup

- Create `play-billing@suskii-prod.iam.gserviceaccount.com` and invite it in Play Console with **app-level** access to `com.suskiierrands.app` only: "View financial data" and "Manage orders and subscriptions". **Do not widen `play-publisher@`.**
- `supabase/tools/set_play_billing_key.py` (owner-run, like `set_fcm_key.py`) sets the secret.
- `_deploy-supabase.yaml` wires the four secrets.

### 5.5 Spend menu (`meet.spend_costs`; client-visible; two signatures to change)

Free: browsing, receiving interest, a basic like, a pass, chatting with a match, emoji reactions on messages, and safety controls.

| Action | Cowries | VIP | Free allowance (member) |
|---|---|---|---|
| wink, poke | 5 | free (fair use 100/day; ceiling 150) | 10 winks/day |
| reaction (status, photo, prompt) | 5 | free (fair use) | — |
| flirt, compliment (canned, in chat) | 10 | free (fair use) | — |
| icebreaker game round (starter pays; responder free) | 10 | — | 5 rounds/day |
| small gift | 20 | — | — |
| super interest | 30 | — | 1/day |
| message before matching (reach request) | 40 | — | — |
| see who liked you (24 h) | 50 | free for Gold and above | — |
| unlock a badge-locked profile (30 days) | 50 | free when the card meets the lock | — |
| premium gifts | 100–2,500 | — | — |
| voice call per started 10 min (M3) | 150 | — | — |
| video call per started 10 min (M3) | 300 | — | — |
| profile boost (30 min) or status boost (6 h) | 300 | Platinum: 1 free status boost/week | perk `boost_minutes` |

### 5.6 VIP

- One Play subscription, `meet_vip`, with base plans `vip-weekly` (P1W, ₦900) and `vip-monthly` (P1M, ₦2,500). Prices are set in Play Console and shown from Play.
- **Before purchase** the VIP page shows the price, the billing period, "Renews automatically until you cancel", and a "Manage or cancel in Google Play" link to `https://play.google.com/store/account/subscriptions?sku=meet_vip&package=com.suskiierrands.app`. No trial in M2; any future trial states its conversion date.
- **Silver = an active VIP entitlement.** Perks:
  - free winks, pokes, reactions, flirts and compliments, under fair-use ceilings;
  - a wider daily set (25);
  - the Silver badge;
  - status posting with audience choice (a space of your own);
  - badge-lock of your own profile.
- VIP **never grants Cowries** (D17).

### 5.7 Card ladder (`meet.cards`, two signatures, all numbers `[A]`, OD-45)

| Card | Pay up: VIP days (cumulative, live only) | Pay up: purchased Cowries spent (lifetime, live wallets) | Play up: level | Upkeep |
|---|---|---|---|---|
| Member | — | — | default | — |
| Silver | VIP active | — | — | while VIP is active |
| Gold | ≥ 90 | ≥ 15,000 | ≥ 25 | kept once earned |
| Platinum | ≥ 180 | ≥ 45,000 | ≥ 45 | kept once earned |
| Captain | ≥ 365 | ≥ 120,000 | ≥ 70 | **monthly**, any one of: VIP active; ≥ 5,000 purchased spent in 30 days; ≥ 1,500 XP in 30 days. Otherwise drops to Platinum after a 7-day warning (`meet_progress` push) |

- **Recompute:** `private.meet_card_for(uid)` runs on every grant, spend, VIP sync or level-up. When VIP lapses, the card falls to the highest card still earned by days, spend or level.
- **What each card opens** (shown as "locked doors" on the ladder):

  | Card | Opens |
  |---|---|
  | **Member** | Meet people at your level; basic games (this-or-that, daily question); see the whole ladder |
  | **Silver** | VIP perks (§5.6) |
  | **Gold** | Reach popular and verified reachable members whose lock is Gold or lower; free reveals; compatibility quiz and light truth-or-dare; Gold-exclusive gifts |
  | **Platinum** | Priority placement (spotlight weight 2 in others' sets, requests listed first); reach reachable VIPs (lock ≤ Platinum); host up to 6 active meet-ups (M3 meet-ups v2); conveniences: incognito browsing, hide last-active, hide distance band; 1 free status boost a week |
  | **Captain** | Reach anyone reachable; a rare animated card frame shown at every connection; Captain-only events (`meetups.min_card`, M3); Captain-only gifts |

- **Unlocking is the privilege to reach.** It never guarantees a reply or a meeting, and the owner can always decline or block. The copy says exactly that.

### 5.8 XP and levels (`meet.xp`)

- **Curve:** `total_xp(L) = 25·L²`. L10 = 2,500; L25 = 15,625; L45 = 50,625; L70 = 122,500.
- **Daily cap:** 300 XP, excluding gift-received XP, which has its own cap of 50 a day. At the cap, Gold by play takes about 52 days, Platinum about 169 and Captain about 408, matching the 3-, 6- and 12-month VIP landmarks.
- **Events:**

  | Event | XP |
  |---|---|
  | daily_check_in | 10 |
  | profile_complete | 50, once |
  | photo_verified | 50, once |
  | game_round_finished | 15 |
  | first_reply_in_match | 10 |
  | status_posted | 10 |
  | daily_question | 10 |
  | streak_claim | 10 |
  | mission | its own reward |
  | gift_received | 1 per 10 Cowries of the gift (cap 50/day) |

- **Spending never buys XP**, so pay-up and play-up stay separate paths.
- **Level rewards** (`meet_levels`, every second or third level):

  | Level | Reward |
  |---|---|
  | 2 | 3 free winks |
  | 4 | compatibility-quiz preview round |
  | 6 | frame "sunset" (7 days) |
  | 8 | 1 extra card |
  | 10 | gift unlock "sunflower" |
  | 12 | 15 boost minutes |
  | 15 | game pack |
  | … | |

  Levels **never pay Cowries**. A level-up push (`meet_progress`) says only "You reached a new level"; the "close to next level" nudge has no numbers on the lock screen.

### 5.9 Streaks (`meet.streak.rewards`)

- A day counts once in the user's local time zone when they open Meet, do one action, then claim.
- Rewards: days 1–6 give 2 bonus Cowries and 10 XP; day 7 gives 15 Cowries and 50 XP; then the cycle restarts.
- A missed day resets the streak. **There is no paid repair**, which would be a dark pattern.
- "Streak about to break" is a `meet_reminder` push between 20:00 and 21:00 local, when unclaimed with a streak of at least 2, quiet hours respected.
- Streak Cowries obey the farming controls (§5.14).

### 5.10 Missions (`meet_mission_defs`, `meet.missions`)

- Three a day, drawn from: `complete_prompt`, `reply_to_match`, `finish_game`, `post_status`, `add_photo`, `daily_question`, `verify_photo` (once).
- Each pays 2 bonus Cowries and 15 XP. `complete_profile` is a one-time onboarding mission that pays 50 XP and three `free_wink` perks: **the first-session quick win, with no Cowries**.
- No mission ever counts likes, winks, messages sent, gifts or purchases.

### 5.11 Daily surprise (the spec's free spin, `meet.spin.prizes`, two signatures)

- One per local day per user (`UNIQUE (user_id, spin_date)`). There is no other route to more.
- The draw is server-side with `gen_random_bytes`.
- **Prizes are perks only**: non-giftable, non-transferable, expiring after 7 days, never Cowries.

  | Prize | Quantity | Weight (bps) |
  |---|---|---|
  | free_wink | 3 | 3500 |
  | extra_card | 3 | 3000 |
  | free_game_round | 1 | 2000 |
  | boost_minutes | 15 | 1000 |
  | profile_frame | 24 h | 500 |

- **Presentation:** "Pick one of three cards", never a wheel, slot or roulette. `meet_surprise_odds` returns the same rows the draw uses, as `probability_bps`, shown beside the cards. Official rules are at `https://suskiierrand.com/en/legal/meet-daily-reward-rules` (`legal_documents` type `meet_reward_rules`).

### 5.12 Gifts: status, not cash

**Catalogue (`meet_gift_catalogue`, seeded):**

| Key | Cost | Popularity | Receiver XP | Min card |
|---|---|---|---|---|
| rose, coffee, star, high_five | 20 | 2 | 2 | member |
| sunflower (level reward) | 50 | 5 | 5 | member |
| bouquet | 100 | 10 | 10 | member |
| jollof_party | 150 | 15 | 15 | member |
| crown | 500 | 50 | 50 | member |
| talking_drum | 1000 | 100 | 50 (cap) | member |
| golden_cowrie | 2500 | 250 | 50 (cap) | gold |
| captains_ship | 2500 | 250 | 50 (cap) | captain |

No cash-like or luxury-for-favours imagery: no money bags, designer bags or "allowance".

**Where gifts go:** a status, photo, prompt, profile, or attached to a reach request. **Never into a 1:1 chat.** The receiver must be in the sender's today's set or nearby list, a match or conversation partner, inside a status's audience, or reachable (`reachable`, verified, and the sender's card meets any lock).

**On send, in one transaction:**

1. `meet_spend` charges the sender.
2. The `meet_gifts` row is inserted.
3. Popularity: `+points`, capped by `meet.gifts.caps` (`popularity_per_sender_day` 300, `popularity_per_receiver_day` 3,000), via `meet_popularity_events`.
4. Receiver XP, under the gift-XP cap.
5. The receiver's card is recomputed.
6. A `meet_gift` push ("A gift arrived": no sender, gift name or value).

**What the receiver sees:** an animated gift card with the sender's first name and the gift. **No price, and no total of what anyone has spent on them.**

**Popularity:** `score_30d` is recomputed hourly. It feeds a "Popular" chip above a threshold and a ranking weight capped at +5% in daily sets. **There is no leaderboard anywhere.** The profile shows gift counts by type (`meet_gift_summary`), never senders or values.

**Same device:** gifts between accounts sharing a `device_fingerprint_hash` are delivered but award 0, silently, and raise a flag (`'pair'` subject, rule `meet_same_device_gift`). Accept-and-silently-block is the referral precedent.

**Content removed for policy:** every gift on it becomes `refunded`, each sender gets a `spend_refund` entry split purchased/bonus as paid, and the popularity is reversed.

**Notes:** canned keys only (`note_love_this`, `note_great_smile`, `note_made_my_day`, `note_hello`), so the paid surface carries no free text.

### 5.13 Boosts, unlocks, reach, reveals, calls

- **Profile boost (30 min):** the profile becomes a spotlight card in daily sets generated or topped up during the window, at most 2 spotlights per viewer per day, and is listed first in Nearby within its band.
- **Status boost (6 h):** the status moves to the front of its audience's ring. **A boost never widens the audience.**
- **Unlock:** 30 days.
- **Reveal likes:** shows the list of likers for 24 h.
- **Reach request:** 40 plus an optional gift. It expires in 7 days. Declining tells the sender only "not accepted"; the request is screened text and is blocked, not held, on a contact or solicitation hit.
- **Calls (M3):** the caller pays per started 10-minute block.
  - Block 1 is charged at answer and **refunded if the call ends within 60 s of answering**.
  - Block n is charged at `answered_at + (n−1)·10 min`.
  - A broadcast warning (`meet.call.low_balance`) goes out 60 s before a block the caller cannot afford.
  - At the boundary the server ends the call (`insufficient_cowries`) and the worker disconnects it (S-16).
  - Heartbeats every 60 s; the stale sweep ends calls after 180 s without one.
  - Metadata only, never recorded.

### 5.14 Free-Cowrie farming controls

- **Who gets Cowries:** all free Cowries (streak, missions, welcome) are credited only to profiles that are **at least 72 h old with an approved photo**. Before that, XP and perks are still awarded.
- **Daily cap** on all free Cowries: `meet.free_cowries.daily_cap` = 20.
- **Welcome grant:** 20 bonus Cowries once, after photo approval and 72 h, counted under the cap (OD-46).
- **New accounts:** premium gifts (≥ 100) are blocked for accounts younger than 24 h (`ERR_MEET_GIFT_UNAVAILABLE`, reason `new_account`).
- **Risk rules** (`run_risk_rules`, flags only, OD-25):
  - `meet_gift_concentration`: one receiver gets > 60% of a sender's spend over 7 days, above 2,000;
  - `meet_new_account_gifting`;
  - `meet_void_then_gift`;
  - `meet_mass_liking`: > 300 likes/day on 3 days;
  - `meet_same_device_gift`;
  - `meet_photo_reuse`;
  - `meet_report_cluster`;
  - `meet_strike_velocity`.

### 5.15 Configuration keys (M2)

| Key | Default |
|---|---|
| `meet.spend_costs` | §5.5 |
| `meet.spend.confirm_above` | 20 |
| `meet.vip` | `{"product_id":"meet_vip","base_plans":["vip-weekly","vip-monthly"],"fair_use":{"wink":100,"reaction":200,"flirt":50},"daily_size":25}` |
| `meet.cards` | §5.7 |
| `meet.xp` | `{"daily_cap":300,"gift_daily_cap":50,"curve":"25L2","events":{…}}` |
| `meet.streak.rewards` | `{"daily":{"cowries":2,"xp":10},"day7":{"cowries":15,"xp":50}}` |
| `meet.missions` | `{"per_day":3,"reward_cowries":2,"reward_xp":15}` |
| `meet.spin.prizes` | §5.11 |
| `meet.gifts.caps` | `{"popularity_per_sender_day":300,"popularity_per_receiver_day":3000,"premium_min_account_hours":24,"daily_cap_cowries_per_sender":10000}` |
| `meet.free_cowries` | `{"daily_cap":20,"min_account_hours":72,"welcome":20}` |
| `meet.boost` | `{"profile_minutes":30,"status_hours":6,"spotlight_per_viewer_day":2}` |
| `meet.unlock.days` | 30 |
| `meet.reach` | `{"ttl_days":7,"per_day":10,"decline_cooldown_days":30}` |
| `meet.billing` | `{"accept_test_purchases":true,"fraud_void_hold_days":90,"void_lookback_hours":2,"repeat_void_limit":2,"new_account_daily_units":6000,"daily_units":20000}` (server) |
| `meet.admin.adjustment` | `{"single_max":1000,"approved_max":5000}` (server) |

### 5.16 Economics `[A]`

- Nigeria is on the legacy 15%/30% service fee, and VAT is remitted from tax-inclusive prices. The ₦5,000 pack therefore nets about ₦0.66 per Cowrie.
- Because there are no earnings, no payout liability has to be priced in.
- Revenue lands on the personal payments profile until OD-29 is settled (OD-51).

---

## 6. Client

### 6.1 Ownership

All of §6 lives in Kimi's paths (`apps/mobile`, `packages/*`). The owner confirms per PR who builds it (§1.6).

**New code goes in new files** wherever possible, to keep the hotspot files small:

- `packages/suskii_domain/lib/src/repositories/meet_repositories.dart`;
- a `part` file for mocks;
- `apps/mobile/lib/app/meet_providers.dart`;
- `features/meet/**`;
- `meet.en.ts`/`meet.pcm.ts`.

The hotspots are `repositories.dart` (937 lines), `mock_repositories.dart` (3,949) and `router.dart`.

### 6.2 Shell and routes (`apps/mobile/lib/app/router.dart`)

**`AppRoutes`** gains constants and `xPath()` builders.

The shell is a third `StatefulShellRoute.indexedStack`, built by `MeetShell` (`features/meet/shell/meet_shell.dart`), **always forced dark** with `Theme(data: SAppTheme.dark())`. It reuses `AppShellScaffold`. `ShellDestination` gains an optional `badgeCount`; the field is additive, so the customer and provider shells are unchanged.

| Branch | Path | Label | Badge |
|---|---|---|---|
| 1 | `/meet/discover` | Discover | — |
| 2 | `/meet/chats` | Chats | unread chats + new matches |
| 3 | `/meet/nearby` | Nearby (label "Events" when `meet.nearby` is off) | — |
| 4 | `/meet/likes` | Likes | new likes, winks, requests |
| 5 | `/meet/me` | Me | — |

**Flat pushed routes**, declared before the shells with static segments before parameters:

| Milestone | Routes |
|---|---|
| M1 | `/meet/welcome`, `/meet/onboarding`, `/meet/filters`, `/meet/profile/:profileId`, `/meet/matches/:matchId`, `/meet/chats/:conversationId` (root navigator), `/meet/statuses/new`, `/meet/statuses/:profileId`, `/meet/games/:roundId`, `/meet/events/new`, `/meet/events/:id`, `/meet/me/edit`, `/meet/me/photos`, `/meet/me/privacy`, `/meet/me/notifications`, `/meet/me/blocked`, `/meet/me/verify`, `/meet/safety` |
| M2 | `/meet/cowries`, `/meet/vip`, `/meet/ladder`, `/meet/surprise`, `/meet/missions`, `/meet/requests`, `/meet/me/lock` |
| M3 | `/meet/calls/:callId` |

**Legacy and redirects:**

- The flat `/meet/new` and `/meet/:id` routes are removed.
- Redirect step **0b** (after the App Link step 0): `^/meet/([0-9a-fA-F-]{36})$` → `/meet/events/$1`, and `/meet/new` → `/meet/events/new`. Old `cancel_meetup` pushes and App Links `/app/meet/<id>` keep working.
- `/meet` itself, decided from `meetAccessProvider` (`meet_get_state`, refreshed on `user:{uid}` `meet.inbox` plus a 60 s poll; added to `_routerRefreshProvider`):
  - `v5 == false`: today's `MeetPage`, unchanged, so `_meetEvents` passes on it;
  - otherwise `/meet/welcome` when `eligibility != eligible` or the guidelines are outdated; `/meet/onboarding` when there is no active-or-pending profile; `/meet/safety?suspended=1` when suspended; else `/meet/discover`.
- A route for a feature that is switched off redirects to `/meet/discover`.

**Entry and exit:**

- `customer_home_page.dart` `home.suskiiMeet` becomes `context.go(AppRoutes.meet)`.
- A "Suskii Meet" row appears in the profile menu in both modes.
- Out: Android back at a Meet shell root goes to `context.go(<mode home>)` (PopScope), plus "Back to Suskii Errands" in Me. In M1 the top bar's left slot is an Errands home icon; from M2 it is the Boost rocket.

**`SecureScreen` (FLAG_SECURE)** wraps `/meet/chats/:id`, `/meet/profile/:id`, `/meet/statuses/:id`, `/meet/me/verify`, `/meet/cowries` and `/meet/calls/:id`.

### 6.3 Screens

Every screen handles loading (an `SSkeleton` shaped like the final layout), empty, error (`SErrorState` plus `localizedError`), offline (`SOfflineBanner`), feature-off and permission-denied states. All copy is l10n (en and pcm).

**M1 screens:**

1. **MeetGatePage** (`gate/meet_gate_page.dart`).
   - Brand illustration only, never photos of people. Four panels:
     1. "Meet new people, privately".
     2. "Adults only": a date-of-birth wheel, "I confirm I'm 18 or older", and the note that the date can't be changed later.
     3. "Keep it kind": guidelines with a checkbox and a link to the `meet_guidelines` URL.
     4. "The ladder": an animated `SLadder` preview, the spec §11 glimpse.
   - A refused result shows a calm final screen, "Meet isn't available on this account", with a support link and no retry.
2. **MeetOnboardingPage**, as steps with a progress bar:
   1. First name.
   2. Photos (at least 1, up to 6): a 2×3 grid with drag to reorder; `captureImage()` through the system picker, then 1080 px and 320 px JPEGs, uploaded to `UploadBucket.meetInbox`, then `meet_submit_photo`.
   3. Intent chips.
   4. Interests (up to 8).
   5. "You": gender, optional and hidden by default, with the sensitive-data note and consent.
   6. Area: a prominent disclosure ("We keep only your approximate area, about 5 km. Never your exact location."), then `deviceLocationProvider`, then `meet_set_area`.
   7. Prompts (optional).
   8. Privacy defaults (hide from errand contacts ON).
   9. Review.
   - **Quick win:** "Your photos are in review (usually within 12 hours) — browse today's faces now." Browsing needs an active profile, so the set opens once the first photo is approved. Until then a "Today's question" card and the ladder are shown. After approval the profile gets the `newcomer_until` spotlight (24 h). The `complete_profile` mission grants XP and free winks (M2).
3. **DiscoverPage**.
   - `STopBar`: left is the Errands home icon in M1 and the Boost rocket (with a red dot when a perk exists) in M2; centre is `STodayPill` "Today · 12 left"; right is filters.
   - `SIntentChips`: Everyone, Love, Friendship, Hangout.
   - An `SCardDeck` of `SPhotoCard`s with `SActionRail` on the right: + super interest, chat bubble (reach request, M2; hidden in M1), big white heart (like), X (pass).
   - Today's-question banner card at position 1 once a day.
   - The set ends with "That's today's faces — new ones tomorrow" and a countdown. **No endless scroll.**
   - The card overflow holds report and block; tapping the name opens the profile; a mutual like pushes the match screen.
4. **MeetProfilePage**: carousel, details, prompts, daily answer, gift counts (M2), a gift button on photos and prompts (M2), overflow report/block, wink/poke actions. Locked profiles render `SLockedTeaser` (M2).
5. **MatchPage**.
   - `SMatchCelebration`: a blurred backdrop, two tilted photo cards, "It's a" over "Match!" in the love colour.
   - "You matched with Ada", an `SQuickReplyBar` (pill field with a pink-gradient send button and 👋 😉 ❤️ 😍 chips that send immediately), a "24h to say hi" pill, a secondary "Play an icebreaker" and text "Keep browsing".
6. **LikesPage**, with tabs:
   - Likes you: a count and generated silhouettes (never photos), plus super interests and winks revealed. M2 adds "See who likes you · 50" (free for Gold and above).
   - Matches: `SMatchBubble`s with draining 24 h `SCountdownRing`s.
   - Requests (M2).
   - Gifts (M2: "Ada sent you a Rose · on your status"; Thank opens the profile; Hide).
   - Viewed you: today's count only.
7. **ChatsPage**: an `SStoryRing` row (own "+" first; unseen statuses have a gradient ring), a "New matches" strip with timers, the Requests row (M2), then the `SChatTile` list (avatar, name, tick, card chip in M2, preview or "typing…", time, `SUnreadBadge`). Swipe actions: unmatch, report.
8. **MeetChatPage**.
   - Header: name, tick, "Active today"; overflow with view profile, play a game, unmatch, block, report, safety tips; call (M3).
   - Body: `SChatBubble`s with free emoji reactions on long-press, inline `SGameCard`s, flirt animations (M2), and a first-time `SSafetyTipCard` ("Keep chatting on Suskii. Never send money or gift cards to someone you haven't met.").
   - Composer: a games die, a flirt button (M2), a text field and send.
   - A blocked send shows `SSafetyBanner` inline ("Phone numbers, emails, links and social handles can't be shared in Meet") with no bubble. When restricted, the composer is disabled and shows the end time.
   - Typing is a `meet.typing` broadcast debounced at 3 s; read on visible.
   - **Do not copy `SupabaseChatRepository.watchMessages`' empty-list-and-return bug.**
9. **GameRoundSheet** and **GameRoundPage**: this-or-that, compatibility quiz, light truth-or-dare and the daily question. Answers flip when both have answered, with a result chip ("3/5 in common").
10. **StatusComposerPage**: text on one of 8 gradients, or a photo (photo-verified only); an audience control (My matches / My matches + people who like me); the note "Statuses disappear after 24h and are never public." **StatusViewerPage** (`SStoryViewer`): progress bars, tap zones, hold to pause, a viewers list for the poster, report on others; M2 adds reactions and gifts.
11. **NearbyTab**.
    - Header "Nearby", an `SVisibleToggle` ("Visible"/"Hidden" → `meet_set_discoverable`), and Boost (M2).
    - A location card: "Lekki, Lagos · within 25 km · Edit".
    - Segmented [People | Events]:
      - **People** (behind `meet.nearby`): band sections "Under 5 km", "5–10 km", … as photo tiles ordered by activity, with no map and no presence.
      - **Events**: today's meet-ups body moved to `features/meet/events/events_tab.dart` without its own Scaffold or AppBar. The inner tabs are renamed "Upcoming"/"Mine" (`meetTabDiscover` → `meetEventsUpcoming`). `MeetupCard` becomes `STicketCard` (perforated notches, topic gradient cover, host initial, date and venue, "N going" `SAvatarStack` of initials). The FAB reads "Host a meet-up". `MeetDetailPage` and `CreateMeetPage` are kept and restyled. M3 adds the host approve/decline sheet.
12. **MePage**: the card as others see it, a completeness meter, the "Get verified" call to action, Edit profile, Photos (state per photo: processing, in review, approved, rejected with reason), Privacy, Notifications, Data saver, Safety centre, Blocked, Guidelines, Delete Meet profile, Back to Suskii Errands. M2 adds the Cowrie pill, card and level ring, streak row, missions, daily surprise, VIP banner, and lock and reach settings.
13. **VerifyPage**: biometric consent via `record_consent`, the pose prompt, a selfie through the system camera intent, and "Deleted 30 days after review".
14. **SafetyCentrePage**: tips, how reports work, "Report a child-safety concern" (works with no subject, and lists `childsafety@suskiierrand.com`), SOS through the existing `raise_sos` without a job, trip share, guidelines and terms.
15. **FiltersSheet**: age range (18–99), distance band, intents, and "Show me" with the note "Never shown to anyone, and never visible to Suskii staff."

**M2 screens:**

- **CowriesPage** ("Cowries", never "wallet"): balance, packs with Play price strings and a "Best value" ribbon, the disclosure "Cowries have no cash value. They can't be withdrawn, transferred or exchanged, and refunds go through Google Play.", history, a pending-purchase row, and the negative-balance explanation.
- **VipPage**: weekly and monthly with Play price, period and auto-renew terms; Manage in Google Play; the perks grid.
- **LadderPage** (`SLadder`): every card, its perks and locked doors, with dual-path progress ("Pay up: 42/90 VIP days · Play up: Level 14/25").
- **GiftSheet** (`SGiftPickerSheet`): prices visible to the sender only; an "Send Rose · 20" button; `SGiftBurst` honouring reduced motion.
- **SurprisePage** (`SMysteryCards` plus an `SOddsTable` and a rules link).
- **MissionsSheet**, **StreakSheet**, **BoostSheet**, **LockSettingsPage**, **RequestsTab**.
- **LockedProfileTeaser**: first name, card, primary photo, tick, and the honest ways in.

**M3 screens:**

- **MeetCallPage**: voice, with a pre-call price sheet ("150 Cowries per 10 minutes, charged to you"), a block meter, a low-balance top-up chip, and end-and-report.
- **Meet app lock** (`local_auth`, free; that PR verifies the manifest permission is not on the denylist).

### 6.4 `suskii_design` additions

Components go in `packages/suskii_design/lib/src/components/meet/`, exported from the barrel, each with a component golden. Tokens only, reduced motion through `SMotion.of`, semantics labels everywhere.

| Component | Spec |
|---|---|
| `SPhotoCard` | Full-bleed photo; segmented photo bars at the top; tap the left or right third to switch; bottom `photoScrim` gradient; top-left tag chip (New here, Popular, Verified); name + age + `SVerifiedTick` + `SCardTierBadge` (M2); chips for distance band (pin icon), intent and up to 3 interests; a shared-interest line ("You both love Afrobeats & suya"); today's answer |
| `SCardDeck<T>` | A stack of 3. Drag rotates ±12°. LIKE (heart, love colour) and NOPE stamps fade in past 25% of the width. A fling commits at 35% of the width or 800 px/s. An up-swipe is super interest. Haptics: selection at the threshold, medium on commit. Controller for button-driven swipes. Semantics actions "Like" and "Pass". Reduced motion: no rotation |
| `SActionRail` | Vertical, right, bottom-aligned: + super interest (48), chat (48, cost tag in M2), heart (72 px white disc, love-colour heart), X (56, translucent). Tooltips |
| `SMatchCelebration`, `SQuickReplyBar` | As in §6.3. Confetti is static under reduced motion |
| `SIntentChips` | Horizontal scroll; selected = white fill, navy text |
| `STopBar`, `STodayPill` | Left slot, centre pill with a countdown when empty, right filters, `SCowriePill` (M2) |
| `SStoryRing`, `SStoryViewer` | Segmented gradient ring per unseen status, grey when seen; a "+" on your own |
| `SChatTile`, `SUnreadBadge`, `STypingDots`, `SMatchBubble`, `SCountdownRing` | Unread pill shows "9+"; the countdown ring drains over 24 h |
| `SChatBubble`, `SGameCard`, `SSafetyBanner`, `SSafetyTipCard` | Mine: gradient fill. Theirs: `surfaceHigh`. Seen tick; reactions row |
| `STicketCard`, `SAvatarStack` | Perforated notches via a `CustomClipper`, a dashed separator, "N going" |
| `SVisibleToggle`, `SDistanceBandChip`, `SVerifiedTick` | |
| `SNetworkPhoto` | A path-keyed `ImageProvider` over the gateway's authenticated object fetch, with an in-memory LRU plus an app-private disk cache cleared on sign-out, a placeholder, a fade-in, and data-saver awareness (thumbs and the primary photo only until tapped). An injectable factory gives `MemoryImage` in goldens |
| M2: `SCowriePill`, `SCowriePrice`, `SGiftPickerSheet`, `SGiftBurst`, `SCardTierBadge`, `SLadder`, `SXpBar`, `SStreakFlame`, `SMysteryCards`, `SOddsTable`, `SLockedTeaser` | The pill floats "−5"/"+20" on `meet.wallet` and has a red outline when restricted. `SCowriePrice` is an integer plus the shell glyph, **never `Money`** |
| M3: `SCallMeter` | Time left in the block |

**Tokens.** `SColors` plus the `SuskiiColors` extension gain the following, in dark and light, mirrored by hand into `packages/design-tokens/tokens.json` and checked with `node packages/design-tokens/build-css.mjs --check`. WCAG AA pairs are added in `design_tokens_test.dart`.

| Token | Value |
|---|---|
| `love`, `onLove` | brand red on a white disc |
| `verified` | AA-checked royal blue, ≥ 3:1 for graphics on navy |
| `tierSilver`, `tierGold`, `tierPlatinum`, `tierCaptain` | Captain is the brand gradient with navy foil |
| `photoScrim` | transparent to navy at 90%, bottom 45% |
| `chipOnPhoto` | white at 20% with white text |

Typography: Sora for names and "It's a Match!" (w800), Manrope for body. **InMessage's layout only: never its name, logo, icons or images.**

### 6.5 Domain (`packages/suskii_domain`)

**Entities** (freezed, `@JsonValue` snake_case) in `lib/src/entities/meet/`, exported from `suskii_domain.dart`:

| Milestone | File | Contents |
|---|---|---|
| M1 | `meet_state.dart` | `MeetState`, `MeetEligibility`, `MeetFeature`, `MeetRestriction`, `MeetUnread` |
| M1 | `meet_profile.dart` | `MeetProfile`, `MeetPhoto`, `MeetPhotoStatus`, `MeetPrompt`, `MeetIntent`, `MeetGender`, `MeetProfileDraft`, `MeetDiscoveryPrefs`, `Seeking`, `MeetPrivacy` |
| M1 | `discovery.dart` | `DiscoveryCard`, `DistanceBand`, `ActivityBand`, `SwipeAction`, `LikeKind`, `SwipeResult`, `SignalKind`, `LikesSummary` |
| M1 | `meet_match.dart` | `MeetMatch`, `MeetMatchStatus` |
| M1 | `meet_chat.dart` | `MeetConversation`, `MeetMessage`, `MeetMessageKind`, `MeetSendResult {status, reason, restrictedUntil}` |
| M1 | `meet_status.dart` | `MeetStatusPost`, `StatusAudience`, `StatusRingEntry` |
| M1 | `icebreaker.dart` | `MeetGame`, `GameRound`, `GameAnswer`, `DailyQuestion` |
| M1 | `meet_safety.dart` | `MeetReportReason`, `MeetSubjectKind`, `BlockedProfile`, `VerificationPose` |
| M2 | `cowries.dart` | `@immutable class Cowries { final int units; }` with `format()`; **never a `Money`** |
| M2 | `meet_economy.dart` | `CowrieBalance`, `CowrieTxn`, `SpendCosts`, `GiftItem`, `ReceivedGift`, `CowriePack`, `VipPlan`, `VipStatus`, `CardTier`, `LadderStep`, `MeetProgressInfo`, `Streak`, `Mission`, `SurprisePrize`, `Perk`, `ReachRequest`, `PurchaseOutcome` |
| M3 | `meet_call.dart` | `MeetCall` |

**Repository interfaces** go in the new `lib/src/repositories/meet_repositories.dart`, exported. Every mutating method takes `required String idempotencyKey`. Method names are shared by app and web, for parity.

| Repository | Methods |
|---|---|
| `MeetAccessRepository` | `getState`, `checkIn`, `acceptGuidelines` |
| `MeetProfileRepository` | `getMyProfile`, `saveProfile`, `setArea`, `setDiscoveryPrefs`, `submitPhoto`, `removePhoto`, `reorderPhotos`, `savePrompt`, `removePrompt`, `setDiscoverable`, `setPaused`, `setPrivacy`, `deleteMeetProfile`, `getProfile` |
| `MeetDiscoveryRepository` | `dailySet`, `nearby`, `swipe`, `sendSignal`, `likesSummary` |
| `MeetMatchRepository` | `matches`, `unmatch` |
| `MeetChatRepository` | `conversations`, `watchConversations`, `messages`, `watchMessages`, `sendMessage`, `markRead`, `reactToMessage`, `sendTyping`, `watchTyping` |
| `MeetStatusRepository` | `ring`, `post`, `delete`, `view`, `viewers` |
| `MeetGameRepository` | `catalogue`, `start`, `answer`, `round`, `dailyQuestion`, `answerDailyQuestion` |
| `MeetSafetyRepository` | `report`, `block`, `unblock`, `blockedProfiles`, `verificationPose`, `submitVerification` |
| M2 `CowrieRepository` | `billingContext`, `balance`, `watchBalance`, `history`, `verifyPurchase` |
| M2 `MeetEconomyRepository` | `catalogue`, `sendReaction`, `sendGift`, `giftsReceived`, `hideGift`, `giftSummary`, `sendFlirt`, `sendReachRequest`, `reachRequests`, `respondReachRequest`, `revealLikes`, `unlockProfile`, `boost`, `setProfileLock`, `setReachable` |
| M2 `MeetProgressRepository` | `progress`, `ladder`, `missions`, `claimStreak`, `claimMission`, `surpriseOdds`, `openSurprise`, `perks` |
| M2 `StoreBillingService` (not a repository) | `isAvailable`, `loadProducts`, `buyPack`, `buyVip`, `restore`, `purchaseUpdates` |
| M3 | `MeetCallRepository`, `MeetCallAdapter` |

`UploadBucket` gains `meetInbox` and `meetVerify` (`bucketIdFor()` and `MockMediaUploadRepository` cases).

### 6.6 Data (`packages/suskii_data`)

**Mocks**

- `lib/src/mock/mock_meet_repositories.dart` is `part of 'mock_repositories.dart'`, so it can extend the library-private `_MockRepo`. `fixtures_meet.dart` adds `MockDatabase` Meet maps and broadcast controllers.
- Personas: user-ada, user-chidi, user-kofi and user-emeka, plus Meet-only personas whose **abstract illustrated avatars** are 8 PNGs in `packages/suskii_data/assets/meet_mock/`, never photos of real people.
- Fixture situations: a match expiring in 2 h, a held photo, a blocked message, a restricted sender. M2 adds a locked Captain, a negative balance, a voided purchase and a pending request.
- Times come from `clock` only.
- **Mocks mirror the server rules**: the same error codes, limits and 24 h timers, and a Dart port of the contact filter tested against the shared vectors in `contracts/v1/fixtures/meet/contact_filter_cases.json`. While in the area, fix the known `MockMeetupRepository` divergences (`ERR_INVALID_ARGUMENT`, host join, `ERR_MEETUP_CLOSED`).

**Supabase**

- `lib/src/supabase/meet/supabase_meet_*_repository.dart` call `rpc('fn', {'p_…': …})` with literal maps through a `_rows(String function, …)` helper.
- `SupabaseGateway` gains `authenticatedObject(bucket, path)`, which supplies the URL and current auth headers for `SNetworkPhoto`, and `invokeFunction('meet-purchase-verify', …)`.
- Chat streams use `refreshes(topics: ['meet:$id'])` plus polling, and **stay open when the list is empty**.
- Until a milestone's backend lands, repositories are const "unavailable" stubs (the `SupabasePromoRepository` pattern). With the skeleton, contracts exist on day 1.

**Billing:** `lib/src/billing/play_billing_service.dart` plus `MockStoreBillingService`.

### 6.7 Providers and idempotency

**Providers** go in `apps/mobile/lib/app/meet_providers.dart`, imported by `providers.dart`.

- Each `meet*RepositoryProvider` watches `sessionUserIdProvider` and picks the gateway or the mock.
- Data comes through `FutureProvider.autoDispose.family` and `StreamProvider.family`.
- `meetAccessProvider` drives the router.
- `storeBillingProvider` is used by `StorePurchaseCoordinator`.

**Intents** (`IdempotencyKeys.forIntent`, cleared on sign-out):

| Area | Intents |
|---|---|
| M1 | `meet.checkin`, `meet.profile.save`, `meet.photo.submit:<position>`, `meet.swipe:<profileId>`, `meet.signal:<kind>:<profileId>:<localDate>`, `meet.send:<conversationId>:<draftId>` (a State field, reset on success), `meet.report:<subjectKind>:<subjectId>`, `meet.block:<profileId>`, `meet.status.post:<draftId>`, `meet.game.start:<conversationId>:<gameKey>:<nonce>` |
| M2 | `meet.gift:<receiver>:<giftKey>:<target>:<nonce>`, `meet.surprise:<localDate>`, `meet.streak:<localDate>`, `meet.mission:<key>:<localDate>` |
| Purchases | Keyed by the purchase token, not a client key |

### 6.8 Localisation, errors and copy

- About 300 `meet*` ARB keys in `app_en.arb` and `app_pcm.arb`, with placeholders declared.
- Notification title keys (`notification.meet.like.title` and so on) never contain a name or amount.
- `ErrorCodes` constants in `suskii_core/errors.dart` and cases in `error_l10n.dart`.
- Copy follows `docs/store/meet-copy-rules.md` (§8.12).

### 6.9 Push deep links (`routeForPushLink` case `'meet'`)

| Server link | Route |
|---|---|
| `/meet/chats/<id>` | conversation |
| `/meet/matches/<id>` | match |
| `/meet/likes` | Likes tab |
| `/meet/likes?tab=requests` | Requests (M2) |
| `/meet/statuses/<profileId>` | status viewer |
| `/meet/me` | Me (streak, level, card) |
| `/meet/me/photos` | review outcomes |
| `/meet/cowries` | purchase credited or reversed (M2) |
| `/meet/calls/<id>` | call (M3) |
| `/meet/events/<id>` | meet-up |
| `/meet/<uuid>` (legacy) | `/meet/events/<uuid>` |
| anything else | `/meet` |

`push_notifications_test.dart` covers every row and keeps the existing `/meet/<id>` assertion, now expecting the events path. The server writes only these shapes.

### 6.10 Tests and goldens

**Flows** (`apps/mobile/test/flows/app_flows.dart`)

- `_suskiiMeet` becomes `_meetEvents` (`home.suskiiMeet` → Nearby/Events → `meet.card.meet-1` → join). With `meet.v5` off it runs against the legacy page unchanged.
- M1: `_meetGateUnderAge`, `_meetOnboardingToDiscover`, `_meetLikeToMatchToChat`, `_meetContactBlocked`, `_meetReportAndBlock`, `_meetStatusPostAndView`, `_meetGameRound`, `_meetNearbyBands`, `_meetDeleteProfile`.
- M2: `_meetCowriesShopMock`, `_meetGiftOnStatus`, `_meetInsufficientThenTopUpReplay`, `_meetSurpriseOddsThenOpen`, `_meetVipPlans`, `_meetNegativeBalance`, `_meetLockedTeaserUnlock`.
- M3: `_meetVoiceCallPriceSheet`.

**Goldens** (`screen_catalog_test.dart` `customerRoutes`, dark and light at 1x and 2x text, no overflow at 200%)

- M1: `/meet/welcome`, `/meet/onboarding`, `/meet/discover`, `/meet/profile/meet-p-ada`, `/meet/matches/meet-m-1`, `/meet/likes`, `/meet/chats`, `/meet/chats/meet-c-1`, `/meet/statuses/new`, `/meet/statuses/meet-p-chidi`, `/meet/nearby`, `/meet/events/meet-1`, `/meet/events/new`, `/meet/me`, `/meet/me/photos`, `/meet/me/privacy`, `/meet/safety`, `/meet/filters`.
- M2: `/meet/cowries`, `/meet/vip`, `/meet/ladder`, `/meet/surprise`.
- M3: `/meet/calls/meet-call-1`.
- Mock images are precached in `harness.dart`, as `_precacheBrandLogo` does.
- **Goldens are recorded on Linux with `goldens-record.yaml` only.**

**Data tests:** `packages/suskii_data/test/mock_meet_*_test.dart` and `supabase_e2e_test.dart` cases.

**Store screenshots:** `integration_test/store_screenshots_test.dart` gains Discover, Match and Chats shots using **licensed or illustrative imagery** (§8.10).

---

## 7. Website parity and admin

### 7.1 Website scope (D1)

`apps/web-customer` keeps meet-ups and the Meet account controls. Discovery, photos, chat, statuses, games and the economy are app-only.

| Route | Content |
|---|---|
| `/[locale]/meet` | `MeetLandingClient`. With `meet.v5` off for the caller (`meetAccessRepository.getState`), today's `MeetClient` unchanged. Otherwise: "Meet's profiles, chat and statuses are in the Android app" (a link to the Play listing; web to app is allowed), the Events call to action, and, for users with a Meet profile, a link to account controls |
| `/[locale]/meet/events` | `EventsClient` (moved from `MeetClient`; testids kept) |
| `/[locale]/meet/events/[id]` | `MeetDetailClient` (moved) |
| `/[locale]/meet/events/new` | create form (moved) |
| `/[locale]/meet/[id]` | Server redirect to `events/[id]` for uuids; static segments win |
| `/[locale]/meet/account` | `MeetAccountClient`. Calls `meetAccessRepository.getState`, `meetProfileRepository.getMyProfile` (read-only summary), `meetProfileRepository.setDiscoverable`, `meetProfileRepository.setPaused`, `meetProfileRepository.setPrivacy`, `meetProfileRepository.deleteMeetProfile`, `meetSafetyRepository.blockedProfiles` and `meetSafetyRepository.unblock` |
| `/[locale]/settings` | Gains the Meet notification categories (`social`, `social_nudges`) through the existing settings repository, matching the app |
| M2 | No customer economy pages. A Cowries mention says only "Cowries are available in the Android app", with no link to buy and no web checkout |

**Implementation:**

- Repositories: `src/lib/supabase/meetAccessRepository.ts`, `meetProfileRepository.ts`, `meetSafetyRepository.ts`. Mocks in `src/mocks/repos/meetV5.ts`; types appended to `mocks/types.ts`.
- **Repository calls stay in `.tsx` files**, because the parity scanner reads only `.tsx`.
- Strings: `src/lib/i18n/meet.en.ts`/`meet.pcm.ts` (`satisfies MeetDictionary`). The dashboard card stays at index 2 in `cardHrefs` and both dictionaries.
- **Not indexed:** `apps/web-customer/src/app/robots.ts` disallows everything (if absent), and `X-Robots-Tag: noindex, nofollow` is set for the whole customer app. The CSP is unchanged (`blob:` is already in `img-src`).
- **Smoke tests** (`tests/web-smoke/smoke.spec.ts`): routes become `/en/meet`, `/en/meet/events`, `/en/meet/events/meet-1`, `/en/meet/account` and the legacy redirect `/en/meet/meet-1`. The meet-up testids move with the pages; the home "Suskii Meet" heading is kept.
- The Cloudflare 3 MiB gzip Worker limit is respected: no Lottie, no swipe or carousel libraries on web.

### 7.2 Parity checker changes (`contracts/tools/check_screen_parity.py`, Claude-owned, M0-PR2)

Add `PLATFORM_REPOSITORIES: dict[str, str]` (repository → reason). Any app call on such a repository is exempt. Add a unit test in `contracts/tools/tests`.

**Repository-level entries**: `meetDiscovery`, `meetMatch`, `meetChat`, `meetStatus`, `meetGame`, `cowrie`, `meetEconomy`, `meetProgress`, `meetCall`. Reason: "18+ discovery, chat, statuses, games, Cowries and calls are Android-only: Play Restrict Minor Access and FLAG_SECURE cannot apply on the web; spec §3/§13 'never web'; purchases need Play Billing (ADR-0026 D1, OD-39)".

**Method-level `PLATFORM` entries:**

| Repository | Methods |
|---|---|
| `meetAccess` | `checkIn`, `acceptGuidelines` |
| `meetProfile` | `saveProfile`, `setArea`, `setDiscoveryPrefs`, `submitPhoto`, `removePhoto`, `reorderPhotos`, `savePrompt`, `removePrompt`, `getProfile` |
| `meetSafety` | `report`, `block`, `verificationPose`, `submitVerification` |

Reason: "profile building and in-Meet safety actions happen where the content is, in the app".

`storeBilling` is a service, not a repository, so the checker does not see it.

### 7.3 Admin console (`apps/web-admin`)

Built on origin/main's Supabase seam (`lib/supabase/*Repository.ts`, `gw.rpc`). Data layer: `lib/supabase/meetTrustRepository.ts` (M1) and `meetEconomyRepository.ts` (M2), mocks in `mocks/repos/meet.ts`.

**NAV entries** (`ConsoleShell.tsx`):

| Milestone | Group | Page | Contents |
|---|---|---|---|
| M1 | Trust & safety | `/meet/moderation` | Tabs Photos (large preview, reason picker, keyboard approve and reject), Profiles & text, Statuses, Game answers. Ordered by priority, then SLA |
| M1 | Trust & safety | `/meet/reports` | DataTable plus a Drawer with the reported item, evidence snapshot, reporter's reason, subject history; actions dismiss, remove content, warn, restrict, suspend (incl. a permanent ban request), escalate. The read is audited |
| M1 | Trust & safety | `/meet/verifications` | Selfie beside profile photos through `kyc-document-url`, approve or reject |
| M1 | System | `/meet/readiness` | The m1, m2_testers and m2 checklists, testers list, flag state |
| M1 | — | Directory `EntityDrawer` | Meet section via `admin_meet_user_summary`, with Suspend, Lift and Correct birth date |
| M2 | Money | `/meet/economy` | Tabs: spend costs, gifts, packs, cards, XP, surprise odds. Price and rule changes go through `propose_config_change` (two signatures) |
| M2 | Money | `/meet/purchases` | Lookup, voids, negative balances, refund |
| M2 | Money | `/meet/adjustments` | Four-eyes |
| M2 | — | `EntityDrawer` | Cowrie section |
| M3 | Analytics | — | `meet_daily` series in `SupabaseAnalyticsRepository.getSeries`; `kpi_meet_safety`, `kpi_meet_economy` |

**AdminAction and PERMISSIONS** (`mocks/repos/base.ts`; mutations in `SENSITIVE`, 5-minute reauth):

| Action | Roles |
|---|---|
| `meet.moderate` | meet_moderator, super_admin |
| `meet.reports` | meet_moderator, super_admin |
| `meet.verify` | verification_officer, meet_moderator, super_admin |
| `meet.suspend` | meet_moderator, super_admin |
| `meet.ban.approve` | super_admin |
| `meet.readiness` | super_admin |
| `meet.economy.read` | finance_officer, super_admin |
| `meet.economy.propose` | finance_officer, super_admin |
| `meet.purchases.read` | finance_officer, super_admin |
| `meet.purchases.refund` | finance_officer, super_admin |
| `meet.cowries.adjust` | finance_officer, super_admin |

`AdminRole` gains `'meet_moderator'` with a `dict.roles` label. Admin smoke routes are added to `routes.admin`, and `tests/web-admin-e2e` flows run against the real stack in `backend-db.yaml`.

### 7.4 Coordination

- Before touching the admin barrels (`ConsoleShell.tsx`, `lib/i18n.ts`, `lib/repositories.ts`, `mocks/repos/base.ts`, `mocks/types.ts`, `smoke.spec.ts`), read `HANDOFF.md` for any in-flight Kimi web-admin work (W10) and build after it lands.
- Never build on the stale `.gemini` clone at `f48ff01`.
- Commit only from a worktree off `origin/main`.

---

## 8. Safety and Play policy

### 8.1 The 18+ gate (layered)

| Layer | Control |
|---|---|
| **L1: Play** | Restrict Minor Access ticked (App content → Target audience 18+, already 18+ only under OD-28, so no audience is lost). Google-identified minors cannot find, install or buy |
| **L2: in-app** | `meet_check_in` takes the birth date **once**. The age is computed server-side in the user's time zone. Corrections only through `admin_meet_correct_birth_date` (super_admin, MFA, evidence) |
| **L2: refusal** | Stores no birth date. Sets `refused_minor` on the account (outside the deletable profile) and bars every registered device fingerprint for 365 days. A retry with another date, or another account on the same phone, gets `{status:'unavailable'}`. Appeals go to support with ID |
| **L3: device integrity** | Check-in is refused when `integrity_verdict = 'fail'`, which stops emulator farms |
| **L4: signals after entry** | `underage`/`child_safety` reports give an immediate discovery hold and a 2 h SLA. The photo-review checklist includes "appears under 18" (reject, hold, child-safety review). `meet_text_rules` category `underage` holds bios mentioning jss, ss1–ss3, waec, neco, "secondary school", "my mum won't let me", or a written age under 18 |
| **L5: age signals** | `meet_eligibility.age_signal`/`method 'age_signal'` is ready for Play's Age Signals API (S-17, VERIFY-IN-RESEARCH) |

Meet-ups join the gate in M3 meet-ups v2. A self-declared date of birth alone may be judged "easily circumvented", which is why L1, L3 and L4 exist (OD-37).

**Edge tests** (pgTAP 73): an 18th birthday today, in the user's time zone, on either side of midnight; a 29 February birthday treated as 1 March in non-leap years; a future date; age 99 or more.

### 8.2 Contact filter: `private.meet_screen_text(p_text, p_country, p_surface, p_conversation_id DEFAULT NULL, p_sender DEFAULT NULL)` → `{action:'allow'|'hold'|'block', category, rule_keys[]}`

Deterministic SQL; the rules are data. It runs **before** `private.moderate_text`; blocked text never reaches it, and passed text then goes through it.

1. **Normalise:**
   - `normalize(text, NFKC)` then `lower()`;
   - strip zero-width characters (U+200B–U+200D, U+2060, U+FEFF);
   - map keycap, circled and full-width digits;
   - map Cyrillic and Greek look-alikes to Latin;
   - inside a digit run, `o`/`O`→0 and `l`/`I`/`|`→1.
2. **Digit stream:** tokenise, then map number words:
   - English and Pidgin: zero, oh, one…nine, tree; "double X" and "triple X" expand;
   - Yoruba: odo, ookan/okan, eeji, eeta, eerin, aarun, eefa, eeje, eejo, eesan;
   - Igbo: efu, otu, abuo, ato, ano, ise, isii, asaa, asato, itoolu;
   - Hausa: sifili, daya, biyu, uku, hudu, biyar, shida, bakwai, takwas, tara.

   All are `[A]` until native speakers review them (OD-50). Ambiguous words (to, too, for, ate, won, o) count only next to at least two unambiguous digit tokens. A run may include spaces, punctuation, emoji and at most one filler word.
3. **Phone or account number:** block on a longest run of at least 7 digits, or the Nigerian shapes `0[789][01]\d{8}`, `234[789][01]\d{8}`, or a 10-digit NUBAN near "account" or "acct". Times (7:30), ages, prices of up to 6 digits and house numbers do not reach 7.
4. **Split across messages:** the sender's trailing run (at most 12 digits, kept 10 minutes in `meet_conversation_members.digit_tail`; no content is stored) is joined to the next message's leading run. "0803", then "123", then "4567" is caught on the third message.
5. **Email:** `handle (@|(at)|[at]| at ) domain (.|(dot)|[dot]| dot ) tld`, or a mail-provider word (gmail, yahoo, ymail, outlook, hotmail, icloud, proton) next to a handle-shaped token.
6. **Links:** `http(s)://`, `www.`, `word(.| dot )(com|net|org|ng|me|io|co|app|ly|link|ee|gg|tv)`, `wa.me`, `t.me`, `bit.ly`, `linktr.ee`.
7. **Handles:** a platform word next to a handle-shaped token is blocked. Platform words: whatsapp, whats app, watsapp, wassap, wa, telegram, tg, instagram, insta, ig, snapchat, snap, sc, facebook, fb, messenger, tiktok, twitter, x.com, signal, imo, wechat, viber. So is a contact phrase: "my number", "call me on", "text me on", "dm me", "add me on", "hit me up on", "reach me on", "chat me on". A platform word on its own ("I don't use WhatsApp") is allowed, recorded as `platform_mention` with no strike, and the sender sees a tip.
8. **Solicitation, scams and sexual content** (`meet_text_rules`, `[A]`, OD-24/OD-50):
   - **Blocked in chat, reach notes and every profile surface:** sugar daddy, sugar mummy, sugar mommy, sugar baby, pay me, send me money, send money first, transport fare, tf first, allowance, gift card, itunes card, steam card, bank details, account number, send gift first, sex for money, escort, price list. Bank and fintech names (opay, palmpay, moniepoint, kuda) are blocked only together with digits or "send".
   - **Held in bios:** sponsor, runs, aristo, hookup, generous, spoil me, investment, forex, crypto, usdt, bitcoin.

**Outcome by surface:**

| Surface | Result |
|---|---|
| message, reach_note | Contact, solicitation or block rule: **not delivered**; returns `{status:'blocked', reason}`; one strike (a safety event, rule keys only) |
| first_name, bio, prompt, status, game_answer | **Raise** `ERR_MEET_CONTACT_NOT_ALLOWED`/`ERR_MEET_SOLICITATION_NOT_ALLOWED`; nothing written, no strike |
| a hold verdict | Delivered. Opens a case for profile text; in chat, opens a case only for the `sexual` and `underage` categories, to keep volume manageable |

**Strikes:** 3 within 24 h create a `meet_restrictions` row on `messages` and `new_conversations` for 24 h (a rate limit, not a ban). 5 within 7 days open a moderation case; only a person may suspend.

**What the sender sees:** the category only, never the matched span, which would teach evasion.

**Failure mode:** any error in the screen aborts the RPC, so nothing is delivered unchecked (D2).

**Tests:** `75_meet_contact_filter_test.sql` is table-driven from `contracts/v1/fixtures/meet/contact_filter_cases.json`, with **at least 200 vectors**, including negatives that must pass: "I'm 25, love 2 dogs", "see you at 7:30", "₦5,000 dinner?", "flat 12", "I'm 5'9", "call me at 9pm". The same vectors drive the Dart and TypeScript mock ports.

### 8.3 Moderation

- **Kinds:** `meet_profile`, `meet_prompt`, `meet_photo`, `meet_status`, `meet_message`, `meet_game_answer`, then `meet_reach_note` in M2.
- **Decisions:** `private.meet_case_decided()` runs AFTER UPDATE OF status ON `moderation_cases` WHEN `subject_kind LIKE 'meet\_%'`. On upheld:

  | Subject | Action |
  |---|---|
  | photo | `removed`, plus `storage.erase_object`; the profile becomes undiscoverable if no approved photo remains |
  | profile text | The field is cleared and returns to `held` |
  | status | `removed`, and its media erased |
  | message | `removed_at` set; the body is kept until the evidence purge |
  | game answer | Removed |

  From M2, an upheld case also refunds the gifts on that content and reverses its popularity. The author gets a `meet_account` notice by key only.
- **Queue priority:**
  1. child safety or underage, or a photo flagged underage;
  2. reports with evidence;
  3. first-photo pre-moderation, which blocks onboarding;
  4. other photos and statuses;
  5. text holds.

  Each carries `sla_due_at`, and the `meet_moderation_sla` health check warns on breach.
- **Visibility:** only `meet_moderator` and `super_admin` can see `meet_*` cases and reports, in country scope through `moderation_subject_countries` by `author_id`. **Authors can no longer read their own `meet_*` cases**, which closes the report oracle. support_agent sees nothing.
- **Staffing (OD-41):** at least two `meet_moderator` accounts with MFA (an automatic readiness item) before `meet.v5` leaves testers. The tester and rollout gates act as the brake on volume.
- **Bans:** permanent bans for child safety, underage and ban evasion need two people (an `approvals` row, `meet_ban`) and bar the user's devices. **CSAM procedure (RB-17):** preserve the evidence, ban, report through the counsel-confirmed route (OD-42), and never re-share or download outside the console.

### 8.4 Reporting and blocking UI (UGC policy)

- **Reachable in at most two taps** wherever another person appears: the discovery card overflow, the full profile, the match screen, the chat header, a long-press on a message, the status viewer, a game answer, Likes items, requests and gifts received (M2), and the event detail (host).
- **The sheet:** reasons start with **Under 18, Child safety, Asking for money or gifts, Scam**, then Sexual content, Harassment, Fake profile, Sharing contacts, Hate, Threats, Spam, Unsafe meeting, Other. Optional details up to 2,000 characters. "Also block" is on by default. The confirmation reads "They won't be told. Our team reviews within 24 hours (2 hours for child safety)."
- **Blocking** is immediate, symmetric (`is_blocked_pair`) and never shown to the blocked person. It closes matches and conversations and hides both people from each other everywhere, including errands (OD-52).
- **Safety centre:** tips (meet in public, tell a friend, trip share, "never send money or gift cards to someone you met here"), SOS through the existing `raise_sos` without a job, the child-safety concern route, guidelines and terms.
- **Terms acceptance** (`meet_terms` consent plus guidelines) comes before any content is created.

### 8.5 Photo privacy

- **Upload:** the system picker or camera intent only, with no `CAMERA` or `READ_MEDIA` permission. Client resize to 1080 px plus a 320 px thumb.
- **Server:** byte-level metadata stripping (`meet-media-worker`), magic-byte and dimension checks, and storage under the **opaque profile id**.
- **Before anyone sees it:** human review.
- **Reads:** per request through the authenticated endpoint under `meet_media_visible_to`. No shareable URLs. Staff signed URLs last at most 300 s.
- **Display:** `FLAG_SECURE` on profile, chat, status viewer, verification and Cowries screens; no download or share buttons.
- **Data saver** loads thumbs and the primary photo only until a tap.
- **Duplicates:** an exact-duplicate SHA-256 across users raises a flag. Perceptual hashing is unavailable.
- **Deletion:** removing a photo or status uses `storage.erase_object`; the Meet profile and account erasure use `storage.erase_prefix`. Verification selfies are deleted 30 days after the decision.

### 8.6 Location bands

- **Stored:** only `ST_GeoHash(point, 5)` (about 4.9 × 4.9 km), its centroid and the nearest city code. Raw coordinates are never stored, and there is no history. Updates are limited to one every 6 h, and the `location` consent is required.
- **Distance:** centroid to centroid, returned only as a band (`under_5`, `5_10`, `10_25`, `25_50`, `over_50`) plus the area label. Moving your own position can reveal at most someone's cell.
- **Nearby:** grouped by band and ordered by activity. No map of people, no "online now", activity as "Active today" or "Active this week". `hide_distance` (Platinum) shows "Nearby" only.
- **Meet-ups** keep public venue points (the ADR-0020 principle).
- **InMessage's map of people is deliberately not built.**

### 8.7 Data minimisation (Nigerian law on orientation)

- "Show me" is optional and defaults to 'everyone'. It is consented, stored in `meet_discovery_prefs`, read only by the owner's own functions, applied one way, and never displayed, in `admin_meet_user_summary`, in analytics, in staff reads or in a partner's export. It is erased with the Meet profile.
- Gender is optional and hidden by default. No orientation labels, intents or "nonbinary" options are stored (OD-38).
- **No aggregate by gender × seeking, ever.**
- If counsel says no, `seeking` is dropped and discovery runs on intent and age only. The client change is hiding one control.

### 8.8 Sugar-dating safeguards (Inappropriate Content policy)

- **Product:**
  - gifts are reactions to content, never payment for attention, company or meetings, and never inside a 1:1 chat;
  - nothing pays out to anyone: no earnings, cash-out, gift totals, leaderboards, wishlists or gift requests;
  - no "generous", "sponsor" or "top gifter" badges;
  - no income or net-worth fields;
  - receivers never see prices; canned notes only;
  - gifting never unlocks a reply or a meeting;
  - every gender earns status the same way.
- **Enforcement:**
  - the solicitation and scam terms are **blocked** in chat and notes;
  - the report reason "Asking for money or gifts" carries a 24 h SLA. An upheld case means a suspension of at least 30 days, and a repeat goes to a permanent-ban request;
  - the first-chat safety tip.
- **Statuses:** pre-moderated photos, and popularity reversed on removal, so gifts cannot reward sexual content.

### 8.9 Gambling line

- Games never take stakes: the 10-Cowrie fee starts a round and there is no prize.
- The daily surprise is free only, perks only, non-giftable, with odds disclosed and no casino visuals.
- No paid random item exists anywhere.

### 8.10 Play Console declaration changes (owner actions; drafts land in the same PR as the feature)

Docs updated with each change: `docs/store/play-data-safety.md`, `docs/store/app-privacy.md`, `apps/web-marketing/src/content/privacy-policy.ts` and RB-15 §3.4.

**M1, before `meet.v5` leaves testers (m1 readiness):**

1. **Target audience and content:** confirm 18+ only and **tick Restrict Minor Access**.
2. **Child Safety Standards:**
   - publish the CSAE standards page (§8.11) at `https://suskiierrand.com/en/legal/child-safety`;
   - name the child-safety point of contact `childsafety@suskiierrand.com` (Cloudflare Email Routing);
   - declare the in-app reporting mechanism and compliance.
3. **Data safety**, newly collected, not shared, processed by service providers only:
   - Personal info → Other info: date of birth; gender (optional). Purposes: app functionality, account management, fraud prevention.
   - Personal info → **Sexual orientation**: the optional "show me" preference, app functionality only, while it exists (OD-38).
   - Photos: profile and status photos, and the verification selfie. Purposes: app functionality, fraud prevention, safety.
   - Messages → Other in-app messages: Meet chat.
   - App activity → App interactions (likes, winks, matches, game answers); Other user-generated content (bio, prompts, statuses).
   - Location → **Approximate location**: the Meet area. Revise the "distance sort (not stored)" wording; precise location stays for errands.
   - Deletion: the in-app path plus `https://suskiierrand.com/en/delete-account`, now naming Meet data.
4. **Content rating (IARC retake):**
   - users interact or exchange content with strangers: **yes**;
   - user-generated content and social features: **yes**;
   - **shares the user's location with other users: yes** (distance bands still disclose approximate location);
   - digital purchases: no in M1;
   - random items: no;
   - keep 18+;
   - no gambling depiction.
5. **UGC:** terms acceptance before content, in-app report and block, pre-moderation plus a queue with SLAs.
6. **Store listing:**
   - add "Meet new people nearby — adults 18+, verified photos, private chat and group meet-ups";
   - never "earn", "money", "gifts for dates", "sugar", "sponsor" or "discreet affairs";
   - screenshots use licensed or illustrative imagery, never fixture faces presented as members, and nothing from InMessage.
7. **Prominent disclosure** shown before the Meet area permission request.

**M2, before `meet.purchases`/`meet.vip` (m2 readiness):**

1. **Data safety:** Financial info → **Purchase history** (Cowrie and VIP orders, gifts). Not "User payment info": Play collects card data.
2. **Content rating:** digital purchases **yes**; random items still **no**.
3. **Financial features declaration:** keep **"My app doesn't provide any financial features"**. Cowries are Play-billed, used only in the app, and cannot be withdrawn, transferred or exchanged; gifts are spends; nothing holds money. VERIFY-IN-RESEARCH: no Google page explicitly exempts in-app currency, and the 2026-10-25 rejection followed a "wallet" declaration. Any cash-out would be a financial feature and needs OD-29 plus counsel. It stays out of the build.
4. **Subscriptions:** the VIP disclosures (price, period, renewal, cancellation through Play).
5. **Products:** 4 consumables and `meet_vip` with 2 base plans in NGN.
6. **Monetisation setup:** RTDN topic plus "Send test message"; license testers.
7. **Listing:** mention optional in-app purchases.
8. **Legal pages:** publish `/legal/meet-terms` and `/legal/meet-daily-reward-rules`.

**M3:**

- Voice: `RECORD_AUDIO` is already declared, so no new permission.
- **Video (OD-47) is its own PR:**
  - add `CAMERA` to the manifest and change `mobile-native.yaml`'s denylist with a justification comment;
  - Data safety (camera/video not stored);
  - RB-15;
  - a DPIA note (metadata only).

### 8.11 The CSAE standards page

`apps/web-marketing/src/app/[locale]/legal/child-safety/page.tsx` (Kimi path, licensed per PR). It:

- names **"Suskii Errands"** exactly as on Play;
- states zero tolerance for child sexual abuse and exploitation;
- explains how to report: in the app (Safety centre → "Report a child-safety concern", and the report sheet's "Under 18" and "Child safety" reasons) and by email to `childsafety@suskiierrand.com`;
- states what happens: immediate removal, preservation of evidence, a permanent ban, and reporting to the relevant Nigerian authorities through the route counsel confirms (OD-42);
- states that Meet is 18+ only, with Restrict Minor Access and an age check;
- names the child-safety point of contact and the response time;
- links the Meet guidelines and the privacy policy.

The `legal_documents` NG row of type `child_safety` is inserted when the page is live.

### 8.12 Copy rules

- `docs/store/meet-copy-rules.md` lists the forbidden terms: wallet, earn, earnings, cash, cash out, withdraw, get paid, sponsor, sugar, generous, allowance, pay to chat, gifts for dates, discreet affairs.
- `contracts/tools/check_preview.py` gains a grep over `meet*` ARB keys and values in `app_en.arb`/`app_pcm.arb`, `meet.en.ts`/`meet.pcm.ts` and the web-marketing Meet copy, failing CI on any hit.

### 8.13 Runbook RB-17 (Meet moderation and child safety)

RB-17 covers:

- queue SLAs and the dashboard SQL (`kpi_meet_safety`);
- the photo-review checklist;
- the child-safety escalation and the CSAM procedure;
- ban approvals;
- appeal handling (birth-date correction with ID);
- false-positive review of the filter, monthly, from `meet_safety_events` rule-key counts only;
- the tester and rollout steps;
- the 1.4.0 inbox note.

---

## 9. Milestones: ordered PR list

**Rules for every PR**

- Branch from `origin/main` in a throwaway worktree: `git worktree add -b <branch> <scratch>/wt origin/main`. Stage only the PR's paths, then push and remove the worktree. After merging, the shared tree is fast-forwarded with `git reset --mixed origin/main`. Never check out a branch in the shared tree.
- **Backend PRs** carry, in the same PR:
  - the migration and its pgTAP file;
  - regenerated `contracts/v1` (`generate_v1.py`), `codes.json` entries and a CHANGELOG line under `[Unreleased]` in a "Meet v5 M<n> (planned 2.<x>.0)" block;
  - the `00_structure_test` allowlist, AI deny-list entries and RLS-matrix rows;
  - a `HANDOFF.md` entry, edited in place and committed by Kimi.
- **Backend PRs must pass** `backend-db.yaml`: pgTAP, `db lint --fail-on warning`, advisors, `check_migration_order`, `check_rls_matrix`, `check_allowlist`, `check_production_reference`, and the e2e scripts. They must also pass `contracts.yaml`.
- **Frontend PRs** land app and web together, or use `PLATFORM` entries. They must pass `frontend-ci` (format, analyze, package and app tests, goldens recorded on Linux and committed, dart2js, web build, web-smoke), `contracts.yaml` (`check_frontend_calls`, `check_screen_parity`) and `mobile-native.yaml`.
- **Order:** backend before the data layer that calls it. The skeleton PRs make contracts available on day 1.
- **Flags** stay off until the milestone's release PR. The M1 and M2 release steps are owner actions.
- **Each restated shared function** reruns tests 23, 25, 46, 59 and the realtime assertions.
- **Skeleton stubs** reference every parameter through `private.meet_not_built(fn, jsonb_build_object(...))`. Lint locally first.

### M0: decisions and tooling (Claude)

**M0-PR1: docs.**

- ADR-0026 (Proposed): Meet v5 as an 18+ social layer, extending ADR-0020, with D1–D25.
- ADR-0027 and ADR-0028 drafts (Proposed).
- `docs/adr/README.md` rows.
- OD-37…OD-53 (§10.2).
- `docs/research/spikes/README.md` gains S-15, S-16 and S-17.
- Authored `contracts/v1/fixtures/meet/*.json`: daily set, locked teaser, blocked message, expiring match, held photo, negative balance, pending purchase, contact-filter vectors (200+).
- `contracts/v1/state-machines/meet_match.json` and `meet_play_purchase.json`.
- `docs/store/meet-copy-rules.md`.
- RB-17 draft.
- **Tests:** none beyond the existing docs checks. No RLS-matrix rows yet, because they land with the objects.
- **Owner:** approve ADR-0026. Answer OD-39, OD-40 and OD-41. Engage counsel on OD-37, OD-38, OD-42 and OD-50.

**M0-PR2: contract tooling.**

- `generate_v1.py` replays `ALTER TYPE public.X ADD VALUE [IF NOT EXISTS] 'v' [BEFORE|AFTER 'w']`, with a unit test.
- `enums.json` is regenerated (`notification_kind` gains `call_incoming`/`call_missed`) with a PATCH CHANGELOG note "regenerated; the values already existed".
- `check_screen_parity.py` gains `PLATFORM_REPOSITORIES`, with a test.
- `check_preview.py` gains the Meet copy-rules grep, with a test.

**M0-PR3: outbox hygiene.**

- `20261125120000_prune_outbox.sql`: `private.prune_outbox()` deletes `ledger` and `call` aggregate rows (nothing claims them) older than 30 days, plus dispatched rows of every aggregate older than 30 days. Cron `outbox-prune`.
- pgTAP inside `72_` is not needed; add it to `00_structure` or a small `72_meet_gating_test`. Reserve 72 for M1 and test `prune_outbox` in an assertion appended to the existing outbox test, keeping numbering clean.

### M1: social core, no money (contracts 2.7.0, app 1.5.0)

**M1-PR1: enum values (Claude).**

- `20261126120000_meet_v5_enum_values.sql`: `notification_kind` adds `meet_like`, `meet_match`, `meet_message`, `meet_reminder`, `meet_account`; `admin_role` adds `meet_moderator`; `consent_kind` adds `meet_terms`, `meet_sensitive_data`.
- **Tests:** `00_structure`. An assertion that `is_any_admin()` now admits `meet_moderator`, and that each of its 14 gates (reads of `feature_flags`, `remote_config`, `countries` and the rest) is acceptable for that role, or is restated to exclude it, with a documented list. RLS-matrix role column. Regenerated `enums.json`.

**M1-PR2: contract skeleton and gating (Claude).**

- `…120100_meet_v5_contract.sql`:
  - `private.meet_flag_on`, `meet_require_access`, `meet_not_built`;
  - `private.meet_testers` and `private.meet_readiness` with the guard trigger;
  - flags and config rows;
  - **every M1 client and admin RPC signature** as a stub, with grants;
  - `admin_meet_readiness`, `admin_meet_set_readiness`, `admin_meet_testers`, `admin_meet_set_tester` implemented for real;
  - M1 error codes catalogued (status `planned` until implemented).
- **Tests:** `72_meet_gating_test.sql`:
  - flags exist and are off;
  - stubs raise `ERR_FEATURE_UNAVAILABLE`;
  - `anon` cannot execute;
  - testers-only gating;
  - enabling `meet.v5` without testers-only is refused with `ERR_MEET_NOT_READY`;
  - disabling always works;
  - the guard catches a `review_config_change` apply, leaving it pending.
- **This unblocks M1-PR10.**

**M1-PR3: identity and media (Claude).**

- `…120200_meet_v5_identity.sql`:
  - eligibility, refusal devices, profiles, prefs, photos, prompts, reference keys;
  - the `meet-inbox`, `meet-media` and `meet-verify` buckets and policies, and `meet_media_visible_to`;
  - legal-document types;
  - `invoke_edge_worker` restated with `meet-media-worker`;
  - real bodies for the eligibility and profile RPCs;
  - `gateway_meet_media_*`;
  - the `check_production_reference.sql` assertion.
- Functions: `meet-media-worker` (index and handler), `_shared/media/strip_metadata.ts`, storage-worker `storage.erase_object` and the new buckets, `config.toml` (`verify_jwt=false`), and an OpenAPI worker entry.
- **Tests:**
  - `73_meet_eligibility_test`: a minor's birth date is never stored; the refusal persists (returned, not raised); device lockout; set-once; guidelines version; integrity fail; the 29 February and time-zone boundary cases; flag off.
  - `74_meet_profiles_media_test`: allow and deny for each RPC; no client table grants; the storage policy matrix (owner, set viewer, blocked, other country, minor, staff in and out of scope); no uid in any viewer-readable path; text screening; photo limits.
  - Deno: `strip_metadata_test` (fixtures with GPS EXIF, PNG text chunks and WebP XMP produce zero metadata bytes), `meet-media-worker/handler_test`, storage-worker `erase_object` allowlist tests (wrong bucket, wrong folder and traversal are refused).

**M1-PR4: safety (Claude).**

- `…120300_meet_v5_safety.sql`:
  - `meet_text_rules` seed, `meet_screen_text` with the digit tail;
  - `meet_safety_events` (partitioned, with cron);
  - restrictions, suspensions (with the `approvals` `meet_ban` branch in `approval_subject_country`), banned devices, `meet_reports`, evidence;
  - `blocks.source`;
  - the moderation subject-kind CHECK, `moderation_cases_read`, `moderation_queue` and `decide_moderation_case` restated;
  - `meet_case_decided`;
  - the report, block, unblock and blocked-list RPCs;
  - every admin queue and verb;
  - the risk rules.
- **Tests:**
  - `75_meet_contact_filter_test` (200+ vectors from the fixture JSON, including false-positive guards);
  - `76_meet_safety_admin_test`: support_agent cannot see `meet_*` cases or reports; authors cannot read their own `meet_*` cases; country scope; suspension bounds; a permanent ban needs two approvers; MFA; audit rows written before return; a child-safety report puts an immediate hold; the strike persists (S.2).
  - Regressions: `23_moderation_test`, `59_suskii_meet_test`.

**M1-PR5: discovery, nearby, matches, notifications (Claude).**

- `…120400_meet_v5_discovery.sql`: daily sets (set-based, under an advisory lock), nearby, swipes, signals, counters, matches with expiry and reminders, view counts, `meet_notify`, `notification_category`, `notification_channels` restated, the preference CHECK, `dispatch_push_targets_for_kind`.
- `notifications-worker` switched to `dispatch_push_targets_for_kind`; `FORBIDDEN_IN_PUSH` gains the Meet keys.
- **Tests:**
  - `77_meet_discovery_test`: blocks both ways; errand contacts hidden by default (job-pair fixture); one-way seeking; two-way age; no-oracle not-found; no profile means no set; the like limit; the pass cooldown; expiry and reminder; unmatch is permanent; nearby bands and caps; EXPLAIN uses the pool index.
  - `supabase/tests/e2e/meet_swipe_e2e.sh`: concurrent mutual likes produce exactly one match.
  - Deno: notifications-worker filters `meet_*` by app version; `payloadIsSafe` on Meet payloads.

**M1-PR6: chat (Claude).**

- `…120500_meet_v5_chat.sql`: conversations, members, partitioned messages with cron, reactions, the send pipeline, `may_join_topic` restated, broadcasts.
- `contracts/v1/realtime-events/client-events.json` gains `meet.typing`; `channels.json` is regenerated, with any stale lines from replaced functions noted.
- **Tests:** `78_meet_chat_test`:
  - a blocked message is not stored but the strike persists;
  - split digits across three messages;
  - a closed or expired conversation refuses;
  - `mark_read` only moves forward;
  - quiet hours respected;
  - topic authorisation allowed and denied;
  - all five old topic branches still pass;
  - partitions exist.

**M1-PR7: statuses and games (Claude).**

- `…120600_meet_v5_statuses_games.sql`: statuses with audience, expiry and media erase; views; curated en and pcm prompts (reviewed); rounds; the daily question.
- **Tests:** `79_meet_statuses_games_test`: the audience never exceeds matches or admirers; photo statuses require verification and review; answers are hidden until both have answered; expiry erases media.

**M1-PR8: lifecycle (Claude).**

- `…120700_meet_v5_lifecycle.sql`: `collect_personal_data` and `erase_account` restated with the Meet tables; `meet-daily` purges; evidence retention.
- **Tests:** `80_meet_lifecycle_test` plus a `46_account_lifecycle` regression:
  - export includes own Meet data, never the partner's text or anyone's seeking;
  - erasure closes and purges conversations for both;
  - evidence under an open report is kept and pseudonymised;
  - an under-18 refusal survives profile deletion.

**M1-PR9: photo verification (Claude).**

- `…120800_meet_v5_verification.sql`: verifications, pose and submit, queue, decision, access; the 30-day purge emits `storage.erase_object` on `meet-verify`.
- `kyc-document-url` gains `subject: 'meet_verification'`, with an OpenAPI update.
- **Tests:** `81_meet_verification_test` (biometric consent, no self-review, `audit.kyc_access` before the path, TOTP, the purge) and Deno `kyc-document-url` tests.

**M1-PR10: client foundation (Kimi, or Claude if licensed).**

- `suskii_domain` entities and `meet_repositories.dart`.
- `suskii_data`: mocks (part file, fixtures, illustrated avatars), Supabase repositories, gateway `authenticatedObject`.
- `suskii_design`: Meet components and tokens, `tokens.json`/CSS.
- ARB keys (en and pcm), `errors.dart`, `error_l10n`.
- **Tests:** mock tests against the shared filter vectors; `design_tokens_test` AA pairs; component goldens.

**M1-PR11: app shell and screens (Kimi or Claude).**

- Router (shell, redirects 0b, flag-off path, access guard), `MeetShell`, every M1 screen, the moved Events tab, push links, `SecureScreen` wrappers.
- Web in the same PR: the `/meet` landing, the events move, the legacy redirect, `/meet/account`, the Meet notification settings, robots and noindex, `meet.en.ts`/`meet.pcm.ts`, smoke updates, and the `PLATFORM` entries in use.
- **Tests:** flows, catalogue goldens (Linux), `push_notifications_test`, dart2js, web build and smoke, parity green.

**M1-PR12: admin console (Kimi or Claude).**

- `/meet/moderation`, `/meet/reports`, `/meet/verifications`, `/meet/readiness`, the Directory Meet section, AdminActions, the `meet_moderator` role and dict.
- **Tests:** admin smoke; `web-admin-e2e` against the real stack.

**M1-PR13: legal and store (Claude docs plus Kimi web-marketing pages).**

- web-marketing pages `legal/child-safety` and `legal/meet-guidelines`; the privacy-policy Meet section (photos, chat, approximate location, date of birth, optional gender and seeking, retention, the partner-copy rule, evidence retention); the delete-account page.
- `docs/store/play-data-safety.md`, `app-privacy.md`; RB-15 §3.4 Meet answers.
- A migration inserting the NG `meet_guidelines` and `child_safety` `legal_documents` rows with the live URLs.

**M1-PR14: release (owner plus Claude).**

1. Ship app 1.5.0 to internal, then closed testing. Production may follow once stable, because the Meet code stays dark for non-testers.
2. Add testers (`admin_meet_set_tester`). Enable `meet.v5` (testers-only payload) and the M1 feature flags for NG.
3. Owner completes the m1 readiness items:
   - Play: Restrict Minor Access, Child Safety Standards, content rating, Data safety, listing;
   - the CSAE page and `childsafety@` live;
   - two or more `meet_moderator` accounts with 2FA;
   - **Supabase plan upgrade and working daily backups** (OD-53);
   - counsel answers OD-37, OD-38 and OD-42.
4. Then switch `meet.v5` to general at `rollout_pct` 5 → 25 → 100. Watch the moderation SLA, the report rate (`kpi` SQL in RB-17) and the filter's false positives.
5. Update CLAUDE.md status and add a HANDOFF entry.

### M2: economy (contracts 2.8.0, app 1.6.0)

**M2-PR1: docs (Claude).**

- ADR-0027 and ADR-0028 accepted.
- `docs/plan/meet-cowrie-flows.md` (postings, sign rules, invariants, reconcile).
- RB-18 (license-test checklist, RTDN, clawback, refunds, service-account rotation, monthly reconciliation).
- OD-44, OD-45, OD-46 and OD-51 brought to the owner and counsel.

**M2-PR2: enum values (Claude).** `20261210120000`: `meet_gift`, `meet_request`, `meet_progress`. Tests: `00_structure` and regenerated `enums.json`.

**M2-PR3: economy skeleton (Claude).**

- Every M2 RPC signature as a stub; flags and config; M2 error codes.
- The changed-body RPCs (`meet_swipe` and friends) keep their signatures (their `p_expected_cost` was published in M1).
- **Unblocks M2-PR10.**

**M2-PR4: wallet (Claude).**

- `…120200_meet_econ_wallet.sql`: the `meet_econ` schema, wallets, partitioned entries with sign rules and an append-only trigger, `meet_spend` and `meet_grant`, `meet_reconcile` plus the health check, packs.
- `partition_health` restated to include `meet_econ`.
- `backend-db.yaml` lint `--schema` and `supabase/README.md` gain `meet_econ`; `00_structure_test` schema arrays gain it.
- **Tests:**
  - `82_meet_wallet_test`: every illegal sign rejected; a negative balance blocks spends; raises are catchable; no client USAGE on `meet_econ`, not even `service_role`; no float columns; reconcile detects a tampered wallet; `partition_health` lists `meet_econ.entries`.
  - e2e `meet_spend_e2e.sh` (20 parallel spends against 100 → exactly 3).

**M2-PR5: Play Billing backend (Claude).**

- `…120300_meet_econ_play_billing.sql`: purchases, subscriptions, `billing_state`, adjustments; all `gateway_meet_*` billing functions; the `webhook_events` gateway CHECK widened; `config_change_levels` and `approval_subject_country` restated; the admin purchase, wallet, adjustment and refund RPCs.
- **Tests:** `83_meet_play_billing_test`:
  - a token binds once (another user gets a returned `rejected`, a recorded attempt and a flag);
  - an account mismatch is rejected, not granted;
  - pending does not grant;
  - a test purchase is accepted, flagged, and sets `test_funds`;
  - a replayed verify grants once;
  - full and partial quantity voids;
  - clawback to negative, then repayment by a new purchase;
  - fraud reasons set the hold and reverse gift popularity;
  - a linked token supersedes;
  - erasure pseudonymises;
  - the readiness guard tiers for `meet.purchases`.

**M2-PR6: billing Edge Functions (Claude).**

- `_shared/play/{client.ts, oidc.ts, types.ts}`, `meet-purchase-verify`, `play-rtdn`, `meet-billing-worker`.
- `invoke_edge_worker` restated (adds `meet-billing-worker`) in a small migration.
- `config.toml`, `edge-functions.openapi.yaml`, `set_play_billing_key.py`, `_deploy-supabase.yaml` secrets.
- **Deno tests:**
  - OIDC accepted, and rejected for the wrong `aud`, `iss` or email, an unverified email, or expiry (against a local JWKS);
  - duplicate `messageId`;
  - each notification type re-reads the API (mocked fetch);
  - consume failure goes to retry;
  - refund on reject;
  - voided-sweep cursor and pagination;
  - the 202 path when paused;
  - `payloadIsSafe` on purchase pushes.

**M2-PR7: infra (Claude).** Terraform Pub/Sub (topic, publisher binding for Play, push subscription with OIDC, token creator) and both APIs. `infra.yaml` validates. **Owner:** apply with `infra-deploy`.

**M2-PR8: spend surfaces (Claude).**

- `…120400_meet_econ_spend_surfaces.sql`: reactions, gifts (catalogue seed), reach requests (moderation kind `meet_reach_note`), reveals, unlocks, boosts and spotlight, priced signals, super interest, game rounds and flirts, popularity and the hourly score, moderation refunds, risk rules, the `meet_gift` and `meet_request` notifications.
- **Tests:** `84_meet_spend_surfaces_test`:
  - the receiver never sees a cost in any return;
  - no gift target can be a conversation;
  - same-device confers 0 and raises a flag;
  - caps hold;
  - premium gifts are blocked under 24 h;
  - removed content refunds senders and reverses popularity;
  - a blocked reach note costs nothing;
  - unreachable and locked targets are refused;
  - `p_expected_cost` mismatch → `ERR_MEET_PRICE_CHANGED` with no entry;
  - no row in `meet_econ.entries` ever credits a receiver.

**M2-PR9: progression and VIP (Claude).**

- `…120500_meet_econ_progression.sql`: XP, levels, cards, VIP entitlement, streaks, missions, the daily surprise, perks, the Captain review, `collect_personal_data` and `erase_account` restated with the economy tables.
- **Tests:** `85_meet_progression_test`:
  - one surprise a day even with VIP and Cowries;
  - the odds equal the draw's config;
  - perks cannot be transferred;
  - streak by local day;
  - missions never count likes;
  - free Cowries respect the 72 h, photo and cap rules;
  - lapsed VIP falls back;
  - only live purchased spend counts;
  - Captain upkeep;
  - test VIP accrues no days.

**M2-PR10: client economy foundation (Kimi or Claude).** `Cowries` type, entities, repositories, mocks (including `MockStoreBillingService`), Supabase repositories, `PLATFORM_REPOSITORIES` in use.

**M2-PR11: app billing (Kimi or Claude).**

- `in_app_purchase: 3.3.1` (exact), `PlayBillingService`, `StorePurchaseCoordinator`, `CowriesPage`, `VipPage`; graceful on dev flavours and iOS.
- A merged-manifest check confirms `com.google.android.play.billingclient.version` survives.
- **Tests:** mock billing flows; goldens for `/meet/cowries` and `/meet/vip`.
- **Do not merge before the RB-18 draft exists.**

**M2-PR12: app economy screens (Kimi or Claude).** Cowrie pill, gift sheet, reactions, flirts, ladder, surprise, missions, streak, boost, lock and reach settings, requests, likes reveal, locked teaser, insufficient → store → replay. Goldens and flows. Web: no customer pages (`PLATFORM`).

**M2-PR13: admin economy (Kimi or Claude).** `/meet/economy`, `/meet/purchases`, `/meet/adjustments`, the Cowries drawer section, the m2 readiness view. Smoke and e2e.

**M2-PR14: legal and store.** web-marketing `legal/meet-terms` (no cash value; no transfer or withdrawal; refunds through Google Play; forfeiture on deletion; negative balances after refunds) and `legal/meet-daily-reward-rules`; the privacy policy; `docs/store` purchase history; RB-15 billing steps; `legal_documents` rows.

**M2-PR15: release (owner plus Claude). Owner actions, in order:**

1. Resolve the payments-profile alert at payments.google.com (a blocker).
2. Link the merchant profile; add a USD-capable bank account; complete tax.
3. Create `play-billing@` and invite it with app-level permissions.
4. Run `set_play_billing_key.py`.
5. Apply Terraform.
6. Ship 1.6.0 (with the Billing Library) to internal.
7. Create the 4 consumables and `meet_vip` (2 base plans) in NGN, checking the price floor.
8. Set RTDN to "all notifications", then **Send test message** (readiness sets itself).
9. Add license testers.
10. Enable `meet.purchases`/`meet.vip` in testers-only mode, then run **S-15** (buy each pack, pending, cancel, refund, void and clawback, VIP weekly, upgrade to monthly, renewal, revoke) and record `license_tests_passed`.
11. Counsel's OK on the terms (OD-44); the OD-51 revenue decision; backups confirmed.

Then, in order: `meet.economy`, `meet.progression`, `meet.spin` (earned Cowries only); then `meet.gifts`, `meet.reach`, `meet.badge_lock`, `meet.boosts`; and **last** `meet.purchases` and `meet.vip` (general), at `rollout_pct` 5 → 25 → 100. Watch reconcile, voids and negative balances.

### M3: calls, analytics, polish (contracts 2.9.0, app 1.7.0)

**M3-PR1: spike S-16 (Claude).** LiveKit RoomService `RemoveParticipant`/`DeleteRoom` (Twirp paths, auth) and webhook signature verification against the docs and the owner's project. Writes `docs/research/spikes/S-16-results.md`, ADR-0029 and RB-19.

**M3-PR2: enum values (Claude).** `meet_call_incoming`, `meet_call_missed` (not urgent).

**M3-PR3: calls backend (Claude).**

- `…120100_meet_calls.sql`: calls, blocks, verbs, heartbeats, `meet_bill_calls`, `meet_expire_calls`, gateway functions; `invoke_edge_worker` restated (adds `meet-call-worker`).
- **Tests:** `86_meet_calls_test`:
  - no recording column (structural);
  - one live call per conversation;
  - block 1 charged at answer and refunded under 60 s;
  - block n charged exactly once;
  - an insufficient balance forces the end;
  - a stale heartbeat ends the call;
  - quiet hours apply;
  - video requires verification and a 72 h match.

**M3-PR4: call Edge Functions (Claude).** `meet-call-token`, `meet-call-worker`, and optionally `livekit-webhook`; OpenAPI; Deno tests.

**M3-PR5: client voice calls (Kimi or Claude).** `MeetCallAdapter` (a variant of `LiveKitCallAdapter` that reads `meet.calls.ring_timeout_seconds`, fixing the 60 s vs 45 s mismatch), the price sheet, the call page, goldens. Web: `PLATFORM` (`meetCall`).

**M3-PR6: analytics (Claude, plus an admin page).** `…120200_meet_analytics.sql`: `analytics.meet_daily`, `kpi_meet_safety`, `kpi_meet_economy`. **Tests:** `87_meet_analytics_test` (no person column; no gender, seeking or age dimension, asserted against `information_schema`; small cells NULL; test purchases excluded).

**M3-PR7: meet-ups v2 (Claude backend, then frontend). Only after the owner raises `min_supported_app_version.android` past 1.4.0 (RB-13).**

- `…120300_meetups_v2.sql`: the gate, `requires_approval`/`min_card`, join requests, `create_meetup_v2`, `meetup_requests`, `respond_meetup_request`, per-card host limits, the moderation-upheld notice.
- The app's host approve/decline sheet; web parity for events.
- **Tests:** `88_meetups_v2_test`; `59_suskii_meet_test` passes unchanged with the flag off.

**M3-PR8: polish (Kimi or Claude).**

- Meet app lock (`local_auth`; verify the manifest).
- Data-saver tuning.
- The Age Signals seam if S-17 confirms availability.
- 200% text and screen-reader passes; Pidgin QA.
- Store screenshots from licensed or illustrative imagery.
- The `docs/plan` iOS StoreKit plan (App Store guideline 3.1.1) before any iOS build shows Cowrie purchases.
- An admin editor for `meet_text_rules` (two signatures).
- A discovery bench at 100k profiles.

**M3-PR9: video (separate; only after OD-47 is answered).** `CAMERA` in the manifest, the `mobile-native.yaml` denylist change with its reason, Data safety, RB-15, a DPIA note, and `meet.calls.video`.

**Owner actions for M3:** LiveKit production credentials (staging is paused); the OD-47 decision; a review of the M2 economy numbers with real data.

---

## 10. Risks and open questions

### 10.1 Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | **Blast radius.** Meet ships inside the errands package on the personal account "Hubert.dev", which hosts three other apps. A dating, UGC, child-safety or sugar-dating strike could remove errands, or the whole account | Medium / severe | Everything dark; testers first; the database-enforced readiness gates (D23); D1–D25; rollout percentage as the brake. **OD-43: split Meet into its own package (`com.suskiierrands.meet`) before M2 purchases go general.** The module is self-contained, and `play_purchases.package_name` already allows it |
| 2 | **Sugar-dating clause.** Gifts in a dating context sit beside Play's own example | Medium / severe | Decision 2 (status, not cash); D8; solicitation terms blocked; the report reason; canned notes; no chat gifts; the copy grep; no earnings code anywhere |
| 3 | **Payments-profile alert (since 30 Oct).** Blocks all of M2; at worst Google removes the developer presence (answer/14177239). The same identity's GCP billing refusal (OR_BACR2_59) suggests a risk review `[A]` | High / severe | The owner fixes it first. Nothing sells until the m2 readiness is complete. M2's earned-Cowrie economy can ship without it |
| 4 | **Revenue on the personal payments profile** for an app the client owns. After a transfer, orders made before it stay on the old account, and financial reports do not transfer | High / medium | OD-51 before general purchases; monthly report downloads (RB-18); settle OD-29 early |
| 5 | **Minors.** A self-declared date of birth can be circumvented | Medium / severe | Restrict Minor Access, set-once, account and device lockout, integrity, holds, photo-review checks, text rules; the Age Signals seam (S-17). No CSAM hash-matching vendor exists, so human pre-moderation is the control (OD-42) |
| 6 | **Orientation data in Nigeria** [S]. Entrapment and extortion; legal-process requests | Medium / severe | D5 one-way and never displayed; consent; no aggregates; counsel (OD-38) may drop `seeking` with one hidden control |
| 7 | **Free-plan capacity and no backups** (OD-33). Photos exhaust 1 GB of storage at about 600 profiles; balances and purchase tokens are money-equivalent records | High / severe | **Hard readiness items**, both before `meet.v5` leaves testers and before purchases (OD-53). Partitions, retention, `prune_outbox`, thumbs and data saver |
| 8 | **Moderation capacity.** Pre-moderation stalls onboarding | High / medium | Testers and rollout percentage as the brake; at least 2 moderators; the SLA health check; RB-17; the quick-win copy sets expectations |
| 9 | **Contact-filter arms race and false positives** | High / low–medium | Strikes, then restriction, then a human; 200+ vectors; monthly rule review from rule-key counts; native-speaker review (OD-50) |
| 10 | **Purchase fraud.** Stolen cards, friendly fraud, chargebacks after the 30-day window `[A]`, token replay | Medium / medium | Token binding, an obfuscated id, RTDN plus the sweep, negative balances, holds, popularity reversal, flags; loss is bounded to digital goods |
| 11 | **Billing integration unknowns.** `completePurchase` after a server consume; the subscription cancel endpoint; refund with revoke; the exact productsv2 paths | Medium / medium | S-15 with license testers before general purchases; the 24 h unacknowledged health check |
| 12 | **Compatibility with 1.4.0.** Restated shared functions; inbox title keys rendered raw | Low / medium | Whole restatements from the latest versions; tests 23, 25, 46 and 59 plus realtime rerun; pushes filtered by version; cosmetic inbox issue accepted and documented |
| 13 | **Ownership and concurrency.** Most frontend work is in Kimi's paths; parity forces app and web together; hotspot barrels conflict | High / medium | Per-PR owner confirmation; worktree-only commits; new files; HANDOFF entries; build after any in-flight W10 work |
| 14 | **Contract drift.** `realtime_topics()` keeps topics from replaced functions; helper errors are missing from per-RPC lists | Medium / low | M0-PR2 enum fix; author the realtime additions explicitly and review `channels.json` by hand; list helper errors in `codes.json` notes |
| 15 | **Realtime authorisation unverified** (S-02) | Medium / medium | Broadcasts carry ids only; every read re-checks membership |
| 16 | **Server-side call disconnect unverified** | Medium / medium | Voice stays off until S-16 passes; heartbeats and the stale sweep; the token TTL cannot cut a call |
| 17 | **Video and `CAMERA`.** Sextortion; manifest gate; Data safety | — | Separate PR behind OD-47 (D11) |
| 18 | **Goldens with photo-heavy screens.** Non-determinism; Windows rendering differs | Medium / low | `MemoryImage` factory, precaching, Linux-only recording |
| 19 | **The owner may insist on web Meet** (D1 against the 2026-10-24 rule) | Medium / medium | OD-39 records why: no Restrict Minor Access, no `FLAG_SECURE`, no Play Billing on web. A web Meet would be weaker on every axis |
| 20 | **Deceptive behaviour.** Seeded or fake profiles; fabricated "someone likes you" pushes | Low / severe | `check_production_reference` asserts no `meet_profiles` exist on a migrations-only database; notifications fire only on real events |
| 21 | **Expanding beyond Nigeria.** Several target markets also criminalise same-sex relations [S] | — | Meet flags are per country; each new country needs legal review and country rows in `meet_text_rules` first |
| 22 | **iOS.** App Store guideline 3.1.1 would require StoreKit for Cowries | Low now | iOS shows no purchase UI; a StoreKit plan comes before any iOS Cowrie sale (M3-PR8) |
| 23 | **Web Worker size** (3 MiB gzip on Workers Free) | Low | No 18+ surfaces on web; library-free; size measured in `web-deploy.yaml` |

### 10.2 Open decisions (to add to `docs/OPEN-DECISIONS.md`; defaults are what the build ships)

| OD | Question | Default taken | Owner | Needed by |
|---|---|---|---|---|
| OD-37 | Age assurance for Meet | Self-declared set-once date of birth + Restrict Minor Access + device lockout + integrity + holds; Age Signals when available | Counsel | m1 readiness |
| OD-38 | Store an optional "show me" (orientation-revealing) preference in Nigeria? | Yes: optional, one-way, never displayed or visible to staff, consented. Dropped if counsel says no | Counsel | m1 readiness |
| OD-39 | 18+ surfaces app-only, as an exception to the 2026-10-24 web-parity rule | **Decided 2026-11-26 (owner): app-only (D1)** | Owner | M1-PR11 |
| OD-40 | Meet chat filter fails closed (an exception to OD-21) | **Decided 2026-11-26 (owner): block before delivery** | Owner | M1-PR4 |
| OD-41 | Photo pre-moderation and the `meet_moderator` role and staffing (at least 2, SLAs) | **Decided 2026-11-26 (owner): every photo human-approved; the owner reviews at first and adds moderators as Meet grows; Meet stays testers-only until reviews keep up** | Owner | m1 readiness |
| OD-42 | Child-safety escalation route (authority), the CSAE contact and evidence-retention law | `childsafety@` plus the counsel-confirmed route | Counsel | m1 readiness |
| OD-43 | Ship Meet as a separate Play package before general purchases? | Recommended: yes, before M2 general | Owner | Before `meet.purchases` general |
| OD-44 | Cowrie terms: no cash value, forfeiture on deletion, negative balances, refunds through Play, purchase-record retention | As stated in §5 | Counsel | m2 readiness |
| OD-45 | Economy numbers: costs, packs, VIP, card thresholds, XP curve, caps | §5.5–§5.15 `[A]` | Owner | M2-PR8 |
| OD-46 | Free-Cowrie volume and the welcome grant | 20/day cap; 20 welcome after 72 h and photo approval | Owner | M2-PR9 |
| OD-47 | Video calls (the `CAMERA` permission) | Not built until answered | Owner + counsel | M3-PR9 |
| OD-48 | Text statuses for Members in M1 (before VIP exists)? | Yes, text only; photo statuses need verification; becomes Silver when VIP is on | Owner | M1-PR7 |
| OD-49 | Automatic discovery hold on underage and child-safety reports, against OD-25 | Yes: a visibility hold, not a sanction | Owner | M1-PR4 |
| OD-50 | Meet restricted-terms list and the Pidgin, Yoruba, Igbo and Hausa number words | Seeded `[A]` | Counsel + native speakers | m1 readiness |
| OD-51 | Revenue on the personal payments profile before OD-29. Decision 4 supersedes OD-29 for in-app digital goods only; financial features stay "none" | Accept with monthly report downloads, or wait for the organisation account | Owner | m2 readiness |
| OD-52 | A block made in Meet also applies to errands | Yes (`is_blocked_pair` everywhere; `blocks.source` records the origin) | Owner | M1-PR4 |
| OD-53 | Supabase plan upgrade and working backups before Meet leaves testers (revisits OD-33) | Required (readiness items) | Owner | m1 readiness |

### 10.3 VERIFY-IN-RESEARCH list (settled by the named spike before the dependent flag goes on)

| Spike | What it settles | Gates |
|---|---|---|
| S-15 | Exact androidpublisher v3 paths and responses for productsv2, subscriptionsv2, consume, acknowledge, voided list, `orders.refund?revoke`, `subscriptionsv2.revoke` and subscription cancel; whether `completePurchase` after a server consume is a no-op; whether the plugin redelivers after a server consume | `meet.purchases`/`meet.vip` general |
| S-16 | LiveKit RoomService `RemoveParticipant`/`DeleteRoom` Twirp paths and auth; webhook signing | `meet.calls.voice` |
| S-17 | Whether `image_picker` resizing carries EXIF GPS (the server strip is authoritative regardless); Play Age Signals availability and terms in Nigeria | L5 seam |
| — | Whether Google treats in-app virtual currency as a financial feature (no exemption page found); re-checked at M2 submission | m2 readiness |
