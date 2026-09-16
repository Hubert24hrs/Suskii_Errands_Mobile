# ADR-0002 — Hold customer funds in our ledger and release them through gateway transfers

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-16 |
| Deciders | Claude Code (design), counsel per country (OD-12) |
| Unblocked by | Counsel opinions (OD-12), spike S-12 |

## Context

The spec requires the customer to pay upfront and the platform to hold the money until the job is confirmed, while warning that holding customer funds is regulated differently in every country and that we may not call it "escrow" in the UI.

Phase 0 found that Flutterwave escrow endpoints are documented only in the **v2** API (`/transactions/escrow/settle`) and do not appear in v3 or v4 [V]. Stripe Connect cannot pay African connected accounts at all [V]. Nigeria has no escrow licence: only licensed entities such as mobile money operators may hold customer funds, and others do it through bank partnerships [S]. South Africa requires TPPP registration with PASA through a sponsoring bank before collecting on behalf of third parties [V].

## Decision

We will collect into the platform gateway merchant balance, record the money as `held_funds` in our own double-entry ledger, and release it to the provider with the gateway Transfers API after `CUSTOMER_CONFIRMED` plus the dispute window. We will not depend on any gateway escrow product. The ledger is designed so the holding account can move to a bank-partner or licensed-entity account without changing job, offer or payout logic. UI copy says "held by Suskii" and never "escrow".

## Consequences

**Good:** one flow works across Flutterwave and Paystack; the regulatory model can change per country without touching the state machine; refunds and partial releases stay under our control.

**Bad / costs:** we carry reconciliation and float risk ourselves; settlement timing (1–5 business days into the merchant balance) sits between confirmation and payout, so the ledger must distinguish *owed* from *available*.

**Follow-on work:** ledger accounts and invariants (entries per transaction sum to zero); payout state machine; daily reconciliation against gateway settlement reports; a per-country `funds_holding_model` field in the country pack.

## Alternatives considered

| Option | Why not |
|---|---|
| Flutterwave v2 escrow | Legacy API generation, absent from v3/v4 docs; pins us to a deprecated surface |
| Gateway split or subaccounts at charge time | Splits at capture, so there is no conditional release and no dispute hold |
| Licensed e-money entity per country | The right answer at scale, the wrong cost and timeline for launch; the ledger keeps the door open |

## Revisit when

Counsel rejects the collection-agent model in any live country, a gateway ships a supported conditional-release product, or volume justifies a payment licence.
