# RB-10 — A key or secret must be rotated (routine or suspected exposure)

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | Routine: none. Suspected exposure: SEV1 (RB-01, and RB-07 if personal data could be read) |
| Last rehearsed | Not yet — rotate every secret below once on staging before launch |
| Related | [infra-cicd.md](../plan/infra-cicd.md) §4; ADR-0007; RB-01, RB-07, RB-14 |

## Inventory

Where every secret lives, who uses it, and how often to rotate it **routinely**. Rotate **immediately**, whatever the schedule, if it may have been exposed.

| Secret | Source of truth | Used by | Routine | Procedure |
|---|---|---|---|---|
| Send SMS Hook secret (`send-sms-hook-secrets`) | GCP Secret Manager | Supabase Auth (signs) and `auth-send-sms` (verifies) | 180 days | **A** — dual-secret, no downtime |
| Supabase DB password (`supabase-db-password`; GitHub env secret `SUPABASE_DB_PASSWORD`) | Secret Manager + GitHub environment | Deploy pipeline (`db push`, `link`) | 90 days | **B** |
| Supabase access token (`SUPABASE_ACCESS_TOKEN`) | GitHub environment secret | Deploy pipeline | 90 days | **B** |
| Supabase secret API keys (default; named `monitoring`) | Supabase dashboard; `HEALTH_CHECK_API_KEY` in GitHub and Terraform | Edge Functions (admin client), uptime check | 180 days | **C** |
| Supabase publishable key | Supabase dashboard; app build config | Apps | On exposure only (it is public by design) | **C**, then a forced update if clients must change (RB-13) |
| Play Integrity service account key (`google-play-integrity-service-account`) | Secret Manager | `device-integrity` | 90 days | **D** |
| Sentry DSNs | Secret Manager | Functions, AI service | On exposure only | **B** |
| Gateway, KYC, SMS, LiveKit, telephony keys | Secret Manager (added when those integrations are built) | Functions, workers | Per vendor; 180 days default | Written with each integration (Phases 4–6) |
| Envelope-encryption key-encryption keys (ADR-0007) | Secret Manager | Encrypt/decrypt functions (not built yet) | Yearly | **E** — written with Phase 4 |
| GitHub → GCP deploy auth | None: Workload Identity Federation | CI | Nothing to rotate | Revoke by changing the WIF provider condition in Terraform |

## Symptoms (unplanned rotation)

- gitleaks finds a secret in history (`security.yaml`), or one is pasted in a ticket, chat or log.
- A laptop or account with access is lost or compromised.
- A vendor reports that keys may be exposed.
- Unexplained use: OTP spend spike (R-31), unexpected function calls, gateway activity we did not initiate.
- A staff member with access leaves.

## Immediate actions (suspected exposure)

1. Open an incident (RB-01). If the secret could read personal data, start RB-07.
2. Rotate using the procedure below. **Rotate first, investigate after.**
3. Check usage logs for the window between exposure and rotation (vendor dashboards, function logs, audit rows).
4. If the secret was committed to git: rotating is the fix. Rewriting git history does not un-leak a pushed secret.

**Stop conditions:**
- Never paste a secret value into chat, tickets, workflow inputs, commit messages or Terraform variables files.
- Never put a new secret in a GitHub **repository** secret when it belongs to an **environment**: environment secrets are only readable by jobs in that environment.
- Never delete the old secret version before the new one is proven in use (except when the old one is known to be abused).

## Procedures

### A — Send SMS Hook secret (dual secret, no downtime)

Both sides accept several secrets separated by `|`: the Supabase CLI validates each entry (checked in the CLI source) and `auth-send-sms` accepts a request signed with any configured secret.

1. Generate a new secret: `v1,whsec_` + base64 of 32 random bytes.
2. Add a new Secret Manager version with **both**: `v1,whsec_NEW|v1,whsec_OLD`.
3. Deploy the environment (RB-14 pipeline, or `rollback-functions` at the current SHA for functions and secrets only). The function now accepts both; `config push` gives Auth both.
4. Request an OTP on a test number. Expected: SMS received; no `send_sms.signature_rejected` in logs.
5. Add another version with only `v1,whsec_NEW`; deploy again; test again.
6. Disable the old versions in Secret Manager.

### B — Credentials used only by the deploy pipeline

1. Create the new credential (Supabase: reset the database password or create a new access token).
2. Update the GitHub **environment** secret (and the Secret Manager version for the DB password).
3. Run the pipeline for the environment (`workflow_dispatch` of `pipeline-main`, or `deploy-production` with the current SHA). Expected: link and dry run succeed.
4. Revoke the old credential.

### C — Supabase API keys

1. Supabase dashboard → project → API keys: create a new secret key with the same name (for example `monitoring`), keeping the old one active.
2. Update consumers: `HEALTH_CHECK_API_KEY` (GitHub environment secret and `TF_VAR_health_check_api_key`, then `infra-deploy` apply for the uptime check). Edge Functions read platform-provided keys and pick up the new set on redeploy.
3. Verify: uptime check green; health endpoint 200 with the new key; old key still works.
4. Revoke the old key; verify the health endpoint returns 401 with it.
5. For the **publishable** key: ship app builds with the new key first, raise `min_supported_app_version` (RB-13), and revoke the old key only after clients have moved.

### D — Play Integrity service account key

1. GCP IAM → the Play Integrity service account → Keys → add key (JSON).
2. Add the JSON as a new version of `google-play-integrity-service-account`.
3. Deploy functions (RB-14). Verify on a test device: `device-integrity` returns `pass`, not `play_integrity_not_configured` or `token_decode_failed`.
4. Delete the old key in IAM; disable the old secret version.

### E — Envelope-encryption keys (placeholder)

ADR-0007 rotates by **re-wrapping data keys**, not re-encrypting every row. The exact procedure is written with the encryption functions in Phase 4 and rehearsed before any encrypted column holds real data.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Which version is live | Secret Manager version list; function `release` in health | Newest version enabled, old disabled after rotation |
| Auth accepts the hook | OTP to a test number | SMS delivered, no signature rejections |
| Nothing still uses the old secret | Vendor dashboards, function logs after revoking | No authentication failures from our own services |

## Backout

Until the old secret is revoked, re-enable its version and redeploy. After revocation, the only way back is forward: issue another new secret.

## Communication

Routine rotation: note in the ops log. Exposure: RB-01 and, where personal data was reachable, RB-07.

## After the rotation

- Update the inventory table (date rotated, next due).
- For an exposure: a write-up covering how it leaked and which check (gitleaks, review, access control) should have caught it.
