# supabase/ — database, auth hooks, Edge Functions

Owner: Claude Code. Design sources: [ERD](../docs/plan/erd.md), [RLS policy matrix](../docs/plan/rls-policy-matrix.md), [infra and CI/CD plan](../docs/plan/infra-cicd.md), [ADR-0013](../docs/adr/0013-backend-foundation-before-contracts-v1.md).

## Layout

| Path | What |
|---|---|
| `config.toml` | Local stack and project settings: exposed schemas (`public` only), phone and email auth, TOTP MFA, auth hooks |
| `migrations/` | Timestamped SQL, applied in order by the Supabase CLI. Pre-contract migrations are editable until a shared environment applies them (ADR-0013) |
| `seed/` | **Dev and staging only.** Countries, cities, legal document placeholders, flags, remote config |
| `tests/database/` | pgTAP suites. `00_structure_test.sql` guards grants, RLS, `search_path` and money column types for every future migration |
| `local-fallback/` | Runner for machines without Docker: a Supabase shim plus a script for plain PostgreSQL 17 + PostGIS. Kept outside `tests/` because `supabase test db` runs every `.sql` file under it |
| `functions/` | Edge Functions (Deno 2 workspace). `_shared/` holds dependency-free modules; each function keeps a testable `handler.ts` and a thin `index.ts` that wires `@supabase/server` and environment |
| `.env.example` | Local secrets template (copy to git-ignored `supabase/.env`) |

## What exists (Phase 2 foundation)

| Migration | Contents |
|---|---|
| `…120000_foundation_schemas` | `pgcrypto`, `postgis`, guarded `pg_cron`/`pgmq`; schemas `private`, `ledger`, `kyc`, `audit`; default privilege revokes |
| `…120100_foundation_types` | Enums with the snake_case wire values Kimi's Dart enums map |
| `…120200_money_primitives` | `currencies` (UGX exponent 0), `private.round_half_even`, `private.apply_bps`, `private.currency_exponent` |
| `…120300_platform_internals` | Error convention, `private.require_user`, idempotency keys, outbox, monthly partitions |
| `…120400_audit_log` | Partitioned, hash-chained, append-only `audit.log`; chain verifier; row-change audit trigger |
| `…120500_reference_and_admin` | `admin_users`, `private.has_admin_role` (aal2 re-check), four-eyes `approvals`, `countries`, `cities`, `legal_documents`, `feature_flags`, `remote_config` |
| `…120600_identity` | `profiles` (column grants), `set_active_mode`, `user_devices` + `register_device`, append-only `consents` + `record_consent`, `notification_preferences` |
| `…120700_auth_hooks_and_bootstrap` | Custom Access Token Hook, Before User Created Hook (refuses unsupported calling codes, R-31), `get_bootstrap()` (PRE-CONTRACT) |
| `…120800_device_integrity` | Single-use integrity nonces bound to user + device + purpose: `request_integrity_nonce` (clients), `consume_integrity_nonce` (service role); pg_cron cleanup of nonces and idempotency keys |

## Edge Functions

| Function | Caller and auth | What it does | Not yet |
|---|---|---|---|
| `auth-send-sms` | Supabase Auth Send SMS Hook; Standard Webhooks signature (`SEND_SMS_HOOK_SECRETS`, `verify_jwt = false`) | Verifies the signature (cross-checked against the reference `standardwebhooks` library), routes by longest calling-code prefix to the ordered `countries.config.server.sms_providers` list, fails over within a 4 s share of Auth's 5 s hook budget, never returns 429/503 (Auth would retry and send duplicate OTPs), logs only masked numbers | Real SMS vendor adapters: chosen and measured by S-09, not written from memory. Only the `console` provider exists, and it refuses to run when `SUSKII_ENV=production` |
| `device-integrity` | Apps, user JWT (`withSupabase({ auth: 'user' })`) | Consumes the nonce for the caller, decodes Play Integrity tokens with Google (`decodeIntegrityToken`, service-account JWT bearer grant), applies the verdict policy (package, nonce, freshness, `PLAY_RECOGNIZED`, `MEETS_DEVICE_INTEGRITY`, `LICENSED`), stores the verdict on `user_devices` with the admin client | **iOS App Attest verification** — recorded as `unevaluated`, never as a pass. Android without credentials is also `unevaluated` |

