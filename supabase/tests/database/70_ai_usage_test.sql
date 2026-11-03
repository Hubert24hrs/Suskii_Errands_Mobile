-- Ask Suskii usage and cost control (20261103120200): the reservation, settlement and cost, the
-- allowance and its resets, credits, suspension, the global budget, retries, and the staff controls.
-- Concurrency is exercised separately (supabase/tests/e2e/ai_quota_concurrency_e2e.sh): one
-- transaction cannot race itself.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(57);

INSERT INTO auth.users (id, phone) VALUES
  ('a1000000-0000-4000-8000-000000000001', '2348000007001'),   -- the customer
  ('a1000000-0000-4000-8000-000000000002', '2348000007002'),   -- another customer
  ('a1000000-0000-4000-8000-000000000003', '2348000007003'),   -- super admin
  ('a1000000-0000-4000-8000-000000000004', '2348000007004'),   -- finance officer
  ('a1000000-0000-4000-8000-000000000005', '2348000007005');   -- support agent
UPDATE public.profiles SET country_code = 'NG' WHERE user_id::text LIKE 'a1000000-%';
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('a1000000-0000-4000-8000-000000000003', ARRAY['super_admin']::public.admin_role[]),
  ('a1000000-0000-4000-8000-000000000004', ARRAY['finance_officer']::public.admin_role[]),
  ('a1000000-0000-4000-8000-000000000005', ARRAY['support_agent']::public.admin_role[]);
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible)
VALUES ('concierge.text', NULL, true, 100, true)
ON CONFLICT (key, country_code) DO UPDATE SET enabled = true, rollout_pct = 100;
-- No cooldown while the allowance is being counted; it is tested on its own below.
UPDATE public.remote_config SET value = value || '{"cooldown_seconds": 0}'::jsonb
WHERE key = 'ai.limits.concierge' AND country_code IS NULL;

CREATE TEMP TABLE cv (name text PRIMARY KEY, id uuid);
GRANT ALL ON cv TO authenticated;
CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)
     || CASE WHEN p_aal = 'aal2' THEN jsonb_build_object('amr', jsonb_build_array(
          jsonb_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::bigint)))
        ELSE '{}'::jsonb END)::text, true);
  SELECT NULL::void;
$fn$;
-- One turn: begin, then record with the tokens given (0 = the model never ran).
CREATE FUNCTION pg_temp.turn(p_conv uuid, p_key text, p_in integer, p_out integer,
                             p_location text DEFAULT 'europe-west2') RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE v_begin jsonb;
BEGIN
  v_begin := public.concierge_begin_turn(p_conv, p_key);
  IF (v_begin ->> 'reserved')::boolean THEN
    PERFORM public.concierge_record_turn(p_conv, p_key, 'hello', 'ok', 'en', '{}'::jsonb, NULL, 'none',
      '{}', CASE WHEN p_in > 0 THEN 'gemini-3.5-flash' END, NULL, p_in, p_out, 0, 10, NULL, p_location);
  END IF;
  RETURN v_begin;
END $fn$;

SELECT is(private.remote_config_json('ai.quota.tiers') -> 'free',
  '{"daily": 10, "monthly": 150}'::jsonb, 'free users start at 10 a day and 150 a month');
SELECT is(private.remote_config_json('ai.budget'),
  '{"daily_micros": 2000000, "monthly_micros": 25000000}'::jsonb, 'and the platform at $2 a day, $25 a month');

-- Cost: integer micro-dollars from the configured list price, rounded up.
SELECT is(private.ai_cost_micros('gemini-3.5-flash', 'europe-west2', 1000, 100), 2640::bigint,
  'a regional turn costs 1000 x $1.65/M in + 100 x $9.90/M out');
SELECT is(private.ai_cost_micros('gemini-3.5-flash', 'global', 1000, 100), 2400::bigint,
  'the global endpoint at its own price');
SELECT is(private.ai_cost_micros('some-new-model', 'global', 1000, 100), 2400::bigint,
  'an unpriced model is priced as the default, never as free');
SELECT is(private.ai_cost_micros('gemini-3.5-flash', 'europe-west2', 1, 0), 2::bigint,
  'a fraction of a micro-dollar rounds up');

-- A turn reserves, then settles with what the model reported.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO cv SELECT 'c', id FROM public.concierge_start('key-ai-start-000000000001');
CREATE TEMP TABLE b1 AS SELECT pg_temp.turn((SELECT id FROM cv WHERE name = 'c'),
  'key-ai-turn-0000000000001', 1000, 100) AS b;
