# RB-06 — Somebody has raised an SOS

| | |
|---|---|
| Owner | Ops (safety desk) — engineering supports, ops leads |
| Severity | **SEV1, always.** There is no triage step. A false alarm costs a phone call; the other mistake does not have a price |
| Last rehearsed | **Not yet.** Rehearse the console and the phone tree before the first live country — this is the one runbook where rehearsal is not optional |
| Related | Spec SH-24, AD-21; OD-25; `docs/plan/threat-model.md`; RB-01, RB-07, RB-13 |

## Read this first

**No SOS partner is contracted.** Client action 12 (a partner in Lagos, AURA/Rescue.co later) has
not started. `public.sos_partners` ships empty, and `integration` can be `api`, `console` or
`phone` — until a partner exists, **every escalation is a human picking up a telephone**.

That is not a reason to delay this runbook. It is the reason to have it: the fallback *is* the
procedure right now, and it needs to be written down before somebody needs it.

## What the system does on its own

1. `public.raise_sos` records the incident and broadcasts `sos.raised` to the `ops:sos` topic.
2. The safety desk sees it. Status is `open`.
3. If nobody acknowledges within the configured window — **three minutes**, per AD-21 — the
   `sos-escalate` cron (running **every minute**) stamps `escalated_at`, broadcasts `sos.escalated`
   and raises the alarm louder.
4. Status moves `open → acknowledged → dispatched → resolved`, with `false_alarm` as the other end.

The three-minute clock is the only automatic thing here. Everything after it is people.

**`raise_sos` is deliberately kept away from the AI.** It is on the deny list in
`services/ai/tools/allowlist.json` with a written rationale: an emergency must never depend on a
model understanding somebody. A human taps the button, or the button did not get tapped.

## Symptoms

`sos.raised` on `ops:sos`. That is it. There is no ambiguous version of this alert.

## Impact

A person may be in danger. Everything else on the incident board waits.

## Immediate actions (first 60 seconds — not five minutes)

1. **Acknowledge in the console.** This stops the three-minute escalation and tells the rest of the
   desk it is being handled. Acknowledging is not resolving.
2. **Call the person who raised it.** Their number is on the incident. Do not message first.
3. If they answer and are safe: `false_alarm`, with a note. Do not skip the note — a pattern of
   false alarms from one account is itself a signal.
4. If they do not answer, or answer and are not safe: **escalate now**, do not investigate first.
   - `[PARTNER]` API or console partner: dispatch through it.
   - **Today, with no partner:** call the local emergency number for the country, then the
     escalation phone on the matching `sos_partners` row if one is configured.
5. Only once help is moving: pull the job context — who the counterparty is, the trip trail, the
   last known location.

**Stop conditions.**

- **Never wait to confirm it is real.** The three minutes is the system's patience, not yours.
- **Never resolve an SOS to clear the board.** `resolved` means you know the outcome.
- **Never suspend or ban the counterparty as a reflex.** OD-25: what follows a flag is an explicit,
  bounded, audited decision by a person with the authority to take it. In the moment, get help
  moving; the account decision belongs to the review afterwards.
- **Never share the raiser's location with anyone except emergency services or the contracted
  partner.** Not with the counterparty, not in a general channel.

## Diagnosis

Do this **after** help is moving, never before.

| Check | Where | What it tells you |
|---|---|---|
| The job | `sos_incidents.request_id` → the job | Who else is there, and where they were going |
| Location trail | `public.job_trail(request_id)` | Where the provider has been. **Reading it writes an audit row**, which is correct: somebody must be accountable for having looked |
| Trusted contacts | `trusted_contacts` (numbers encrypted per ADR-0007) | Who to call if the person cannot be reached |
| Trip share | `trip_share_links` | Whether somebody outside is already watching |
| Counterparty history | `fraud_flags`, prior reports | Context for the review, **not** grounds for an on-the-spot decision |
| Escalation fired? | `sos_incidents.escalated_at` | If set, nobody acknowledged in three minutes — that is a desk failure to review |

## Resolution

1. Stay on the line, or keep calling, until help has arrived or the person is confirmed safe.
2. Record what happened in `update_sos_incident` as it happens, not afterwards from memory.
3. Move to `dispatched` when help is actually moving; `resolved` only when you know the outcome.
4. Hand over explicitly if a shift ends mid-incident. An SOS must never be inherited silently.

## Backout

There is nothing to back out. An SOS raised in error is closed as `false_alarm` with a note, and
that is a complete and honest outcome.

## Communication

- **The person who raised it:** stay with them.
- **Their trusted contacts:** if they cannot be reached and the contacts exist, call them. That is
  what they are for.
- **The counterparty:** only what safety requires. They may be a witness; they may be the subject.
  Say nothing that assumes either.
- **Head of Trust and Safety and the client:** every SOS, same day, regardless of outcome.
- **Regulator:** not for the SOS itself. If the incident involved a data exposure, RB-07 applies
  separately and its clocks start independently.
- **Press:** nobody on the desk. Route to the client.

## After the incident

- **Within 24 h**, a written timeline with the exact acknowledgement time. If the three minutes
  elapsed, that is the first finding and it is about staffing, not about the person on shift.
- Review the counterparty's account **as a separate, deliberate decision** with the evidence in
  front of the person taking it (OD-25). `suspend_provider` requires an end date, so a permanent
  ban is not something one function call can do — that is deliberate, and it is not to be worked
  around in the heat of an incident.
- Check whether the trusted contacts were reachable and whether the trip share was in use. Both are
  features people only discover they needed afterwards.
- `[PARTNER]` Once a partner exists, re-rehearse this whole runbook against them. A phone tree that
  worked in rehearsal against ourselves has proved nothing about them.
