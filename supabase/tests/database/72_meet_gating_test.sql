-- Meet v5 M1-PR2 (20261126120100): the contract skeleton, the flags, testers-only gating and the
-- readiness guard (design §2.3, §3.3, §9 M1-PR2).
--
-- What has to hold before any Meet feature is built: every M1 RPC exists with its final
-- signature, none does anything yet, nobody signed out can reach one, the flags start off, only
-- testers pass a testers-only flag, and Meet cannot leave testers (by any write path, the
-- four-eyes config change included) until the checklist is complete, while switching it off
-- always works.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(93);

INSERT INTO auth.users (id, phone) VALUES
  ('b7211111-1111-4111-8111-727272727272', '2348000007201'),   -- T: tester, NG
  ('b7222222-2222-4222-8222-727272727272', '2348000007202'),   -- N: not a tester, NG
  ('b7244444-4444-4444-8444-727272727272', '2348000007204'),   -- A: super admin
  ('b7255555-5555-4555-8555-727272727272', '2348000007205'),   -- B: super admin
  ('b7266666-6666-4666-8666-727272727272', '2348000007206'),   -- M1: meet moderator, NG
  ('b7277777-7777-4777-8777-727272727272', '2348000007207'),   -- M2: meet moderator, NG
  ('b7288888-8888-4888-8888-727272727272', '2348000007208');   -- S: support agent, NG
UPDATE public.profiles SET country_code = 'NG' WHERE user_id::text LIKE 'b72%-727272727272';
-- C: a tester who signed up with an email and has not chosen a country yet.
INSERT INTO auth.users (id, email)
VALUES ('b7233333-3333-4333-8333-727272727272', 'tester.c@suskii.test');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('b7244444-4444-4444-8444-727272727272', ARRAY['super_admin']::public.admin_role[], NULL),
  ('b7255555-5555-4555-8555-727272727272', ARRAY['super_admin']::public.admin_role[], NULL),
  ('b7266666-6666-4666-8666-727272727272', ARRAY['meet_moderator']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('b7277777-7777-4777-8777-727272727272', ARRAY['meet_moderator']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('b7288888-8888-4888-8888-727272727272', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2', p_fresh boolean DEFAULT true)
RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)
     -- An aal2 session entered its TOTP code just now, or an hour ago when p_fresh is false.
     || CASE WHEN p_aal = 'aal2' THEN jsonb_build_object('amr', jsonb_build_array(
          jsonb_build_object('method', 'totp', 'timestamp',
            extract(epoch FROM now() - CASE WHEN p_fresh THEN interval '0 seconds'
                                            ELSE interval '1 hour' END)::bigint)))
        ELSE '{}'::jsonb END)::text, true);
  SELECT NULL::void;
$fn$;

-- Calls every stub with NULL arguments as the current role and records how each one ended.
CREATE FUNCTION pg_temp.stub_outcomes()
RETURNS TABLE (fn text, outcome text)
LANGUAGE plpgsql AS $fn$
DECLARE
  r       record;
  v_state text;
  v_msg   text;
BEGIN
  FOR r IN
    SELECT p.proname::text AS name,
           (SELECT coalesce(string_agg(format('NULL::%s', format_type(a.t, NULL)), ', '
                                       ORDER BY a.i), '')
            FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(t, i)) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.proname LIKE 'meet\_%' OR p.proname LIKE 'admin\_meet\_%')
      AND p.proname NOT IN ('admin_meet_readiness', 'admin_meet_set_readiness',
                            'admin_meet_testers', 'admin_meet_set_tester')
    ORDER BY 1
  LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM public.%I(%s)', r.name, r.args);
      fn := r.name; outcome := 'returned';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      fn := r.name; outcome := v_state || ' ' || v_msg;
    END;
    RETURN NEXT;
  END LOOP;
END $fn$;

CREATE FUNCTION pg_temp.error_detail(p_sql text)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  v text;
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v = PG_EXCEPTION_DETAIL;
  RETURN v;
