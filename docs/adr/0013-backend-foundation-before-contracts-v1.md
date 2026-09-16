# ADR-0013 — Build the backend foundation before contracts v1

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | User (approved Option B in [timeline.md](../plan/timeline.md) §6), Claude Code |
| Unblocked by | — |

## Context

The spec's sequence has Claude Code build the backend only after contracts v1, which waits for Kimi Code's M8.5 hand-off (~2 Nov 2026). Phase 2 of the backend — projects, CI, schemas, auth hooks, audit log, outbox, identity tables — depends on the Phase 1 Stage A documents, not on any screen or contract content. Waiting would idle the backend for about seven weeks and push the Supabase spikes (S-02, S-11) back with it.

## Decision

Start Phase 2 now, on the user's approval (2026-09-16), with two rules that keep contracts v1 authoritative:

1. **Build only what Stage A already decides**: schemas, extensions, enums matching Kimi's committed wire values, money primitives, idempotency, outbox, audit log, reference configuration, admin identity, profiles, devices, consents, notification preferences, auth hooks and the bootstrap function. No marketplace, money-movement, KYC or communication tables before contracts v1.
2. **Pre-contract migrations stay editable until the first shared environment applies them.** No Supabase project exists yet, so editing a migration in place is cheaper and clearer than stacking corrective migrations. From the moment `suskii-dev` (or any shared database) applies them, migrations are append-only as usual. Anything whose shape contracts v1 may change — notably the `get_bootstrap()` response — is marked `PRE-CONTRACT` in its SQL.

## Consequences

**Good:** about two weeks off the base-case launch; Phase 3 starts the day contracts v1 lands; CI runs migrations and pgTAP on the real Supabase stack from day one; the S-02 questions below get answered by CI instead of waiting for a project.

**Bad / costs:** a contract decision at Stage B may rename a foundation column or reshape bootstrap, costing an edit before the first shared apply, or a migration after it. Accepted: the enums and identity tables already mirror Kimi's committed domain package.

**Follow-on work:** S-02 on a real project must confirm what the local fallback cannot:
- the `postgres` role has `BYPASSRLS` (the admin helper reads `admin_users`, which has FORCE RLS and a policy that calls the same helper);
- Auth hook payload and error shapes for `custom_access_token` and `before_user_created`;
- the `[auth.hook.send_sms]` config keys;
- `pg_cron` and `pgmq` availability and schemas on the chosen plan.

## Alternatives considered

| Option | Why not |
|---|---|
| Option A — spec order, start after contracts v1 | Seven idle backend weeks and later spikes, for no reduction in risk: foundation work does not depend on contract content |
| Build everything, including marketplace tables, now | Would pre-empt contracts v1 and force a breaking v2 when Kimi's full inventory lands (PHASE-1-PLAN) |

## Revisit when

Contracts v1 is published (re-check every foundation object against it), or the first shared Supabase environment applies these migrations (the editability rule ends).
