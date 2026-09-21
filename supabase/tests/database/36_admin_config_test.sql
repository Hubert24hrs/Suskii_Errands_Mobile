-- Country packs, feature flags, remote config and the four eyes over them (spec phase 8,
-- "country packs, settings"; RLS matrix §1 and §10), plus the analytics views and the export
-- cursor behind them.
--
-- The point of the four-eyes path is that there is no other path: these tables have had no write
-- grant for any client role since Phase 2, and adding one now would have been the wrong fix.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(52);

INSERT INTO auth.users (id, phone) VALUES
  ('a1111111-1111-4111-8111-333333333333', '2348000000401'),   -- super admin, proposes
  ('a2222222-2222-4222-8222-333333333333', '2348000000402'),   -- super admin, approves
  ('a3333333-3333-4333-8333-333333333333', '2348000000403'),   -- super admin, second approver
  ('a4444444-4444-4444-8444-333333333333', '2348000000404'),   -- finance officer
  ('a5555555-5555-4555-8555-333333333333', '2348000000405');   -- nobody in particular
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('a1111111-1111-4111-8111-333333333333',
                  'a2222222-2222-4222-8222-333333333333',
                  'a3333333-3333-4333-8333-333333333333',
                  'a4444444-4444-4444-8444-333333333333',
                  'a5555555-5555-4555-8555-333333333333');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('a1111111-1111-4111-8111-333333333333', ARRAY['super_admin']::public.admin_role[]),
  ('a2222222-2222-4222-8222-333333333333', ARRAY['super_admin']::public.admin_role[]),
  ('a3333333-3333-4333-8333-333333333333', ARRAY['super_admin']::public.admin_role[]),
  ('a4444444-4444-4444-8444-333333333333', ARRAY['finance_officer']::public.admin_role[]);

CREATE TEMP TABLE cc (name text PRIMARY KEY, id uuid);
GRANT ALL ON cc TO authenticated, service_role;

-- The three sessions this test speaks from. An admin verb needs `aal2`: a stolen token without
-- MFA is exactly what `has_admin_role` refuses.
CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    format('{"sub": %L, "role": "authenticated", "aal": "aal2"}', p_user), true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- Nobody writes config directly, which is the premise everything else rests on.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a1111111-1111-4111-8111-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$UPDATE public.remote_config SET value = '9999'
                   WHERE key = 'settlement_hold_hours'$$,
  '42501', NULL, 'not even a super admin writes remote config by hand');
SELECT throws_ok($$UPDATE public.countries SET commission_rate_bps = 2000 WHERE code = 'NG'$$,
  '42501', NULL, 'nor a commission rate');

-- ---------------------------------------------------------------------------
-- One approver, and it cannot be the proposer.
-- ---------------------------------------------------------------------------
INSERT INTO cc VALUES ('flag', public.propose_config_change('key-cfg-flag-000000001',
  'feature_flag', 'calls.pstn_fallback', '{"enabled": true, "rollout_pct": 25}'::jsonb));
SELECT is((SELECT approvals_required FROM public.config_changes
           WHERE id = (SELECT id FROM cc WHERE name = 'flag')), 1::smallint,
  'a kill switch needs one other pair of eyes');
SELECT is((SELECT enabled FROM public.feature_flags
           WHERE key = 'calls.pstn_fallback' AND country_code IS NULL), false,
  'and nothing has changed yet: a proposal is not a write');
SELECT throws_ok(
  format($$SELECT public.review_config_change('key-cfg-self-00000001', %L, true)$$,
         (SELECT id FROM cc WHERE name = 'flag')),
  '42501', NULL, 'the proposer cannot approve their own change');
RESET ROLE;

SELECT pg_temp.act('a2222222-2222-4222-8222-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-flag-ok-000001',
            (SELECT id FROM cc WHERE name = 'flag'), true), 'applied',
  'a second super admin applies it');
RESET ROLE;
SELECT is((SELECT enabled FROM public.feature_flags
           WHERE key = 'calls.pstn_fallback' AND country_code IS NULL), true,
  'and now the flag is on');
SELECT is((SELECT rollout_pct FROM public.feature_flags
           WHERE key = 'calls.pstn_fallback' AND country_code IS NULL), 25::smallint,
  'with the percentage the proposal named');
SELECT is((SELECT client_visible FROM public.feature_flags
           WHERE key = 'calls.pstn_fallback' AND country_code IS NULL), true,
  'and the field it did not name left alone — a proposal is a diff, not a replacement');
SELECT ok((SELECT count(*) FROM audit.log WHERE action = 'config.review') > 0,
  'the decision is in the audit log');

-- ---------------------------------------------------------------------------
-- Two approvers, for money and for going live.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a1111111-1111-4111-8111-333333333333');
SET LOCAL ROLE authenticated;
INSERT INTO cc VALUES ('rate', public.propose_config_change('key-cfg-rate-000000001',
  'country', 'NG', '{"commission_rate_bps": 1300}'::jsonb));