END $fn$;

CREATE TEMP TABLE outcomes (who text, fn text, outcome text);
CREATE TEMP TABLE proposal (id uuid);
CREATE TEMP TABLE scratch (name text PRIMARY KEY, value jsonb);
GRANT ALL ON outcomes, proposal, scratch TO authenticated;

-- ---------------------------------------------------------------------------
-- The seed: seven flags, all off; the remote config; the checklist.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(key ORDER BY key) FROM public.feature_flags
   WHERE key LIKE 'meet.%' AND country_code IS NULL),
  ARRAY['meet.chat', 'meet.discovery', 'meet.games', 'meet.nearby', 'meet.photo_verification',
        'meet.statuses', 'meet.v5'],
  'the seven M1 flags exist as global rows');
SELECT is((SELECT count(*)::int FROM public.feature_flags WHERE key LIKE 'meet.%' AND enabled),
  0, 'and every one is off');
SELECT ok((SELECT payload ->> 'testers_only' = 'true' AND rollout_pct = 0
           FROM public.feature_flags WHERE key = 'meet.v5' AND country_code IS NULL),
  'meet.v5 starts testers-only at a 0% rollout, so leaving testers takes a deliberate percentage');
SELECT is((SELECT count(*)::int FROM public.feature_flags
           WHERE key LIKE 'meet.%' AND NOT client_visible), 0,
  'all seven are client-visible (design 3.3)');
SELECT is((SELECT count(*)::int FROM public.remote_config
           WHERE key LIKE 'meet.%' AND country_code IS NULL), 32,
  'the 32 M1 remote-config keys exist');
SELECT set_eq(
  $$SELECT key FROM public.remote_config WHERE key LIKE 'meet.%' AND NOT client_visible$$,
  ARRAY['meet.require_device_integrity', 'meet.limits.new_conversations_per_day',
        'meet.limits.messages_per_minute', 'meet.limits.reports_per_day',
        'meet.area.min_update_hours', 'meet.contact_filter', 'meet.retention',
        'meet.notify.max_social_per_hour', 'meet.moderation.sla_hours'],
  'exactly the nine the design marks "server" stay out of the apps');
SELECT ok((SELECT b -> 'remote_config' ? 'meet.min_client_version'
                  AND NOT b -> 'remote_config' ? 'meet.contact_filter'
                  AND (b -> 'feature_flags' ->> 'meet.v5')::boolean IS FALSE
           FROM (SELECT public.get_bootstrap('NG') AS b) x),
  'bootstrap carries the client keys and meet.v5 = false, and never the filter''s thresholds');
SELECT is(
  (SELECT array_agg(milestone || ':' || n ORDER BY milestone)
   FROM (SELECT milestone, count(*) n FROM private.meet_readiness GROUP BY 1) x),
  ARRAY['m1:13', 'm2:4', 'm2_testers:4'], 'the checklist has 13 m1, 4 m2_testers and 4 m2 items');
SELECT set_eq(
  $$SELECT item FROM private.meet_readiness WHERE milestone = 'm1' AND 'm2' = ANY (gates)$$,
  ARRAY['supabase_plan_upgraded', 'backups_running'],
  'the plan upgrade and backups hold back both Meet and purchases (D23)');
SELECT is(
  (SELECT array_agg(item ORDER BY item) FROM private.meet_readiness WHERE done),
  ARRAY['owner_od39_od40_od41'], 'only the owner''s three decided ODs start done');
SELECT set_eq($$SELECT item FROM private.meet_readiness WHERE auto$$,
  ARRAY['meet_moderators_staffed', 'rtdn_test_received'], 'two items are set automatically');

