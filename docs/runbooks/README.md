# Runbooks

Operational procedures for on-call and ops staff. A runbook is written **before** the feature it covers goes live (spec: definition of done — "docs and runbooks updated"), and it is rehearsed at least once before launch.

Write for someone under pressure at 3 a.m.: numbered steps, exact commands, exact dashboards, explicit stop conditions, and who to wake.

## Planned runbooks

Owned by Claude Code, written in the phase shown. **All fourteen are now written** (2026-09-22).

**Written is not rehearsed.** Every one of these still has `Last rehearsed: not yet`, and a restore
procedure nobody has run is a document rather than a capability. Rehearsal needs deployed
environments, which needs GCP billing and a Supabase organisation (client actions 1 and 8, both
unstarted) — so the gap between this table and an operable platform is a credential, not more
writing.

Two runbooks cannot be fully rehearsed even then, and say so at the top of the file rather than
pretending otherwise: **RB-11** needs the AI service that Vertex billing blocks, and **RB-12** needs
spike S-11 to replace vendor limits with our own measurements. Two more describe a vendor that does
not exist yet and mark those steps inline: **RB-05** (`[VENDOR]`, no identity vendor contracted) and
**RB-06** (`[PARTNER]`, no SOS partner, so escalation is a telephone call today).

| # | Runbook | Phase | Trigger it covers |
|---|---|---|---|
| [RB-01](RB-01-incident-response.md) | Incident response and severity ladder | 2 | Any production incident; defines SEV levels, comms, roles. **Written** |
| [RB-02](RB-02-payment-failures.md) | Payment failures and stuck jobs | 5 | Gateway outage, webhook gap, `payment_pending` pile-up. **Written** |
| [RB-03](RB-03-reconciliation-mismatch.md) | Reconciliation mismatch | 5 | Daily ledger vs gateway settlement mismatch. **Written** |
| [RB-04](RB-04-payout-failures.md) | Payout and withdrawal failures | 5 | Failed or reversed transfers, frozen balances. **Written** |
| [RB-05](RB-05-kyc-vendor-outage.md) | KYC vendor outage | 4 | Vendor unavailable; queueing and the no-auto-approve rule. **Written**; vendor steps marked `[VENDOR]` because none is contracted |
| [RB-06](RB-06-sos-escalation.md) | SOS escalation | 4 | SOS raised; acknowledgement, dispatch, follow-up. **Written**; with no partner contracted, every escalation is a phone call |
| [RB-07](RB-07-data-breach.md) | Data breach and regulator notification | 2 | Per-country clocks (NG 72 h, ZA eServices portal, KE, GH, UG). **Written** |
| [RB-08](RB-08-country-go-live.md) | Country go-live | 10 | Running the checklist and flipping a pack to `live`. **Written** |
| [RB-09](RB-09-backup-restore.md) | Backup restore and PITR drill | 2 | Rehearsed restore; documented RPO/RTO. **Written** |
| [RB-10](RB-10-key-rotation.md) | Key rotation | 2 | Rotating envelope-encryption keys and vendor secrets (ADR-0007). **Written** |
| [RB-11](RB-11-model-swap-and-rollback.md) | Model swap and rollback | 7 | Changing an LLM model ID in remote config (ADR-0006). **Written**; the eval gate cannot run until the AI service exists |
| [RB-12](RB-12-realtime-saturation.md) | Realtime or quota saturation | 3 | Connection and message limits, Enterprise quota. **Written**; thresholds are the vendor's, our own load is unmeasured until S-11 runs |
| [RB-13](RB-13-kill-switch-and-forced-update.md) | Forced update and kill switch | 2 | Disabling a feature or forcing a client upgrade. **Written** |
| [RB-14](RB-14-backend-deploy-and-rollback.md) | Backend deploy failed or release rollback | 2 | Red deploy run, unhealthy release, failed migration; one-time environment setup checklist. **Written** |

## Template

Copy [0000-template.md](0000-template.md) to `RB-NN-short-title.md` and add a row above.
