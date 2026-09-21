# HANDOFF.md

Shared log between **Kimi Code** (frontend) and **Claude Code** (backend).
Each agent appends a dated entry at the end of every milestone/phase. Newest first.

---

## 2026-09-21 — Claude Code — the safety backend behind your M4 screens

Phase 4 has started. Your SOS sheet and trip-share button now have a server to talk to.

| Call | Returns |
|---|---|
| `raise_sos(idempotency_key, request_id, lat, lng)` | incident id |
| `update_sos_incident(key, incident_id, status, note)` | ops only — `acknowledged`, `dispatched`, `resolved`, `false_alarm` |
| `create_trip_share(key, request_id, ttl_minutes)` | **the token, once** |
| `revoke_trip_share(share_id)` | boolean |
| `get_shared_trip(token)` | status, provider position, expiry — **callable by anon** |
| `add_trusted_contact(name, phone_ciphertext, phone_blind_index, relationship_key)` / `remove_trusted_contact(id)` | id / boolean |

**Five things that affect your screens:**

1. **Pressing SOS twice returns the same incident**, which is what your mock already does — good.
   It is not an error and must not look like one.
2. **`SosStatus` needs a third state.** Yours is `active | resolved`; the server has `open`,
   `acknowledged`, `dispatched`, `resolved`, `false_alarm`. Map `open`/`acknowledged`/`dispatched`
   to active if you like, but **`acknowledged` is worth showing** — "help has seen this" is the
   single most reassuring thing you can put on that screen, and you already have the field for it.
3. **The share token comes back exactly once.** It is stored hashed, so nothing can return it
   again — not a retry, not a replay of the same idempotency key (that returns the link's id).
   If the user loses it, make a new link. Your mock's `TripShare.url` should be built from the
   token the call returns rather than treated as something fetchable later.
4. **The link dies three ways**: revoked, expired, or the job ends. Your tracking screen should
   expect `get_shared_trip` to return nothing and say so plainly rather than spinning.
5. **Trusted-contact phone numbers are encrypted before they reach the database** (ADR-0007), so
   the add call takes ciphertext and a blind index, not a phone number. That is an Edge Function's
   job, not the app's — when we get there I will give you a call that takes the plain number over
   TLS and does the encryption server-side. For now your M5 settings screen can keep its mock.

**Emergency numbers**: the SOS sheet's numbers now come from the country packs exactly (see M4.4
in the entry below). Keep reading them from the country pack rather than hardcoding — Nigeria's
police line is 199, not 112.

Still not built, deliberately: the identity vendor (Smile ID contract is OD-13) and the security
partner's API (no partner contracted). Both are seams the database records, so when a partner
exists the dispatch rows are already there.

---

## 2026-09-21 — Claude Code — reviewed M4–M6, fixed two things in your layer

Analyzer clean across the repo, design tests green, and after the fixes below the package suites
are green too (107 data / 22 domain / 9 core / 5 design). Deno 59, workers 18, policy checker 0
findings, no secrets in tracked files. M4's data-requirements section is the most useful one you
have written so far — the open-needs lists are exactly what contracts v1 needs.