-- ---------------------------------------------------------------------------
-- The surface: 64 functions, authenticated only; the private half unreachable.
-- ---------------------------------------------------------------------------
SELECT set_eq(
  $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND (p.proname LIKE 'meet\_%' OR p.proname LIKE 'admin\_meet\_%')$$,
  ARRAY[
    'meet_get_state', 'meet_check_in', 'meet_accept_guidelines', 'meet_save_profile',
    'meet_set_area', 'meet_set_discovery_prefs', 'meet_get_my_profile', 'meet_submit_photo',
    'meet_remove_photo', 'meet_reorder_photos', 'meet_save_prompt', 'meet_remove_prompt',
    'meet_set_discoverable', 'meet_pause', 'meet_set_privacy', 'meet_delete_profile',
    'meet_daily_set', 'meet_get_profile', 'meet_nearby', 'meet_swipe', 'meet_send_signal',
    'meet_likes_summary', 'meet_matches', 'meet_unmatch',
    'meet_conversations', 'meet_messages', 'meet_send_message', 'meet_mark_read',
    'meet_react_to_message',
    'meet_post_status', 'meet_delete_status', 'meet_status_ring', 'meet_view_status',
    'meet_status_viewers', 'meet_game_catalogue', 'meet_start_game', 'meet_answer_game',
    'meet_get_round', 'meet_daily_question', 'meet_answer_daily_question',
    'meet_report', 'meet_block', 'meet_unblock', 'meet_blocked_profiles',
    'meet_verification_pose', 'meet_submit_verification',
    'admin_meet_moderation_queue', 'admin_meet_decide_case', 'admin_meet_decide_photo',
    'admin_meet_report_queue', 'admin_meet_report_detail', 'admin_meet_resolve_report',
    'admin_meet_suspend', 'admin_meet_approve_ban', 'admin_meet_lift_suspension',
    'admin_meet_correct_birth_date', 'admin_meet_user_summary',
    'admin_meet_verification_queue', 'admin_meet_decide_verification',
    'admin_meet_verification_access',
    'admin_meet_readiness', 'admin_meet_set_readiness', 'admin_meet_testers',
    'admin_meet_set_tester'],
  'every M1 client and admin RPC in design 4.2 and 4.3 exists, and no other');
SELECT is(
  (SELECT coalesce(array_agg(p.proname::text ORDER BY 1), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND (p.proname LIKE 'meet\_%' OR p.proname LIKE 'admin\_meet\_%')
     AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'anon can execute none of them');
SELECT is(
  (SELECT coalesce(array_agg(p.proname::text ORDER BY 1), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND (p.proname LIKE 'meet\_%' OR p.proname LIKE 'admin\_meet\_%')
     AND NOT (has_function_privilege('authenticated', p.oid, 'EXECUTE')
              AND p.prosecdef
              AND 'search_path=""' = ANY (p.proconfig))),
  '{}'::text[], 'authenticated can execute all of them; each is a definer with an empty search_path');
SELECT is(
  (SELECT coalesce(array_agg(p.proname::text ORDER BY 1), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'private' AND p.proname LIKE 'meet\_%'
     AND (has_function_privilege('authenticated', p.oid, 'EXECUTE')
          OR has_function_privilege('anon', p.oid, 'EXECUTE'))),
  '{}'::text[], 'no client role can execute a private Meet helper');
SELECT ok(NOT has_table_privilege('authenticated', 'private.meet_testers', 'SELECT')
          AND NOT has_table_privilege('authenticated', 'private.meet_readiness', 'SELECT')
          AND NOT has_table_privilege('anon', 'private.meet_testers', 'SELECT')
          AND NOT has_table_privilege('anon', 'private.meet_readiness', 'SELECT'),
  'no client role reads the testers or the checklist');
SELECT is(
  (SELECT count(*)::int FROM pg_class c
   WHERE c.oid IN ('private.meet_testers'::regclass, 'private.meet_readiness'::regclass)
     AND c.relrowsecurity AND c.relforcerowsecurity), 2,
  'both tables have row level security enabled and forced');

SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.meet_get_state()$$, '42501', NULL,
  'signed out, meet_get_state is refused by the grant');
SELECT throws_ok($$SELECT * FROM public.admin_meet_readiness()$$, '42501', NULL,
  'and so is admin_meet_readiness');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The stubs: every one raises ERR_FEATURE_UNAVAILABLE, and an admin stub asks for its role and
-- its step-up first.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'super_admin', * FROM pg_temp.stub_outcomes();
RESET ROLE;
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272', 'aal2', false);
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'super_admin_stale', * FROM pg_temp.stub_outcomes();
RESET ROLE;
SELECT pg_temp.act('b7222222-2222-4222-8222-727272727272', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'user', * FROM pg_temp.stub_outcomes();
RESET ROLE;

SELECT is((SELECT count(*)::int FROM outcomes WHERE who = 'super_admin'), 60,
  'sixty of the functions are stubs');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'super_admin' AND outcome <> 'P0001 ERR_FEATURE_UNAVAILABLE'),
  '{}'::text[], 'every stub raises ERR_FEATURE_UNAVAILABLE, client and admin alike');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'user' AND fn LIKE 'meet\_%' AND outcome <> 'P0001 ERR_FEATURE_UNAVAILABLE'),
  '{}'::text[], 'a signed-in user gets ERR_FEATURE_UNAVAILABLE from all 46 client stubs');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'user' AND fn LIKE 'admin\_meet\_%' AND outcome <> '42501 ERR_PERMISSION_DENIED'),
  '{}'::text[], 'and ERR_PERMISSION_DENIED from all 14 admin stubs');
