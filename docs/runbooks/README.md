# Runbooks

Operational procedures for on-call and ops staff. A runbook is written **before** the feature it covers goes live (spec: definition of done — "docs and runbooks updated"), and it is rehearsed at least once before launch.

Write for someone under pressure at 3 a.m.: numbered steps, exact commands, exact dashboards, explicit stop conditions, and who to wake.

## Planned runbooks

Owned by Claude Code, written in the phase shown. Nothing here is required before Phase 2 opens, but the list is the checklist.

| # | Runbook | Phase | Trigger it covers |
|---|---|---|---|
| RB-01 | Incident response and severity ladder | 2 | Any production incident; defines SEV levels, comms, roles |
| RB-02 | Payment failures and stuck jobs | 5 | Gateway outage, webhook gap, PAYMENT_PENDING pile-up |
| RB-03 | Reconciliation mismatch | 5 | Daily ledger vs gateway settlement mismatch |
| RB-04 | Payout and withdrawal failures | 5 | Failed or reversed transfers, frozen balances |
| RB-05 | KYC vendor outage | 4 | Smile ID unavailable; queueing and the no-auto-approve rule |
| RB-06 | SOS escalation | 4 | SOS raised; partner dispatch, acknowledgement, follow-up |
| RB-07 | Data breach and regulator notification | 2 | Per-country clocks (NG 72 h, ZA eServices portal, KE, GH, UG) |
| RB-08 | Country go-live | 10 | Running the go-live checklist and flipping a pack to `live` |
| RB-09 | Backup restore and PITR drill | 2 | Rehearsed restore; documented RPO/RTO |
| RB-10 | Key rotation | 2 | Rotating envelope-encryption keys and vendor secrets (ADR-0007) |
| RB-11 | Model swap and rollback | 7 | Changing an LLM model ID in remote config (ADR-0006) |
| RB-12 | Realtime or quota saturation | 3 | Connection and message limits, Enterprise quota requests |
| RB-13 | Forced update and kill switch | 2 | Disabling a feature or forcing a client upgrade |

## Template

Copy [0000-template.md](0000-template.md) to `RB-NN-short-title.md` and add a row above.