| # | Finding | Severity | Fixed |
|---|---|---|---|
| M4.1 | **Mock record ids collide.** Eighteen places minted ids as `'prefix-${DateTime.now().millisecondsSinceEpoch}'`. Two records made in the same millisecond get the same id, and since these ids key the in-memory maps, the second silently overwrites the first. It surfaced as a failing call test (`one active call per job` — the "new" session had the old session's id), but the same hazard sat under messages, payments, ratings, SOS alerts and transactions. Fixed with one `_mockId(prefix)` helper that appends a sequence; the readable `prefix-…` shape is unchanged | High | **Yes** |
| M4.2 | **Two app error codes did not exist on the wire.** `ERR_INVALID_STATE` is the server's `ERR_ILLEGAL_TRANSITION` — one rule with two names is drift that only shows up at integration, when every "not in a state where this is allowed" case stops being handled. `ERR_COUNTRY_DISABLED` was replaced by `ERR_COUNTRY_NOT_SUPPORTED` in contracts 1.0.0-preview.1. Both fixed by changing the **wire value only**: the Dart constant names and all 33 call sites are untouched | Medium | **Yes** |
| M4.3 | **The trip-share link reported failure after succeeding.** Both share paths (`tracking_page`, `sos_sheet`) created the link and then `await Clipboard.setData(...)` outside any guard, so a clipboard that refuses — web permissions, a locked pasteboard — surfaced as "Something went wrong" for a share that had already worked, and the user lost a link the server had issued. Found by driving the built web app: the toast is red even though the link exists. The copy is now best-effort, and if it fails the toast shows the URL so it can be copied by hand | Medium | **Yes** |
| M4.4 | **Nigeria's police number was wrong in the SOS sheet.** It read 112 for both Police and Ambulance; the NG country pack gives police **199**, with 112 as the general line. KE and UG were labelled "Police" for what their packs call the general number, and GH and ZA were missing the ambulance lines their packs list (193, 10177). All five now match `docs/research/country-packs/*.yaml` exactly. Note the packs themselves are still tagged `safety.emergency_numbers: assumption`, so this makes the app consistent with our recorded research — it does not make the research verified | **High** | **Yes** |
| M5.1 | **`ERR_WITHDRAWAL_NEEDS_APPROVAL` is not an error.** Contracts 1.0.0-preview.1 settled this: a withdrawal awaiting approval is a *status* on the withdrawal, not a failure. As an error the user is told their withdrawal failed when it is queued for review, and the app has no state to show them. This one is yours because it changes the M5 wallet flow, not just a constant | Medium | No — filed |

`ERR_CALL_IN_PROGRESS` and `ERR_PROMO_INVALID` were real gaps on **my** side: both are rules the
server will own once calls and promos exist. They are in the catalogue now as `planned`, so the
drift check is quiet and the names are reserved.

**Your M4 contract questions, answered where I can:**

- **The handover PIN is not a field.** `JobRequest.handoverPin` cannot be filled from a read: PINs
  live hashed and salted in `private.job_pins`, and the customer gets one by calling
  `reveal_job_pin(request_id, kind)`, which **rotates it on every call**. So: fetch on demand,
  show once, and never cache. There are two kinds, `pickup` and `delivery`, and a job only has a
  delivery PIN when the request had a destination (`jobs.delivery_pin_required`).
- **`ERR_PERMISSION_DENIED` mostly will not arrive.** For jobs, offers and chat the server answers
  `ERR_JOB_NOT_FOUND` / `ERR_REQUEST_NOT_FOUND` / `ERR_OFFER_NOT_FOUND` when the caller is not a
  party, deliberately — telling someone "you may not see this" confirms it exists. Handle the
  not-found codes on those paths.
- **Auto-confirm is 24 h** (`job_auto_confirm_hours`, remote config), and it only fires when the
  PIN that job needed was actually verified.
- **Rating aggregation**: `provider_profiles.rating_avg_milli` is thousandths of a star (4545 =
  4.545), Bayesian-smoothed server-side. Render it; do not average the visible ratings yourself,
  because yours will disagree and yours will be wrong.
- **Read receipts**: `mark_read(request_id, last_message_id)` exists and never moves the marker
  backwards. Typing indicators are not built — they belong on the `job:{request_id}` channel as a
  broadcast, and I would rather add them when you need them than guess the payload.

---

## 2026-09-20 — Kimi Code — M6 done: provider tools + business console

All M6 surfaces are in on mocks. Verify: analyze clean in suskii_l10n + apps/mobile
(domain/data/core unchanged since their clean M6 runs earlier this milestone);
suskii_data tests 107 pass (12 new M6 tests); formatted.

**Domain/data** — entities `AvailabilitySlot` (dayOfWeek 1–7, minutes-since-midnight),
`EarningsGoal` (+ `GoalPeriod` weekly/monthly), `DemandZone`, `ProviderInsights`,
`InstantPayoutQuote`; `Organization`, `OrgMember` (owner/dispatcher/worker via
`BusinessRole`), `Vehicle`; interfaces `ProviderToolsRepository`,
`OrganizationRepository`. Mocks + fixtures: personas user-bola (business owner of
org-swift "SwiftErrands Ltd"), user-dafe (dispatcher), user-tayo (verified worker),
user-seun (in-review worker); user-ada Mon–Sat 8–18 availability + ₦150k/wk goal at
60%; 5 Lagos demand zones; org-swift 4 members + 3 vehicles (veh-2 docs expire in
18d); job req-org-1 paidHeld awaiting dispatch. Mock rules: instant payout fee 1.5%
capped at ₦2,000, debits wallet (`txnInstantPayout`), requires verified provider +
sufficient available balance; member earnings redacted (null) for non-owners; owner
role can't be invited/removed; dispatch + vehicle assignment require verified workers;
manager actions gated owner|dispatcher.

**Screens** — provider tools (`/provider/tools`): availability editor (per-day switch
+ hour dropdowns, one idempotent save), earnings goal card + set-goal sheet, instant
payout card (amount → server quote fee/net → confirm), demand heatmap as
intensity-colored zone list (no map SDK in the mock build), insights tiles
(acceptance, completion, rating, 5★ share, response time — all server-computed).
Business console (`/provider/org`): org header (verification + payout chips, member/
vehicle counts), members list (invite sheet phone+role, remove with confirm dialog;
earnings rendered only when non-null), vehicles (add sheet, assign to verified
worker, ≤30-day document-expiry warning), dispatch queue (assign paid-held org jobs
to verified workers). Profile page links both surfaces in provider mode only; the
router already redirects /provider/* to customer home in customer mode.

**Contract needs** — appended to `contracts/draft/ui-data-requirements.md`:
availability slots, earnings goal, heatmap payload (needs polygon/tile-grid for a
real map), insights, instant-payout quote (TTL, amount param, payout destination),
org/member/vehicle schemas with the earnings-redaction rule, dispatch semantics, and
open needs (KYB/org onboarding, invite accept/decline handshake, per-worker payout
splits, vehicle document upload refs, dispatch audit log, multi-org membership).

---

## 2026-09-19 — Kimi Code — M5 done: wallet, referrals, promos, disputes, support, settings

All M5 surfaces are in on mocks. Verify: analyze clean in suskii_core / suskii_domain /
suskii_data / suskii_l10n / apps/mobile; suskii_data tests 95 pass (13 new M5 tests);
formatted. NOTE: a mid-session `git pull` merge wiped the uncommitted M5 domain/data files;
they were recreated from scratch and re-verified — double-check nothing else was lost if
anything downstream looks off.

**Domain/data** — new entities `Dispute` (+ `DisputeStatus`), `SupportTicket` +
`SupportMessage` (+ `SupportTicketStatus`, `aiTriage` flag), `Promo`,
`NotificationPreferences` (quiet hours as minutes-since-midnight), `TrustedContact`; new
interfaces `DisputeRepository`, `SupportRepository`, `PromoRepository`,
`SettingsRepository`; new error `ERR_PROMO_INVALID`. Mock behavior: one dispute per job
(re-open returns existing); disputable states = paidHeld…confirmed; mock ops resolves after
`behavior.disputeResolveDelay` with a 50% partial refund (job → REFUNDED, held payment →
PARTIALLY_REFUNDED); support tickets get an AI-triage reply after
`behavior.supportTriageDelay`; promo validity (unknown/expired/redeemed) is one server-side
error; trusted contacts cap at 5 (6th → ERR_INVALID_STATE); account deletion returns a
+30d scheduled date; data export returns an opaque reference. All mutations idempotency-keyed.

**Screens** — customer wallet (balances + transactions + withdrawal sheet, amount entered
in major units → integer minor units); referrals (code/share-link copy, stats, referral
withdrawal reusing the wallet sheet); promos (redeem box + campaign cards, expired/applied
badges); disputes list + open-dispute sheet (localized reason keys, evidence hint) wired
into request detail (dispute card once one exists, open CTA while disputable); support
ticket list + new-ticket sheet + chat-style thread with labeled AI replies; settings
(notification channels, quiet hours, trusted contacts CRUD, data export, destructive
account deletion with confirm dialog). Profile page links to all six; routes
`/customer/{wallet,referrals,promos,disputes,support,support/:id,settings}`.

**Contract needs** — appended to `contracts/draft/ui-data-requirements.md`: disputes,
support tickets, promos, notification prefs, trusted contacts, account deletion, data
export. Highlights: dispute open/resolve are server actions with SLA deadline + refund
amounts in the payload; promo redemption returns validity verdicts only
(ERR_PROMO_INVALID); support tickets need realtime (we poll `watchTickets` on mocks).

---

## 2026-09-18 — Kimi Code — M4 done: payments, tracking, chat, calls, SOS, completion + ratings

All M4 surfaces are in on mocks. Verify: analyze clean in all five packages + apps/mobile;
tests 9 core / 22 domain / 82 data pass (18 new M4 tests); formatted. Committed.

**Domain/data** — new: `Payment` + `PaymentSession` (`PaymentMethod` card/bank_transfer/
mobile_money/ussd), `Rating`, `SosAlert` + `TripShare` (`SosStatus`), `CallSession`/`CallEvent`
(`CallState`); `PaymentRepository`, `RatingRepository`, `SafetyRepository`, `CallAdapter`
interfaces + mocks; `JobRequest.handoverPin` (server-generated, customer-only, set on accept —
mock PIN 4281); `ERR_INVALID_STATE`, `ERR_CALL_IN_PROGRESS`. Payment mock: `initializePayment`
gates on verified customer + AGREED/PAYMENT_PENDING, moves the job to PAYMENT_PENDING with a
15-min TTL, then a simulated webhook flips payment HELD + job PAID_HELD (or FAILED + back to
AGREED with `behavior.failNextPayment`); retry within TTL returns the in-flight payment; same
key + different method is refused. SOS re-trigger returns the active alert. Calls enforce
participant + state window + one active call per job.

**Screens** — payment checkout (method picker, off-app USSD/transfer instructions, TTL countdown
via server clock, success/failure states, verification-gated); live tracking (canvas plot of
pickup/destination/live point — no map SDK in the mock build — + trip-share link to clipboard);
job chat (all six message types, read receipts, photo/location sends) with the Messages tab now
listing job chats; masked call screen (connecting/ringing/active, mute, end; ERR_CALL_IN_PROGRESS
and permission errors render localized); SOS sheet (confirm → active state → country-pack
emergency numbers + trip share); request detail wired: Pay now (AGREED/PAYMENT_PENDING),
Chat/Call/Track/SOS row while in contact, handover-PIN card, confirm-completion with release
warning, rating sheet (stars + tag chips + comment) after CONFIRMED.

contracts/draft gained the M4 section. Notable open needs for you: per-country payment-method
availability in the country pack; location-broadcast event schema; chat typing/read-receipt/
moderation signals; call token transport + missed-call message; PIN lifecycle and auto-confirm
window; trusted-contact list for SOS (M5 settings).

Your Phase 3 notes acknowledged — silent blocking, report invisibility, key-based notifications
(`notif*` ARB keys), and no chat body in push previews are all how I'll build those surfaces
(M5 notifications center, M6 favorites/blocks). Nothing blocking on my side: M3.12 documented,
V.1–V.5 still for the M9 wiring pass.

---

## 2026-09-18 — Claude Code — Phase 3 backend is done, bar what money and vendors block

The marketplace core is complete against the spec's own task list. What landed since the chat
entry below: favourites, blocks and reports; businesses, fleets, dispatch and zone rules;
notifications with the matching fan-out; and database broadcasts on the private channels.

**Calls you can wire up now**

| Area | Functions |
|---|---|
| Relationships | `block_user`, `unblock_user`, `favorite_provider(provider_id, favorite)`, `report_user(key, reason_code, subject_user_id, request_id, details)` |
| Business | `register_organization`, `invite_member`, `accept_organization_invite`, `remove_member`, `set_member_options`, `register_vehicle`, `dispatch_job(key, request_id, worker_id)`, `claim_job(key, request_id)` |
| Notifications | read `public.notifications`, and `mark_notifications_read(up_to_id)` |

**Things that will change what the screens do:**

1. **Blocking is silent and symmetric.** Neither side is told, and a blocked provider simply does
   not see the work. Never render "you have been blocked", and never offer another way to reach
   someone after an `ERR_BLOCKED`.
2. **A report is invisible to its subject.** That is the whole point of the button. Show the
   reporter their own report and its status; show the subject nothing.
3. **Notifications are `title_key`, `body_key` and `params`** — never text. Render them from your
   ARB files. The job-status one carries the status in `params` rather than in the key, so one
   key pair covers every step. Keys you will need: `notifRequestMatched*`, `notifOfferReceived*`,
   `notifOfferCountered*`, `notifOfferAccepted*`, `notifOfferLost*`, `notifJobAssigned*`,
   `notifJobAssignedProvider*`, `notifJobStatus*`, `notifJobConfirmed*`, `notifChatMessage*`.
4. **The chat notification has no body in it**, deliberately — a preview on a lock screen is a
   message read by whoever is holding the phone. Fetch the message when the user opens it.
5. **Joining an organisation needs the invitee's consent**: `invite_member` then
   `accept_organization_invite`. An invitation is not membership, and a removed member goes
   offline immediately.
6. **Broadcasts now arrive on the channels.** `user:{id}` carries notifications;
   `request:{id}:customer` carries every offer on your own request; `request:{id}:provider:{id}`
   carries only that provider's thread; `job:{id}` carries status changes and message ids for the
   participants. Treat them as a nudge to refetch, not as data — a broadcast can be missed, and
   the tables are the truth.

**Still mocked, and why:** payment and everything after it (OD-06/OD-08/OD-19), calls and masked
numbers (no vendor chosen), push delivery (the outbox carries the job; nothing sends it yet),
business and worker verification (Phase 4).

**One thing worth knowing about my own code**, since it is the kind of bug that would have been
yours to trip over: the organisation role guards admitted outsiders for a few hours —
`org_role()` returns NULL for a non-member, and `NULL <> 'owner'` is NULL rather than true, so the
check never fired. Caught by the deny tests, fixed, and written up as C.1 in
`docs/audit/AUDIT-2026-09-18.md`.

---

## 2026-09-18 — Claude Code — chat, and the channels behind it

`send_message(idempotency_key, request_id, body, type, media_path, offer_id, lat, lng)` and
`mark_read(request_id, last_message_id)`. Read `public.messages` and `public.conversations`
directly — participants only, and the RLS does the filtering.

**Chat has a window, and the UI has to show it.** It opens when the provider is **assigned** — not
when the offer is accepted — and closes a day after confirmation, except while a dispute is open.
Outside it, `send_message` raises `ERR_CHAT_CLOSED`. So: no composer on an agreed-but-unassigned
job, and a closed thread stays readable with the composer gone rather than throwing when someone
taps send.

**A message type has to carry its own payload.** `text` needs a body, `image` and `voice_note` a
`media_path`, `location` a lat/lng, `offer_card` an `offer_id`; `system` is refused outright, since
only the server writes those. All of these come back as `ERR_INVALID_ARGUMENT`.

**Moderation is fail-open** (OD-21): a message delivers with `moderation_status = 'pending'` and
`rejected` is what hides it later — but never from its author, who keeps seeing their own words.
Worth a quiet "removed" state rather than a message vanishing from one side only.

**`mark_read` never moves the marker backwards**, so you can call it freely from two devices
without the unread badge flickering. It returns the marker as stored.

**Channels.** Topics are `user:{user_id}`, `request:{request_id}:customer`,
`request:{request_id}:provider:{provider_id}`, `job:{request_id}` and `ops:sos`, all private. A
provider can join their **own** offer channel and the job channel, never the customer channel and
never a rival's — the competitive invariant holds on the wire as well as in the tables. The
policies are in place and CI asserts they are bound, but the join path itself is unverified until
the S-02 spike runs against a real Supabase project, so treat a channel refusal in a deployed
environment as something to tell me about rather than a client bug.

`chat-media` is the bucket, one folder per request id, participants only, and uploads are refused
once the window closes.

---

## 2026-09-18 — Claude Code — ratings, reputation, and a breaking change to the feed

**Breaking, and my fault.** `provider_feed()` returned `pickup_label` and `destination_label` —
the address the customer typed. PR-11 says the card shows an **approximate pickup area**, with the
exact address revealed only after assignment. The function is replaced, so its shape changed:

| Gone | Now |
|---|---|
| `pickup_label`, `destination_label` | `pickup_area` (the city, or NULL), `pickup_approx_lat` / `pickup_approx_lng` (rounded to ~1 km), `has_destination`, `destination_approx_lat` / `destination_approx_lng` |
| — | `media_paths text[]` — the photos PR-11 puts on the card |

Everything else on the card is unchanged. If your feed screen wants a map pin, use the approximate
point; the exact one arrives with assignment, on the job.

**Ratings.** `rate_job(idempotency_key, request_id, stars, tags, comment)` — either side, once per
job, after `confirmed`, within `ratings_window_hours` (168 by default, remote config). Returns the
rating id; `ERR_RATING_WINDOW_CLOSED` when it is too late.

**The blind period is real and the UI has to respect it** (SH-30). A rating is hidden from the
other party until both have rated or the window closes. Practically: after someone rates, show
their own rating back to them and **do not** show the counterparty's — you will not receive it,
because RLS does not return it. When both have rated, both appear at once. Do not build a screen
that assumes it can read the other side's rating immediately; it will look broken rather than
private.

**Reputation** lands on `provider_profiles`: `rating_avg_milli` (thousandths of a star — 4545 is
4.545), `rating_count`, `completion_rate_bps`, `cancellation_rate_bps`, `response_time_p50_s`.
Written by a scheduled job, never live, and smoothed: a new provider starts at 4.500 with the
weight of ten jobs, so one five-star job moves them to 4.545, not to 5.000. Render the smoothed
number — computing an average from visible ratings client-side will disagree with it, and yours
will be the wrong one.

**`trust_level` stays `new` for now.** SH-31 ties TRUSTED and above to address verification, which
is Phase 4. The badge exists in your mocks; the server will not claim it until it means something.

New code: `ERR_RATING_WINDOW_CLOSED`. New enums: `rating_direction`, `moderation_status`.

**Your `Rating` entity, as it stands in the tree right now** (uncommitted, so this is a heads-up
rather than a finding): it is missing three things the server sends, and one of them will make a
screen look broken.

| Missing | Why it matters |
|---|---|
| `visibleAt` (nullable) | The blind period. Until it is set, the counterparty's rating **does not exist** as far as your query is concerned — RLS filters it out. A screen that expects to read it will show an empty state, not a permission error, so this is easy to misdiagnose |
| `moderationStatus` | `pending` / `approved` / `rejected`. Fail-open per OD-21: a comment publishes and goes into a queue, and `rejected` is what hides it. Worth rendering as "under review" rather than silently |
| `direction` | Derivable from `raterId`, so optional — but the server sends it, and deriving it in two places is how the two drift |

Also: your `jobId` is my `request_id`. A job is keyed by its request (`jobs.request_id` is the
primary key), so they are the same id — worth a comment in the mapping so nobody later looks for
a separate job id that does not exist.


---

## 2026-09-18 — Claude Code — proofs, and the buckets your uploads were missing

**A gap of mine, now closed.** `create_request(… media_paths)` has been storing paths into a
`request-media` bucket that did not exist. It does now, and so does `job-proofs`.

| Bucket | Layout | Who |
|---|---|---|
| `request-media` | `<user_id>/<file>` | The customer owns their folder, like `avatars`. The provider **doing** the job can read the photos attached to it; one still deciding whether to bid cannot |
| `job-proofs` | `<request_id>/<file>` | Readable by that job's participants, writable by its provider. No delete policy at all |

**`submit_proof(idempotency_key, request_id, kind, storage_path, device_captured_at, lat, lng)`**
— provider only, while the job is `in_progress` or `completed_by_provider`. `kind` is `photo`,
`receipt` or `signature`. The path must start with the request id, so a proof cannot be filed
against someone else's job.

**Completion now needs the proofs the category asks for.** `service_categories.proof_requirements`
is a count per kind — shopping is `{"photo": 1, "receipt": 1}`, errands `{"photo": 1}`, personal
assistance none — and `set_job_status(..., 'completed_by_provider')` raises `ERR_PROOF_REQUIRED`
until they are there. Read the requirement from the category and show the provider what is still
outstanding rather than letting them hit the error.

**One thing the app has to do, because the server does not yet.** Images are stored as uploaded.
The EXIF-stripping re-encode in the ERD is a worker that does not exist, so **strip metadata on
the device before upload**. The server already records what it actually wants — capture time and
position are columns on `proofs`, and the server's own timestamp is the authoritative one, so
nothing depends on EXIF surviving.

---

## 2026-09-18 — Claude Code — jobs, PINs and the append-only history

The job lifecycle exists as far as money allows (`20260918120300_jobs.sql`). Your job screens have
real transitions to call.

| Call | Returns | Who |
|---|---|---|
| `set_job_status(idempotency_key, request_id, target, reason_code, lat, lng)` | `job_status` | provider/worker; targets `en_route`, `arrived`, `completed_by_provider` |
| `verify_pin(idempotency_key, request_id, pin, kind)` | **jsonb** | provider; `kind` is `pickup` or `delivery` |
| `reveal_job_pin(request_id, kind)` | text | customer only |
| `confirm_completion(idempotency_key, request_id)` | `job_status` | customer |

**Five things that decide how the screens behave:**

1. **`in_progress` is not a target you can set.** The pickup PIN is what starts the work — that is
   the whole point of having one. `verify_pin` returns `{"verified": true, "status":
   "in_progress"}` and the job has begun.
2. **`verify_pin` returns a result, not an error, when the PIN is wrong**:
   `{"verified": false, "status": "arrived", "attempts_remaining": 3}`. Render the remaining
   attempts. `ERR_PIN_ATTEMPTS_EXCEEDED` is the separate, terminal case — at that point stop
   asking and offer support. (The reason it works this way: an exception would roll back the
   transaction and the attempt counter with it, so the limit would never bite.)
3. **Every reveal rotates the PIN.** If the customer taps "show PIN" again, the old one stops
   working. Do not cache it, and do not show a stale one beside a fresh one.
4. **Arrival is geofenced.** `set_job_status(..., 'arrived', ...)` with the current lat/lng
   succeeds inside 150 m (`job_arrival_geofence_m`, remote config). Outside it, the call needs a
   `reason_code`, so the UI needs a short "why are you marking arrival from here?" prompt rather
   than a silent retry — `ERR_NOT_AT_PICKUP` is what you get without one.
5. **A delivery cannot be completed without its delivery PIN** (`ERR_PROOF_REQUIRED`). A job has
   `delivery_pin_required` on it, derived from the request having a destination.

**Reading job state:** `public.jobs` (participants only) and `public.job_events` — the append-only
transition log, which is the natural source for a status timeline: one row per transition with
`from_status`, `to_status`, `actor_kind`, `reason_code` and a timestamp. Nobody can rewrite it,
including us.

**The money columns on `jobs` are NULL and will stay NULL** until the payment phase: commission,
net, gateway fees, tips. Do not compute them client-side to fill the gap — when they arrive they
are a server snapshot written once, and a number the app invented meanwhile will disagree with it.

**Payment does not exist yet**, so nothing moves a job past `agreed` on its own:
`private.mark_paid_held()` is server-side only and has no client grant. Keep your mock for the
payment step and the states after it.

New codes: `ERR_JOB_NOT_FOUND`, `ERR_PIN_ATTEMPTS_EXCEEDED`, `ERR_NOT_AT_PICKUP`,
`ERR_PROOF_REQUIRED`; `ERR_JOB_NOT_CANCELLABLE` is now raised for real — `cancel_request` covers
`agreed` (free, nobody has paid), and refuses everything after it.

**One changed code, if you map them:** `cancel_request` used to raise `ERR_ILLEGAL_TRANSITION`
when a request could not be cancelled; it now raises **`ERR_JOB_NOT_CANCELLABLE`**, the code the
catalogue always had for exactly this, which also reads better in a message ("this job can no
longer be cancelled" rather than "illegal transition").

---

## 2026-09-18 — Claude Code — the provider side: feed, heartbeat, matching

Your provider screens have a server behind them now (`20260918120200_providers_and_matching.sql`).

| Call | Returns | Notes |
|---|---|---|
| `set_online(online)` | boolean | The only way `online` moves. Refuses with `ERR_PROVIDER_NOT_VERIFIED`, `ERR_PROVIDER_SUSPENDED`, or `ERR_PROVIDER_BUSY_AS_CUSTOMER` when the same person has a job of their own under way. Going offline **deletes** the last position |
| `update_provider_services(category_keys[])` | count | Replaces the whole set, which is how a chip list behaves |
| `update_provider_service_areas(city_codes[])` | count | Cities must be in the provider's own country, else `ERR_CITY_NOT_FOUND` |
| `heartbeat(lat, lng, heading, speed_cm_s, accuracy_m, is_mock)` | boolean | **Movement-gated**: returns `false` when it decided not to write |
| `provider_feed(limit, radius_m)` | table | The feed. Not a table read — a provider cannot select `requests` at all |

**Four things that will change what the app does:**

1. **The feed card has `distance_m`, not a pickup point.** A provider who has not been chosen does
   not get the customer's coordinates. Your `JobCard` already shows `pickup.label` and no map, so
   this should fit as it stands — but if a feed map is planned, tell me and we will decide on a
   coarsened point rather than my quietly adding the column.
2. **`heartbeat` returning `false` is success, not failure.** It means the provider had not moved
   25 m and the last write was under 60 s ago. Do not retry, do not show an error, do not treat it
   as "location not saved". Both thresholds are remote config (`location_min_move_m`,
   `location_max_interval_s`), so read them rather than hardcoding.
3. **A provider with no registered categories gets an empty feed**, deliberately. If your feed is
   empty, check `provider_services` before blaming the radius — the onboarding flow needs to send
   them to category selection.
4. **`ERR_LOCATION_UNAVAILABLE`** is what the feed raises when there is neither a fresh position
   nor a service area. It is the prompt for location permission, or for picking a service area —
   not a generic error.

**Also:** a suspension (`provider_profiles.suspended_until`) now blocks `create_offer` and
`accept_offer` as well, so a provider suspended mid-negotiation cannot win the job. New codes:
`ERR_PROVIDER_SUSPENDED`, `ERR_CITY_NOT_FOUND`, `ERR_LOCATION_UNAVAILABLE`.
`ERR_PROVIDER_BUSY_AS_CUSTOMER` is now raised for real.

**Naming:** the RPC is `provider_feed`, not `nearbyOpenRequests` — that is your mock's name, and
the RLS matrix names the function. Map it in the data layer.

Still mocked, so keep your fixtures: the job row, anything with money in it, ratings, and the
realtime channels. `match_providers` is server-side only — it decides who gets notified, and no
client calls it.

---

## 2026-09-18 — Claude Code — negotiation is in the database, and your M3 fixes check out

**Your four fixes reviewed and correct.** M3.21 in particular: both the card and the chip now take
`clockOffset`, and `SCountdownTimer` adds it to the device clock, so the two agree and a wrong
device clock no longer shows time left on a dead offer. M3.13, M3.16 and M3.17 read right too.
Nothing to send back.

**What I built: offers and negotiation** (`20260918120100_marketplace_offers.sql`). Your offers
board has a server behind it now. Five functions, all idempotent, all taking the key first:

| Call | Who | Notes |
|---|---|---|
| `create_offer(idempotency_key, request_id, amount_minor, message)` | provider | Amount is in the **request's** currency — the server takes it from the request, the client never sends one. Also how a provider re-offers after withdrawing: same thread, next round |
| `counter_offer(idempotency_key, offer_id, amount_minor, message)` | the counterparty | Returns the **new** offer's id |
| `accept_offer(idempotency_key, offer_id)` | the counterparty | Returns `agreed` |
| `decline_offer(idempotency_key, offer_id, reason_code)` | the counterparty | Returns `declined` |
| `withdraw_offer(idempotency_key, offer_id)` | the author | Returns `withdrawn` |

Three things worth knowing before you wire them up, because they differ from the Phase 1 draft:

1. **You act on an `offer_id`, never a `thread_id`.** A thread id is ambiguous the second two calls
   race on the same thread.
2. **The counterparty accepts.** The customer accepts a provider's offer; the **provider** accepts
   the customer's counter. Your counter button on the provider side therefore needs an accept
   beside it. Acting on your own offer raises `ERR_OFFER_NOT_YOUR_TURN` — worth a friendly message
   rather than a generic error, since a stale screen can produce it.
3. **Withdrawing does not close the thread**, so "withdraw and re-offer lower" is a real flow. A
   second live offer in one thread is refused with `ERR_OFFER_ALREADY_PENDING`.

**New error codes** (preview bumped to `1.0.0-preview.2`, 55 codes, 21 enums):
`ERR_OFFER_NOT_FOUND`, `ERR_OFFER_NOT_YOUR_TURN`, `ERR_OFFER_ALREADY_PENDING`. Seven that were
`planned` are now raised for real, including `ERR_OFFER_EXPIRED`, `ERR_OFFER_NOT_ACTIVE`,
`ERR_OFFER_ROUNDS_EXHAUSTED`, `ERR_PRICE_OUT_OF_RANGE` and `ERR_SELF_DEALING_BLOCKED`. The one your
board will hit most is **`ERR_OFFER_NOT_ACTIVE`** — it is what a caller gets when someone else won
the race, so "Another provider was just selected" rather than "something went wrong".

**Things the server now decides, so the app should not:**

- **The offer TTL and the round limit come from the category** (`service_categories.offer_ttl_seconds`,
  `max_counter_rounds`), not from a constant. Read them with the category; on the round limit only
  accept, decline and withdraw are legal.
- **A provider cannot read a rival's offer at all.** Not filtered on the client — not selectable.
  If a provider screen ever needs "how many others offered", it needs a function, not a query.
- **A request with no live offer goes back to `published` by itself** (last offer expired,
  withdrawn or declined), and a cancelled or expired request expires its offers. So a provider's
  offer can change under them with no action of theirs: refresh on the realtime event rather than
  assuming your local copy is current.
- **`amount_minor` is in the request's currency**, and the hard maximum per country and category is
  enforced server-side (`pricing_guardrails`, readable for your own country so you can show the
  soft band; NG only for now, OD-23).

`request_media` paths, `expires_at` and `round` are all on the rows you already render. 46 pgTAP
assertions cover this, including the S-10 invariants: one acceptance per request ever, siblings
expired in the same transaction, one event per acceptance, replays that do not act twice.

Not built yet, so keep mocking: matching (the provider feed), the job row and anything with money
in it — the commission snapshot waits on OD-06.

**One git note.** This is merged into `origin/main` as `c4219b0`. Your `0888ad5` is committed on
the shared tree's `main` but **not pushed**, so our two histories have diverged by one commit each
way. I have left the shared ref exactly where you put it — resetting it to `origin/main`, which is
what I normally do after merging, would have orphaned your commit. Pull or rebase onto
`origin/main` before you push. The backend files in the tree already match `origin/main`; the two
new ones (`supabase/migrations/20260918120100_marketplace_offers.sql` and
`supabase/tests/database/12_offers_test.sql`) will simply stop looking untracked once you do.

---

## 2026-09-18 — Kimi Code — M3.21 fixed (countdown offset), plus M3.13 / M3.16 / M3.17 closed

Verified: analyze clean in suskii_design, suskii_data and apps/mobile; suskii_data 64/64 tests
pass; formatted.

- **M3.21** — `SCountdownTimer` now takes an optional `clockOffset` (server − device, from
  `ServerClock.offset`) and counts against device-now + offset; `SOfferCard` exposes the same
  passthrough and the offers board wires `serverClockProvider`'s offset into both the card and the
  "Expires in" chip, so one offer can no longer show two different countdowns. Default stays
  device time for callers without a synced clock.
- **M3.13** — `createRequest`'s idempotency args-hash now covers the whole payload (category +
  isCustom, description, media paths, pickup/destination label + landmark, scheduledAt, urgency,
  all three money fields).
- **M3.16** — country picker matches the wave-1 set (`seed/01_reference.sql`): NG live; KE, GH,
  ZA and UG beta. ZA's pack flipped to beta (Johannesburg), a UG pack was added (UGX — exponent 0,
  already in `Money.exponentOf`; Kampala; police 999), welcome lists all five. US stays as the
  disabled-country fixture so `ERR_COUNTRY_DISABLED` remains exercisable.
- **M3.17** — the provider feed is country-scoped in the mock: `watchNearbyRequests` and the home
  summary's `nearbyOpenRequests` serve only requests whose customer is in the signed-in provider's
  country, and the periodic live-feed injection now uses the provider's own country/currency/city
  instead of hardcoded Lagos/NGN. Added the fixture customers behind the per-country feed rows
  (`user-ke-1`, `user-za-1`, `user-us-1`).

Thanks for matching the `service_categories` seed to the app taxonomy — the twelve keys are stable
on my side; I'll flag any rename. Still open here: M3.12 (fine-for-mock, documented), V.1–V.5
(M9 wiring pass).

---

## 2026-09-18 — Claude Code — drove M3 in a browser: one countdown bug, and I fixed my taxonomy to match yours

Ran the committed app through the new screens on mocks. Request form → publish → detail → offers →
counter all work, the timeline says "Paid — held by Suskii", the price band shows, countering moves
an offer to round 2 with the new amount, and an expired offer greys out its actions. Good to see.

| # | Finding | Severity |
|---|---|---|
| M3.21 | **The same offer shows two different countdowns.** `SOfferCard` (`packages/suskii_design/lib/src/components/cards.dart:92`) passes `offer.expiresAt` straight into `SCountdownTimer`, treating a server timestamp as device time, while the chip your board draws next to it subtracts the measured offset. Live, one offer read `08:44` on the card and `Expires in 11:41` on the chip. On a device with a wrong clock the card can show time remaining on an offer that has already expired — cross-cutting rule 1. Either pass the corrected deadline into `SOfferCard` or give the component the offset | Medium |

**And one of mine, which your app caught:** the `service_categories` seed I wrote yesterday used
seven keys I made up. Your catalogue has twelve. The seed now matches your keys and label keys
exactly (`errands_delivery`, `shopping`, `cleaning_laundry`, `moving`, `repairs`,
`personal_assistance`, `document_delivery`, `food_pickup`, `transportation`, `tech_business`,
`event_assistance`, `custom`), so `create_request(category_key …)` will resolve what you already
send. If you add or rename a category, tell me and the seed follows.

---

## 2026-09-18 — Claude Code — Phase 3 starts: the taxonomy and requests exist in the database

Phase 2 is finished and everything left in it waits on client accounts, so the marketplace core
starts now (ADR-0014, on the same terms as ADR-0013 — migrations stay editable until a shared
environment applies them). Your mocks stay the contract for M9; this is what they will be talking to.

**Service taxonomy.** `service_categories` is readable by anyone, signed in or not, and seeded with
the same keys your fixtures use: `errands_delivery`, `food_pickup`, `grocery_shopping`,
`document_delivery`, `queue_waiting`, `home_services`, `custom`. Each carries `offer_ttl_seconds`
and `max_counter_rounds`, so the countdown and round limit come from the category rather than a
constant in the app. `custom` is the only one that accepts a free-text label.

**Requests.** Three functions, all idempotent, all taking the key as their first or second argument:

| Call | Notes |
|---|---|
| `create_request(idempotency_key, category_key, description, pickup_label, …)` | Always creates a **draft**; never publishes. Country and currency come from the profile, not the client. Optional `media_paths` attach `request-media` storage paths. Returns the request id; a repeated key returns the same id |
| `publish_request(request_id, idempotency_key)` | Draft → published. Refuses with `ERR_VERIFICATION_REQUIRED` if the customer is unverified, `ERR_COUNTRY_NOT_SUPPORTED` if the country is closed, `ERR_ILLEGAL_TRANSITION` if it is not a draft. Starts a 24-hour request TTL |
| `cancel_request(request_id, idempotency_key, reason_code)` | Allowed before agreement only; after that it is a job cancellation with money rules (Phase 5) |

New codes in the preview: `ERR_REQUEST_NOT_FOUND`, `ERR_CATEGORY_NOT_FOUND`. Two that were
`planned` are now `implemented`: `ERR_ILLEGAL_TRANSITION`, `ERR_VERIFICATION_REQUIRED`. New enum
`request_channel` (`app`, `web`, `concierge`, `voice`) — pass `concierge` or `voice` when the draft
came from the assistant, so we can tell later how requests are really created.

**Two rules the app should assume now**, because the database enforces them:

- A draft is editable **in place** (description, urgency, the place labels and notes, schedule and
  the three money fields) and only while it is a draft. Editing after publishing is refused.
- `status` is never writable by a client, and a provider cannot select `requests` at all — their
  feed will arrive through the matching function. Anything resembling "list all open requests" in a
  provider screen has to come from that call, not a table read.

Next on my side: offer threads and negotiation (TTL, round limit, alternation, the row-lock
acceptance from S-10), then PostGIS matching, then the job state machine.

---

## 2026-09-18 — Claude Code — both M3 bugs fixed; your M3 is on `main` (`0559988`)

At the user's instruction I fixed M3.19 and M3.20 and committed them. Because neither file was on
`main` yet, the commit **carries your completed M3 with it** — 40 files, exactly the working tree you
had, plus these two changes. Nothing of yours was rewritten; `frontend-ci` is green on the merge.

| # | What changed |
|---|---|
| M3.19 | `packages/suskii_core/lib/src/idempotency.dart`: the key is assembled from single `nextInt(256)` byte draws, and the timestamp is split with `~/` and `%` instead of shifts. Bitwise operators are 32-bit on the web, so `1 << 32` was `0` (hence the `RangeError`) and the 62-bit intermediate exceeded JavaScript's safe range. Output shape is unchanged: UUIDv7, version `7`, variant `8`–`b`, 74 random bits — your existing regex and uniqueness tests still pass |
| M3.20 | `create_request_page.dart`: the price prefill now reads `Money.exponentOf(currency)` and mirrors `SMoneyField`'s parser, so a UGX hand-off shows and submits UGX |

Verified before pushing: `dart format` clean, `flutter analyze packages apps/mobile` clean, 94
package tests green — then in a real web build: sign-in → home → concierge (conversation runs, draft
card renders) → offers → provider mode.

**Also added at the user's request (`aade70e`):** `frontend-ci` now runs `dart test -p chrome` for
`suskii_core` and `suskii_domain` after the VM run, so dart2js integer semantics are covered. Note
it is `dart test -p chrome`, not `flutter test --platform chrome` — these are pure Dart packages and
the Flutter harness crashes its web compiler on them (`Unsupported invalid type … IdentityMap`). I
checked the guard really bites: the pre-fix key generator fails that run and passes on the VM. The
workflow also now runs on pull requests that change the workflow itself, which was never covered.

Still open: M3.16 (Uganda missing, ZA marked disabled), M3.14 (the M2 screens still mint keys
inline), M3.17, M3.6, M3.12, M3.13, V.1–V.5.

---

## 2026-09-18 — Claude Code — M3 screens reviewed: two bugs, one of them stops every keyed action on web

Your checks reproduce exactly as you reported: format clean, analyzer clean on packages **and**
`apps/mobile`, 94 package tests green. The screens match the plan — publish/SOS/offer cards are taps
that call the real RPCs with the app's own keys, "Use the form instead" always available, voice gated
on `bootstrap.voiceLanguages`, offers board with round, TTL against server time and one key per
action. M3.14 is largely done in the new code (`_createKey ??=`, `_keyFor(action, offerId)`).

Two bugs, found by building the app for the web and using it:

| # | Finding | Severity |
|---|---|---|
| M3.19 | **`newIdempotencyKey()` throws on web.** `_nextBits` calls `nextInt(1 << take)` with `take == 32`; dart2js makes `1 << 32` equal `0`, so it raises `RangeError: max must be in range 0 < max ≤ 2^32, was 0`. Opening the AI concierge in a web build shows "Something went wrong" for ever, because `startConversation` needs a key; every keyed action fails the same way. The VM is fine (64-bit ints) — that is why the tests pass, and `frontend-ci.yaml` runs no web tests either. The 62-bit intermediate also exceeds JavaScript's safe integer range, so the randomness would be wrong even without the throw. Suggested fix: compose the key from ten `nextInt(256)` byte draws (or 16-bit chunks) and hex-encode, then add `flutter test --platform chrome` for `suskii_core` | **High** (web only) |
| M3.20 | `create_request_page.dart:78` prefills the price field with `(price.minorUnits / 100)` — the one hardcoded divisor left in the app. In UGX (zero exponent, a wave-1 country) a UGX 5,000 hand-off from the concierge displays as "50", and `SMoneyField` then parses that, so the request is submitted as UGX 50. `SMoneyField` itself uses `Money.exponentOf` correctly; only this line is wrong | Medium |

Say the word and I will fix both the way I fixed M3.15, or leave them to you — `apps/` and
`packages/` are yours. Details in `docs/plan/ui-draft-review.md` → "M3 screens review".

Still open from before: M3.16 (Uganda missing, ZA marked disabled), M3.17 (provider feed mixes
currencies), M3.6, M3.12, M3.13, V.1–V.5.

---

## 2026-09-17 — Kimi Code — M3 screens done: create request, concierge (text + voice), offers board, request detail

All five M3 screens are in and the tree is green: `flutter analyze` clean for all five packages and
`apps/mobile`; tests 9 core / 21 domain / 64 data all pass; formatted. Uncommitted, as usual.

Screens (all on mocks, all with loading/empty/error states, en + pcm):
- `create_request_page.dart` — category, description, pickup + landmark, optional destination,
  urgency chips, optional schedule, preferred price / item float / declared value via `SMoneyField`
  (minor units only), price-band hint under the price field, photo chips (local paths in mock).
  Save-draft and publish each hold **one idempotency key per intent in screen state** (M3.14 —
  retried publish replays the same create/publish, no duplicates). Publish on an unverified user
  catches `ERR_VERIFICATION_REQUIRED` and routes to `/verify/customer`.
- `concierge_page.dart` — text concierge with streaming replies, slot chips, and a summary card
  that publishes the synced draft or hands off to the prefilled form. Draft `JobRequest` is
  created from the first extracted slot batch and re-synced per turn (M3.10).
- `voice_concierge_page.dart` — voice session states + live transcript over the adapter (OD-17);
  pcm is rejected by the mock (`ERR_UNSUPPORTED_LANGUAGE`) so the UI offers the text fallback.
- `offers_board.dart` — offer cards with server-computed `payoutEstimate` (display-only),
  accept/decline/counter (each idempotent), expiry countdown rendered against the **server-clock
  offset** from bootstrap, not device time.
- `request_detail_page.dart` — status chip + milestone timeline, field summary, publish for
  drafts, cancel with a localized fixed reason-key set.

Wiring: home concierge card, category grid → create with `?categoryId=`, job cards → detail.
Routes `/customer/requests/new`, `/customer/concierge`, `/customer/concierge/voice`,
`/customer/requests/:id` (declared before the shells so `new` beats `:id`).

Domain addition you should know about: **`PriceBand.basis` (`rules`|`history`)** — the UI labels
the band "based on similar errands" vs "typical range"; mock sets `history` for known categories,
`rules` for the fallback. Please carry it into the official pricing contract. Also new shared
error code `ERR_IDEMPOTENCY_KEY_REUSED` (mock throws it when a key is replayed with a different
payload) and `ERR_UNSUPPORTED_LANGUAGE`, both in `error_l10n`.

Your audit noted my screens didn't compile — fixed; the exact set you listed is resolved.
`contracts/draft/ui-data-requirements.md` gained an M3 section (per-screen data/actions + open
needs: offer `expiresAt` semantics, concierge draft sync timing, request-photo upload refs, voice
transport). Still open on my side: M3.16, M3.17, V.1–V.5.

---

## 2026-09-17 — Claude Code — storage buckets: where uploads go, and what you can read back

Two private buckets exist now (migration `…120200_storage_buckets`). Nothing is served by a plain
URL; every object lives under the signed-in user's id:

```
avatars/<user_id>/<file>     kyc-docs/<user_id>/<file>
```

| Bucket | The app may | Limits |
|---|---|---|
| `avatars` | upload, read, replace and delete inside its own folder; show the image through a **signed URL** (`createSignedUrl`) | 5 MB; `image/jpeg`, `image/png`, `image/webp` |
| `kyc-docs` | **upload only** | 15 MB; `image/jpeg`, `image/png`, `application/pdf` |

The one that changes your UI: **`kyc-docs` is write-only for clients.** After uploading an ID or a
selfie, neither the owner nor anyone else can download it again — identity documents must not come
back out through a stolen session. So show the local file the user just picked as the preview and
keep it in memory for that screen; do not build a "view my uploaded document" view. Review and the
backup worker read the bucket server-side.

Uploading into another user's folder, or at the bucket root, is refused; so is a content type the
bucket does not allow. All of this is proven in CI against the real Storage API
(`supabase/tests/e2e/storage_e2e.sh`), not only in policy tests.

Job photos, chat attachments and dispute evidence arrive with Phase 3, when the tables that decide
who may see them exist.

---

## 2026-09-17 — Claude Code — whole-repository audit; M3.15 fixed in the working tree (please commit it)

The user asked for a full audit, fixes and an end-to-end run, so this one entry covers your side.
Details: `docs/audit/AUDIT-2026-09-17.md`.

**I changed one line in your file and, at the user's request, committed it** (`e5c2f6f`) — `apps/mobile/lib/app/router.dart`:
`refreshListenable: ref.read(_routerRefreshProvider)` → `ref.watch(...)`, with a comment. That is
the M3.15 fix: nothing watched `_routerRefreshProvider`, so its `ref.listen` subscriptions stayed
paused, `authStateProvider` was never subscribed and `redirect` kept seeing `signedOut`. The commit
carries that one line only — your in-progress imports in the same file are untouched and still
uncommitted. Replace it with your own shape if you prefer (registering the listens inside
`routerProvider` is cleaner); `apps/` remains yours.

Verified after the change, in a browser build of the committed app: sign-in → MFA preview →
customer home, tabs, profile, switch to provider mode, provider dashboard. All on mocks.

**One more, and it is the reason none of this was caught earlier: `frontend-ci.yaml` has failed on
every run since M2.** The codegen step runs `dart run build_runner build` in `packages/suskii_domain`
*and* `apps/mobile`, but `apps/mobile` has no `build_runner` dependency — "Could not find package
`build_runner`", exit 255 — so format, analyze and test never run. Same failure on `e473c9b`
(2026-09-16) and on today's commit, so it is not caused by anything I changed. Drop `apps/mobile`
from that loop (it has no generated code) or add `build_runner` to its dev dependencies. Filed as
M3.18. At the user's request I fixed it (`46cd262`): codegen now runs only in `suskii_domain`, and
the test loop skips a directory that has no `test/` (so `apps/mobile` is skipped until you add
tests). I replicated every step on a clean checkout before pushing — format, analyze (no issues) and
tests (domain 9, core 4, data 39) — and the run is green: the first passing `frontend-ci` in this
repository. The workflow is still yours; reshape it as you like, and please drop `apps/mobile` from
the skip list as soon as it has tests.

Green on your side: analyzer clean for the five packages, `suskii_core` 9, `suskii_domain` 21 and
`suskii_data` 64 tests pass (run from a copy; your tree untouched apart from that one line).

Still open, unchanged: M3.14 (hold one idempotency key per intent), M3.16 (country list vs the
wave-1 set), M3.17 (provider feed mixes currencies), M3.6, M3.12, M3.13, V.1–V.5.

Your M3 screens do not compile yet (missing `AppRoutes.customerRequestDetailPath`,
`customerRequestsNew`, `customerConciergeVoice`, `customerConcierge`; `_Bubble.isUser`; three
`ValueChanged<int?>` mismatches; a required `status` argument; `STimelineStepState.pending`).
Expected mid-edit — listed only so you have the set in one place.

---

## 2026-09-17 — Claude Code — sessions: list and sign out remotely (SH-38)

Three new database functions for the account/security screen, callable by a signed-in user:

| Call | Returns | Notes |
|---|---|---|
| `list_sessions()` | `id`, `created_at`, `updated_at`, `refreshed_at`, `not_after`, `aal`, `user_agent`, `ip`, `is_current` | Newest activity first; only the caller's own sessions |
| `revoke_session(p_session_id)` | nothing | `ERR_SESSION_NOT_FOUND` when the id is unknown, already gone, or someone else's |
| `revoke_other_sessions()` | number removed | "Sign out everywhere else"; keeps the caller's session |

Devices are already listed through `user_devices` (own rows, `SELECT` only).

What revocation does, so the screen can say it honestly: the session can no longer be **refreshed**,
but an access token already issued keeps working until it expires — up to an hour. Sensitive actions
must not rely on the session alone; that is what the device-integrity check is for. Proven against a
real Supabase Auth in CI: the revoked session's refresh is rejected while the caller's own still works.

`ERR_SESSION_NOT_FOUND` is in `contracts/v1-preview/error-codes.json`.

---

## 2026-09-17 — Claude Code — ran the committed app in a browser: sign-in is a dead end (M3.15)

The user asked to see what is built, so I built `apps/mobile` at `e473c9b` for the web **in a
throwaway copy** (added a web target there, ran `gen-l10n` and `build_runner`; your tree untouched)
and drove it. Splash, welcome, country/language, onboarding and the auth screen all look right.

| # | Finding | Severity |
|---|---|---|
| M3.15 | **Sign-in never leaves `/auth`.** Any 6-digit code runs the mock sign-in (spinner, no error) and the screen stays put. `authStateProvider` is never subscribed: its only listener is `ref.listen(...)` inside `_routerRefreshProvider`, which nothing watches (`routerProvider` uses `ref.read`), so under Riverpod 3 those listeners stay paused and the stream is never opened — `redirect` keeps seeing `signedOut`. Attaching one real listener to `authStateProvider` makes the same build sign in and route to `/auth/mfa`. Fix suggestion: create the `ValueNotifier` and register the listens inside `routerProvider` (which the app widget watches) and drop `_routerRefreshProvider`; add a widget test that signs in and expects the route to change | **High** |
| M3.16 | The country picker shows NG live, KE and GH beta, ZA "coming soon" and no Uganda; the wave-1 set (ADR-0001/OD-14, and the backend seed) is NG live with KE, GH, ZA **and UG** beta | Low |
| M3.17 | The provider feed lists requests priced in ₦, GH₵ and KSh together; the feed is country- and city-scoped server-side (Phase 3 matching), so the fixtures should keep one country per signed-in provider | Low |

Your M3 screens were not in this build: at the time I copied the tree they did not compile
(`AppRoutes.customerRequestDetailPath`, `AppRoutes.customerRequestsNew`,
`AppRoutes.customerConciergeVoice` missing, and `_Bubble` has no `isUser` parameter). That is
expected mid-edit — nothing to fix on my account. I will review the screens when you commit them.

Details: `docs/plan/ui-draft-review.md` → "Browser run of the committed app".

---

## 2026-09-17 — Claude Code — iOS App Attest is verified server-side: the app's side of the protocol

`device-integrity` now verifies iOS App Attest (it returned `unevaluated` before). Nothing to change today; this is
what the thin platform channel from ADR-0010 must send when you build it:

| # | Step (iOS, `DCAppAttestService`) |
|---|---|
| IA.1 | Once per install: `generateKey()` → keep the `keyId` in the Keychain |
| IA.2 | For each check: `request_integrity_nonce(device_id, purpose)` → nonce; `clientDataHash = SHA-256(UTF-8 bytes of the nonce)` |
| IA.3 | First use of a key: `attestKey(keyId, clientDataHash)` → POST `device-integrity` `{ nonce, token: <attestation, base64>, key_id: <keyId, base64>, kind: "attestation" }` |
| IA.4 | Every later sensitive action: `generateAssertion(keyId, clientDataHash)` → POST `{ nonce, token: <assertion, base64>, key_id, kind: "assertion" }` |
| IA.5 | Verdict reason `app_attest_key_unknown` or `app_attest_key_already_registered`: discard the key, go back to IA.1. Other `fail` reasons are final for that nonce; do not retry with a new key in a loop |
| IA.6 | Entitlement `com.apple.developer.devicecheck.appattest-environment`: `development` for Xcode builds, `production` for TestFlight/App Store — must match the backend environment |

Android is unchanged: `{ nonce, token }`. Missing `key_id`/`kind` on an iOS device returns 400 `ERR_INVALID_ARGUMENT`.

---

## 2026-09-17 — Claude Code — M3 foundation hand-off: one change to the key wiring

Thanks — M3.7–M3.10 were already verified, and the C.1 wiring into the M2 screens is a good catch. One change before
the M3 screens copy the pattern:

| # | Change | Severity |
|---|---|---|
| M3.14 | Your 8 call sites create the key inline, so tapping again after an error sends a new key. If the first call timed out but the server finished, that repeats it — a second paid ID lookup, a duplicate KYC step. Hold one key per user intent in the page state: create it when the intent starts, reuse it on every retry, replace it after success or when the input changes (for `submitIdLookup`, when the ID type or number changes). Safe with the backend: a call that fails with an error rolls back its key claim, so the same key runs again; only a finished call replays | Medium |

My earlier cross-cutting note said "fresh per attempt"; that was wrong and is corrected in `docs/plan/ui-draft-review.md`.
V.1–V.5 from the contracts preview are still open (not urgent). The M3 screen review starts when you commit them.

---

## 2026-09-17 — Kimi Code — M3 foundation complete + review fixes M3.7–M3.10

### Applied (your M3 progress check, all four items)
- **M3.7** — `newIdempotencyKey()` no longer throws: the 74 random bits are composed from 32-bit
  `Random.secure()` draws (`_nextBits`); UUIDv7 layout (version 7, variant 10) unchanged and
  covered by the existing regex/uniqueness test.
- **M3.8** — mock idempotency now stores an argument hash per key; the same key with a different
  payload throws `ERR_IDEMPOTENCY_KEY_REUSED` (new `ErrorCodes.idempotencyKeyReused`), a matching
  payload replays. Wired at every payload-bearing call site (amounts, offer counters, chat,
  withdrawals, concierge send, ID lookup, …).
- **M3.9** — `verifyHandoverPin(jobId, pin, {idempotencyKey})` on interface + mock. The mock
  counts wrong-PIN attempts per job and locks out after 5 (`ERR_PERMISSION_DENIED`); a same-key
  retry replays without spending an attempt.
- **M3.10** — the concierge's underlying draft `JobRequest` is created from the FIRST saved slot
  and synced as later turns fill slots, so half-finished concierge drafts are resumable (CU-01).
  Publishing still goes through `RequestRepository.publishRequest` (verification-gated).

### Also in this pass
- Finished the half-applied C.1 refactor: `MockProviderKycRepository.saveOnboarding`/`submitStep`/
  `submitForReview` now take `idempotencyKey`; all stale tests updated; M2 screens in `apps/mobile`
  pass one fresh key per user intent (8 call sites).
- Verification: analyze zero issues in core/domain/data/mobile; tests 94/94 green
  (core 9, domain 21, data 64); format clean.

### Next
- M3 screens: request creation, AI concierge UI (text + voice behind per-language flag),
  offers and negotiation — on mocks, honoring A.1–A.7 (money fields only from UI controls,
  publish card via `publishRequest`, `handoff_to_form` exit, `show_sos_card`).

---

## 2026-09-17 — Claude Code — contracts/v1-preview: error codes, Auth mapping, enums, Money (not binding)

Your `ErrorCodes` comment calls it a placeholder until the official error-code contract exists. Official v1 still waits
for M8.5, but the pieces we both already use are now pinned in `contracts/v1-preview/`, and CI keeps them in step with
the backend code (`contracts.yaml`):

| File | Use it for |
|---|---|
| `error-codes.json` | Every code: raised by the backend today (`implemented`), reserved for a documented rule (`planned`), or produced only by the app (`client`); with HTTP status, retryability and what the app should do. 28 of your 30 codes are in it; the other two are V.2 and V.3 below |
| `auth-error-mapping.json` | Supabase Auth codes (`otp_expired`, `over_sms_send_rate_limit`, `insufficient_aal`, and others) to app codes |
| `enums.json` | Generated from the migrations; matches your `@JsonValue` wire values |
| `money.schema.json` | `{ "amount_minor": 1250000, "currency": "NGN" }` |

Changes for you (none urgent; before wiring the real backend at M9):

| # | Change |
|---|---|
| V.1 | `Money.fromJson` / `toJson`: keys `amount_minor` and `currency` (today `minorUnits` / `currency`) — review C.7 |
| V.2 | Rename `ERR_COUNTRY_DISABLED` to `ERR_COUNTRY_NOT_SUPPORTED` |
| V.3 | Drop `ERR_WITHDRAWAL_NEEDS_APPROVAL`: a withdrawal above the approval threshold succeeds with a pending-approval status |
| V.4 | Add the codes your app can receive that it lacks: `ERR_INVALID_ARGUMENT`, `ERR_IDEMPOTENCY_KEY_INVALID`, `ERR_IDEMPOTENCY_IN_PROGRESS` (retry with the same key), `ERR_PROFILE_NOT_FOUND`, `ERR_LANGUAGE_NOT_SUPPORTED`, `ERR_DEVICE_NOT_FOUND`, `ERR_INTEGRITY_NONCE_INVALID`, `ERR_INTERNAL` (retry), and the planned `ERR_ILLEGAL_TRANSITION`, `ERR_OFFER_NOT_ACTIVE`, `ERR_PRICE_OUT_OF_RANGE` |
| V.5 | Read database-function errors from the PostgREST `message` field, Edge Function errors from `error.code`, and Auth errors from `AuthApiException.code` through the mapping file |

Request changes through `contracts/CHANGE_REQUESTS.md` as usual.

---

## 2026-09-17 — Claude Code — M3 follow-up check: all fixes verified

Thanks — M3.7, M3.8, M3.9 and M3.10 are all fixed, and I verified rather than just read them: 20,000 generated keys
are valid unique UUIDv7s; the mock refuses a reused key with a different payload; `verifyHandoverPin` takes a key;
`requestId` is set from the first saved slot. Your package suites pass on the current working tree (core 9, domain 21,
data 64 — run from a copy, your tree untouched).

Nothing blocking. Two low notes for when the screens land (details in `docs/plan/ui-draft-review.md`):
- M3.13: include pickup, destination, schedule and money fields in `createRequest`'s argument hash.
- M3.12: the backend refuses one key reused for a different offer or operation; your mock scopes keys per target, so
  it replays instead. Fine for now; contracts v1 documents the backend rule.

When you commit M3 with the request, concierge and offer screens, I'll review them against the PRD (CU-01…CU-15),
the offer state machine and the AI design.

---

## 2026-09-16 — Claude Code — M3 progress check (your uncommitted package changes)

Nice work on the foundation review: C.1 idempotency keys (25 signatures), M3.1 no `publishDraft`, M3.2 `proposedAction`,
M3.4 voice languages from bootstrap and M3.5 monotonic `ServerClock` all landed. No M3 screens exist in `apps/` yet,
so the UI review waits for them. Before the screens start calling these methods:

| # | Change | Severity |
|---|---|---|
| M3.7 | **`newIdempotencyKey()` throws on every call**: `Random.secure().nextInt(1 << 62)` exceeds Dart's 2^32 limit (reproduced: `RangeError (max): Must be positive and <= 2^32`). Build the 74 random bits from several `nextInt(1 << 32)` draws or 10 random bytes; keep version `7` and variant `10`. Your existing regex test in `core_test.dart` will confirm | **High** |
| M3.8 | Mock idempotency ignores the payload: the same key with a different amount replays the old result. The backend refuses that with `ERR_IDEMPOTENCY_KEY_REUSED` — please store an argument hash and throw that code on mismatch | Medium |
| M3.9 | `verifyHandoverPin` needs an `idempotencyKey` (`verify_pin` counts attempts; a retry must not spend a second one) | Medium |
| M3.10 | Set `ConciergeDraft.requestId` from the first saved slot, not only when complete, so a customer can resume a half-finished concierge draft (CU-01) | Low |

Backend side: `remote_config.voice_languages` is now `{"en": true, "pcm": false}` to match your `voiceLanguages` map.
Details: `docs/plan/ui-draft-review.md` → "M3 progress check".

---

## 2026-09-16 — Claude Code — Phase 2: observability and Terraform

Backend observability and GCP infrastructure-as-code landed (`supabase/functions/health`, `_shared/observability.ts`,
migration `…120900_health_checks`, `infra/terraform`). One thing for you:

| # | What | For you |
|---|---|---|
| P2.7 | Every Edge Function response now carries an **`x-request-id`** header, and a 500 body includes `error.request_id` | Attach it to Sentry breadcrumbs / support tickets in the apps so a user report can be traced to one backend log line |

---

## 2026-09-16 — Claude Code — Phase 2: Edge Functions for OTP and device integrity

Two Edge Functions and their DB side landed (`supabase/functions/`, migration `…120800_device_integrity`). What
they mean for the app (all pre-contract; final shapes in contracts v1):

| # | What | For you |
|---|---|---|
| P2.4 | **Phone OTP** goes through our `auth-send-sms` hook. Numbers outside live/beta countries fail with `ERR_COUNTRY_NOT_SUPPORTED`; provider failure is `ERR_SMS_DELIVERY_FAILED` | Localized messages on the OTP screen; retry button for the delivery failure |
| P2.5 | **OTP autofill**: the SMS ends with the Android SMS Retriever app hash when configured — no `READ_SMS` permission needed | Use the SMS Retriever API; send me the app hash per flavor when signing keys exist |
| P2.6 | **Device integrity flow** for sensitive actions: `register_device(...)` → `request_integrity_nonce(device_id, purpose)` (purposes: `register_device`, `sign_in`, `go_online`, `payment`, `withdrawal`, `payout_account_change`, `sos`) → Play Integrity classic request with that nonce → POST `{ nonce, token }` to `/functions/v1/device-integrity` with the user JWT → `{ status: pass/fail/unevaluated, reasons, purpose }` | Nonces are single use and expire after 5 min. iOS returns `unevaluated` until App Attest verification is built — design the UI so `unevaluated` never blocks a user today |

---

## 2026-09-16 — Claude Code — Phase 2 started: backend database foundation

With the user's approval, backend Phase 2 started before contracts v1 (ADR-0013). New: `supabase/` (config, 8 migrations,
dev seed, pgTAP suites) and `.github/workflows/backend-db.yaml` (path-filtered to `supabase/**`, so it never touches
`frontend-ci.yaml`). Nothing changes for your mocks yet, but three things are now real and worth aligning with:

| # | What | For you |
|---|---|---|
| P2.1 | **Enum wire values** exist as Postgres enums and match your snake_case `@JsonValue` mappings exactly (`job_status`, `offer_status`, `payment_status`, `verification_status`, `kyc_step_*`, `trust_level`, etc.) | Treat any rename as a contract change from now on |
| P2.2 | **Error convention**: the message is the stable code — `28000 ERR_UNAUTHENTICATED`, `42501 ERR_*`, `P0001` business rules (`ERR_PROVIDER_NOT_VERIFIED`, `ERR_IDEMPOTENCY_KEY_REUSED`, `ERR_COUNTRY_NOT_SUPPORTED`…), `22023 ERR_*` invalid input | Same codes your `AppError` already uses |
| P2.3 | **`get_bootstrap(country_code, platform)`** returns `server_time`, `min_supported_app_version` (per platform), live/beta `countries`, a client-safe `country_pack` (with currency exponent), `feature_flags`, client `remote_config` (incl. `voice_languages`, M3.4) and `user`. Shape is **pre-contract** — final in contracts v1 | No action; your `AppBootstrap` maps closely |

Phone sign-up is refused server-side for numbers outside live/beta countries (`ERR_COUNTRY_NOT_SUPPORTED`, R-31) — worth a
localized message on the phone screen.

---

## 2026-09-16 — Claude Code — Phase 1 Stage A complete: revised timeline

`docs/plan/timeline.md` closes Stage A (13 of 13). Base case launch is the week of **7 June 2027** (range late April to
early August), set by external lead times — merchant onboarding, counsel, KYC contract, devices, pen test, store
review — not by coding speed.

What it assumes from you (tell me if any of these is wrong): M3 by 27 Sep, one milestone a week through M8, and
**M8.5 around 2 Nov 2026** with the demo APK, TestFlight build and web previews. TestFlight needs the client's Apple
Developer organisation account, which is on the client action list. Stage B (contracts v1) starts the day M8.5 lands.

---

## 2026-09-16 — Claude Code — Phase 1: PRD (147 user stories)

`docs/plan/prd/` — personas, non-functional requirements and 147 stories with acceptance criteria, split by surface:
`shared.md` (SH), `customer.md` (CU), `provider.md` (PR), `business.md` (BU), `web.md` (WB, MK), `admin.md` (AD).

For you: at M8.5 your screen inventory gets mapped onto these story IDs, so a screen with no story (or a story with
no screen) becomes a UI change-list item. Tagging screens or routes with story IDs as you build (e.g. `CU-12`) would
make that mapping mechanical. Three stories mention your current work directly: CU-01/CU-02 (concierge: publish
card, form hand-off, SOS card, money fields only from UI controls), SH-17 (push payloads carry only an id) and
SH-25 (Android Contact Picker for trusted contacts). WB-03 assumes the voice concierge is app-only on the web at
launch — tell me if you plan otherwise.

---

## 2026-09-16 — Claude Code — M3 foundation review (your uncommitted domain/data/core changes)

Thanks. C.2, C.3, C.4, C.6, snake_case enums and `serverTime` all landed well. Before the M3 UI builds on it
(details: `docs/plan/ui-draft-review.md` → "M3 foundation"):

| # | Change | Severity |
|---|---|---|
| C.1 | **Idempotency keys are still missing** on every mutating method — now also `publishRequest`, `withdrawOffer`, `publishDraft`, concierge `sendMessage`. Please do this before the M3 screens multiply the call sites | High |
| M3.1 | **Drop `ConciergeRepository.publishDraft`.** The concierge keeps a server-side draft; `ConciergeDraft` carries `requestId`; the publish card's button calls `RequestRepository.publishRequest(requestId, idempotencyKey)`. The AI path must not hold a publish capability (ai-design §4.2) | Medium |
| M3.2 | Replace `readyToPublish` with a `proposedAction` enum on assistant messages: `none`, `show_publish_card`, `show_offer_comparison`, `show_sos_card`, `handoff_to_form` — the last two need UI | Medium |
| M3.4 | Pidgin voice availability from a per-language flag, not hardcoded in the adapter (S-08 may pass) | Low |
| M3.5 | `ServerClock`: use a monotonic `Stopwatch`, not `DateTime.now()` differences | Low |

---

## 2026-09-16 — Claude Code — Phase 1: AI design, infra/CI-CD plan, test strategy

New in `docs/plan/`: `ai-design.md`, `infra-cicd.md`, `test-strategy.md`. New open decisions OD-20 (client recruits
native Pidgin speakers for evals) and OD-21 (moderation outage behaviour). Stage A has the PRD and timeline left.

**What the AI design means for your M3 concierge UI** (text + voice):

| # | Rule | Why |
|---|---|---|
| A.1 | The concierge **never publishes, accepts or pays**. Each turn returns `proposed_action`: `none`, `show_publish_card`, `show_offer_comparison`, `show_sos_card` or `handoff_to_form`. The UI renders the card; the user's tap calls the normal RPC with the app's own idempotency key | Spec: publishing with user confirmation; AI never moves money |
| A.2 | **Money fields are never filled by the model.** Preferred price, item float and declared value come only from UI controls, even inside the concierge flow | ai-design §5.3 |
| A.3 | `handoff_to_form` opens the ordinary request form **prefilled with the slots so far**. The concierge must always have this exit (budgets, outages, kill switch) | ai-design §6.5 |
| A.4 | `show_sos_card` puts the SOS button and the country's emergency numbers on screen first and pauses the errand flow | ai-design §6.4 |
| A.5 | Price bands carry `basis` (`rules`/`history`) and `sample_size`; label a `rules` band as a rough guide | ai-design §9 |
| A.6 | Voice: send the Supabase JWT to the agent **only by a targeted LiveKit RPC/data message**, never in room or participant metadata, and re-send on refresh | ADR-0012, ai-design §7 |
| A.7 | Pidgin voice may ship as **text-only** if it fails the S-08 gate (OD-17) — keep the voice entry point behind a per-language flag | R-03 |

**Two questions for you** (from `infra-cicd.md` §11 and `test-strategy.md` §9): the **web hosting** target for the three Next.js apps (I-2), and the **minimum OS floor** — I propose Android 8.0 (API 26) and iOS 15, which matches your current iOS target (T-2). Backend CI will use path filters and never touch `frontend-ci.yaml`.

---

## 2026-09-16 — Claude Code — M2 code review (commit `e473c9b`)

Read the committed `suskii_domain` + mock layer against the backend plan. Good work: no client-side money
arithmetic, no "escrow" in either locale, reason keys not free text, upload-only KYC refs, vendor SDK behind an
adapter, and `requestStatusChange` maps onto `set_job_status`. Full table: `docs/plan/ui-draft-review.md` →
"M2 code review". Please fold into M3:

| # | Change | Severity |
|---|---|---|
| C.1 | **Add `idempotencyKey` to every mutating repository method** — one key per user intent (UUIDv7), reused only when retrying that same intent | High |
| C.2 | **Remove `matchGovernmentId` / `matchedName` from the device adapter.** ID lookup is server-side via `submitIdLookup` and returns outcome + `reasonKey` only; returning the registry name lets anyone map a NIN to a full name. Liveness capture stays on the adapter; payout `resolvedName` is fine | High |
| C.3 | `publishRequest` (verification gate, per 2.14) | Medium |
| C.4 | `withdrawOffer` for providers | Medium |
| C.6 | `Money`: unknown currency must not silently default to exponent 2 — throw in debug; exponents will ship in the country pack | Medium |

C.5, C.7, C.8 (evidence refs on status changes, `amount_minor` JSON key, storage object keys) are contract items for Stage B — no action now.

---

## 2026-09-24 — Kimi Code — Milestone M2 (complete): Auth, facial verification UI, provider KYC UI

### Delivered (UI half — data/domain half in the 2026-09-23 entry below)
- `suskii_l10n`: ~85 new keys in en + pcm (welcome/countries, email auth, MFA, consent/liveness/ID
  copy, all KYC step titles/bodies/statuses, rejection reasons, 5 new error messages).
- `apps/mobile`:
  - `/welcome` — country selection (NG live; KE/GH/ZA beta chips via `getCountryPack`) + language
    picker; first-run gate welcome → onboarding → auth.
  - Auth — segmented phone/email OTP; Google/Apple disabled with "coming soon" (mock throws
    `ERR_FEATURE_UNAVAILABLE`); `/auth/mfa` skippable MFA preview.
  - `/verify/customer` — consent (explicit biometric consent) → simulated liveness via
    `IdentityVerificationAdapter` (failure + retry states) → ID lookup (NIN/BVN/voter's card/
    driver's licence/passport) → live result via `watchCustomerVerification`.
  - `/provider/onboarding` — individual/business, services, areas, vehicle; `/provider/kyc` —
    9-step checklist with live status flips, per-step forms, separate criminal-record consent on
    police clearance, simulated upload-only refs, payout name-match preview via
    `resolvePayoutAccount`, submit-for-review with `ERR_KYC_INCOMPLETE` handling.
  - Router: unverified provider-mode attempts → provider onboarding; verify banner on customer
    home until verified; profile rows wired to both flows.
- Verification: `flutter analyze` zero issues; tests 57/57 green (core 4, data 39, design 5,
  domain 9); format clean. No on-device run yet.

### Decisions (Kimi scope)
- No real KYC/camera SDK in M2 — liveness + capture simulated behind `IdentityVerificationAdapter`;
  Smile ID v11/v12 stays with spike S-05. No new dependencies added.
- Welcome-seen / MFA-ack flags are in-memory until a persistence layer lands (Drift, specced).

### Claude's M2 screen review — accepted, scheduled as M3 prep (not yet applied)
1. Move customer-verification check from createRequest to publishing with `ERR_VERIFICATION_REQUIRED`.
2. Push payloads carry only an id; fetch content after unlock (applies when notifications land).
3. Never cache KYC captures on device after upload (simulated refs only today — keep it that way).
4. Contract additions accepted: ID types in country pack, `list_service_areas`,
   `list_payout_institutions` (incl. mobile money), `mfa_enrolled` on session — UI hardcodes
   country list/ID types/bank field until then.
Plus the earlier Stage A list for M3+: snake_case `@JsonValue` enum mappings, `server_time` in
bootstrap for countdowns, selfie-check on go-online launches liveness, expiry-aware police
clearance states, consent versioning.

### Next
- M3: request creation, AI concierge UI (text + voice), offers and negotiation — on mocks, with the
  review items above folded in where they touch M3 surfaces.

---

## 2026-09-16 — Claude Code — Phase 1: money flows, C4 architecture, threat model, data-flow diagram

New in `docs/plan/`: `money-flows.md` (17 verified ledger postings), `architecture-c4.md`, `threat-model.md`
(STRIDE per component), `data-flow.md` (data classes, trust boundaries, 26 flows). New ADRs: 0011 (chart of
accounts) and **0012 — the AI concierge and voice agent call tools with the end user's JWT, never the service
role**, so a prompt-injected concierge can only do what the user could already do.

I also reviewed your new M2 screens (`ui-draft-review.md` → "M2 screens"). They are good; four things for you:

| # | Change | Why |
|---|---|---|
| 1 | **Move the customer-verification check from `createRequest` to publishing**, and use a specific `ERR_VERIFICATION_REQUIRED` so the UI routes to `/verify/customer` | Spec: unverified customers may browse and use the AI concierge; only publishing and paying require verification. Blocking at create would stop the concierge drafting for them |
| 2 | **Push payloads carry only an id** — no message text, addresses or amounts; fetch content after unlock | Push transits Google/Apple and shows on the lock screen (data-flow flow 18) |
| 3 | **Never cache KYC captures on the device** after upload | Biometric and ID images (data-flow flows 2, 4, 5) |
| 4 | Contract additions accepted from your "open needs": ID types in the country pack, `list_service_areas`, `list_payout_institutions` (**covers mobile money, not only banks**), `mfa_enrolled` on the session | Your M2 requests |

---

## 2026-09-16 — Claude Code — Phase 1 Stage A started: state machines, ERD, RLS matrix, draft review

Phase 1 is split because contracts v1 needs your complete UI inventory at M8.5. **Stage A (now)** is the
backend truth that does not depend on your screens; **Stage B (contracts v1 + fixtures)** waits for M8.5.
Everything is in `docs/plan/` — start with `PHASE-1-PLAN.md`.

- `state-machines/job-lifecycle.md` — 20 states, 31 transitions with actor, guard, side effects, timeouts.
- `state-machines/offer-negotiation.md` — offer states, thread and round rules, pricing guardrails.
- `erd.md` — every table, key, constraint, index, partition and schema placement.
- `rls-policy-matrix.md` — role × table × operation × **writable columns**, plus storage and realtime rules.
- `ui-draft-review.md` — review of your M1/M2 draft.

**Headline for you: M1 and M2 contain no client-side business logic that must move server-side.** Your
domain names were adopted where they differed from mine: `OfferStatus` `pending`/`declined`,
`commissionRateBps` as integer basis points, and `PaymentStatus.partiallyRefunded` for partial refunds
(so no extra job state). `JobStatus` already matches the spec's 20 states exactly.

### UI change list (from `docs/plan/ui-draft-review.md`)

| # | Change | Why |
|---|---|---|
| 1 | **Enum wire values are `snake_case`** (`offers_received`) — add `@JsonValue` mappings to the camelCase Dart enums | Postgres and Supabase-generated types use snake_case; cheaper to settle before M3 adds more enums |
| 2 | **Add `server_time` to bootstrap** and render every countdown (offer TTL, payment TTL, auto-confirm) against server time with a measured offset | A device with a wrong clock otherwise shows the wrong deadline |
| 3 | **Provider "go online" must handle `ERR_SELFIE_CHECK_REQUIRED` by launching a liveness session**, not only showing an error | Recurring selfie check is a spec rule and the OD-13 cost driver |
| 4 | **Police clearance needs expiry-aware states** — "expiring in N days" and "expired, job acceptance blocked", from server-supplied dates | Nigerian certificates last ~3 months (OD-09) |
| 5 | **Consent versioning** — a "consent out of date, please re-accept" path, not only first-time consent | Legal text changes must trigger re-consent (DPIA) |
| 6 | `Urgency` has four levels — no change for you; the backend country packs are adding the fourth | Alignment note only |

Already communicated earlier and still standing: idempotency keys per user action, `Money` reads the
currency exponent (never `/100`), "held by Suskii" never "escrow", and the Contact Picker for trusted contacts.

---

## 2026-09-16 — Claude Code — Two more spikes added and passed: S-13 (RLS) and S-14 (money)

None of the ten remaining planned spikes can run without credentials or devices, so I added two that
need neither. Both run on the local portable Postgres and both found real fixes.

- **S-13 — access control, 17/17 passed.** Emulates Supabase locally (anon / authenticated /
  service_role, `auth.uid()` from `request.jwt.claims`) and asserts allow **and** deny cases by
  SQLSTATE. Headline finding: **RLS alone does not protect a column** — a user owns the row and can
  rewrite `status`, `trust_level` or `agreed_amount_minor` unless column-level `GRANT UPDATE (...)`
  restricts it. The Phase 1 policy matrix will therefore carry a "writable columns" column.
- **S-14 — money, 24/24 passed.** The spec worked example reproduces exactly (100.00 → 12.50
  commission → 87.50 net → 2.19 referral → 10.31 platform revenue). Headline finding: **Postgres
  `round()` is half-away-from-zero, not half-even**. At a 12.5% rate exact .5 ties are common, so the
  built-in would drift the ledger by one minor unit per affected job, always the same direction.

### For Kimi Code

- **`Money` must read the currency exponent, not divide by 100.** S-14 keeps exponents in a
  `currencies` table (UGX = 0, the rest 2). Your `suskii_domain` exponent table already matches —
  worth keeping a golden test for UGX so a later refactor cannot reintroduce `/100`.
- The client must never compute commission, referral or payout, even for display. Those are single
  server-side calculations snapshotted on the job; the UI shows the server breakdown (already your
  design — this spike is the backend proof of it).

---

## 2026-09-16 — Claude Code — S-06 and S-10 passed (no Docker needed); S-07 blocked on billing

Status board: `docs/research/spikes/README.md`.

- **S-06 (PostGIS nearest provider) and S-10 (offer-acceptance races): both PASSED.** Docker would not
  install, so they ran on portable PostgreSQL 17.5 + PostGIS 3.6 — no installer, no admin rights
  (`spikes/postgres/setup-local-windows.sh`, one command).
  - S-06: p95 **1.87 ms** against a 50 ms target at the production write rate for 1M MAU; passes to
    ~10× that. The limit is row churn and bloat, not the query.
  - S-10: **zero double acceptances in 750 concurrent attempts**, zero deadlocks, including
    same-offer and same-key contention.
  - Risks R-11 and R-12 downgraded from High/Critical to Medium on measured evidence.
- **S-07 (Gemini): still blocked, but the earlier diagnosis was wrong.** The API is now enabled; the
  first 403s came from a missing quota project. The real blocker is that the GCP project has no
  billing and both billing accounts on the Google account are closed.
- Both write-ups record the harness bugs that first produced *misleading passes* — worth reading if
  you write load or concurrency tests: `docs/research/spikes/S-06-results.md` §"The harness was wrong
  first" and `S-10-results.md`.

### For Kimi Code (M2-relevant)

- **Idempotency keys must be generated per user action**, not per screen or per session. S-10 shows a
  reused key correctly replays the earlier result — which in a UI would look like a successful accept
  that did nothing. This applies to your accept/counter/pay actions in M3 and M4.
- **Losing callers in an offer race need a friendly message**, not a raw error. Contracts v1 will map
  these to stable codes; plan UI copy along the lines of "Another provider was just selected".
- Nothing in `apps/` or `packages/` was touched. `spikes/` stays untracked on `main` by design.

---

## 2026-09-23 — Kimi Code — M2 data/domain foundation (verification + KYC)

### Delivered
- `packages/suskii_domain`:
  - New enums: `KycStepKind` (10 step kinds), `KycStepStatus` (7 states), `IdentityCheckOutcome`.
  - New entities (`src/entities/verification.dart`, freezed + json): `KycStep`, `VerificationSession`,
    `ProviderKycProfile`, `PayoutAccountResult`; input DTOs (`PoliceClearanceInput`, `IdDocumentInput`,
    `AddressInput`, `GuarantorInput`, `PayoutAccountInput`, `VehicleDocumentsInput`, `CredentialsInput`,
    `ProviderOnboardingInput`). Rejection reasons are localization keys, never free text.
  - New interfaces (`src/repositories/repositories.dart`): `IdentityVerificationAdapter` (vendor-neutral;
    Smile ID plugs in after spike S-05), `VerificationRepository` (customer facial flow with consent
    gating + `watchCustomerVerification`), `ProviderKycRepository` (onboarding, typed `submitStep`,
    server-side `resolvePayoutAccount` name match, `submitForReview` gating).
  - `AuthRepository` extended: email OTP + `signInWithGoogle`/`signInWithApple` placeholders.
- `packages/suskii_core`: new `ErrorCodes` — `featureUnavailable`, `consentRequired`,
  `verificationRejected`, `kycStepInvalid`, `kycIncomplete`.
- `packages/suskii_data`: `MockIdentityVerificationAdapter` (`failLiveness` flag), consent-gated
  `MockVerificationRepository` (in-review → verified flip after `MockBehavior.kycReviewDelay`),
  `MockProviderKycRepository` (full step state machine; expired police clearance rejected server-side
  with `kycRejectPoliceClearanceExpired`; payout name match false when account ends in `00`).
  Personas: `user-chidi` = unverified, `user-emeka` = rejected police clearance, `user-ada` = verified.
- Tests: 20 new (`test/mock_verification_test.dart`); data 39/39, domain 9/9 green; analyze clean.

### For Claude Code
- New data needs recorded in `contracts/draft/ui-data-requirements.md` (M2 section): consent records,
  KYC step outcomes + reason keys, payout name-match result, opaque upload refs (upload-only bucket),
  session expiry.
- Social sign-in (Google/Apple) is a placeholder throwing `ERR_FEATURE_UNAVAILABLE` — needs backend
  config before M2 screens ship it for real.

---

## 2026-09-16 — Claude Code — Spike runs: S-01 inconclusive, S-07 blocked, S-06/S-10 ready

Status board for all 12 spikes: `docs/research/spikes/README.md`.

- **S-01 (region latency): attempted, inconclusive.** The dev machine is behind a VPN egressing in
  Europe, so its latency ordering measures distance from that egress, not from Lagos. Two findings
  worth keeping: TCP timings are proxied in this environment and must not be trusted (every region
  returned the same ~131 ms floor), and ICMP works. Needs RIPE Atlas probes or testers on real SIMs
  in Lagos/Nairobi/Johannesburg. ADR-0008 (Supabase region) stays Proposed.
- **S-07 (Gemini evals): blocked.** Vertex returns 403 in every region including `us-central1`, so
  `aiplatform.googleapis.com` is not enabled on the available GCP project. Enabling it touches
  billing, so it is a client decision.
- **S-06 and S-10: harnesses written, unrun** — they need only Docker, which this machine lacks.
  Branch `spike/phase-0-runs`, folder `spikes/postgres/`. S-10 covers the critical offer-acceptance
  race (R-12) and its assertions become pgTAP tests later.
- **S-03, S-04, S-05 (device spikes)** need physical Tecno/Infinix/itel and iPhone hardware plus your
  app. Now that M1 is done, these are the next joint piece of work — worth agreeing who buys or
  rents the device matrix.

**For Kimi Code:** `spikes/` will show up as untracked in your `git status` on `main`. It is
deliberately not committed to `main` (throwaway spike code lives on `spike/*` branches), so please
leave it out of your commits — or add `spikes/` to `.gitignore`, which is your file.

---

## 2026-09-16 — Claude Code — Merged the backend docs into `main`

`main` now contains everything from the two Claude commits: `docs/` (research, ADRs, open decisions,
runbooks, audit), `CLAUDE.md`, `contracts/README.md`, `contracts/CHANGELOG.md` and `docs/spec/`.
It was a fast-forward, so there is no merge commit. The working branch `claude/phase-0-research` has
been deleted now that it is merged, so `main` is the only branch on the remote.

**For Kimi Code — your work is untouched, but read this before your next commit:**
- Nothing on disk changed. Your files (`apps/`, `packages/`, `AGENTS.md`, `HANDOFF.md`, `.github/`,
  `melos.yaml`, `pubspec.*`, `analysis_options.yaml`, `.gitignore`, `.fvmrc`, `README.md` edits) are
  still uncommitted and still yours to commit.
- The shared tree was fast-forwarded with `git reset --mixed origin/main`, so local `main` already
  matches the remote. You do **not** need to pull, and please do not `git pull` while files are
  uncommitted — a checkout could clash with untracked files.
- `git add -A` would now sweep in nothing of mine (my paths are committed and clean), so commit
  normally. Stage your own paths to be safe.

---

## 2026-09-16 — Claude Code — Backend doc scaffolding (ADRs, open decisions, runbooks, audit, contracts README)

### Delivered
- `docs/adr/` — index, template, and ADR-0001 to ADR-0010 writing up the Phase 0 decisions D-01 to D-10
  (wave-1 countries, funds-hold model, fee bearer, Flutterwave v3, Smile ID, model routing, encryption
  without pgsodium, Supabase region, location transport, rejected client packages).
- `docs/OPEN-DECISIONS.md` — the canonical OD-01 to OD-18 register (status, owner, needed-by phase).
  This replaces scattered lists; the checkpoint is now just a snapshot of it.
- `docs/runbooks/` — index of the 13 planned runbooks + template. `docs/audit/` — severity rules,
  audit log, and the project-specific checks the frontend audit will run.
- `contracts/README.md` and `contracts/CHANGELOG.md` — what contracts v1 will contain and the rules
  binding both agents. Your `draft/` and `CHANGE_REQUESTS.md` are untouched.
- `docs/README.md`, and `CLAUDE.md` now carries a maintenance policy (which doc updates on which trigger).

### For Kimi Code
- Nothing here blocks you, and nothing in `apps/` or `packages/` was touched.
- `docs/adr/0010-client-package-exclusions.md` is the authoritative list of packages not to adopt, with
  replacements. The audit checks lockfiles against it at every integration milestone.
- `contracts/README.md` lists the design constraints contracts v1 will honour, so you can shape mock
  repositories the same way now: server-computed quote/breakdown objects, requested status changes,
  idempotency keys, private per-job realtime channels, and "held" rather than "escrow" in copy.

---

## 2026-09-16 — Claude Code — Phase 0 (Deep Research) complete (run in parallel with Kimi M1)

### Delivered
- `docs/research/`:
  - REPORT (13 research tasks, evidence-tagged, with sources);
  - vendor decision matrix + package due diligence;
  - country pack drafts NG/KE/GH/ZA/UG;
  - compliance checklist + DPIA outline;
  - risk register (30 risks);
  - cost model at 1k/10k/100k/1M MAU;
  - spike plan (12 spikes);
  - `CHECKPOINT-PHASE-0.md`.
- `CLAUDE.md` at the repo root. No application code; `apps/` untouched.

### Findings that affect Kimi's work
- Don't adopt these packages:
  - `flutterwave_standard` (no verified publisher, stale) → the server creates a hosted checkout link; open it in a Custom Tab / SFSafariViewController;
  - `app_device_integrity` (stale) → a thin platform channel for Play Integrity / App Attest;
  - `background_locator_2` (abandoned);
  - `prembly_identity_kyc`.
- `flutter_background_geolocation` needs a **paid licence for release builds**. The free alternative is `flutter_foreground_task` + `geolocator`; spike S-04 decides.
- Smile ID has a new v12 Flutter SDK (`usesmileid` 12.1.1) alongside v11 `smile_id` 11.2.13. Keep KYC behind the adapter; S-05 picks the version on 2 GB devices. Web: `@smileid/web-sdk` 12.0.4.
- UI copy: held funds are "held by Suskii", **never "escrow"**.
- Trusted contacts: use the Android Contact Picker, not `READ_CONTACTS` (Play policy, Apr 2026).
- Play precise-location declaration opens Nov 2026 and is enforced 27 Jan 2027. The FGS types (location, phoneCall, microphone, dataSync) need demo videos. Full-screen intent is default-granted only to calling apps, so handle denial.
- Gemini Live does not list Nigerian Pidgin. Keep a text fallback in the voice concierge UI (OD-17).
- UGX has ISO 4217 exponent **0**. Make sure `Money` formatting uses the exponent table (mocks include NGN/KES/GHS/ZAR/USD; add UGX if Uganda is in scope).

### Decisions (Claude Code, become ADRs in Phase 1)
Recommendations D-01…D-10 are in `docs/research/CHECKPOINT-PHASE-0.md`. The main ones:
- Wave-1 countries: NG live; KE, GH, ZA, UG beta.
- Hold funds in our ledger + gateway Transfers (Flutterwave escrow is v2-only).
- Flutterwave v3 + Paystack as the second African rail.
- Supabase London region, provisional.
- Model IDs in remote config.
- No pgsodium.

### Open decisions (client)
- OD-01…OD-08 from the spec are unchanged.
- New and proposed: OD-09 police-clearance recency/renewal, OD-10 payout transfer fees, **OD-11 Stripe can't pay African providers → Paystack**, OD-12 funds-holding licensing per country, OD-13 selfie-check frequency (cost), OD-14 wave-1 countries, OD-15 data residency, OD-16 Swahili/Luganda, OD-17 Pidgin voice gate, OD-18 tax on referral payouts.

### Next
- Claude Code runs spikes S-01, S-02, S-03, S-04, S-05 and S-12 (the device spikes S-03, S-04 and S-05 with Kimi) on `spike/*` branches outside `apps/`.
- Phase 1 starts on Kimi's M8.5 hand-off.

---

## 2026-09-23 — Kimi Code — Repo setup + Milestone M1 (complete)

### Delivered
- Repo initialized as monorepo at https://github.com/Hubert24hrs/Suskii_Errands_Mobile
- `docs/spec/SUSKII_BUILD_PROMPT.json` saved verbatim from the client's build prompt (v3.1.0)
- `AGENTS.md` (Kimi Code instructions), this HANDOFF, `contracts/draft/ui-data-requirements.md` skeleton,
  `contracts/CHANGE_REQUESTS.md`
- M1 complete:
  - `packages/suskii_domain` — entities (bootstrap, catalog, chat, notification, offer, referral,
    request, user, wallet; freezed + json_serializable), `Money` (minor units + ISO 4217, exponent
    table incl. UGX exponent 0), `GeoPoint`, status enums, repository interfaces (one per feature;
    money/state/verification mutations are server-decided action requests).
  - `packages/suskii_core` — env config, `AppError` + stable `ErrorCodes`, logging, connectivity.
  - `packages/suskii_design` — token-driven design system (colors/typography/spacing/radius/elevation/
    motion, light+dark themes) + components (buttons, cards, chips, inputs, feedback, skeleton,
    states, timeline, rating, countdown). Placeholder brand tokens swappable via token files only.
  - `packages/suskii_l10n` — English + Nigerian Pidgin (`pcm`) ARB files + generated localizations.
  - `packages/suskii_data` — mock repositories for every domain interface with latency/offline/error
    switches and edge-case fixtures (multiple currencies, expired docs, unverified user, …).
  - `apps/mobile` — splash, startup-error, onboarding carousel, demo phone-OTP auth, Customer and
    Provider shells (own nav stacks via `StatefulShellRoute`), home/requests/messages/profile and
    feed/jobs/earnings screens, mode switch (Provider gated on verification), simulated-offline
    toggle, language + theme pickers. Every screen handles loading/empty/error/offline.
- Verification: `flutter analyze` — zero issues; tests 37/37 green (core 4, data 19, design 5,
  domain 9); `dart format` clean.

### Decisions made (Kimi scope)
- App ID placeholder `com.suskiierrands.mobile` until branding/legal entity is decided.
- Design tokens carry placeholder brand colors; swap = edit token files only.
- Nigerian Pidgin locale registered as `pcm`. Flutter's Material/Cupertino delegates have no `pcm`
  data, so Material widgets fall back to English for `pcm`; all app strings are translated.

### For Claude Code
- `CLAUDE.md` is yours to create (per your first_instruction) — point it at `docs/spec/SUSKII_BUILD_PROMPT.json`.
- `contracts/draft/ui-data-requirements.md` grows with each frontend milestone; treat it as input, not authority.

### Open decisions (client, from spec — keep visible until resolved)
- OD-01 referral commission funding (default: platform funds from its 12.5%)
- OD-02 referral duration (default: lifetime + admin-configurable cap)
- OD-03 both sides referred (default: 2.5% each, max 5% of net)
- OD-04 shopping item float (default: separate non-commissionable prepaid line)
- OD-05 insurance (default: none at launch; claims via disputes)
- OD-06 commission rate (default: 12.5%, per-country configurable)
- OD-07 launch countries (default: Nigeria first)
- OD-08 gateway fee on refunds (default: platform absorbs except late customer cancellations)

### Known issues / limitations (M1)
- No on-device run yet — compile-correctness via `flutter analyze` only.
- `ProviderJobsPage` and `MessagesPage` are empty-state-only: the M1 repository contracts expose no
  provider-job-list or conversation-list methods (wired in M4/M6).
- Riverpod 3.4.3 pinned: use `AsyncValue.value`, not `valueOrNull`.

### Plugin/SDK decisions pending (per spec "plugins_to_evaluate")
To be decided per milestone; paid SDKs (e.g. flutter_background_geolocation) NOT adopted without flagging here.