SELECT set_eq(
  $$SELECT fn FROM outcomes WHERE who = 'super_admin_stale' AND outcome = 'P0001 ERR_REAUTH_REQUIRED'$$,
  ARRAY['admin_meet_decide_case', 'admin_meet_decide_photo', 'admin_meet_resolve_report',
        'admin_meet_suspend', 'admin_meet_approve_ban', 'admin_meet_lift_suspension',
        'admin_meet_correct_birth_date', 'admin_meet_decide_verification',
        'admin_meet_verification_access'],
  'an hour-old TOTP code is asked again by the nine admin stubs that change something or open a selfie');

SELECT pg_temp.act('b7222222-2222-4222-8222-727272727272', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is(
  pg_temp.error_detail($$SELECT public.meet_check_in('key-72-stub-0000001', '2001-02-03', 1)$$),
  'meet_check_in(p_birth_date, p_guidelines_version, p_idempotency_key) is not built yet',
  'the detail names the arguments and never their values: no birth date reaches a log');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Testers-only gating.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
  $$UPDATE public.feature_flags SET enabled = true WHERE key = 'meet.v5' AND country_code IS NULL$$,
  'meet.v5 goes on testers-only with the checklist incomplete: the guard allows it');
SELECT is(private.meet_flag_on('meet.v5', 'b7211111-1111-4111-8111-727272727272', 'NG'), false,
  'on, but T is not a tester yet');

SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
SELECT is(public.admin_meet_set_tester('key-72-tester-000001',
    'b7211111-1111-4111-8111-727272727272', true, 'internal QA'),
  '{"user_id": "b7211111-1111-4111-8111-727272727272", "tester": true}'::jsonb,
  'a super admin adds T as a tester');
SELECT lives_ok($$SELECT public.admin_meet_set_tester('key-72-tester-000002',
    'b7233333-3333-4333-8333-727272727272', true, NULL)$$, 'and C, who has no country yet');
RESET ROLE;

SELECT is(private.meet_flag_on('meet.v5', 'b7211111-1111-4111-8111-727272727272', 'NG'), true,
  'a tester passes');
SELECT is(private.meet_flag_on('meet.v5', 'b7222222-2222-4222-8222-727272727272', 'NG'), false,
  'somebody who is not a tester does not');
UPDATE public.feature_flags SET rollout_pct = 100 WHERE key = 'meet.v5' AND country_code IS NULL;
SELECT is(private.meet_flag_on('meet.v5', 'b7222222-2222-4222-8222-727272727272', 'NG'), false,
  'not even at a 100% rollout: testers-only admits testers and nobody else');
