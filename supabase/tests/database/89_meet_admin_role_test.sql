-- Meet v5 M1-PR1 (20261126120000): the new enum values, and the any-admin gates held to the
-- inventory in that migration's header.
--
-- `is_any_admin()` grows with `admin_role`, so adding meet_moderator widened every gate written
-- with it. Ten were restated to name the five roles they admitted before, and one, the role-name
-- check in a staff change, was left open on purpose. Each is asserted from both sides: the meet
-- moderator is refused, and the roles that passed before still pass. The deny half alone would
-- pass whether the restatement was right or the gate had simply broken for everybody.
--
-- pgTAP 89 is the one unassigned number in the design's 72-89 range (§1.6), so the numbers it
-- gives M1-PR2 onward are untouched.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(41);

INSERT INTO auth.users (id, phone) VALUES
  ('b8911111-1111-4111-8111-898989898989', '2348000008901'),   -- meet moderator, scoped NG
  ('b8922222-2222-4222-8222-898989898989', '2348000008902'),   -- meet moderator, unscoped
  ('b8933333-3333-4333-8333-898989898989', '2348000008903'),   -- support agent, scoped NG
  ('b8944444-4444-4444-8444-898989898989', '2348000008904'),   -- meet moderator and support
  ('b8955555-5555-4555-8555-898989898989', '2348000008905'),   -- super admin A
  ('b8966666-6666-4666-8666-898989898989', '2348000008906'),   -- super admin B
  ('b8977777-7777-4777-8777-898989898989', '2348000008907');   -- nobody, not staff yet
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id::text LIKE 'b89%-898989898989';
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('b8911111-1111-4111-8111-898989898989', ARRAY['meet_moderator']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('b8922222-2222-4222-8222-898989898989', ARRAY['meet_moderator']::public.admin_role[], NULL),
  ('b8933333-3333-4333-8333-898989898989', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('b8944444-4444-4444-8444-898989898989',
   ARRAY['meet_moderator', 'support_agent']::public.admin_role[], ARRAY['NG']::char(2)[]),
  ('b8955555-5555-4555-8555-898989898989', ARRAY['super_admin']::public.admin_role[], NULL),
  ('b8966666-6666-4666-8666-898989898989', ARRAY['super_admin']::public.admin_role[], NULL);

-- One pending proposal, so "reads none" means refused rather than empty.
INSERT INTO public.config_changes (target, target_key, proposed, approvals_required, requested_by)
VALUES ('feature_flag', 'calls.pstn_fallback', '{"enabled": true}', 1,
        'b8955555-5555-4555-8555-898989898989');

-- What the table holds, read as the owner, so an allowed read can be held to "all of it".
CREATE TEMP TABLE expected (name text PRIMARY KEY, n integer);
INSERT INTO expected VALUES
  ('feature_flags', (SELECT count(*) FROM public.feature_flags)),
  ('remote_config', (SELECT count(*) FROM public.remote_config)),
  ('countries', (SELECT count(*) FROM public.countries));
CREATE TEMP TABLE grant_change (id uuid);
GRANT ALL ON expected, grant_change TO authenticated;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)
     -- A session that has passed MFA entered its code just now (the step-up, Z.11).
     || CASE WHEN p_aal = 'aal2' THEN jsonb_build_object('amr', jsonb_build_array(
          jsonb_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::bigint)))
        ELSE '{}'::jsonb END)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- The values.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT r[array_position(r, 'call_missed') : array_position(r, 'call_missed') + 5]
   FROM (SELECT enum_range(NULL::public.notification_kind)::text[] AS r) x),
  ARRAY['call_missed', 'meet_like', 'meet_match', 'meet_message', 'meet_reminder', 'meet_account'],
  'notification_kind gains the five M1 Meet kinds, appended after the last existing one');
SELECT is(
  (SELECT count(*)::int
   FROM unnest(ARRAY['meet_like', 'meet_match', 'meet_message', 'meet_reminder',
                     'meet_account']::public.notification_kind[]) k
   WHERE private.notification_is_urgent(k)), 0,
  'none of them is urgent, so quiet hours always apply (design 2.8)');
SELECT ok('meet_moderator' = ANY (enum_range(NULL::public.admin_role)::text[]),
  'admin_role gains meet_moderator');
SELECT ok(enum_range(NULL::public.consent_kind)::text[] @> ARRAY['meet_terms', 'meet_sensitive_data'],
  'consent_kind gains meet_terms and meet_sensitive_data');

-- ---------------------------------------------------------------------------
-- is_any_admin() admits the new role, and still only with MFA.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b8911111-1111-4111-8111-898989898989');
SET LOCAL ROLE authenticated;
SELECT ok(private.is_any_admin(), 'is_any_admin() admits a meet moderator with aal2');
RESET ROLE;
SELECT pg_temp.act('b8911111-1111-4111-8111-898989898989', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(NOT private.is_any_admin(), 'and not without MFA');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Gates 1 to 10 refuse a meet moderator.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b8911111-1111-4111-8111-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.feature_flags), 0,
  'gate 1: a meet moderator reads no feature flag');
SELECT is((SELECT count(*)::int FROM public.remote_config), 0,
  'gate 2: no remote config');
SELECT is((SELECT count(*)::int FROM public.countries), 0,
  'gate 3: no country pack, so no gateway routing or thresholds');
SELECT is((SELECT count(*)::int FROM public.config_changes), 0,
  'gate 4: no config proposal, so no staff grants or promo budgets');
