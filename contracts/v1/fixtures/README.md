# fixtures

Realistic payloads in the **real wire shape**, for the screens that are easy to get wrong because
the happy path never exercises them. `../README.md` rule 4 asks fixtures to match Kimi's mock data
so the M9 swap is mechanical. They do, with one deliberate exception.

## The exception, and it is a migration note

Kimi's mocks use readable identifiers — `req-1`, `disp-1`, `off-2`. **Every id the backend returns
is a UUID.** These fixtures use UUIDs, because a fixture that showed `req-1` would be teaching the
app a shape it will never receive, and the failure would land at M9 as a cast error on every
screen at once rather than in one place.

What this costs at M9: `String` id fields keep their type, but anything that *parses* or *formats*
an id, sorts by it, or builds a route from it needs checking. Deep links are the sharp edge —
`/customer/requests/req-1` becomes `/customer/requests/3f2a…`.

`messages.id` is the other one: it is **`bigint`**, not a UUID, because chat is partitioned and a
monotonic key is what makes that work. On the wire it arrives as a JSON number that can exceed
2^53 in principle; treat it as an opaque string in Dart rather than an `int`.

## Files

| File | The case it covers | Why it is here |
|---|---|---|
| [`expired-offer.json`](expired-offer.json) | An offer whose TTL elapsed while the customer was deciding, and a sibling accepted in the same transaction | The offers board has to render a dead offer without making it tappable, and the two reasons look identical to a client |
| [`failed-payment.json`](failed-payment.json) | A gateway decline, and a payment whose 15-minute TTL elapsed | Two different recoveries: retry the same payment, or start again from `agreed` |
| [`disputed-job.json`](disputed-job.json) | A job frozen mid-settlement with evidence from both sides | `frozen_from` is the field people miss: withdrawing restores the exact prior status, not `confirmed` |
| [`suspended-provider.json`](suspended-provider.json) | A provider suspended with an end date, and what a customer sees of them | Suspension is bounded and audited by design (OD-25); there is no permanent-ban payload because one function call cannot do that |
| [`money.json`](money.json) | The spec's own worked example, posted end to end | The only fixture with arithmetic in it, and the numbers are the ones `28_ledger_test.sql` proves |

## Rules these obey

- Money is `{ amount_minor, currency }` with integer minor units. The UGX rows have exponent 0 on
  purpose — a fixture set that was NGN-only would let a `/100` bug through, which is exactly how
  M3.20 happened.
- Every timestamp is RFC 3339 with an offset.
- Enum values are the snake_case wire form from `../enums.json`, never the Dart name.
- No fixture contains a real phone number, a real name, or a plausible address in a real city
  block. They are recognisably fictional, because fixtures get pasted into issues.