SELECT is(private.meet_flag_on('meet.discovery', 'b7211111-1111-4111-8111-727272727272', 'NG'),
  false, 'a sub-flag that is off stays off for a tester');
UPDATE public.feature_flags SET enabled = true
WHERE key = 'meet.discovery' AND country_code IS NULL;
SELECT is(private.meet_flag_on('meet.discovery', 'b7211111-1111-4111-8111-727272727272', 'NG'),
  true, 'switched on, it passes for the tester');
SELECT is(private.meet_flag_on('meet.discovery', 'b7222222-2222-4222-8222-727272727272', 'NG'),
  false, 'and not for anybody else, though it is at 100%: every sub-flag needs meet.v5');
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible, payload)
VALUES ('meet.v5', 'NG', false, 100, true, '{"testers_only": true}');
SELECT ok(NOT private.meet_flag_on('meet.v5', 'b7211111-1111-4111-8111-727272727272', 'NG')
          AND private.meet_flag_on('meet.v5', 'b7211111-1111-4111-8111-727272727272', 'GH'),
  'a country row wins over the global one, and only in its own country');
DELETE FROM public.feature_flags WHERE key = 'meet.v5' AND country_code = 'NG';
SELECT is(private.meet_flag_on('meet.nonexistent', 'b7211111-1111-4111-8111-727272727272', 'NG'),
  false, 'a flag with no row is off');
SELECT is(private.meet_flag_on('concierge.text', 'b7211111-1111-4111-8111-727272727272', 'NG'),
  false, 'and only meet.* keys are Meet flags');

SELECT throws_ok(
  $$SELECT private.meet_require_access('b7222222-2222-4222-8222-727272727272', 'meet.v5', false)$$,
  'P0001', 'ERR_FEATURE_UNAVAILABLE', 'the access check refuses somebody the flag does not admit');
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7233333-3333-4333-8333-727272727272', 'meet.v5', false)$$,
  'P0001', 'ERR_COUNTRY_NOT_SET', 'then a tester with no country');
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7211111-1111-4111-8111-727272727272', 'meet.v5', true)$$,
  'P0001', 'ERR_MEET_ELIGIBILITY_REQUIRED',
  'and past both, nobody is eligible before M1-PR3: the check fails closed rather than passing');
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7211111-1111-4111-8111-727272727272', 'concierge.text', false)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a feature that is not a Meet flag is a programming error');

SELECT pg_temp.act('b7211111-1111-4111-8111-727272727272', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_get_state()$$, 'P0001', 'ERR_FEATURE_UNAVAILABLE',
  'with meet.v5 on for them, a tester still gets ERR_FEATURE_UNAVAILABLE from a stub');
RESET ROLE;

SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
SELECT is(public.admin_meet_set_tester('key-72-tester-000003',
    'b7211111-1111-4111-8111-727272727272', false, NULL) ->> 'tester', 'false',
  'a super admin removes T');
RESET ROLE;
SELECT is(private.meet_flag_on('meet.v5', 'b7211111-1111-4111-8111-727272727272', 'NG'), false,
  'and T no longer passes');

-- ---------------------------------------------------------------------------
-- The readiness guard.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.feature_flags SET payload = '{}' WHERE key = 'meet.v5' AND country_code IS NULL$$,
  'P0001', 'ERR_MEET_NOT_READY', 'meet.v5 cannot leave testers while the m1 checklist is open');
SELECT ok(
  (SELECT d LIKE 'meet.v5 needs readiness m1: %' AND d LIKE '%meet_moderators_staffed%'
          AND d LIKE '%supabase_plan_upgraded%' AND d NOT LIKE '%owner_od39_od40_od41%'
   FROM (SELECT pg_temp.error_detail($$UPDATE public.feature_flags SET payload = '{}'
           WHERE key = 'meet.v5' AND country_code IS NULL$$) AS d) x),
  'and the refusal lists what is missing, and only that');
