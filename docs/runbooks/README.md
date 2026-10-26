# Runbooks

Operational procedures for on-call and ops staff. A runbook is written **before** the feature it covers goes live (spec: definition of done — "docs and runbooks updated"), and it is rehearsed at least once before launch.

Write for someone under pressure at 3 a.m.: numbered steps, exact commands, exact dashboards, explicit stop conditions, and who to wake.

## Planned runbooks

Owned by Claude Code, written in the phase shown. **All fourteen are now written** (2026-09-22), and RB-15 (store release) joined them on 2026-09-28.

**Written is not rehearsed.** Every one of these still has `Last rehearsed: not yet`, and a restore
procedure nobody has run is a document rather than a capability. Rehearsal needs deployed
environments, which needs GCP billing and a Supabase organisation (client actions 1 and 8, both
unstarted) — so the gap between this table and an operable platform is a credential, not more
writing.

**Local rehearsals, 2026-10-13.** Five runbooks have had the parts that a local stack can run
rehearsed against the CLI's stack, with real data and the real jobs; each records exactly what ran
and what did not. RB-09 (the logical backup: dump, verify, damage, restore; its step 4 failed as
written and is fixed), RB-16 (KEK rotation, a missing key, two integrity failures), RB-13 (the
break-glass switches; the text predated the admin console and is fixed), RB-03 (reconciliation
detection with a planted drift) and RB-06 (the automatic escalation, which lands between three and
four minutes, now written down). **A local rehearsal is not a staging one**: none of them touched a
console, a vendor, a phone or a real-sized database, and each still says so.

**Staging rehearsals, 2026-10-26.** RB-13, RB-03, RB-06, RB-08 and RB-05 against `suskii-staging`,
each with a rehearsal record at the end of its file. Every one found something a local stack could not.
**RB-13**: staging had no switch rows at all, so every break-glass `UPDATE` would have changed
nothing and reported success (the commands are now upserts, and a migration creates the switches).
**RB-03**: the ledger's controls all held, but `get_health()` never read the reconciliation result,
nor four other recorded checks, so none of them could ever fire the uptime alert (fixed).
**RB-06**: escalation worked and reached nobody, because nothing reads SOS events. Fixed the same
day by the *SOS unacknowledged* alert (`health?scope=safety`, its own uptime check), which was then
rehearsed on staging too: open 5 min 13 s after the escalation, email delivered, closed by itself.
**RB-08** (the database half, with a fake country): every refusal and every signature
rule held; `countries.approved_by` named the proposer rather than the approver (fixed).
**RB-05** (the queue half): its queue-depth query failed from the SQL editor and its switch did not
exist (both fixed), and **no app reads any switch at all**, which makes RB-13 inert on devices
(HANDOFF part 19).

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
| [RB-15](RB-15-store-release.md) | Mobile store release, and a broken release in the field | 10 | Signing, building and uploading to Play and the App Store; halting a rollout. **Written 2026-09-28**; cannot be rehearsed until the store accounts exist (client action 9). The native release builds compile in CI (`mobile-native`, `mobile-ios`, since 2026-09-28) |
| [RB-16](RB-16-field-encryption-keys.md) | Field-encryption keys: escrow, rotation, a missing key, a failed integrity check | 2 | Vault KEK and wrapped data keys (ADR-0018). **Written 2026-09-29**; escrow needs GCP Secret Manager (action 1), and the whole procedure must be rehearsed on staging before any real access note exists |

## Template

Copy [0000-template.md](0000-template.md) to `RB-NN-short-title.md` and add a row above.