SELECT is((SELECT b ->> 'reserved' FROM b1), 'true', 'a turn within the allowance is reserved');
SELECT is((SELECT (b -> 'usage' ->> 'remaining_today')::int FROM b1), 9, 'and nine are left today');
SELECT is((SELECT (b -> 'limits' ->> 'max_output_tokens_per_turn')::int FROM b1), 800,
  'with the per-turn token caps for the function');
RESET ROLE;
SELECT is((SELECT status || ':' || cost_micros || ':' || model_id || ':' || location FROM public.ai_usage
           WHERE idempotency_key = 'key-ai-turn-0000000000001'),
  'completed:2640:gemini-3.5-flash:europe-west2', 'recording the reply settles it with tokens and cost');
SELECT is((SELECT tokens_in FROM public.ai_messages WHERE idempotency_key = 'key-ai-turn-0000000000001'),
  1000, 'and the reply row still carries its tokens');

-- A turn the model never answered costs nothing.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE s1 AS SELECT pg_temp.turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000002', 0, 0);
SELECT is((public.my_ai_usage() ->> 'remaining_today')::int, 9,
  'a reply that never reached the model is not counted');
RESET ROLE;
SELECT is((SELECT status FROM public.ai_usage WHERE idempotency_key = 'key-ai-turn-0000000000002'),
  'released', 'its reservation is released');

-- The daily allowance.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE s2 AS SELECT pg_temp.turn((SELECT id FROM cv WHERE name = 'c'),
  'key-ai-turn-day-' || lpad(g::text, 9, '0'), 100, 10) FROM generate_series(1, 9) g;
CREATE TEMP TABLE b2 AS SELECT public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'),
  'key-ai-turn-0000000000003') AS b;
SELECT is((SELECT b ->> 'limited' FROM b2), 'day', 'the eleventh counted message of the day is refused');
SELECT is((SELECT b ->> 'reserved' FROM b2), 'false', 'and nothing is reserved for it');
SELECT is((public.my_ai_usage() ->> 'remaining_today')::int, 0, 'the screen shows none left');
SELECT is((public.my_ai_usage() ->> 'available')::boolean, true,
  'while the assistant itself is still available');
RESET ROLE;
SELECT is((SELECT (b ->> 'reset_at')::timestamptz FROM b2),
  (date_trunc('day', now() AT TIME ZONE private.user_timezone('a1000000-0000-4000-8000-000000000001'))
     + interval '1 day') AT TIME ZONE private.user_timezone('a1000000-0000-4000-8000-000000000001'),
  'with the time it comes back: midnight where the person is');

-- Credits extend it, and go back when the model never runs.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000005', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((public.admin_grant_ai_credits('key-ai-credit-00000000001', 'a1000000-0000-4000-8000-000000000001',
           2, 'Pilot tester') ->> 'credits')::int, 2, 'a support agent grants two credits');
SELECT is((public.admin_grant_ai_credits('key-ai-credit-00000000001', 'a1000000-0000-4000-8000-000000000001',
           2, 'Pilot tester') ->> 'credits')::int, 2, 'and a retried grant is not granted twice');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SELECT is((pg_temp.turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000004', 0, 0) ->> 'reserved'),
  'true', 'a credit pays for a message past the allowance');
SELECT is((public.my_ai_usage() ->> 'credits')::int, 2, 'and is given back when the model never ran');
CREATE TEMP TABLE s3 AS SELECT pg_temp.turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000005', 100, 10);
SELECT is((public.my_ai_usage() ->> 'credits')::int, 1, 'and is spent when it did');
RESET ROLE;

-- Retries: the same message is one row, counted once, whatever happens to its attempts.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
INSERT INTO cv SELECT 'd', id FROM public.concierge_start('key-ai-start-000000000002');
CREATE TEMP TABLE s4 AS SELECT public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'd'), 'key-ai-retry-000000000001');
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'd'), 'key-ai-retry-000000000001')
           ->> 'limited'), 'in_progress', 'a retry while the first attempt is in flight waits');
CREATE TEMP TABLE s5 AS SELECT 1 AS done FROM (SELECT public.concierge_release_turn((SELECT id FROM cv WHERE name = 'd'),
  'key-ai-retry-000000000001', 'gemini-3.5-flash', 'europe-west2', 1000, 0, 0)) x;