SELECT throws_ok(
  $$INSERT INTO public.feature_flags (key, country_code, enabled, payload)
    VALUES ('meet.v5', 'NG', true, '{}')$$,
  'P0001', 'ERR_MEET_NOT_READY', 'a country row going general is checked the same way');
SELECT throws_ok(
  $$INSERT INTO public.feature_flags (key, country_code, enabled, payload)
    VALUES ('meet.v5', 'NG', true, '{"testers_only": "yes"}')$$,
  'P0001', 'ERR_MEET_NOT_READY', 'a payload that is not exactly testers_only true counts as general');
SELECT throws_ok(
  $$INSERT INTO public.feature_flags (key, country_code, enabled, payload)
    VALUES ('meet.purchases', NULL, true, '{"testers_only": true}')$$,
  'P0001', 'ERR_MEET_NOT_READY', 'purchases for testers need the m2_testers items');
SELECT throws_ok(
  $$INSERT INTO public.feature_flags (key, country_code, enabled, payload)
    VALUES ('meet.vip', NULL, true, '{}')$$,
  'P0001', 'ERR_MEET_NOT_READY', 'VIP for everybody needs every m2 item');
SELECT lives_ok(
  $$INSERT INTO public.feature_flags (key, country_code, enabled, payload)
    VALUES ('meet.purchases', NULL, false, '{}')$$,
  'a guarded flag that is off is never checked');
SELECT lives_ok(
  $$UPDATE public.feature_flags SET enabled = false, payload = '{}'
    WHERE key = 'meet.v5' AND country_code IS NULL$$,
  'switching meet.v5 off always works, even dropping testers-only on the way (the RB-13 kill switch)');
SELECT is((SELECT enabled FROM public.feature_flags WHERE key = 'meet.v5' AND country_code IS NULL),
  false, 'and it is off');
UPDATE public.feature_flags SET payload = '{"testers_only": true}'
WHERE key = 'meet.v5' AND country_code IS NULL;

-- The four-eyes path. The release step names only `enabled`; the apply's upsert builds its insert
-- row with an empty payload, which a BEFORE trigger would have read as "general".
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
INSERT INTO scratch VALUES ('on', to_jsonb(public.propose_config_change('key-72-propose-00000',
  'feature_flag', 'meet.v5', '{"enabled": true}')));
RESET ROLE;
SELECT pg_temp.act('b7255555-5555-4555-8555-727272727272');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-72-review-000000',
    (SELECT (value #>> '{}')::uuid FROM scratch WHERE name = 'on'), true),
  'applied', 'switching meet.v5 on through a config change that names only enabled applies');
RESET ROLE;
SELECT is((SELECT enabled::text || ' ' || (payload ->> 'testers_only') FROM public.feature_flags
           WHERE key = 'meet.v5' AND country_code IS NULL),
  'true true', 'and Meet is on for testers only');

-- Taking it general the same way: the apply runs inside the reviewer's transaction, so a refusal
-- there aborts the review and the proposal is left exactly as it was.
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
INSERT INTO proposal VALUES (public.propose_config_change('key-72-propose-00001', 'feature_flag',
  'meet.v5', '{"enabled": true, "payload": {}}'));
RESET ROLE;
SELECT pg_temp.act('b7255555-5555-4555-8555-727272727272');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.review_config_change(%L, %L, true)', 'key-72-review-000001',
         (SELECT id FROM proposal)),
  'P0001', 'ERR_MEET_NOT_READY', 'a review that would take meet.v5 general is refused at apply');
RESET ROLE;
SELECT is((SELECT status FROM public.config_changes WHERE id = (SELECT id FROM proposal)),
  'pending', 'the proposal is still pending');
SELECT is((SELECT count(*)::int FROM public.approvals
           WHERE subject_kind = 'config_change' AND subject_id = (SELECT id FROM proposal)::text
             AND status = 'pending'), 1, 'with its signature unspent');
SELECT is((SELECT payload ->> 'testers_only' FROM public.feature_flags
           WHERE key = 'meet.v5' AND country_code IS NULL), 'true', 'and the flag untouched');