SELECT throws_ok($$SELECT * FROM public.config_change_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 5: config_change_queue refuses');
SELECT throws_ok($$SELECT * FROM public.country_pack_readiness()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 6: country_pack_readiness refuses');
SELECT throws_ok($$SELECT * FROM public.admin_overview()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 7: the errands dashboard refuses');
SELECT throws_ok($$SELECT * FROM public.kpi_jobs_by_state(current_date - 30, current_date)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 8: kpi_jobs_by_state refuses');
SELECT throws_ok($$SELECT * FROM public.kpi_funnel(current_date - 30, current_date)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 9: kpi_funnel refuses');
SELECT throws_ok($$SELECT * FROM public.kpi_supply_demand(current_date - 30, current_date)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'gate 10: kpi_supply_demand refuses');
RESET ROLE;

-- The scope is not what refuses them: an unscoped meet moderator is refused the same way.
SELECT pg_temp.act('b8922222-2222-4222-8222-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.countries), 0,
  'an unscoped meet moderator reads no country pack either');
SELECT throws_ok($$SELECT * FROM public.admin_overview()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'nor the dashboard');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The roles that passed before still pass every one.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b8933333-3333-4333-8333-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.feature_flags),
  (SELECT n FROM expected WHERE name = 'feature_flags'), 'a support agent still reads every flag');
SELECT is((SELECT count(*)::int FROM public.remote_config),
  (SELECT n FROM expected WHERE name = 'remote_config'), 'and all remote config');
SELECT is((SELECT count(*)::int FROM public.countries),
  (SELECT n FROM expected WHERE name = 'countries'), 'and every country pack');
SELECT is((SELECT count(*)::int FROM public.config_changes), 1, 'and the proposal');
SELECT is((SELECT count(*)::int FROM public.config_change_queue()), 1, 'and the queue');
SELECT lives_ok($$SELECT * FROM public.country_pack_readiness()$$, 'and the go-live gaps');
SELECT ok((SELECT count(*) FROM public.admin_overview()) > 0,
  'and the dashboard, with a row for Nigeria');
SELECT lives_ok($$SELECT * FROM public.kpi_jobs_by_state(current_date - 30, current_date)$$,
  'and kpi_jobs_by_state');
SELECT lives_ok($$SELECT * FROM public.kpi_funnel(current_date - 30, current_date)$$,
  'and kpi_funnel');
SELECT lives_ok($$SELECT * FROM public.kpi_supply_demand(current_date - 30, current_date)$$,
  'and kpi_supply_demand');
RESET ROLE;

-- The gate asks for one of the five roles; it does not refuse meet moderators as such.
SELECT pg_temp.act('b8944444-4444-4444-8444-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.feature_flags),
  (SELECT n FROM expected WHERE name = 'feature_flags'),
  'a meet moderator who is also a support agent keeps support''s reads');
SELECT lives_ok($$SELECT * FROM public.admin_overview()$$, 'including the dashboard');
RESET ROLE;

SELECT pg_temp.act('b8955555-5555-4555-8555-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.countries),
  (SELECT n FROM expected WHERE name = 'countries'), 'a super admin reads every country pack');
SELECT is((SELECT count(*)::int FROM public.config_change_queue()), 1,
  'and the config queue');
RESET ROLE;

SELECT pg_temp.act('b8977777-7777-4777-8777-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.feature_flags), 0,
  'somebody who is not staff still reads no flag rows');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Gate 11 stays open: the role is granted through the four-eyes staff change.
-- ---------------------------------------------------------------------------
SELECT is(private.config_proposal_problem('admin_user', 'b8977777-7777-4777-8777-898989898989',
    '{"roles": ["meet_moderator"]}', NULL, 'b8955555-5555-4555-8555-898989898989'), NULL,
  'gate 11: meet_moderator is a role a staff change may name');
SELECT is(private.config_proposal_problem('admin_user', 'b8977777-7777-4777-8777-898989898989',
    '{"roles": ["meet_mod"]}', NULL, 'b8955555-5555-4555-8555-898989898989'),
  'meet_mod is not a role', 'and a misspelling of it is still refused');

SELECT pg_temp.act('b8955555-5555-4555-8555-898989898989');
SET LOCAL ROLE authenticated;
INSERT INTO grant_change VALUES (public.propose_config_change('key-89-meet-mod-grant-01',
  'admin_user', 'b8977777-7777-4777-8777-898989898989',
  '{"roles": ["meet_moderator"], "country_scope": ["NG"]}'));
SELECT is((SELECT approvals_required FROM public.config_changes
           WHERE id = (SELECT id FROM grant_change)), 1::smallint,
  'a super admin proposes it; one other signature applies it');
RESET ROLE;
SELECT pg_temp.act('b8966666-6666-4666-8666-898989898989');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-89-meet-mod-grant-02',
  (SELECT id FROM grant_change), true), 'applied', 'a second super admin signs');
RESET ROLE;
SELECT is((SELECT roles FROM public.admin_users
           WHERE user_id = 'b8977777-7777-4777-8777-898989898989'),
  ARRAY['meet_moderator']::public.admin_role[], 'and the new meet moderator has the role');
SELECT is((SELECT country_scope FROM public.admin_users
           WHERE user_id = 'b8977777-7777-4777-8777-898989898989'),
  ARRAY['NG']::char(2)[], 'scoped to Nigeria');

SELECT is(private.custom_access_token_hook(jsonb_build_object(
    'user_id', 'b8977777-7777-4777-8777-898989898989', 'claims', '{}'::jsonb))
    -> 'claims' -> 'admin_roles',
  '["meet_moderator"]'::jsonb,
  'the access token carries the role, a hint for the console that the database never trusts');

SELECT pg_temp.act('b8977777-7777-4777-8777-898989898989');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.feature_flags), 0,
  'and granting it opens none of the ten gates');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