SELECT is((public.my_ai_usage() ->> 'used_today')::int, 1, 'a failure after the model ran counts');
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'd'), 'key-ai-retry-000000000001')
           ->> 'reserved'), 'true', 'its retry is reserved again');
SELECT is((public.my_ai_usage() ->> 'used_today')::int, 1, 'without being counted a second time');
CREATE TEMP TABLE s6 AS SELECT public.concierge_record_turn((SELECT id FROM cv WHERE name = 'd'), 'key-ai-retry-000000000001',
  'hello', 'ok', 'en', '{}'::jsonb, NULL, 'none', '{}', 'gemini-3.5-flash', NULL, 1000, 100, 0, 10, NULL,
  'europe-west2');
RESET ROLE;
SELECT is((SELECT cost_micros FROM public.ai_usage WHERE idempotency_key = 'key-ai-retry-000000000001'),
  1650::bigint + 2640, 'and the cost of both attempts is kept');
SELECT is((SELECT count(*)::int FROM public.ai_usage WHERE idempotency_key = 'key-ai-retry-000000000001'),
  1, 'in one row');

-- A reservation nobody settles is abandoned and still counts.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE s7 AS SELECT public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'd'), 'key-ai-dead-0000000000001');
RESET ROLE;
UPDATE public.ai_usage SET created_at = now() - interval '11 minutes'
WHERE idempotency_key = 'key-ai-dead-0000000000001';
SELECT ok(private.ai_usage_housekeeping() >= 1, 'housekeeping abandons a reservation left for ten minutes');
SELECT is((SELECT status FROM public.ai_usage WHERE idempotency_key = 'key-ai-dead-0000000000001'),
  'abandoned', 'which is marked abandoned');
UPDATE public.ai_usage SET created_at = now() WHERE idempotency_key = 'key-ai-dead-0000000000001';
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT is((public.my_ai_usage() ->> 'used_today')::int, 2, 'and still counted: crashing is not a way round');
RESET ROLE;

-- The monthly allowance.
UPDATE public.remote_config SET value = '1000'::jsonb
WHERE key = 'concierge.messages_per_minute' AND country_code IS NULL;
INSERT INTO public.remote_config (key, country_code, value) VALUES ('concierge.messages_per_minute', NULL, '1000')
ON CONFLICT DO NOTHING;
INSERT INTO public.ai_usage_accounts (user_id, daily_limit_override) VALUES ('a1000000-0000-4000-8000-000000000002', 1000)
ON CONFLICT (user_id) DO UPDATE SET daily_limit_override = 1000;
INSERT INTO public.ai_usage (user_id, country_code, idempotency_key, status)
SELECT 'a1000000-0000-4000-8000-000000000002', 'NG', 'key-ai-month-' || lpad(g::text, 12, '0'), 'completed'
FROM generate_series(1, 148) g;
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE b3 AS SELECT public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'd'),
  'key-ai-turn-0000000000006') AS b;
SELECT is((SELECT b ->> 'limited' FROM b3), 'month', 'the 151st message of the month is refused');
RESET ROLE;
SELECT is((SELECT (b ->> 'reset_at')::timestamptz FROM b3),
  (date_trunc('month', now() AT TIME ZONE private.user_timezone('a1000000-0000-4000-8000-000000000002'))
     + interval '1 month') AT TIME ZONE private.user_timezone('a1000000-0000-4000-8000-000000000002'),
  'and comes back on the first of next month');

-- A person's own override, and its expiry.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000005', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((public.admin_set_ai_quota('a1000000-0000-4000-8000-000000000001', 20, 300,
           now() + interval '7 days', 'Testing the long flow') ->> 'remaining_today')::int, 10,
  'raising one person''s limits gives them more today');
SELECT throws_ok($$SELECT public.admin_set_ai_quota('a1000000-0000-4000-8000-000000000001', 20, 300,
                   now() - interval '1 day', 'In the past')$$, '22023', 'ERR_INVALID_ARGUMENT',
  'an override cannot expire before it starts');
RESET ROLE;
UPDATE public.ai_usage_accounts SET override_expires_at = now() - interval '1 second'
WHERE user_id = 'a1000000-0000-4000-8000-000000000001';
SELECT is((private.ai_quota('a1000000-0000-4000-8000-000000000001') ->> 'daily_limit')::int, 10,
  'and once it expires the tier applies again');

