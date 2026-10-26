# RB-08 — Taking a country live

| | |
|---|---|
| Owner | Claude Code / ops / the client |
| Severity | Not an incident. A planned change with a rollback, run to a checklist |
| Last rehearsed | **2026-10-26, on staging**, the database half with a fake country (`ZZ`) taken `disabled → beta → live → disabled` through the four-eyes flow by three temporary super admins, inside a block that rolled itself back (rehearsal record below). Everything refused what it should and applied what it should. **Finding:** `countries.approved_by` recorded the proposer, not the approver (fixed in `…20261026195000_country_approved_by`). Not rehearsed: the sign-offs in *The things the gap check cannot see*, the week of watching, and the apps seeing the change at their next bootstrap |
| Related | OD-07, OD-12, OD-14, OD-23, OD-24; `docs/research/country-packs/*.yaml`; ADR-0001; RB-13, RB-14, RB-01 |

## What "live" means

`public.countries.status` is `disabled | beta | live`. The spec's rule is one line — a country goes
live only when its pack is complete — and `private.country_pack_gaps(code)` makes it mechanical
rather than a matter of somebody's judgement at the time.

```sql
SELECT * FROM public.country_pack_readiness('NG');
-- country_code | status | gaps | ready
```

`ready` is false while `gaps` is non-empty. The gaps it checks:

| Gap | Means |
|---|---|
| `cities` | No city rows, so matching has nowhere to happen |
| `legal.terms` | No terms document for the country |
| `legal.privacy` | No privacy policy for the country |
| `config.client.accepted_id_types` | Verification does not know what ID to accept |
| `config.server.sms_providers` | No OTP route |
| `config.server.payment_providers` | No way to take money |
| `config.server.payout_providers` | No way to pay providers |
| `config.server.payment_providers.console_only` | **The pack routes only to the development provider.** A live country on the console provider would report a customer as paid when nobody paid. The Edge Function refuses it too; refusing it here means nobody has to find out that way |

The status change itself goes through `propose_config_change` / `review_config_change` and needs
**two signatures** — a country going live is on the two-approver list, alongside commission and
referral rates. A proposal is a diff, so a field it does not name is left alone.

## The things the gap check cannot see

`country_pack_gaps` checks what is in the database. These are not in the database and are the ones
that actually block a launch:

| Gate | Who signs | Open decision |
|---|---|---|
| Funds-holding model and operating entity | Counsel | **OD-12** |
| Restricted items and prohibited services list | Counsel | **OD-24** — every rule is currently tagged `[A]` and no lawyer has read one |
| Data protection registration | Counsel | OD-15 |
| Price guardrails calibrated | Client | **OD-23** — today seven of Nigeria's twelve categories have no hard cap, and the other four countries are uncapped entirely. A hard cap is a fraud control, not a pricing opinion |
| Merchant account live, not sandbox | Client | Client action 4 |
| Police-clearance recency rule | Client + counsel | OD-09 |
| SOS partner contracted for the city | Client | Client action 12 — and RB-06's escalation is a phone call until it is |
| Trip-share link base set | Ops | `remote_config.trip_share_base_url` (global): the page a trusted contact opens. Until it is set, `create_trip_share` returns no URL and the app says sharing is unavailable. Needs the domain (I-2) |

**Do not flip a country to `live` with any of these open.** The gap check passing is necessary and
nowhere near sufficient.

**`beta` is not gated by the pack at all**, on purpose: the testers' sandbox runs Nigeria in `beta`
on the development providers, and closed testing needs that. So the checklist in step 1 is the only
thing between an incomplete pack and real customers in beta. Treat it as a gate, not a formality.

**A refused `live` stays `pending`.** When the last signature hits an incomplete pack, the change
is not applied and is not rejected either; once the pack is complete, the same change lands on the
next signature (`36_admin_config_test` asserts this). If the refusal meant *not yet*, that is
convenient. If it meant *no*, reject the change explicitly, as the 2026-10-26 rehearsal did, so a
signature given weeks ago does not take a country live today.

## Procedure

### 0. On a new production project (once)