SELECT is((SELECT approvals_required FROM public.config_changes
           WHERE id = (SELECT id FROM cc WHERE name = 'rate')), 2::smallint,
  'changing what the platform takes needs two');
RESET ROLE;

SELECT pg_temp.act('a2222222-2222-4222-8222-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-rate-a1-000001',
            (SELECT id FROM cc WHERE name = 'rate'), true), 'pending',
  'the first signature is not enough');
SELECT throws_ok(
  format($$SELECT public.review_config_change('key-cfg-rate-a2-000001', %L, true)$$,
         (SELECT id FROM cc WHERE name = 'rate')),
  '42501', NULL, 'and the same person cannot sign twice, which no CHECK could see');
RESET ROLE;
SELECT is((SELECT commission_rate_bps FROM public.countries WHERE code = 'NG'), 1250,
  'so the rate has not moved');

SELECT pg_temp.act('a3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-rate-a3-000001',
            (SELECT id FROM cc WHERE name = 'rate'), true), 'applied',
  'the second one applies it');
RESET ROLE;
SELECT is((SELECT commission_rate_bps FROM public.countries WHERE code = 'NG'), 1300,
  'and Nigeria takes 13% from now on');
SELECT is((SELECT version FROM public.countries WHERE code = 'NG'), 2,
  'the pack version moves with it');

-- ---------------------------------------------------------------------------
-- A country is live only when its pack is complete.
-- ---------------------------------------------------------------------------
SELECT set_eq(
  $$SELECT unnest(private.country_pack_gaps('KE'))$$,
  ARRAY['config.server.payment_providers', 'config.server.payout_providers',
        'legal.privacy', 'legal.terms'],
  'Kenya is missing the four things that would make it live in name only');

SELECT pg_temp.act('a1111111-1111-4111-8111-333333333333');
SET LOCAL ROLE authenticated;
INSERT INTO cc VALUES ('live', public.propose_config_change('key-cfg-live-000000001',
  'country', 'KE', '{"status": "live"}'::jsonb));
RESET ROLE;
SELECT pg_temp.act('a2222222-2222-4222-8222-333333333333');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$SELECT public.review_config_change('key-cfg-live-a2-000001', %L, true)$$,
         (SELECT id FROM cc WHERE name = 'live')),
  'the first of two signatures is fine');
RESET ROLE;
SELECT pg_temp.act('a3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.review_config_change('key-cfg-live-a3-000001', %L, true)$$,
         (SELECT id FROM cc WHERE name = 'live')),
  'P0001', 'ERR_COUNTRY_PACK_INCOMPLETE',
  'and the last one refuses, because the pack is not finished');
RESET ROLE;
SELECT is((SELECT status FROM public.countries WHERE code = 'KE'),
  'beta'::public.country_status, 'Kenya stays in beta');
SELECT is((SELECT status FROM public.config_changes
           WHERE id = (SELECT id FROM cc WHERE name = 'live')), 'pending',
  'and the change stays pending rather than claiming it was applied');

-- Fill the gaps and it goes through.
INSERT INTO public.legal_documents (country_code, type, version, locale, url, published_at) VALUES
  ('KE', 'terms',   1, 'en', 'https://suskii.invalid/ke/terms/v1',   now()),
  ('KE', 'privacy', 1, 'en', 'https://suskii.invalid/ke/privacy/v1', now());
UPDATE public.countries SET config = jsonb_set(jsonb_set(config,
    '{server,payment_providers}', '["flutterwave", "paystack"]'::jsonb),
    '{server,payout_providers}', '["flutterwave"]'::jsonb)
WHERE code = 'KE';
SELECT is(cardinality(private.country_pack_gaps('KE')), 0, 'now the pack is complete');

SELECT pg_temp.act('a3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-live-a3-000002',
            (SELECT id FROM cc WHERE name = 'live'), true), 'applied',
  'and the same approval now lands');
RESET ROLE;
SELECT is((SELECT status FROM public.countries WHERE code = 'KE'),
  'live'::public.country_status, 'Kenya is live');
SELECT isnt((SELECT approved_at FROM public.countries WHERE code = 'KE'), NULL,
  'and approved, which the spec asks for in the same breath as complete');

-- A pack that routes only to the development provider is not complete either: it would report a
-- customer paid when nobody did.
UPDATE public.countries
SET config = jsonb_set(config, '{server,payment_providers}', '["console"]'::jsonb)
WHERE code = 'GH';
SELECT ok('config.server.payment_providers.console_only'
          = ANY (private.country_pack_gaps('GH')),
  'and routing a live country to the console provider is itself a gap');

-- ---------------------------------------------------------------------------
-- A rejection, and who may look.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a1111111-1111-4111-8111-333333333333');
SET LOCAL ROLE authenticated;
INSERT INTO cc VALUES ('bad', public.propose_config_change('key-cfg-bad-000000001',
  'remote_config', 'settlement_hold_hours', '{"value": 1}'::jsonb));
RESET ROLE;
SELECT pg_temp.act('a2222222-2222-4222-8222-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-bad-no-000001',
            (SELECT id FROM cc WHERE name = 'bad'), false, 'too_short'), 'rejected',
  'a change can simply be refused');
