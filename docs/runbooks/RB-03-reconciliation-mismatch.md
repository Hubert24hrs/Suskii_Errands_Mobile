# RB-03 — The ledger and the gateway disagree

| | |
|---|---|
| Owner | Claude Code / Finance |
| Severity | SEV2 by default. SEV1 if the gap is growing, or if any provider balance is affected |
| Last rehearsed | **2026-10-26, on staging**, with a deliberately broken posting, every write inside one block that rolled itself back (rehearsal record below). Every control in the ledger held; **the alert did not**: the nightly job recorded `fail` and `get_health()` still said `ok`, so the first symptom below could not happen. Fixed by `…20261026140000_health_reads_recorded_checks`. The gateway-settlement comparison and the Finance steps still need a gateway (action 4). Before that, **2026-10-13, locally**, the detection half: the nightly job's own command run by hand (`ok`), then a one-unit drift planted in `ledger.balances` inside a rolled-back transaction (`ledger.reconcile()` found the account; the health check recorded `fail` with `drifted_accounts: 1`). The gateway-settlement comparison and the Finance steps need a gateway (action 4). Rehearse the whole runbook on staging with a deliberately broken posting before the first live country |
| Related | ADR-0011 (chart of accounts); S-14 (money invariants); money-flows.md; RB-02, RB-04 |

## What reconciliation actually checks

`ledger.reconcile()` runs nightly at 03:17 through `private.record_health_check('ledger_reconcile', …)`.
It asserts the things that must be true of a double-entry ledger no matter what the gateway says:

1. **Every transaction's entries sum to zero.** Enforced by a deferred constraint trigger as well,
   which cannot be caught — per S-14, `ledger.post` validates *before* writing and raises a
   catchable `P0001`, and the trigger stays as the invariant nothing can route around.
2. **One currency per transaction.**
3. **Stored balances match the sum of entries.** `ledger.balances` is a running total that
   `ledger.post` increments under a row lock, and `ledger.reconcile()` compares it with the sum of the
   entries. A divergence means something wrote one without the other: a write that went around
   `ledger.post`, or a half-applied migration. (This line used to call it a view; it never was.)

A mismatch against the **gateway** is a different thing from a mismatch **inside** the ledger, and
the first question is always which one you have.

## Symptoms

- `/health` returns 503 and the uptime alert fires: `get_health()` shows `checks.ledger_reconcile`
  as `fail`, with `detail.drifted_accounts` and `detail.unbalanced_transactions`. **Only since
  2026-10-26**: before that the snapshot never read this check (rehearsal record).
- Finance's morning check: gateway settlement total ≠ `held_funds` movement for the day.
- A provider says their available balance is wrong.

## Impact

Money is being described incorrectly. Nobody has necessarily lost anything yet — that is what makes
this urgent rather than calm: an unexplained gap that is allowed to age becomes an unexplainable one.

## Immediate actions (first 5 minutes)

1. Open the incident (RB-01). Reconciliation is Finance's call to escalate, not on-call's alone.
2. Decide which mismatch you have:
   ```sql
   SELECT * FROM ledger.reconcile();
   ```
   Clean means the ledger is internally consistent and the disagreement is with the gateway.
   Not clean means stop and treat it as a data-integrity incident.
3. **Freeze the thing that spends.** If any provider balance may be overstated, pause withdrawal
   dispatch before you investigate — `dispatch-withdrawals` runs hourly at :43.

**Stop conditions.**

- **Never adjust a balance.** There is no balance to adjust: balances are derived. The only way to
  change one is to post a correcting transaction, and that needs Finance's sign-off and a reason.
- **Never delete or edit a ledger entry.** Append-only is the whole point.
- **Never "fix" a gap by moving money at the gateway** to make the books match. That inverts the
  relationship: the books describe reality, they do not instruct it.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Ledger internally consistent | `SELECT * FROM ledger.reconcile();` | No rows / no findings |
| Unbalanced transactions | entries grouped by transaction, summed | Every sum exactly 0 |
| Mixed currency | entries per transaction, distinct currency | Exactly 1 |
| Today's holds vs gateway | `held_funds` movement vs the gateway settlement report | Equal, or differing only by events after the cut-off |
| Manual intervention yesterday | `audit.log` for the period | Nothing, ideally. If something, that is your answer |
| Chargebacks | `record_chargeback` postings | Each one has a matching gateway event |

