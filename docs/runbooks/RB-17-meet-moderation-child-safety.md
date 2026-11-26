# RB-17 — Meet moderation, child safety and the review queues

| | |
|---|---|
| Owner | The owner as first reviewer (OD-41), then the `meet_moderator` team; Claude Code for the system half |
| Severity | **SEV1** for a suspected child, CSAM or a person in danger. SEV2 for an SLA breach on reports. SEV3 for the photo backlog |
| Status | **Draft, 2026-11-26.** Written in M0 from the design, before any Meet table exists. The SQL names objects M1 creates; check each query against the migrations when M1-PR4 lands, and correct this file in the same PR |
| Last rehearsed | Not yet. Cannot be until M1 is deployed to testers; rehearse sections 3 and 4 with a planted test report before `meet.v5` leaves testers |
| Related | [ADR-0026](../adr/0026-meet-v5-social-layer.md) (D2, D3, D16, D25); OD-25, OD-37, OD-41, OD-42, OD-49, OD-50, OD-52; [RB-01](RB-01-incident-response.md), [RB-06](RB-06-sos-escalation.md), [RB-07](RB-07-data-breach.md), [RB-13](RB-13-kill-switch-and-forced-update.md), [RB-15](RB-15-store-release.md); design §8.1–§8.4, §8.13 |

## Read this first

- **Every Meet photo is approved by a person before anyone else sees it** (OD-41, decided
  2026-11-26). There is no image-moderation vendor and no CSAM hash-matching vendor. The reviewer
  *is* the control.
- **The owner reviews alone at first.** Meet stays testers-only until reviews keep up, and two
  `meet_moderator` accounts with MFA are a readiness item the database checks before Meet can open
  to anyone else (ADR-0026 D23).
- **Only `meet_moderator` and `super_admin` see Meet cases and reports**, in their country scope.
  Support agents see nothing beyond whether someone has a Meet profile (D25). Do not paste Meet
  content into support tickets, chat channels or email.
- **The reporting route for child sexual abuse material is not yet confirmed by counsel (OD-42).**
  Until it is, section 4 says what to do instead. Never improvise a route.

## 1. Queues and service levels

The console's Meet queues are ordered by priority, then by `sla_due_at`:

| Priority | What | SLA (`meet.moderation.sla_hours`) |
|---|---|---|
| 1 | Child safety or underage: a report with reason `underage` or `child_safety`, a photo rejected as `underage_appearance`, an `underage` text hold on any surface, chat included | **2 hours** |
| 2 | Reports with evidence (every other reason) | 24 hours |
| 3 | First-photo pre-moderation, which blocks a new member's onboarding | 12 hours |
| 4 | Other photos and photo statuses | 12 hours |
| 5 | Text holds (bio, prompts, chat holds for `sexual`) | 48 hours |

"Asking for money or gifts" reports are priority 2 with a 24-hour SLA; an upheld one means a
suspension of at least 30 days, and a repeat goes to a permanent-ban request (design §8.8).

**The alarm.** The `meet-health` job (every 15 minutes) records `meet_moderation_sla` through
`private.record_health_check`; it warns when any item passes its `sla_due_at`. `meet_media_backlog`
warns when photos sit in `processing` (the media worker is behind or failing).

**Dashboard SQL** until `kpi_meet_safety` exists (M3). Run it in the Supabase SQL editor for the
right project, as the database owner: no Meet table is granted to any client role (design §2.2), and
the console has no SQL access. Counts only; never export rows:

```sql
-- Open work by priority, and how much is past its SLA.
select priority,
       count(*)                                   as open_items,
       count(*) filter (where sla_due_at < now()) as breached,
       min(sla_due_at)                            as oldest_due
from public.meet_reports
where status in ('open', 'reviewing', 'escalated')
group by priority
order by priority;

-- Photos waiting for review, oldest first (counts only).
select count(*) as pending, min(created_at) as oldest
from public.meet_photos
where status = 'pending_review';

-- Reports per 1,000 active profiles over the last 7 days (the rollout watch number).
select round(1000.0 * (select count(*) from public.meet_reports where created_at > now() - interval '7 days')
             / nullif((select count(*) from public.meet_profiles
                       where status = 'active' and last_active_on > current_date - 7), 0), 1)
       as reports_per_1000_active;
```

