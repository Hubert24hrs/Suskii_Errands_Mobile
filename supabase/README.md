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
| `functions/` | Edge Functions (Deno) — next |

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

Without Docker (plain PostgreSQL 17 + PostGIS with the pgTAP extension files installed):

```bash
PSQL=/path/to/psql PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=... bash supabase/local-fallback/run-plain-postgres.sh
```

The fallback emulates Supabase's roles, `auth` helpers and permissive default grants, but it is not the real stack: CI (`.github/workflows/backend-db.yaml`) is the authority.

## Rules for new migrations

- Every table in `public`: `ENABLE` and `FORCE ROW LEVEL SECURITY`, `REVOKE ALL … FROM anon, authenticated`, then the exact grants from the RLS matrix. Client-writable columns are column grants.
- Policies wrap `auth.uid()` and helper calls in `(SELECT …)` and keep one permissive policy per role and action (advisors fail CI on warnings).
- Every function: `SET search_path = ''`, `REVOKE ALL … FROM PUBLIC`, explicit `GRANT EXECUTE`. Client-callable ones go on the allowlist in `00_structure_test.sql`.
- Money columns are `*_minor bigint` with a currency code; rates are `*_bps integer`; rounding goes through `private.apply_bps`.
- Creates, transitions and money operations take an idempotency key via `private.idempotency_claim` / `private.idempotency_complete`.
- A migration ships with its pgTAP allow **and** deny tests in the same change.
