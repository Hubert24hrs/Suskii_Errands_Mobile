# contracts/v1 — binding

Version **1.0.0** (2026-09-22). Owner: Claude Code. Supersedes [`../v1-preview/`](../v1-preview/README.md).

This is the agreement between the backend and every frontend. [`../README.md`](../README.md) rule 1:
**clients may call only what is listed here.** Not an endpoint, not a field, not an event more.

## What is in it

| Path | What it pins | How it stays true |
|---|---|---|
| [`rpc-catalog/index.json`](rpc-catalog/index.json) | All **121** functions a client may call: arguments with types and defaults, return shape, the error codes each can raise, whether it needs an idempotency key, and what it requires of the caller | **Generated** from `supabase/migrations` |
| [`rpc-catalog/private.json`](rpc-catalog/private.json) | The `private.*` helpers granted to `authenticated`, which are **not** callable — PostgREST reaches only `public`. Listed so the grant does not read like a mistake | Generated |
| [`db-types/tables.json`](db-types/tables.json) | The **64** tables a client reads directly, their columns, and their **column-level** privileges | Generated |
| [`enums.json`](enums.json) | All **45** Postgres enums and their snake_case wire values, in order | Generated |
| [`storage/buckets.json`](storage/buckets.json) | **6** buckets, size limits, allowed MIME types, and the policies that enforce the path convention | Generated |
| [`realtime-events/channels.json`](realtime-events/channels.json) | **5** topics and the events on each | Generated from the `private.broadcast` calls |
| [`state-machines/job.json`](state-machines/job.json), [`offer.json`](state-machines/offer.json) | States, all 31 job transitions with actor, guard and effects, and the timeouts | **Authored**, cross-checked: a literal from/to pair in SQL that is missing here fails CI |
| [`error-codes/codes.json`](error-codes/codes.json) | **109** codes — 94 implemented, 9 planned, 6 app-side — with SQLSTATE, HTTP status, retryability and what the app should do | Authored, cross-checked against every `ERR_` the backend raises |
| [`error-codes/auth-mapping.json`](error-codes/auth-mapping.json) | Supabase Auth's own codes mapped to app codes | Authored |
| [`money.schema.json`](money.schema.json) | `{ "amount_minor": integer, "currency": "NGN" }` | JSON Schema |
| [`edge-functions.openapi.yaml`](edge-functions.openapi.yaml) | The six Edge Functions. **Exactly one is callable by an app** | Authored |
| [`fixtures/`](fixtures/) | Realistic data for the awkward screens: an expired offer, a failed payment, a disputed job, a suspended provider | Authored |

Regenerate: `python contracts/tools/generate_v1.py . --write`. CI runs it without `--write` and
fails on any difference, which is rule 3.

## The eight things most likely to bite

1. **Money is never a float and never computed on a client.** Integer minor units plus an ISO 4217
   code, and the exponent varies — UGX is 0, so `12500` is ₦125.00 and USh 12,500. Every price,
   commission, fee, payout and referral arrives as a server-computed breakdown. `numeric` columns
   arrive from PostgREST as **strings**; parse them as decimals, never as doubles.
2. **A status is never assigned, only requested.** Call the verb; the server runs the machine
   inside the row lock and returns the new state or `ERR_ILLEGAL_TRANSITION`.
3. **62 of the 121 functions take an idempotency key**, and it is the *first* argument on every
   one of them. Mint it when the user forms the intent, not when the request is sent, and reuse
   it across retries — a replay returns the original outcome rather than acting twice.
4. **Arguments are passed by name.** `supabase.rpc('create_request', { p_category_key: ... })`.
   An optional argument may simply be omitted; do not pass `null` to mean "absent", because for
   several functions `null` is a meaningful value.
5. **Column grants are narrower than table grants on 4 tables.** `promo_codes` is the one to
   notice: a client may read the code and the discount but **not the budget**, because knowing
   the budget tells a customer when to hurry. Requesting a column you were not granted fails the
   whole select.
