# S-13 — RLS default-deny and SECURITY DEFINER patterns (added spike)

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code |
| Status | **Passed, 17/17** |
| Harness | `spikes/postgres/S-13-rls/` (branch `spike/phase-0-runs`) |
| Feeds | Phase 2 RLS policy matrix, contracts v1, ADR for the access-control baseline |

## Why this spike exists

It is not in the original twelve. It was added because it needs **no credentials**: RLS, column privileges and `SECURITY DEFINER` are core Postgres, so the spec's access-control rules can be proven locally without a Supabase project. Supabase is emulated with the same primitives it uses — the `anon` / `authenticated` / `service_role` roles, and `auth.uid()` reading `request.jwt.claims`.

What it does *not* cover: the real JWT verification, PostgREST's exposure rules, Storage policies and Realtime authorisation. Those still need S-02 against a real project.

## Results

All 17 cases pass. Deny cases matter as much as allow cases, so both are asserted by SQLSTATE.

| # | Case | Expected |
|---|---|---|
| 1–2 | `anon` cannot read profiles or requests (default deny, no policy at all) | `42501` |
| 3–4 | An authenticated user reads only their own rows | 1 row |
| 5–6 | A user cannot raise their own `trust_level` or set `verified_at`, **even on their own row** | `42501` |
| 7 | A user can change their own `display_name` | allowed |
| 8–9 | A user cannot write `status` or `agreed_amount_minor` | `42501` |
| 10 | A user cannot insert a row owned by someone else | `42501` |
| 11 | A user can insert their own request | allowed |
| 12 | The owner can publish through the `SECURITY DEFINER` function | allowed |
| 13 | A non-owner cannot publish another user's request | `42501` |
| 14 | An unauthenticated caller is refused | `28000` |
| 15–16 | A Verification Officer reads every profile but writes none | 2 rows / `42501` |
| 17 | `service_role` bypasses RLS entirely | 2 rows |

## Findings

**1. RLS alone does not protect a column.** Cases 5, 6, 8 and 9 pass only because of `GRANT UPDATE (display_name)` — column-level privileges. With RLS alone, a user owns the row and may rewrite `trust_level`, `status` or `agreed_amount_minor` on it. The spec calls for "column privileges + RLS + triggers"; this shows the column privileges are doing the load-bearing work, and a policy matrix that lists only policies is incomplete.

**2. `auth.uid()` must tolerate missing claims — a real fix.** The first implementation cast the claims GUC straight to `json`. With no claims set, an unauthenticated call raised `22P02` (invalid text representation) instead of a clean `28000`. Every anonymous call would have surfaced as a confusing cast error rather than "not signed in". The fix is `nullif(current_setting(...), '')` **before** the cast, so the function returns NULL. This belongs in the real helper.

**3. `BYPASSRLS` is not a grant.** `service_role` ignores policies but still needs table privileges; without them it gets `42501`. Useful to know before debugging a service-role path, and a reminder that the service key is a full bypass of every policy — the spec's "never in any client" rule is exactly right.

**4. Under RLS an attacker cannot even name another user's row.** Case 13 initially "passed" the wrong way: the subquery `min(id) FROM requests` was itself filtered by the attacker's RLS, so they published their *own* request. The real test hands over the foreign id explicitly. Worth remembering when writing negative tests — a deny test that silently tests the wrong row proves nothing.

**5. `FORCE ROW LEVEL SECURITY` is worth setting.** Without it the table owner bypasses policies, which hides mistakes in functions that run as the owner.

## Carry into Phase 2

These become pgTAP tests, and the pattern below becomes the baseline for every exposed table:

```sql
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- no policy for anon: default deny
GRANT SELECT, INSERT ON t TO authenticated;      -- table privileges
GRANT UPDATE (only_user_writable_columns) ON t TO authenticated;   -- column privileges
-- state and money change only through SECURITY DEFINER functions with:
--   SET search_path = ''   and an explicit auth.uid() check
```

The RLS policy matrix in Phase 1 must have a column for **writable columns**, not just policies, or finding 1 will be missed.