Environment: `SEND_SMS_HOOK_SECRETS`, `SUSKII_ENV`, `ANDROID_SMS_RETRIEVER_HASH`, `ANDROID_PACKAGE_NAME`, `GOOGLE_PLAY_INTEGRITY_SERVICE_ACCOUNT` (see `.env.example`). `SUPABASE_URL` and the API keys are provided by the platform.

Error convention for client-callable functions: `28000 ERR_UNAUTHENTICATED`, `42501 ERR_*` not allowed, `P0001 ERR_*` business rule, `22023 ERR_*` invalid argument. The message is the stable code the apps localise.

## Commands

With Docker (CI and normal development):

```bash
npx supabase@2.117.0 start
npx supabase@2.117.0 db reset --local
npx supabase@2.117.0 test db --local supabase/tests/database
npx supabase@2.117.0 db lint --local --schema public,private,ledger,kyc,audit --level warning --fail-on warning
npx supabase@2.117.0 db advisors --local --type all --level warn --fail-on warn
npx supabase@2.117.0 gen types --local --lang typescript --schema public
```

Edge Functions (from `supabase/functions`; Deno via npm works without installing it):

```bash
npx deno@2.9.6 fmt --check
npx deno@2.9.6 lint
npx deno@2.9.6 check */index.ts
npx deno@2.9.6 test --allow-env
```

Without Docker (plain PostgreSQL 17 + PostGIS with the pgTAP extension files installed):

```bash
PSQL=/path/to/psql PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=... bash supabase/local-fallback/run-plain-postgres.sh
```

The fallback emulates Supabase's roles, `auth` helpers and permissive default grants, but it is not the real stack: CI (`.github/workflows/backend-db.yaml`) is the authority.

## Platform assumptions: what CI has confirmed

ADR-0013 lists assumptions the no-Docker fallback cannot prove. Status on the Supabase CLI 2.117.0 local stack (CI run 35132940770, 2026-09-16):

| Assumption | Status |
|---|---|
| All migrations and the seed apply from zero on the real stack | **Confirmed** |
| The admin helper reads `admin_users` (FORCE RLS, self-referencing policy) without recursion from a `SECURITY DEFINER` function | **Confirmed** — identity tests with an `aal2` admin pass |
| Auth starts with `[auth.hook.custom_access_token]` and `[auth.hook.before_user_created]` pointing at `private.*` functions | **Confirmed** at start-up; hook payloads through a real sign-in are not yet exercised |
| `pg_cron` / `pgmq` available on the hosted plan | Open — S-02 on a hosted project |
| `[auth.hook.send_sms]` config keys | **Confirmed** from the CLI source (`enabled`, `uri`, `secrets`, secret pattern `v1,whsec_…`); CI starts Auth with the hook enabled |
| Zero Supabase advisor warnings (security and performance) | **Confirmed**, and enforced by CI |

## Rules for new migrations

- Every table in `public`: `ENABLE` and `FORCE ROW LEVEL SECURITY`, `REVOKE ALL … FROM anon, authenticated`, then the exact grants from the RLS matrix. Client-writable columns are column grants.
- Policies wrap `auth.uid()` and helper calls in `(SELECT …)` and keep one permissive policy per role and action (advisors fail CI on warnings).
- Every function: `SET search_path = ''`, `REVOKE ALL … FROM PUBLIC`, explicit `GRANT EXECUTE`. Client-callable ones go on the allowlist in `00_structure_test.sql`.
- Money columns are `*_minor bigint` with a currency code; rates are `*_bps integer`; rounding goes through `private.apply_bps`.
- Creates, transitions and money operations take an idempotency key via `private.idempotency_claim` / `private.idempotency_complete`.
- A migration ships with its pgTAP allow **and** deny tests in the same change.
