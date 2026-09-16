# ADR-0003 — The merchant account bears gateway fees; the ledger allocates them to the provider

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | — |

## Context

The spec says the customer pays the agreed amount and gateway fees are borne by the provider, deducted from their payout. Flutterwave pricing pages state that **by default the customer bears the charge**, and the merchant changes this in the dashboard [V]. If we left that default in place, the customer would be charged more than the negotiated price, breaking the rule that the final agreed price is the transaction value.

## Decision

We will set the fee bearer to **merchant** in every Flutterwave and Paystack account, in every country. The customer is charged exactly the agreed amount (plus the item float where applicable). The actual fee reported by the gateway for that charge is stored on the job and deducted from the provider payout as `gateway_fee`, as the spec formula requires. The fee is never estimated after the fact: we read it from the gateway response or settlement record. The OD-04 item float is the one exception, where the fee is passed to the customer.

## Consequences

**Good:** what the customer agreed to is what the customer pays; the provider payout breakdown matches reality; per-country fee differences live in the ledger rather than the price.

**Bad / costs:** the platform fronts the fee between capture and payout; if a payout never happens because of a refund, the fee is a platform cost unless OD-08 says otherwise.

**Follow-on work:** account configuration checklist item (compliance P1); `gateway_fee` capture in the payment adapter; provider payout preview showing offer − commission − estimated fee.

## Alternatives considered

| Option | Why not |
|---|---|
| Leave the customer-bears default | The customer pays more than the agreed price, breaking the negotiation contract |
| Estimate the fee from a rate table | Rates change per method and country; estimates drift from settlement and break reconciliation |

## Revisit when

A gateway stops reporting per-transaction fees, or a country forbids passing fees to providers.