6. **30 functions require an admin role, and every one of them requires `aal2`.** MFA is not a
   setting on the admin console, it is a precondition the database enforces.
7. **A provider reads a request only once the job is funded.** `provider_feed` gives an
   approximate area while bidding and exact detail never; `jobs.assigned_at` is what opens the
   full read. Do not build a screen that shows an exact address to a provider who has not been
   assigned a funded job — there is no query that would return one.
8. **Realtime is a courtesy, not a guarantee.** Tables are the truth. Refetch on reconnect.
   Offers broadcast to `request:{id}:customer` and to `request:{id}:provider:{provider_id}` and
   never to a shared topic, because a provider must never learn a rival's price.

## Reading an entry

```jsonc
{
  "name": "accept_offer",
  "signature": "public.accept_offer(text, uuid)",
  "arguments": [
    { "name": "p_idempotency_key", "sql_type": "text", "optional": false, ... },
    { "name": "p_offer_id",        "sql_type": "uuid", "optional": false, ... }
  ],
  "returns": { "kind": "scalar", "schema": { "type": "string", "enum": [...], "enum_name": "job_status" } },
  "errors": ["ERR_ILLEGAL_TRANSITION", "ERR_OFFER_EXPIRED", "ERR_OFFER_NOT_ACTIVE",
             "ERR_OFFER_NOT_FOUND", "ERR_OFFER_NOT_YOUR_TURN"],
  "idempotency_key": "p_idempotency_key",
  "requires": { "authenticated": true },
  "defined_in": "20260918120200_providers_and_matching.sql"
}
```

`returns.kind` is `scalar`, `rows` or `none`. `errors` is every `ERR_` code reachable in that
function's body — treat it as the set your UI must have a message for, not as a ranking.
`requires` is what the **caller** must be; a guard the function applies to somebody else (that the
provider being accepted is still active, say) is not listed, because it is not a precondition the
app can check.

## How an error arrives

| Path | HTTP | Body | Where the code is |
|---|---|---|---|
| `supabase.rpc(...)` through PostgREST | From the SQLSTATE: `28*` 403; `42501` 403 signed in / 401 anonymous; `P0001` and `22*` 400; `23505` 409 | `{ code: <sqlstate>, message: <ERR_ code>, details, hint }` | `message` |
| Edge Function | As listed per code | `{ error: { code, request_id } }`, header `x-request-id` | `error.code` |
| Supabase Auth | Auth's own | `AuthApiException.code` | map with `error-codes/auth-mapping.json` |

## Changing it

Backend: change the code, run the generator, update `../CHANGELOG.md` with a semver entry, and
add a migration note to `HANDOFF.md` for anything breaking (rule 2).

Frontend: open a request in [`../CHANGE_REQUESTS.md`](../CHANGE_REQUESTS.md). Claude Code marks it
ACCEPTED, REJECTED or SHIPPED with a reason. Do not work around a missing field by deriving it on
the client — if the server should be sending it, the answer is a change request, and if it should
not, deriving it is the bug.

## What is not here, and why

Nothing is omitted by accident. These are missing because the thing they would describe does not
exist yet, and each is blocked on a credential rather than on work:

| Absent | Blocked on |
|---|---|
| Push payload contract | APNs/FCM credentials (client action 6). The worker builds the payload; nothing sends it |
| LiveKit token endpoint | A LiveKit account (client action 11) |
| Masked-number contract | No telephony provider is contracted. `request_pstn_fallback` returns NULL and records the demand |
| Gateway checkout payload | Merchant accounts (client action 4). Shapes come from the S-12 sandbox, and are not guessed here |
| `classify_request` embeddings | ADR-0006 must pick a model before a vector dimension can be fixed |
| `saved_places`, `reveal_access_note` | Specified in the RLS matrix §4, not built. See `docs/audit/AUDIT-2026-09-22c.md` |
