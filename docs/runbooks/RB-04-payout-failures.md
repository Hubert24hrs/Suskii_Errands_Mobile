# RB-04 — A payout or withdrawal failed, reversed, or is stuck

| | |
|---|---|
| Owner | Claude Code / Finance |
| Severity | SEV2. SEV1 if payouts are failing across a country — that is people's income |
| Last rehearsed | **Not yet.** Rehearse on staging, including a reversal, before the first live country |
| Related | ADR-0007 (envelope encryption); ADR-0011; money-flows 1d, 7, 8, 9; OD-10 (who pays transfer fees), OD-18 (withholding); RB-02, RB-03 |

## Why payouts have their own state machine

A charge either works or does not. **A transfer can succeed and then reverse hours later**, so
`public.payouts` carries its own states rather than borrowing the job's:

`requested → submitted → pending → succeeded`, with `failed` and `reversed`.

`reversed` is the one that matters. It arrives after `succeeded`, after the provider has been told
they were paid, and sometimes after they have spent it.

Withdrawals are separate and human-gated:
`requested → awaiting_approval → approved → processing → paid`, with `rejected` and `failed`.
The country pack sets one- and two-approver thresholds and they run through the existing four-eyes
`approvals` table. `dispatch-withdrawals` picks up approved ones hourly at :43.

## Symptoms

- `kpi_payout_failures` non-zero, or climbing.
- Providers reporting money promised and not arriving.
- A gateway reversal webhook.
- Withdrawals sitting in `awaiting_approval` past the SLA because nobody approved them.

## Impact

A provider's week. Treat a payout failure as more urgent than its transaction size suggests: the
person on the other end may have planned around it.

## Immediate actions (first 5 minutes)

1. Open the incident (RB-01). Bring Finance in — approvals are theirs.
2. Separate the three cases, because the fixes differ:
   ```sql
   SELECT status, count(*), max(updated_at) FROM public.payouts
   WHERE updated_at > now() - interval '24 hours' GROUP BY 1;
   SELECT status, count(*) FROM public.withdrawals
   WHERE updated_at > now() - interval '24 hours' GROUP BY 1;
   ```
3. If failures are **systemic** (one country, one rail, many providers), stop dispatching before you
   make it worse — a retry storm against a broken rail spends fees and proves nothing.

**Stop conditions.**

- **Never pay a provider out-of-band** and reconcile later. It reliably produces a double payment.
- **Never mark a payout `succeeded` by hand.** That posts settlement. The only door is
  `public.gateway_record_payout_result`, granted to `service_role`.
- **Never decrypt or read a payout account's ciphertext.** It is granted to nobody, deliberately
  (ADR-0007). Name enquiry and verification are the supported operations; if you find yourself
  wanting the raw account number, the thing you actually want is a gateway-side lookup.
- **Never approve your own withdrawal**, and never approve to clear a queue. Four eyes means two
  people who both looked.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Which rail | `payouts.rail` grouped with status | Failures concentrated on one rail points at the rail, not at us |
| Name mismatch | `payout_accounts` verification state | Verified and name-matched before any transfer |
| Shared account flag | `payout_accounts`, blind index collisions | **Flagged, not refused.** Two people may genuinely share one, and refusing strands somebody with no way to be paid |
| Balance actually available | `private.available_minor(user)` | Subtracts referral commissions that are posted but still `holding` |
| Approval trail | `approvals` for the withdrawal | Two distinct approvers above threshold |
| Gateway view | Vendor dashboard for the same reference | Matches our status |

## Resolution

**A. A single transfer failed.**

1. Read the gateway's reason. Most are the account, not the platform: wrong number, closed account,
   name mismatch, limit.
2. If it is the account, the provider must fix it. `add_payout_account` takes the new one; the old
   one stays for the record. Do not edit the existing row.
3. Re-drive the payout. `private.record_payout_result` takes the answer back; the instruction is
   emitted by `private.create_payout`.

**B. A payout reversed after succeeding.**

1. This is `record_chargeback`'s neighbour and it posts. Confirm what the ledger already did:
   settlement may or may not have been recognised, and the correct reversal depends on which
   (audit T.3 is the same class of bug on the charge side).
2. Tell the provider **before** their balance changes under them. A balance that silently drops is
   how you lose somebody who did nothing wrong.
3. If the reversal is disputed, it is a dispute — `open_dispute`, not a manual adjustment.

**C. Withdrawals stuck in `awaiting_approval`.**

Usually not a fault: it means nobody approved them. Check the threshold is what the country pack
intends, check the approvers exist and have the role, and check they have `aal2` — every admin verb
requires MFA at the database level, so an approver without it will find the button does nothing.

**D. Systemic failure on one rail.**

Stop dispatch, tell providers the delay and the expected resolution, and re-drive in a controlled
batch once the rail is confirmed healthy. Watch the first ten individually.

## Backout

Re-driving a payout is safe: the instruction carries an idempotency key and the gateway
de-duplicates. If dispatch was paused, resume only after a successful controlled batch.

## Communication

- **The affected provider, first and plainly.** "Your payout failed because the account name did not
  match; here is how to fix it" beats silence by a wide margin.
- **Finance:** every reversal, every manual intervention.
- **All providers in a country**, if systemic: say it is a transfer problem on our side, give a time,
  and hold to it.
- **Tax:** per-country withholding is OD-18 and unanswered. If a correction crosses a tax boundary,
  ask counsel before posting it.

## After the incident

- Timeline within 24 h.
- Any reversal that reached a provider's balance gets a written explanation to that provider.
- If approvals were the bottleneck, the fix is staffing or thresholds, not removing the second pair
  of eyes.