-- Suspension.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000005', 'aal2');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE s8 AS SELECT public.admin_set_ai_suspension('a1000000-0000-4000-8000-000000000001',
  now() + interval '1 day', 'Automated messages');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000007')
           ->> 'limited'), 'suspended', 'a suspended person is refused before anything else');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000005', 'aal2');
SELECT ok((public.admin_set_ai_suspension('a1000000-0000-4000-8000-000000000001', NULL, 'Reviewed')
           ->> 'suspended_until') IS NULL, 'and the suspension can be lifted');
RESET ROLE;

-- Cooldown between messages.
UPDATE public.remote_config SET value = value || '{"cooldown_seconds": 3}'::jsonb
WHERE key = 'ai.limits.concierge' AND country_code IS NULL;
UPDATE public.ai_usage_accounts SET daily_limit_override = 1000, monthly_limit_override = 1000,
  override_expires_at = NULL WHERE user_id = 'a1000000-0000-4000-8000-000000000001';
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000008')
           ->> 'limited'), 'cooldown', 'a message straight after another waits out the cooldown');
RESET ROLE;

-- The platform budget.
INSERT INTO public.ai_usage (user_id, country_code, idempotency_key, status, cost_micros)
VALUES ('a1000000-0000-4000-8000-000000000004', 'NG', 'key-ai-spend-000000000001', 'completed', 2000000);
UPDATE public.remote_config SET value = value || '{"cooldown_seconds": 0}'::jsonb
WHERE key = 'ai.limits.concierge' AND country_code IS NULL;
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'), 'key-ai-turn-0000000000009')
           ->> 'limited'), 'budget', 'once the day''s budget is spent nobody is answered by the model');
SELECT is((public.my_ai_usage() ->> 'available')::boolean, false, 'and the screen says it is unavailable');
RESET ROLE;

-- Staff: who may read what.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_ai_usage_summary(current_date, current_date)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'a customer cannot read the spend');
SELECT throws_ok($$SELECT * FROM public.ai_usage$$, '42501', NULL, 'or the ledger');
SELECT throws_ok($$SELECT public.admin_grant_ai_credits('key-ai-credit-00000000009',
                   'a1000000-0000-4000-8000-000000000001', 5, 'For me')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'or grant themselves credits');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000005', 'aal2');
SELECT throws_ok($$SELECT public.admin_ai_usage_summary(current_date, current_date)$$,
  '42501', 'ERR_PERMISSION_DENIED', 'a support agent sees people, not the spend');
SELECT ok((SELECT count(*) FROM public.admin_ai_users(current_date, current_date, 'near_limit')) >= 2,
  'but can list who is close to a limit');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000004', 'aal2');
SELECT ok((SELECT (public.admin_ai_usage_summary(current_date, current_date)
           -> 'totals' ->> 'cost_micros')::bigint >= 2000000), 'a finance officer reads the spend');
SELECT is((public.admin_ai_usage_summary(current_date, current_date) -> 'budget' ->> 'day_exceeded'),
  'true', 'with the budget status');
SELECT throws_ok($$SELECT public.admin_set_ai_budget(3000000, 30000000, 'More room')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'but cannot move the budget');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'admin.ai_users'), 1,
  'listing people is audited');

-- The super admin's controls.
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000003', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((public.admin_set_ai_budget(3000000, 30000000, 'Pilot week') ->> 'day_exceeded'), 'false',
  'raising the budget lifts the stop');
SELECT is((public.admin_set_ai_tier('free', 15, 200, 'More for the pilot') -> 'free'),
  '{"daily": 15, "monthly": 200}'::jsonb, 'the free allowance is configuration');
SELECT is(public.admin_set_ai_enabled(false, 'Spend spike'), false, 'the emergency switch turns it off');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000002');
SELECT throws_ok($$SELECT public.concierge_start('key-ai-start-000000000009')$$,
  'P0001', 'ERR_FEATURE_UNAVAILABLE', 'and nobody can start a conversation');
SELECT pg_temp.act('a1000000-0000-4000-8000-000000000003', 'aal2');
SELECT is(public.admin_set_ai_enabled(true, 'Resolved'), true, 'and back on');
RESET ROLE;
SELECT is((SELECT array_agg(action ORDER BY id) FROM audit.log WHERE action LIKE 'ai.%'),
  ARRAY['ai.credits_granted', 'ai.quota_set', 'ai.suspended', 'ai.suspension_lifted', 'ai.budget_set',
        'ai.tier_set', 'ai.disabled', 'ai.enabled'], 'every control is in the audit log');

SELECT * FROM finish();
ROLLBACK;
