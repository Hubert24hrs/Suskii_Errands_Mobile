# ADR-0026 — Meet v5: an 18+ social layer inside the errands app

| | |
|---|---|
| Status | Accepted |
| Date | 2026-11-26 |
| Deciders | Owner (spec v5 and its decisions of 2026-11-25; answers to OD-39, OD-40 and OD-41 on 2026-11-26); Claude Code |
| Extends | [ADR-0020](0020-suskii-meet.md). Its meet-ups stand unchanged and become the Events half of the Nearby tab |
| Design | [`docs/plan/meet-v5-design.md`](../plan/meet-v5-design.md), which is the build plan; this ADR records the decisions in it |
| Related | ADR-0027 (Cowries), ADR-0028 (Play Billing), OD-37 … OD-53, RB-17 |

## Context

The owner's spec v5 asks for "Suskii Meet": a place to meet people you have not met yet, discreet
like WhatsApp but open to strangers. Profiles are discoverable, behaviour stays private. It brings
a daily discovery set, matches, private chat, 24-hour statuses, icebreaker games and, in a second
step, a Cowrie economy with gifts, a VIP subscription and a card ladder.

Five things make this different from anything the platform has built:

- **It is a dating and UGC surface in a live errands app.** `com.suskiierrands.app` is on Google
  Play in Nigeria on a personal developer account that also hosts other apps. A strike for dating,
  child safety, sugar dating or UGC could remove errands with it (design §10.1 risk 1).
- **Strangers, photos and private chat** are exactly the conditions under which minors, sextortion,
  romance scams and off-platform migration appear. No image-moderation or CSAM hash-matching vendor
  is contracted, and no identity vendor either (ADR-0005 is still Proposed).
- **Nigerian law on sexual orientation.** The Same Sex Marriage (Prohibition) Act 2013 and reports
  of entrapment and extortion through dating apps make orientation data dangerous to hold `[S]`.
- **ADR-0020's meet-ups are live**, and the public app 1.4.0 calls their eight functions. Nothing
  about them may change shape.
- **The owner's web-parity rule of 2026-10-24** asks the website to have what the app has, while
  the spec says Meet is "inside the app only… never web".

The owner decided five things on 2026-11-25, recorded in the spec: the InMessage layout patterns in
Suskii branding (layout only, never their name, logo or assets); gifts give status, never cash, and
there is no cash-out; today's group meet-ups stay as a tab with their backend untouched; Google Play
Billing is built now behind a server flag that stays off; and Cowries never touch `public.payments`
or the errands ledger.

## Decision

We will build **Meet v5 as an opt-in, adults-only social layer** inside `com.suskiierrands.app`: a
third shell with five tabs (Discover, Chats, Nearby, Likes, Me) in the InMessage layout, beside the
errands shells and never in place of them. It ships in milestones, each dark behind server flags
that stay off until the database-enforced readiness checklist for that milestone is complete:

| Milestone | Scope | Contracts / app |
|---|---|---|
| M0 | This ADR, ADR-0027, ADR-0028, OD-37 … OD-53, spikes S-15 … S-17, authored fixtures, tooling fixes, outbox pruning | PATCH |
| M1 | The social core with **no money**: 18+ gate, profiles and photos, daily set, Nearby by distance band, matches, chat with the contact filter, statuses, games, reports and blocks, Events tab, photo verification, admin moderation | 2.7.0 / 1.5.0 |
| M2 | The economy: Cowries as Play consumables, VIP as a Play subscription, spend menu, card ladder, XP, streaks, missions, daily surprise, status-only gifts, badge-locked profiles, reach requests, boosts | 2.8.0 / 1.6.0 |
| M3 | Voice calls billed per block (video separately, OD-47), Meet analytics, meet-ups v2 after the forced update past 1.4.0, app lock, data saver | 2.9.0 / 1.7.0 |

The version numbers are the next free MINORs at merge time; 2.6.0 belongs to the unreleased
direct-payment entry.

**Where the spec, the parity rule or a candidate design conflicted with safety, safety won.** Every
such choice is listed here, with the open decision that lets the owner or counsel reverse it.

