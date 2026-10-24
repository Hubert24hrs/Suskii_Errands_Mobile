-- A Google or Apple sign-up arrives without a country (signInWithIdToken carries no metadata).
-- The person chooses it once; after that it is as fixed as it is for an OTP sign-up.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(9);

INSERT INTO auth.users (id, email) VALUES ('a1111111-1111-4111-8111-585858585858', 'social@example.test');
INSERT INTO auth.users (id, phone, raw_user_meta_data)
VALUES ('a2222222-2222-4222-8222-585858585858', '2348000005802', '{"country_code": "NG"}');

SELECT is((SELECT country_code FROM public.profiles
           WHERE user_id = 'a1111111-1111-4111-8111-585858585858'), NULL,
  'a sign-up without metadata has no country yet');

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

SELECT ok(NOT has_function_privilege('anon', 'public.set_initial_country(text, text)', 'EXECUTE'),
  'nobody signed out can set a country');

SELECT pg_temp.act('a1111111-1111-4111-8111-585858585858');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_initial_country('XX')$$, 'P0001', 'ERR_COUNTRY_NOT_SUPPORTED',
  'a country that is not open is refused');
SELECT is(public.set_initial_country('ng', 'pcm'), 'NG'::char(2), 'the person chooses Nigeria');
SELECT is(public.set_initial_country('NG'), 'NG'::char(2), 'choosing it again is not an error');
SELECT throws_ok($$SELECT public.set_initial_country('KE')$$, 'P0001', 'ERR_COUNTRY_ALREADY_SET',
  'and it cannot be changed afterwards');
RESET ROLE;
SELECT is((SELECT country_code || ':' || language FROM public.profiles
           WHERE user_id = 'a1111111-1111-4111-8111-585858585858'), 'NG:pcm',
  'the country and a language it supports are stored');

SELECT pg_temp.act('a2222222-2222-4222-8222-585858585858');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_initial_country('KE')$$, 'P0001', 'ERR_COUNTRY_ALREADY_SET',
  'an OTP sign-up that already has a country cannot use it to move');
RESET ROLE;

SELECT is((SELECT value FROM public.remote_config
           WHERE key = 'customer_verification_required' AND country_code IS NULL),
  'false'::jsonb, 'customers publish without verification unless a country switches it on');

SELECT * FROM finish();
ROLLBACK;
