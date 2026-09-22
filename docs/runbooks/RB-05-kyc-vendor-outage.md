# RB-05 — The identity vendor is down

| | |
|---|---|
| Owner | Claude Code / ops / Verification |
| Severity | SEV2. Not SEV1: nobody is in danger and no money is at risk. It is a growth stop, not an outage |
| Last rehearsed | **Not yet.** Rehearsable today against the queue; the vendor half cannot be rehearsed until a contract exists |
| Related | OD-13 (selfie-check frequency), ADR-0007; PRD SH-06, SH-07, PR-02…PR-08; RB-01, RB-13 |

## Read this first

**There is no identity vendor.** Smile ID is chosen on paper (OD-13) and not contracted — client
action 7, unstarted. What exists today is everything around the vendor: the `kyc` schema no client
role can reach, verification sessions and steps, the officer queue with a no-self-review rule,
blind-indexed identity documents, `audit.kyc_access` written *before* any URL is produced, and
document expiry that lapses the standing with it.

So this runbook covers the part that exists — the queue, the rules and the recovery — and marks the
vendor-specific steps `[VENDOR]`. Those cannot be rehearsed until there is a sandbox.

## The rule that does not bend

**No automatic approval, ever, for any reason, including this one.**

An outage makes the queue long. A long queue is an argument for more officers or a slower funnel.
It is never an argument for approving unverified people, because the verification is what stands
between the platform and somebody using a stranger's identity to be alone with a customer. If you
find yourself reasoning towards "just this once, to clear the backlog", stop and escalate to the
Head of Trust and Safety instead.

`public.decide_kyc_step` requires a human officer, refuses self-review, and writes an audit row. It
has no bypass and must not be given one.

## Symptoms

- `[VENDOR]` The vendor's status page, or timeouts from the liveness SDK.
- Users stuck on the verification screen; support tickets saying "it keeps failing".
- `kyc_review_queue` growing faster than it is drained; `kpi_verification_queue` climbing.
- Sign-ups completing but nobody reaching `verified`.

## Impact

- **Customers** can browse and draft but **cannot publish a request** — publishing requires
  `customer_verification = 'verified'` (job machine transition 2).
- **Providers** cannot complete onboarding, so supply stops growing.
- Nobody already verified is affected. Existing jobs, payments and chats are untouched.

That asymmetry is the whole shape of this incident: it hurts tomorrow's business, not today's users.

## Immediate actions (first 5 minutes)

1. Open the incident (RB-01). Say clearly that no one already verified is affected — it stops the
   channel from escalating past what this is.
2. Confirm the blast radius:
   ```sql
   SELECT status, count(*) FROM kyc.verification_sessions
   WHERE created_at > now() - interval '6 hours' GROUP BY 1;
   SELECT count(*) FROM public.kyc_review_queue();
   ```
3. `[VENDOR]` Confirm it is the vendor and not us: their status page, then a single manual sandbox
   call. A DNS or credential problem on our side looks identical from the app.
4. Turn off the screen that cannot work, rather than letting people fail repeatedly at it. Flip the
   verification entry flag (RB-13) and let the app show "verification is temporarily unavailable"
   instead of a liveness SDK that times out. A user who fails three times assumes they are the
   problem.

**Stop conditions.**

- **Never auto-approve.** See above.
- **Never approve from a document alone** because liveness is down. The document proves the identity
  exists; liveness proves the person presenting it is alive and present. They are different claims.
- **Never lower the bar per country** to keep a launch date. That is OD-13, and it is the client's
  decision to take in daylight, not on-call's to take at 3 a.m.
- **Never read a document** outside a review. `audit.kyc_access` records the read *before* the URL
  exists, and the officer queue is the only legitimate reason.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Sessions starting | `kyc.verification_sessions` created in the last hour | Roughly the sign-up rate |
| Where they stop | session steps by kind and status | No single step holding everything |
| `[VENDOR]` Vendor reachable | Status page, one manual sandbox call | 200 with a verdict |
| Queue depth and age | `kyc_review_queue()`, oldest `created_at` | Within the review SLA |
| Officers available | `admin_users` with `verification_officer`, and their `aal2` | Enough, and all MFA-enrolled |
| Expiry sweep | `kyc-expiry` cron, 02:41 daily | Ran; lapsed standings match expired documents |

## Resolution

**A. Vendor outage.** `[VENDOR]`

1. Queue rather than fail. Sessions already started stay open; they do not need restarting.
2. Tell waiting users a time, not a platitude.
3. When the vendor recovers, drain oldest-first and watch the first few verdicts by hand — a vendor
   coming back up sometimes returns nonsense for a few minutes.

**B. Our side: credentials or configuration.**

Rotate or repair per RB-10. Nothing in the KYC path is safe to "temporarily hardcode".

**C. The queue is long but the vendor is fine.**

This is a staffing incident. More officers, or a slower funnel. Publish the honest wait time; an
applicant who knows it is three days is calmer than one who is told "soon" for three days.

**D. Documents expired en masse.**

The expiry sweep lapses a standing when the document behind it expires — by design, because a
provider working on an expired licence is the client's legal exposure. If a large cohort lapsed at
once, it is because they were onboarded at once. Do not un-lapse them; re-verify them, and stagger
the next intake.

## Backout

Re-enable the verification entry flag once the vendor is confirmed healthy. If a cohort was
re-verified in a hurry, sample ten of them properly afterwards.

## Communication

- **Users mid-verification:** in-app, with a time. This is the group that will otherwise churn.
- **Providers blocked from onboarding:** they may be turning down other work to join. Say when.
- **Head of Trust and Safety:** on every KYC incident, without exception.
- **Regulator:** not for an outage. Only if documents were exposed (RB-07).

## After the incident

- Timeline within 24 h, including the maximum time anybody waited.
- If a manual approval happened, it is a serious finding and goes to Trust and Safety, whatever the
  reason.
- If the queue was the constraint, file the staffing follow-up rather than quietly relying on the
  next person to absorb it.
- `[VENDOR]` Add the vendor's observed failure mode to the diagnosis table.