-- Completing the checklist: the eleven items a person ticks, then the automatic one.
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*)::int
   FROM unnest(ARRAY['play_restrict_minor_access', 'play_child_safety_standards',
                     'play_content_rating', 'play_data_safety', 'play_listing_meet_copy',
                     'csae_page_live', 'childsafety_contact_live', 'meet_guidelines_page_live',
                     'supabase_plan_upgraded', 'backups_running', 'counsel_od37_od38_od42'])
          WITH ORDINALITY i(item, n),
        LATERAL public.admin_meet_set_readiness('key-72-ready-' || lpad(i.n::text, 8, '0'),
                                                i.item, true, 'done in test 72') r
   WHERE (r ->> 'done')::boolean), 11, 'a super admin ticks the eleven m1 items a person completes');
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-auto0001',
    'meet_moderators_staffed', true, NULL)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'but cannot tick the automatic one');
RESET ROLE;
SELECT is(private.meet_readiness_missing('m1'), ARRAY['meet_moderators_staffed'],
  'the automatic one is all that is left');

INSERT INTO auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at,
                              updated_at) VALUES
  (gen_random_uuid(), 'b7266666-6666-4666-8666-727272727272', 'phone', 'totp', 'verified',
   now(), now()),
  (gen_random_uuid(), 'b7277777-7777-4777-8777-727272727272', 'phone', 'totp', 'unverified',
   now(), now());
SELECT is(private.meet_moderators_staffed(), false,
  'two meet moderators, one with an unverified factor, are not two who can work the queue');
UPDATE auth.mfa_factors SET status = 'verified'
WHERE user_id = 'b7277777-7777-4777-8777-727272727272';
SELECT is(private.meet_readiness_missing('m1'), '{}'::text[],
  'with both factors verified, the m1 checklist is complete');

SELECT pg_temp.act('b7255555-5555-4555-8555-727272727272');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-72-review-000002', (SELECT id FROM proposal), true),
  'applied', 'the same proposal, reviewed again, now applies: the refused review had spent nothing');
RESET ROLE;
SELECT is((SELECT payload FROM public.feature_flags WHERE key = 'meet.v5' AND country_code IS NULL),
  '{}'::jsonb, 'meet.v5 is general');
SELECT is(private.meet_flag_on('meet.v5', 'b7222222-2222-4222-8222-727272727272', 'NG'), true,
  'and somebody who is not a tester passes at its 100% rollout');

SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-untick01',
    'backups_running', false, 'nightly restore failed')$$,
  'an item can be unticked later');
RESET ROLE;
SELECT throws_ok(
  $$UPDATE public.feature_flags SET rollout_pct = 50 WHERE key = 'meet.v5' AND country_code IS NULL$$,
  'P0001', 'ERR_MEET_NOT_READY', 'which blocks any further change that keeps Meet general');
SELECT lives_ok(
  $$UPDATE public.feature_flags SET enabled = false WHERE key = 'meet.v5' AND country_code IS NULL$$,
  'and never blocks switching it off');

-- ---------------------------------------------------------------------------
-- The four admin functions built here.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.admin_meet_readiness()), 21,
  'a super admin reads the whole checklist');
SELECT is(
  (SELECT array_agg(DISTINCT milestone) FROM (
     SELECT milestone FROM public.admin_meet_readiness() LIMIT 13) x),
  ARRAY['m1'], 'm1 first');
SELECT is(
  (SELECT done FROM public.admin_meet_readiness() WHERE item = 'meet_moderators_staffed'), true,
  'with the automatic item answered live');
SELECT is(public.admin_meet_set_readiness('key-72-ready-replay01', 'merchant_bank_tax_done', true,
    '  CAC filing done  ') - 'set_at',
  '{"item": "merchant_bank_tax_done", "milestone": "m2", "done": true,
    "note": "CAC filing done"}'::jsonb, 'setting an item returns it, the note trimmed');
