-- First-run role selection and the provider status the app shows (20261103120000).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(19);

INSERT INTO auth.users (id, phone) VALUES
  ('a0e00000-0000-4000-8000-000000000001', '2348000006801'),   -- chooses customer
  ('a0e00000-0000-4000-8000-000000000002', '2348000006802'),   -- chooses provider
  ('a0e00000-0000-4000-8000-000000000003', '2348000006803');   -- never answers
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id::text LIKE 'a0e00000-%';

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

-- A new account has not chosen yet, and is nothing on the provider side.
SELECT pg_temp.act('a0e00000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((public.get_bootstrap() -> 'user' ->> 'role_selected'), 'false',
  'a new account is owed the role screen');
SELECT is((public.get_bootstrap() -> 'user' ->> 'provider_status'), 'not_registered',
  'and is not registered as a provider');

SELECT is((public.select_initial_role('customer', 'key-role-select-0000000001') ->> 'signup_role'),
  'customer', 'choosing Customer is recorded');
SELECT is((public.get_bootstrap() -> 'user' ->> 'role_selected'), 'true',
  'and the screen is not owed again');
SELECT is((public.select_initial_role('customer', 'key-role-select-0000000001') ->> 'signup_role'),
  'customer', 'the same key replays the answer');
SELECT is((public.select_initial_role('provider', 'key-role-select-0000000002') ->> 'signup_role'),
  'customer', 'a second answer later changes nothing');
SELECT is((SELECT signup_role::text FROM public.profiles
           WHERE user_id = 'a0e00000-0000-4000-8000-000000000001'),
  'customer', 'and the stored choice is the first one');
SELECT throws_ok($$UPDATE public.profiles SET role_selected_at = NULL
                   WHERE user_id = 'a0e00000-0000-4000-8000-000000000001'$$,
  '42501', NULL, 'the client cannot reset the answer itself');

-- Choosing Service Provider takes nobody into provider mode.
SELECT pg_temp.act('a0e00000-0000-4000-8000-000000000002');
SELECT is((public.select_initial_role('provider', 'key-role-select-0000000003') ->> 'active_mode'),
  'customer', 'choosing Service Provider leaves the account in customer mode');
SELECT is((public.get_bootstrap() -> 'user' ->> 'signup_role'), 'provider',
  'with the choice there for the app to act on');
SELECT throws_ok($$SELECT public.set_active_mode('provider')$$,
  'P0001', 'ERR_PROVIDER_NOT_VERIFIED', 'and provider mode still waits for approval');

-- The provider statuses follow the verification standing and the suspension.
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT is((public.get_bootstrap() -> 'user' ->> 'provider_status'), 'pending_verification',
  'saving provider details starts verification');
RESET ROLE;
UPDATE public.profiles SET provider_verification = 'in_review'
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
SELECT is(private.provider_status('a0e00000-0000-4000-8000-000000000002'), 'pending_approval',
  'submitted for review is pending approval');
UPDATE public.profiles SET provider_verification = 'rejected'
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
SELECT is(private.provider_status('a0e00000-0000-4000-8000-000000000002'), 'rejected',
  'a refusal is rejected');
UPDATE public.profiles SET provider_verification = 'verified'
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
SELECT is(private.provider_status('a0e00000-0000-4000-8000-000000000002'), 'approved',
  'verified is approved');
UPDATE public.provider_profiles SET suspended_until = now() + interval '1 day'
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
SELECT is(private.provider_status('a0e00000-0000-4000-8000-000000000002'), 'suspended',
  'a suspension overrides approval');
UPDATE public.profiles SET provider_verification = 'expired'
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
UPDATE public.provider_profiles SET suspended_until = NULL
WHERE user_id = 'a0e00000-0000-4000-8000-000000000002';
SELECT is(private.provider_status('a0e00000-0000-4000-8000-000000000002'), 'pending_verification',
  'an expired document means verifying again');

-- Somebody signed out cannot answer for anybody, and anon cannot call it at all.
SELECT is(has_function_privilege('anon', 'public.select_initial_role(public.user_mode, text)', 'EXECUTE'),
  false, 'anon cannot choose a role');
SELECT pg_temp.act('a0e00000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is((public.get_bootstrap() -> 'user' ->> 'role_selected'), 'false',
  'one account answering does not answer for another');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