A project built from the migrations alone (RB-14) already holds the five countries, every one
`disabled`, with their service areas (Nigeria's 36 states and the FCT) and the service catalogue
(migration `20261024150000`; CI proves it on every change with
`supabase/tools/check_production_reference.sql` against a database reset with `--no-seed`). It
holds no admin, no legal page, no SMS, payment or payout provider. Nobody can sign up by phone
until a country is `beta`, because the before-user-created hook refuses a number from a country
that is not open; email accounts are accepted.

1. **The first two admins** — the only step outside the four-eyes flow, because there is nobody
   to approve the first approver. Create two email accounts (Supabase dashboard → Authentication →
   Add user, or `auth.admin.createUser` with the service role), then, in the SQL editor as the
   service role:

   ```sql
   INSERT INTO public.admin_users (user_id, roles, country_scope)
   SELECT id, ARRAY['super_admin']::public.admin_role[], NULL
   FROM auth.users WHERE email IN ('<first admin>', '<second admin>');
   ```

   Each signs in to the admin console and enrols TOTP (`aal2`) before any admin verb works. Every
   later staff change goes through `propose_config_change('admin_user', …)`. Record who ran the
   insert, and when, in `HANDOFF.md`.
2. **Legal pages.** `legal_documents` has no write path for a client or an admin, on purpose: a
   policy's version and URL are reviewed like code. Once counsel has approved and published the
   pages (action 16, OD-24), add a migration with the rows (`terms`, `privacy`, and for KYC
   `biometric_consent` and `criminal_record_consent`) for the country, `published_at` set.
3. **Providers.** Once the SMS sender ID and the gateway merchant accounts exist (actions 4 and 5),
   propose the country's `server` config. `client` and `server` are each replaced whole by a
   proposal, so restate every server key:

   ```sql
   SELECT public.propose_config_change(gen_random_uuid()::text, 'country', 'NG',
     '{"config": {"server": {"sms_providers": ["<vendor>"], "payment_providers": ["flutterwave", "paystack"],
                             "payout_providers": ["flutterwave"]}}}'::jsonb, NULL, 'NG providers');
   ```

   The provider names must be ones the Edge Functions implement; `console` exists for development
   only and `payments-worker` refuses it in production.

### 1. Two weeks before

- [ ] `country_pack_readiness` returns `ready = true`.
- [ ] Every row in the table above is signed, with the sign-off recorded in `docs/OPEN-DECISIONS.md`.
- [ ] The pack's `_status` fields say `verified`, not `assumption`. A pack full of `[A]` tags is a
      research document, not a configuration.
- [ ] Guardrails calibrated for **every** category offered, not just the ones with data (OD-23).
- [ ] `prohibited_items` reviewed by counsel for that jurisdiction (OD-24).
- [ ] RB-01, RB-02, RB-06 and RB-14 rehearsed for this country's staff and hours.

### 2. Move to `beta` first

Always. `beta` allows sign-ups and jobs; it just means you have not told the world.

```sql
SELECT public.propose_config_change(gen_random_uuid()::text, 'country', 'NG',
  jsonb_build_object('status', 'beta'), NULL, 'Go-live step 1: beta');
-- then, as a second, different admin (signed in with TOTP), or from the admin console:
SELECT public.review_config_change(gen_random_uuid()::text, :id, true);
```

Run real jobs with real money in beta. Not test accounts — real customers, real providers, small
volume, watched. The first live payment in a country is the one that finds the thing nobody thought
of, and you want it to find it while you are looking.

### 3. Watch, for at least a week

| Watch | Where | Stop and roll back if |
|---|---|---|
| Payments confirming | RB-02's first query | Any payment charged and not confirmed |
| Ledger clean | `ledger.reconcile()` nightly | One unexplained mismatch (RB-03) |
| Payouts landing | `kpi_payout_failures` | More than a handful, or any reversal |
| OTP delivery | SMS provider dashboard | Sign-ups failing at OTP |
| Verification throughput | `kyc_review_queue()` | Queue growing faster than it drains |
| SOS | `ops:sos` | **Any SOS at all** — stop and review before growing |
| Moderation | `moderation_queue()` | Rules firing on ordinary requests, or not firing at all |

### 4. Go live

Same two-signature path, `beta → live`. Then, and only then, marketing.

## Backout

Going back is cheap and should feel cheap. `live → beta` hides the country without stopping anyone
mid-job. `beta → disabled` stops new sign-ups; the Before User Created Hook refuses phone sign-ups
for a non-live/beta country immediately, while apps see it at their next bootstrap.

**In-flight jobs keep running.** Disabling a country must never strand a provider halfway through a
delivery with money held. If the country genuinely must stop dead, let the open jobs finish and
settle first, or you have converted a configuration change into RB-02 and RB-04 at once.

## Communication

- **Internal, before:** the date, who is watching, and what would make us roll back — agreed in
  advance, so the decision is not taken by whoever is most tired.
- **Providers, before customers.** A country that goes live with demand and no supply teaches
  customers it does not work, and they do not come back for the second launch.
- **Counsel:** confirm the sign-offs are current on the day, not from six weeks ago.
- **Regulator:** per-country registration is OD-15. If registration is a precondition rather than a
  notification, it belongs in section 1, not here.

## After

- Write down what the first week found, in `docs/research/country-packs/<CODE>.yaml`, with evidence
  tags. This is the moment the pack stops being `[A]`.
- Re-check the guardrails against real prices. The placeholders were always meant to be replaced by
  pilot data, and this is the pilot data.
- Update the Status table in `CLAUDE.md` and file a HANDOFF entry.

## Rehearsal record

| Date | Environment | What ran | Result |
|---|---|---|---|
| 2026-10-26 | **Staging** (`suskii-staging`) | One `DO` block that ends by raising its findings, so every write rolls back. A fake country `ZZ` inserted `disabled`, as a migration would; three temporary `super_admin`s (A proposes, B and C sign) with `aal2` and a TOTP `amr` entry; then: `live` straight away; cities and legal pages by insert; providers by proposal, first the development provider, then real ones; `beta`; `live`; back out to `beta` and `disabled` | Gaps at the start: all seven. `live` needs **2** signatures, `beta` and the backout **1** each. A reviewing their own change: `ERR_PERMISSION_DENIED`. The early `live` took B's signature, then C's hit `ERR_COUNTRY_PACK_INCOMPLETE`; the change stayed `pending` and the country `disabled`; C then rejected it. On the development provider the only gap left was `config.server.payment_providers.console_only`. A config proposal naming only `server` kept `client` (`accepted_id_types` still `["nin"]`): a proposal is a diff, as written. Then `ready`, `beta`, `live` (B again: refused as already signed; C with a TOTP ten minutes old: `ERR_REAUTH_REQUIRED`; C fresh: applied), and the backout to `disabled`. Version 7, six changes applied and one rejected, 58 audit rows. **Finding:** `countries.approved_by` was the proposer, A, on every step; fixed, and asserted in `36_admin_config_test` |