## 2. The photo review checklist

Open each photo in the console (a signed URL of at most 300 seconds). Never download it, screenshot
it or open it outside the console. Reject with the first reason that applies:

| Check | Reject as | What else happens |
|---|---|---|
| The person **appears under 18**, alone or with others | `underage_appearance` | **Discovery hold and a priority-1 child-safety review (section 3).** The member sees "rejected", never this reason |
| Nudity, sexual content or a sexual pose | `explicit` | — |
| A phone number, handle, QR code, link or email anywhere in the image | `contact_details` | — |
| Weapons used to threaten, gore, violence | `violence` | — |
| No person, or a person who cannot be seen (a car, a meme, a group with nobody identifiable as the member) | `not_a_person` | — |
| Clearly a celebrity, a stock photo or someone else | `not_you` | — |
| The same image as another account's (the console shows a hash match) | `reused` | A fraud flag (`meet_photo_reuse`) is raised automatically |
| Too dark, too small, heavily filtered | `low_quality` | — |

Approve only when none applies. **Never approve to clear a queue.** If unsure about age, treat it as
`underage_appearance`: the hold is reversible, the other mistake is not.

## 3. A child-safety report or an underage signal

The system has already, at report time:

- put the subject on a **discovery hold** (`hold_reason = 'child_safety_report'` or
  `'underage_report'`): they vanish from every set, list and Nearby view, and nothing tells them
  why (OD-49). It is a visibility hold, not a sanction;
- copied an **evidence snapshot** into `meet_report_evidence`, so deletion by either side cannot
  remove what you must review;
- given the item priority 1 and a 2-hour SLA.

**Within 2 hours:**

1. Open the report in the console and read the snapshot.
2. Decide which of these it is:
   - **An adult who looks young, or a false report.** Lift the hold, dismiss with a note. If the
     report looks malicious, a pattern of them from one reporter is itself a signal (`meet_report_cluster`).
   - **A probable minor** (they say so, the photos show it, the bio names a school year): suspend
     now with reason `underage`, for the longest your role allows, then have a `super_admin` request
     a permanent ban (section 5). Their devices are barred. The account's errands side is untouched
     unless a separate errands report says otherwise.
   - **Sexual content involving a minor, grooming, or a minor in danger:** go to section 4 now.
3. Write the outcome. The reporter is not told who or what; their confirmation already said "Our
   team reviews within 2 hours".

## 4. Suspected child sexual abuse material, grooming or a child in danger

**This is SEV1.** Wake the owner if it is not the owner reviewing.

1. **If a child may be in immediate danger, call the police** through the national emergency number
   (112 in Nigeria `[S]`), with what you know. Do not wait for anything below.
2. **Do not download, copy, forward, screenshot or re-share** the material, not even to a colleague
   or to counsel. It stays in the console and in the evidence store, where access is logged.
3. **Preserve.** The evidence snapshot is already copied. Make sure the report is not closed: an open
   report keeps `retain_until` from starting, so the purge cannot reach it.
4. **Remove and ban.** Uphold the case (the content comes down and its files are erased, except the
   evidence copies), suspend with reason `child_safety`, and have a `super_admin` request the
   permanent ban (section 5).
5. **Report through the confirmed route.** `[PENDING OD-42]` Counsel has not yet confirmed which
   Nigerian authority receives CSAM reports from a platform like this one, what evidence to send, or
   how long the law requires it kept. Until counsel answers: the owner contacts counsel **the same
   day**, with the report id only, and asks for the route. Write the answer into this section when it
   comes. Do not report through an unconfirmed channel, and do not let the open question delay steps
   1 to 4.
6. Record the timeline (RB-01) and keep it out of general channels.

**Stop conditions.**

- Never confront the subject, warn them, or tell them what was found.
- Never delete the account or the evidence to make the problem go away. The evidence snapshot
  survives the subject erasing their account (it is kept until `retain_until`), and nobody removes
  it by hand.
- Never review material on a personal device.

## 5. Bans and two-person approval