INSERT INTO scratch VALUES ('replay', public.admin_meet_set_readiness('key-72-ready-replay01',
  'merchant_bank_tax_done', true, 'CAC filing done'));
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-replay01',
    'merchant_bank_tax_done', false, NULL)$$,
  'P0001', 'ERR_IDEMPOTENCY_KEY_REUSED', 'the same key with different arguments is refused');
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-unknown1',
    'not_an_item', true, NULL)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'an item that does not exist is refused');
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-toolong1',
    'license_tests_passed', true, repeat('x', 501))$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'and so is a note over 500 characters');
SELECT is((SELECT count(*)::int FROM public.admin_meet_testers()), 1,
  'the testers list holds C, the one tester left');
SELECT throws_ok($$SELECT public.admin_meet_set_tester('key-72-tester-unknown',
    'b7299999-9999-4999-8999-727272727272', true, NULL)$$,
  'P0001', 'ERR_PROFILE_NOT_FOUND', 'a tester must be an account that exists');
SELECT throws_ok($$SELECT public.admin_meet_set_tester('key-72-tester-toolong',
    'b7222222-2222-4222-8222-727272727272', true, repeat('x', 201))$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'with a note of at most 200 characters');
RESET ROLE;
SELECT is((SELECT value FROM scratch WHERE name = 'replay') - 'set_at',
  '{"item": "merchant_bank_tax_done", "milestone": "m2", "done": true,
    "note": "CAC filing done"}'::jsonb, 'a replay returns the stored answer');
SELECT is((SELECT count(*)::int FROM audit.log
           WHERE action = 'meet.readiness.set' AND target_id = 'merchant_bank_tax_done'), 1,
  'and writes nothing twice');
SELECT ok((SELECT count(*) >= 3 FROM audit.log
           WHERE actor_id = 'b7244444-4444-4444-8444-727272727272'
             AND action IN ('meet.readiness.read', 'meet.testers.read')),
  'every read of the checklist or the testers is audited');
SELECT set_eq(
  $$SELECT action FROM audit.log WHERE target_id = 'b7211111-1111-4111-8111-727272727272'
      AND action LIKE 'meet.tester.%'$$,
  ARRAY['meet.tester.added', 'meet.tester.removed'], 'adding and removing a tester is audited');

SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272', 'aal2', false);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-stale001',
    'license_tests_passed', true, NULL)$$,
  'P0001', 'ERR_REAUTH_REQUIRED', 'a change to the checklist needs a TOTP code from the last five minutes');
SELECT throws_ok($$SELECT public.admin_meet_set_tester('key-72-tester-stale01',
    'b7222222-2222-4222-8222-727272727272', true, NULL)$$,
  'P0001', 'ERR_REAUTH_REQUIRED', 'and so does a change to the testers');
SELECT lives_ok($$SELECT * FROM public.admin_meet_readiness()$$,
  'reading needs only the aal2 session');
RESET ROLE;

SELECT pg_temp.act('b7244444-4444-4444-8444-727272727272', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_meet_readiness()$$, '42501', 'ERR_PERMISSION_DENIED',
  'a super admin without MFA reads nothing');
RESET ROLE;

SELECT pg_temp.act('b7266666-6666-4666-8666-727272727272');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_meet_readiness()$$, '42501', 'ERR_PERMISSION_DENIED',
  'a meet moderator does not read the checklist');
SELECT throws_ok($$SELECT * FROM public.admin_meet_testers()$$, '42501', 'ERR_PERMISSION_DENIED',
  'or the testers');
SELECT throws_ok($$SELECT public.admin_meet_set_tester('key-72-tester-moder01',
    'b7266666-6666-4666-8666-727272727272', true, NULL)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and cannot make anybody a tester, themselves included');
RESET ROLE;

SELECT pg_temp.act('b7288888-8888-4888-8888-727272727272');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_meet_set_readiness('key-72-ready-support1',
    'license_tests_passed', true, NULL)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'a support agent cannot tick an item');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
