# S-14 — Money rounding and double-entry ledger invariants (added spike)

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code |
| Status | **Passed, 24/24** |
| Harness | `spikes/postgres/S-14-ledger/` (branch `spike/phase-0-runs`) |
| Feeds | Phase 5 money, contracts v1, `money_rules` in the spec |

## Why this spike exists

Added because it needs **no credentials** and it tests the rules that are most expensive to get wrong. The spec fixes integer minor units, ISO 4217 exponents, `round_half_even`, and a double-entry ledger whose entries sum to zero per transaction. All of that is plain SQL.

## Results

All 24 cases pass.

### Rounding

| Case | Result |
|---|---|
| `round_half_even(0.5)` → 0, `(1.5)` → 2, `(2.5)` → 2, `(3.5)` → 4, `(-2.5)` → −2 | correct half-even |
| Postgres built-in `round(2.5)` → **3** | confirms the built-in is half-away-from-zero |

**Postgres `round()` is not banker's rounding.** The spec's `round_half_even` has to be implemented, not assumed. This is not academic: at a 12.5% commission rate, any gross amount ending in an odd multiple of 4 minor units produces an exact .5 tie. `commission_minor(100, 0.125)` is exactly 12.5 → **12** under half-even, **13** under the built-in. One minor unit per affected job, always in the same direction, across every job — that is a systematic drift between our ledger and the gateway.

### The spec's worked example (USD 100.00)

| Quantity | Minor units | Spec |
|---|---:|---|
| gross | 10000 | 100.00 |
| platform commission at 12.5% | 1250 | 12.50 ✔ |
| net | 8750 | 87.50 ✔ |
| referral 2.5% of net (2.1875) | 219 | 2.19 ✔ |
| provider payout (net − 2.90 gateway fee) | 8460 | — |
| platform revenue (commission − referral) | 1031 | 10.31 ✔ |

The spec's worked example reproduces exactly.

### Currency exponents

`UGX` is stored with exponent **0**, `NGN`/`KES`/`GHS`/`ZAR`/`USD` with 2. Any code that divides by 100 to display money is wrong for Uganda. Holding the exponent in a `currencies` table rather than in code is what keeps that from becoming a per-call-site bug.

### Ledger invariants

| Case | Result |
|---|---|
| A full settlement (held funds → payout, gateway fee, platform revenue, referral) balances to zero | pass |
| An unbalanced transaction is rejected | `P0001` |
| A mixed-currency transaction is rejected | `P0001` |
| A zero-amount entry is rejected | `23514` |
| A refund reverses cleanly; the whole ledger sums to zero; provider earnings return to zero after clawback | pass |

## Finding: a deferred constraint cannot be caught, and takes the transaction with it

The balance invariant was first enforced only by a `DEFERRABLE INITIALLY DEFERRED` constraint trigger, which fires at COMMIT. Two test cases then **vanished from the results table entirely** rather than failing.

The cause matters for production: a deferred trigger fires *outside* any PL/pgSQL exception handler, so
1. the calling function cannot catch it and return a stable error code, and
2. the abort rolls back **everything else in that transaction** — including audit rows, outbox records or anything else written alongside.

The fix, now in the harness, is belt and braces: `post_transaction()` validates the entries **before** writing and raises a catchable `P0001`, while the deferred trigger stays as the last-resort invariant. Anything that writes to the ledger should follow the same shape, and no code should assume it can catch a deferred constraint violation.

## Carry into Phase 5

- `round_half_even` and `commission_minor` ship as database functions, with these cases as pgTAP tests. Commission and referral are computed **once**, server-side, and snapshotted on the job (the spec already requires the rate snapshot).
- The `currencies` table with exponents is the single source for formatting; `Money` in the Dart domain package must read the exponent, not divide by 100. (Kimi has already registered UGX exponent 0 in `suskii_domain` — it matches.)
- Ledger: signed minor units, zero-sum per transaction, single currency per transaction, no zero-amount entries, balances derived from entries rather than stored as truth.
- Still to test with a real database: concurrent posting against materialised balances with optimistic locking, and the reconciliation job against gateway settlement reports.