RESET ROLE;
SELECT is((SELECT (rc.value #>> '{}')::integer FROM public.remote_config rc
           WHERE rc.key = 'settlement_hold_hours'), 24,
  'and nothing moves');

SELECT pg_temp.act('a5555555-5555-4555-8555-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.propose_config_change('key-cfg-nobody-00000001',
                     'remote_config', 'anything', '{"value": 1}'::jsonb)$$,
  '42501', NULL, 'somebody with no admin role proposes nothing');
SELECT is((SELECT count(*)::int FROM public.config_changes), 0,
  'and cannot read the queue either');
RESET ROLE;

SELECT pg_temp.act('a4444444-4444-4444-8444-333333333333');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.config_changes) > 0,
  'any admin can see what has been proposed — a vanished feature is support''s question too');
SELECT throws_ok($$SELECT public.propose_config_change('key-cfg-fin-000000001',
                     'country', 'NG', '{"status": "disabled"}'::jsonb)$$,
  '42501', NULL, 'but a finance officer does not change country packs');

-- ---------------------------------------------------------------------------
-- A campaign is a budget, so it takes two as well — and finance may propose one.
-- ---------------------------------------------------------------------------
INSERT INTO cc VALUES ('camp', public.propose_config_change('key-cfg-camp-000000001',
  'referral_campaign', 'new',
  jsonb_build_object('name', 'Lagos launch', 'rate_bps', 500, 'currency', 'NGN',
                     'budget_minor', 5000000, 'starts_at', now(),
                     'ends_at', now() + interval '30 days'),
  'NG'));
SELECT is((SELECT approvals_required FROM public.config_changes
           WHERE id = (SELECT id FROM cc WHERE name = 'camp')), 2::smallint,
  'a campaign spends money, so two people sign for it');
RESET ROLE;

SELECT pg_temp.act('a1111111-1111-4111-8111-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-camp-a1-000001',
            (SELECT id FROM cc WHERE name = 'camp'), true), 'pending', 'one signature');
RESET ROLE;
SELECT pg_temp.act('a2222222-2222-4222-8222-333333333333');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-cfg-camp-a2-000001',
            (SELECT id FROM cc WHERE name = 'camp'), true), 'applied', 'and then two');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.referral_campaigns WHERE name = 'Lagos launch'), 1,
  'the campaign exists');
SELECT is((SELECT spent_minor FROM public.referral_campaigns WHERE name = 'Lagos launch'),
  0::bigint, 'having spent nothing yet');

-- ---------------------------------------------------------------------------
-- Analytics: aggregates, the cursor, and nothing personal.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM information_schema.columns
           WHERE table_schema = 'analytics'
             AND column_name IN ('user_id', 'customer_id', 'provider_id', 'referrer_id',
                                 'payer_id', 'phone', 'display_name', 'email',
                                 'description', 'name')), 0,
  'not one analytics column names a person: that is what pseudonymised means here');

SELECT ok((SELECT count(*)::int FROM analytics.exports WHERE enabled) >= 16,
  'every view is registered for export');
SELECT is((SELECT count(*)::int FROM analytics.exports WHERE exported_through IS NOT NULL), 0,
  'and none has been shipped yet');
SELECT ok((SELECT count(*)::int FROM analytics.due_exports()) >= 16,
  'so all of them are outstanding');
SELECT is((SELECT export_to FROM analytics.due_exports() LIMIT 1), current_date - 1,
  'up to yesterday: a partial day re-exported tomorrow would double-count');

SELECT lives_ok($$SELECT analytics.record_export('jobs_daily', current_date - 1, 12)$$,
  'the worker reports what it shipped');
SELECT is((SELECT exported_through FROM analytics.exports WHERE view_name = 'jobs_daily'),
  current_date - 1, 'and the cursor moves');
SELECT lives_ok(
  $$SELECT analytics.record_export('jobs_daily', current_date, 0, 'bigquery unreachable')$$,
  'a failed run is recorded');
SELECT is((SELECT exported_through FROM analytics.exports WHERE view_name = 'jobs_daily'),
  current_date - 1,
  'and the cursor does not move, so the window it missed is still outstanding');
SELECT is((SELECT count(*)::int FROM analytics.export_health(0)
           WHERE view_name = 'jobs_daily'), 1,
  'which the health check notices');
SELECT throws_ok($$SELECT analytics.record_export('not_a_view', current_date, 1)$$,
  '22023', NULL, 'a view nobody registered cannot report an export');

SELECT pg_temp.act('a5555555-5555-4555-8555-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.analytics_report('jobs_daily')$$,
  '42501', NULL, 'and the dashboards are not open to everybody');
RESET ROLE;
SELECT pg_temp.act('a4444444-4444-4444-8444-333333333333');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT * FROM public.analytics_report('jobs_daily')$$,
  'a finance officer reads them');
SELECT throws_ok($$SELECT * FROM public.analytics_report('pg_class')$$,
  '22023', NULL,
  'and the registry is the allowlist, so a view name can only ever be one of ours');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