**The three causes worth knowing before you look:**

- **A console refund.** Somebody refunded at the gateway without `execute_refund`. The gateway is
  short, the ledger still holds. Most common cause, and RB-02's stop conditions exist to prevent it.
- **A cut-off difference.** The gateway's day ends at a different instant from ours. This is not a
  mismatch; it is a boundary. Compare the same window before escalating.
- **A chargeback before settlement.** Audit finding T.3: this used to reverse postings that were
  never made and invent a debt against a provider. `record_chargeback` now asks the ledger whether
  earnings were recognised first. If you see a provider owing money for a job that never settled,
  check that this migration is actually deployed to the environment you are looking at.

## Resolution

**A. Internally consistent, disagrees with the gateway.**

1. Get both sides for the *same* window, with the gateway's own cut-off.
2. List the transactions present on one side and not the other.
3. For each, find the cause. Do not batch-correct: each difference has a story and the story is what
   Finance needs.
4. Post corrections through `ledger.post` with a reason, one per cause, approved by Finance. A
   correction is a new transaction, never an edit.

**B. Internally inconsistent.**

This should be impossible — the deferred trigger refuses an unbalanced write. If it happened:

1. Treat it as SEV1 and stop withdrawal dispatch.
2. Capture the offending transaction ids **before** anything else touches the tables.
3. Check whether the constraint trigger is actually present in that environment. A migration that
   half-applied is the realistic explanation.
4. Do not post corrections until the cause is known. A correcting entry on top of a broken
   invariant makes the original unrecoverable.

## Backout

A correcting transaction can itself be reversed by a further transaction, with a reason. There is no
delete. If withdrawals were paused, resume them only after `ledger.reconcile()` is clean **and**
Finance agrees the gateway gap is explained.

## Communication

- **Finance:** immediately, and they lead. This is their incident with engineering support.
- **Affected providers:** only once the number is certain. A provider told twice about their own
  money, with different figures, will not believe the second one.
- **Regulator:** not for a mismatch. Only if it turns out to involve personal data (RB-07) or if
  counsel says the funds-holding terms (OD-12) require it.

## After the incident

- Timeline within 24 h with the exact figures, both sides.
- If a console refund caused it, that is a process failure, not a person failure: fix the access or
  the tooling that made it the easy path.
- If the cut-off caused it, write the cut-off into the Finance checklist so the next person does not
  spend a morning on it.

## Rehearsal record

| Date | Environment | What ran | Result |
|---|---|---|---|
| 2026-10-13 | Local CLI stack | The nightly command by hand, then a one-unit drift planted in `ledger.balances` in a rolled-back transaction | `ok`, then `fail` with `drifted_accounts: 1` |
| 2026-10-26 | **Staging** (`suskii-staging`) | One `DO` block that ends by raising its findings, so every write rolls back: checked `ledger-reconcile` is scheduled and `entries_balanced` is present, deferred and enabled; an unbalanced `ledger.post` (one leg off by one unit); a balanced `payment_captured` (9710 / 290 / −10000 USD); an `UPDATE` straight to `ledger.entries` with constraints set immediate; a one-unit drift in `ledger.balances`; the scheduled command run exactly as stored in `cron.job`; then `get_health()` | Books clean before and after the balanced post. Unbalanced post refused, catchably: `P0001 ERR_LEDGER_UNBALANCED`. The write around `ledger.post` refused by the deferred trigger with the same error. The drift found (`reconcile()`: one account, `drift_minor` 1) and recorded as `fail`, `drifted_accounts: 1`. **Finding: `get_health()` returned `ok` and had no `ledger_reconcile` key.** `private.health_snapshot()` read `audit_chain` and the backup keys by name and nothing else, so five recorded checks (`ledger_reconcile`, `partitions`, `notifications`, `outbox_stuck`, `analytics_export`) had never reached `/health` or the uptime alert. Fixed in `…20261026140000`; `63_health_recorded_checks_test` replays this rehearsal |