| Who | Can |
|---|---|
| `meet_moderator` | Suspend up to 30 days; lift their own suspensions of up to 30 days |
| `super_admin` | Suspend up to 365 days; lift any suspension |
| Two different people, each a `super_admin` | A **permanent** ban, only for `child_safety`, `underage` or `ban_evasion` |

A permanent ban is `admin_meet_suspend` with no end date, which only a `super_admin` can request
(a `meet_moderator` is capped at 30 days). It creates an `approvals` row (`meet_ban`) and applies
only when a **different** `super_admin` approves it with `admin_meet_approve_ban`, which no other
role can call (design §4.3). The four-eyes rule refuses the same person twice.

**Nobody can approve a permanent ban until a second `super_admin` exists.** A `meet_moderator`
cannot approve one, and the M1 readiness item adds two `meet_moderator` accounts, not a second
`super_admin`, so meeting readiness does not change this. Until there is one, suspend for the
longest the role allows (365 days as `super_admin`) so the person is off Meet at once, leave the
ban request pending, and have it approved once a second person holds a `super_admin` account. Do
not create a second account for yourself to approve your own ban.

Every suspension is an explicit, bounded, audited decision by a person (OD-25). Nothing in the
system suspends anyone automatically: strikes only rate-limit, and holds only hide.

## 6. Appeals

- **"I was refused as under 18 and I'm not."** The birth date is set once and a refused account's
  devices are barred for 365 days. The person writes to support with government ID; support passes
  the ticket to a `super_admin`, who checks the ID and, if it shows 18 or over, uses
  `admin_meet_correct_birth_date` with an evidence note. Never correct a date on the person's word,
  and never keep a copy of the ID outside the ticket.
- **"My photo was rejected."** Re-review once. If the reason was `underage_appearance`, the appeal
  goes through the ID route above, not a second photo look.
- **"I was suspended."** A different reviewer from the one who decided reads the case and either
  upholds or lifts it, with a note.

## 7. The contact filter's false positives, monthly

The filter blocks before delivery (OD-40), so innocent messages are refused. Once a month:

1. Count `meet_safety_events` by `kind` and `rule_keys` for the month. **Rule keys only: the table
   holds no message content, and nobody reads messages for this.**
2. Compare with the previous month and with the accepted false positives in
   `contracts/v1/fixtures/meet/contact_filter_cases.json`.
3. A rule whose count jumps, or a pattern support tickets keep naming ("I can't send my house
   number"), goes to Claude Code as a proposed rule change with a new test vector.
4. Restricted-term changes go through counsel (OD-24, OD-50); number-word changes through native
   speakers (OD-50).

## 8. Testers and rollout

1. Add testers with `admin_meet_set_tester` (super_admin, MFA, with a note).
2. Enable `meet.v5` with the payload `{"testers_only": true}` and the M1 feature flags for NG through
   the config-change flow. The readiness guard allows this before the checklist is complete.
3. The owner completes the m1 readiness items in the console: Play's Restrict Minor Access, Child
   Safety Standards, content rating, Data safety and listing; the CSAE page and
   `childsafety@suskiierrand.com` live; two `meet_moderator` accounts with MFA; **the Supabase plan
   upgrade and working daily backups** (OD-53); counsel's answers to OD-37, OD-38 and OD-42.
4. Only then switch `meet.v5` to general at `rollout_pct` 5, then 25, then 100. Between each step
   watch the SLA breaches, reports per 1,000 active profiles (section 1) and the filter's false
   positives (section 7). Hold the percentage if reviews fall behind: the rollout is the brake.
5. **To stop Meet:** disable `meet.v5` (RB-13). The guard never refuses a disable.

## 9. The 1.4.0 inbox note

Meet pushes go only to devices on 1.5.0 or later. But a Meet user who also has 1.4.0 installed
somewhere still gets the inbox row, and 1.4.0 may show the unknown title key raw ("notifMeet…").
That is cosmetic, affects Meet users only, and was accepted in the design (§2.8). When verifying a
release, check it on a 1.4.0 install once and note the result here; do not "fix" it by sending Meet
pushes to older versions.

## After an incident

- Timeline within 24 hours (RB-01), held privately for child-safety cases.
- A rule or checklist that let something through gets a new test vector or a new checklist line.
- Correct this runbook where it was wrong, and record the rehearsal in the header.
