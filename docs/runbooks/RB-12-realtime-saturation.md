# RB-12 — Realtime is at its limit, or a quota is about to bite

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | SEV2. Tracking degrades and chat stops feeling live; **no job, payment or safety path stops** |
| Last rehearsed | **Cannot be rehearsed yet.** Needs a Supabase project to measure against — see the blocker |
| Related | ADR-0009 (location is Broadcast, not table changes); ADR-0008; spike S-11; REPORT §9 [P2b]; RB-01, RB-13 |

## Blocker, stated plainly

**No Supabase project exists**, so the numbers below are the vendor's published limits rather than
anything measured here, and **spike S-11 (realtime load for location broadcast) has never run** — it
needs a project and k6 (client action 8, unstarted).

What that means for this runbook: the thresholds are `[V]` from Supabase's own documentation, the
*headroom* is arithmetic from the cost model, and the **projection of our own message rate is `[A]`
and unverified**. Run S-11 before the first live country and replace the italicised estimates with
measurements.

## The limits

| Plan | Connections | Messages/s | Joins/s | Channels per connection | Broadcast payload |
|---|---|---|---|---|---|
| Pro, spend cap **on** | 500 | 500 | — | — | — |
| Pro (no cap) / Team | 10,000 | 2,500 | 2,500 | 100 | 3 MB |
| Enterprise | configurable | | | | |

All `[V]`, REPORT §9 [P2b].

**The trap is the spend cap.** Pro with the spend cap on is 500 connections — twenty times smaller
than Pro with it off. A launch that hits 500 concurrent users would look like a platform-wide
realtime failure and the cause would be a billing checkbox. Confirm which mode the project is in
*before* a go-live, and put it in the RB-08 checklist.

At 1M MAU the cost model projects **~60k peak connections**, which is beyond Team and means an
Enterprise quota conversation. That conversation has a lead time, so it belongs on the roadmap, not
in an incident.

## What is actually on realtime

Five topics (`contracts/v1/realtime-events/channels.json`), all private, all authorised by
`private.may_join_topic`:

| Topic | Events | Volume shape |
|---|---|---|
| `job:{id}` | `job.status`, `chat.message`, `call.*`, `sos.raised` | One per active job |
| `request:{id}:customer` | `offer.created`, `offer.countered`, `offer.{status}`, `payment.checkout_ready` | Bursty during negotiation |
| `request:{id}:provider:{id}` | the same offer events, per provider | **The competitive invariant.** A provider never shares a topic with a rival |
| `user:{id}` | `notification` | One per signed-in user |
| `ops:sos` | `sos.raised`, `sos.escalated`, `sos.updated` | Rare, and never to be shed |

**The thing that makes this survivable:** ADR-0009 puts live location on Broadcast rather than
table changes, and a broadcast is a **courtesy, not a guarantee**. The tables are the truth and every
client refetches on reconnect. So saturation degrades the experience and loses nothing — as long as
nobody has built a screen that treats a broadcast as the only source of a fact.

## Symptoms

- Clients failing to join channels, or joining and receiving nothing.
- Tracking maps stale while the job itself progresses normally.
- Chat messages appearing only on refresh.
- Supabase dashboard showing connections or messages near the plan ceiling.

## Impact

Tracking, chat liveness and in-app notification arrival. **Not** job state, payments, verification or
SOS *recording* — `raise_sos` writes the row and the row is the truth; the broadcast is how the desk
finds out quickly, which is why `ops:sos` is the last thing to shed, not the first.

## Immediate actions (first 5 minutes)

1. Open the incident (RB-01). Say early that money and safety paths are unaffected, so the channel
   does not escalate past what this is.
2. Read the dashboard: connections, messages/s, joins/s, against the plan's ceiling.
3. **Check the spend cap.** If the project is on Pro with the cap on and you are near 500, that is
   the whole incident.
4. If a single client is looping joins, that is a client bug amplifying into an outage — find it
   before adding capacity, or you will buy headroom for a defect.

**Stop conditions.**

- **Never shed `ops:sos`.** If load-shedding is on the table, that topic is exempt.
- **Never move live location to table changes** to reduce message count. ADR-0009 decided that
  deliberately; Postgres changes at that rate is a much worse problem wearing a different hat.
- **Never widen a topic** to reduce channel count. Putting several providers on one request topic
  would let a provider see a rival's price, and the competitive invariant is not negotiable for
  capacity.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Connections vs ceiling | Supabase Realtime dashboard | Comfortably under, with headroom for the daily peak |
| Messages/s vs ceiling | same | Under, and not spiky in a way the job count does not explain |
| Joins/s | same | Steady. A join storm means clients reconnecting in a loop |
| Channels per connection | client behaviour | Well under 100. An app subscribing per list item will find this |
| Payload size | broadcast payloads | Far under 3 MB. Ours are small by design; a large one is a bug |
| Correlation with active jobs | `requests` in active states | Messages should track job count. If it does not, something is chattier than it should be |

## Resolution

**A. Spend cap.** Turn it off (billing decision, so it needs the right person), or accept 500 and
plan the upgrade. This is the fastest real fix and the most embarrassing one to discover late.

**B. Genuine growth.** Upgrade the plan, and start the Enterprise conversation early — the quota has
a lead time and 60k projected peak connections is not a same-week request.

**C. A client defect.** Join loops and per-item subscriptions are the two that show up. File it
against the app, and if it is actively harming everybody, switch off the feature that drives the
subscription (RB-13) until a fix ships.

**D. Shedding, in order.** If you must, and only if you must:

1. `offers.explain`-style enrichment and any non-essential enrichment events.
2. `request:{id}:*` offer broadcasts — the offers board refetches, so it degrades to a slightly
   stale board rather than a broken one.
3. `job:{id}` chat liveness — messages still send and still arrive; they just arrive on refresh.
4. **Never** `ops:sos`.

## Backout

Re-enable anything shed once headroom returns, in reverse order, watching the message rate after
each. A plan upgrade needs no backout.

## Communication

- **Internal:** the numbers, the ceiling, and which of the four causes it is.
- **Users:** only if tracking or chat is visibly degraded. Say that the job is fine and the map is
  behind — that is true and it is the thing they are worried about.
- **Supabase:** open a ticket early for an Enterprise quota. Ceilings are not negotiated during an
  incident.

## After

- **Run S-11 if it still has not run.** An incident is expensive evidence; a load test is cheap
  evidence, and this runbook's numbers stay `[A]` until one exists.
- Replace the projections above with measurements and re-tag them.
- If a client defect caused it, add the case to the frontend audit list in `HANDOFF.md`.
- Put the connection ceiling and the spend-cap state into RB-08's go-live checklist, if the incident
  showed they were not there.