| ID | Decision | Status |
|---|---|---|
| D1 | Discovery, photos, chat, statuses, games and the Cowrie economy are **Android-app-only**. The website keeps meet-ups, the Meet privacy controls and Meet notification settings, through written `PLATFORM` exemptions in the parity checker | **Decided by the owner, 2026-11-26 (OD-39)** |
| D2 | The Meet contact filter **fails closed**: it blocks before delivery, never delivers on hold, and any error in the screen aborts the send. An explicit exception to OD-21, for Meet only | **Decided by the owner, 2026-11-26 (OD-40)** |
| D3 | **Every photo is approved by a person** before anyone else sees it, profile photos and photo statuses alike | **Decided by the owner, 2026-11-26 (OD-41)**: the owner reviews at first, adds `meet_moderator` accounts as Meet grows, and Meet stays testers-only until reviews keep up |
| D4 | No media in Meet chat in M1–M3: no images, voice notes or links | Built as stated |
| D5 | "Show me" is optional, stored apart from the profile, applied one way only, never displayed, never readable by staff, never in analytics, and consented (`meet_sensitive_data`). Gender is optional and hidden by default; no orientation labels | Default shipped; counsel (OD-38) |
| D6 | Safety controls are free for everyone; Platinum's "privacy suite" is conveniences only | Built as stated |
| D7 | The daily surprise (the spec's "spin") is free, once a day, for everyone; prizes are non-giftable perks, never Cowries; no wheel, slot or roulette; odds published | Built as stated |
| D8 | Gifts go to a status, photo, prompt, profile or reach request, **never a 1:1 chat**; canned notes only; receivers never see a price; no leaderboards, wishlists or "top gifter" badges; same-device gifts confer nothing; removed content refunds its gifts and reverses its popularity | Built as stated (owner decision 2 of 2026-11-25) |
| D9 | VIP "unlimited" winks and reactions sit under an anti-spam ceiling | Built as stated |
| D10 | Missions reward quality, never volume of contact | Built as stated |
| D11 | Voice calls first; video is a separate flag, needs both people photo-verified and a match at least 72 h old, and adds `CAMERA` in its own PR | Video waits on OD-47 |
| D12 | The meetup backend is untouched until M3 meet-ups v2, which ships only after the forced update past 1.4.0 | Built as stated (owner decision 3) |
| D13 | Statuses are never a feed: audience `matches` or `matches_and_admirers`; no follow graph; photo statuses need verification and pre-moderation | Default shipped; owner (OD-48) |
| D14 | "Who viewed you" is a daily count, never identities | Built as stated |
| D15 | A separate Meet identity: an opaque `meet_profiles.id` is the only person id a client sees and the storage folder; "hide me from errand contacts" is on by default; no auth uid in any path a viewer can read | Built as stated |
| D16 | An `underage` or `child_safety` report puts the subject on an immediate, reversible **discovery hold**. Suspensions stay human decisions (OD-25) | Default shipped; owner (OD-49) |
| D17 | VIP grants perks only, never a recurring Cowrie bundle | Built as stated |
| D18 | Every spend carries `p_expected_cost`; a changed price refuses the spend before anything is written | Built as stated |
| D19 | Account deletion is never blocked by a Cowrie balance; forfeiture is disclosed; an active VIP is cancelled at Play | Default shipped; counsel (OD-44) |
| D20 | No presence signals: no "online now", only "Active today" or "Active this week" | Built as stated |
| D21 | Nearby people are distance-band sections ordered by activity, never by distance, with no map of people; the smallest band is the stored ~5 km cell; daily cap | Built as stated (owner decision 1, without the map) |
| D22 | Cowries sit in a sealed `meet_econ` schema that no client role, nor `service_role`, can reach | [ADR-0027](0027-cowries-sealed-spend-only-economy.md) (owner decision 5) |
| D23 | Readiness gates in the database: a trigger refuses to enable `meet.v5` beyond testers until the M1 checklist is complete (Play declarations, CSAE page, moderators, **Supabase plan and backups**, counsel answers), and `meet.purchases`/`meet.vip` until the M2 checklist is. Disabling is never refused | Default shipped; owner (OD-53) |
| D24 | A refusal that records something returns a status and never raises, so the record survives (the S.2 raise-after-record class) | Built as stated |
| D25 | Dating trust and safety is its own world: `meet_reports`, `meet_*` moderation kinds readable only by a new `meet_moderator` role and `super_admin` in country scope; support agents read none of it | **Decided by the owner, 2026-11-26 (OD-41)** |

Also decided by the owner on 2026-11-26: **Claude Code builds every Meet v5 PR**, frontend
included (app, website and admin console), logging each in `HANDOFF.md` and committing from a
throwaway worktree off `origin/main`. This changes who builds those paths for Meet only; the
ownership table in `CLAUDE.md` is otherwise unchanged.

**Guarantees that hold through every milestone:**

- The public app 1.4.0 never calls a Meet v5 function, and no existing RPC, table, enum value or
  error code changes name or shape. Shared functions that are restated keep their behaviour, and
  pgTAP tests 23, 25, 46 and 59 re-prove it in each PR that touches them.
- Every Meet table has RLS enabled and forced with no client grant; functions are the only door, as
  for meet-ups and `get_provider_card`.
- No seeded people in production: `check_production_reference` asserts `meet_profiles` is empty on
  a migrations-only database, and notifications fire only on real events.

## Consequences

**Good:**

- The riskiest surfaces (minors, sextortion, contact migration, sugar dating, orientation data) are
  closed by structure rather than by policy text: no chat media, no presence, no orientation
  display, a fail-closed filter, human photo review and database-enforced readiness.
- Errands stay untouched: meet-ups keep their backend, 1.4.0 keeps working, and Cowries cannot
  reach the errands money paths.
- Each milestone ships and switches on alone, so the owner can stop after M1 with a complete,
  moneyless product.

**Bad / costs:**

- Human pre-moderation of every photo stalls onboarding when reviews fall behind. The brake is the
  tester gate and the rollout percentage, and the owner is the only reviewer at first (OD-41).
- App-only Meet departs from the 2026-10-24 parity rule for 18+ surfaces. A web Meet would be weaker
  on every axis: no Restrict Minor Access, no `FLAG_SECURE`, no Play Billing.
- Blocking before delivery will refuse some innocent messages. The filter's false positives are
  reviewed monthly from rule-key counts only (RB-17).
- The personal Play account still carries the blast radius until Meet moves to its own package
  (OD-43).

**Follow-on work:** the M1–M3 PR list in design §9; RLS-matrix rows with each object; RB-17
(drafted with this ADR), RB-18 (M2) and RB-19 (M3); Play Console declaration changes at each
milestone (design §8.10); the CSAE standards page; `docs/store/meet-copy-rules.md` and its CI grep.

## Alternatives considered

| Option | Why not |
|---|---|
| Meet on the website too (owner's parity rule) | Restrict Minor Access, `FLAG_SECURE` and Play Billing cannot apply in a browser; spec §3 and §13 say "never web" (OD-39, decided) |
| A chat filter that masks and delivers | Delivered text is already off-platform once read; blocking before delivery is the only form that stops contact migration (OD-40, decided) |
| Fail-open photo moderation, as OD-21 does for errands text | With no image vendor, fail-open means unreviewed dating photos reach strangers (OD-41, decided) |
| A map of nearby people, as InMessage shows | Exact or trilaterable positions are a stalking vector; distance bands give the same "nearby" without them (D21) |
| Reports in the shared `public.reports` | Restating `reports_read_own` would risk the errands trust console and leave dating reports one policy edit from support staff (D25) |
| Restating the eight meetup RPCs in M1 | Regression risk to test 59 with no benefit before the forced update (D12) |
| Cowries in `ledger.post` with an XCW currency | See ADR-0027 |

## Revisit when

- Counsel answers OD-37, OD-38, OD-42 or OD-50, or the owner answers any open decision differently
  from its default.
- An image-moderation or CSAM hash-matching vendor is contracted (D3, D4).
- Meet moves to its own Play package (OD-43), or the app moves to an organisation account (OD-29).
- Meet is proposed for a country other than Nigeria: each needs legal review and its own
  `meet_text_rules` rows first.
