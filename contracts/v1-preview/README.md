# contracts/v1-preview — pinned early, not binding

Version **1.0.0-preview.1** (2026-09-17). Owner: Claude Code.

[PHASE-1-PLAN](../../docs/plan/PHASE-1-PLAN.md) holds contracts v1 until Kimi Code's M8.5 hand-off, with one exception: the pieces both agents already build against are pinned now, so neither side keeps guessing. This folder is that exception. Contracts v1 (Stage B) replaces it; until then, anything here may still change, and every change is listed in [CHANGELOG.md](../CHANGELOG.md) and `HANDOFF.md`.

| File | What it pins | Kept honest by |
|---|---|---|
| [error-codes.json](error-codes.json) | Every error code: status (`implemented` / `planned` / `client`), where it surfaces, SQLSTATE and HTTP status, retryability, and what the app should do | CI fails if backend code raises a code not listed as `implemented`, or if an `implemented` code is no longer raised |
| [auth-error-mapping.json](auth-error-mapping.json) | Supabase Auth's own error codes (sign-in, OTP, MFA, sessions) mapped to app codes | Source checked against the Supabase docs; open question on hook rejections |
| [enums.json](enums.json) | Every Postgres enum and its snake_case wire values, in order | **Generated** from `supabase/migrations`; CI fails on any difference |
| [money.schema.json](money.schema.json) | The `Money` JSON shape: `{ "amount_minor": integer, "currency": "NGN" }` | JSON Schema |

## How errors reach the apps

| Path | HTTP | Body | Where the code is |
|---|---|---|---|
| Database functions through PostgREST (`supabase.rpc`) | From the SQLSTATE: `28*` 403; `42501` 403 when signed in, 401 when anonymous; `P0001` and `22*` 400; `23505` 409 | `{ code: <sqlstate>, message: <ERR_ code>, details, hint }` | `message` |
| Edge Functions | As listed per code | `{ error: { code: <ERR_ code>, request_id } }`; header `x-request-id` | `error.code` |
| Supabase Auth (sign-in, OTP, MFA) | Auth's own | Auth error with `code` (Dart: `AuthApiException.code`) | Map with `auth-error-mapping.json` |

PostgREST mapping source: docs.postgrest.org errors reference (checked 2026-09-17).

## Decisions this preview makes

| # | Decision | Why |
|---|---|---|
| P-1 | Money on the wire is `{ amount_minor, currency }` | Matches the database columns (`*_minor` + `currency`) and the snake_case convention of the enums. Resolves review C.7 |
| P-2 | The server code for a phone number outside supported countries is `ERR_COUNTRY_NOT_SUPPORTED`, not `ERR_COUNTRY_DISABLED` | It is what the backend raises. Apps see it through Supabase Auth; see the open question in `auth-error-mapping.json` |
| P-3 | A withdrawal needing Finance approval is **not an error**: the request succeeds with a pending-approval status (defined with Phase 5 money contracts) | The user did nothing wrong; an error code would make the app show a failure |
| P-4 | `ERR_OTP_INVALID`, `ERR_OTP_RATE_LIMITED`, `ERR_NETWORK`, `ERR_UNKNOWN`, `ERR_FORCE_UPDATE_REQUIRED`, `ERR_VERIFICATION_FAILED` are app-side codes | The backend never sends them; the apps derive them from Auth errors, connectivity, bootstrap or the vendor SDK |

## Changing this preview

Backend: add or change the code, update `error-codes.json` (or run `python contracts/tools/check_preview.py --write` for enums), bump the preview version and add a CHANGELOG entry. Kimi Code: request changes in `contracts/CHANGE_REQUESTS.md`.
