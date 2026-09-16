-- Auth hooks and get_bootstrap(). PRD SH-01, SH-02, SH-35; R-31; RLS matrix §1.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(21);

INSERT INTO public.countries (code, name, status, currency_code, calling_code, default_language, supported_languages, config)
VALUES
  ('NG', 'Nigeria', 'live', 'NGN', '234', 'en', ARRAY['en', 'pcm'],
   '{"client": {"accepted_id_types": ["nin"]}, "server": {"sms_route": "server-only-value"}}'),
  ('GH', 'Ghana', 'disabled', 'GHS', '233', 'en', ARRAY['en'], '{"client": {}, "server": {}}'),
  ('UG', 'Uganda', 'beta', 'UGX', '256', 'en', ARRAY['en'], '{"client": {}, "server": {}}')
ON CONFLICT (code) DO UPDATE
  SET status = EXCLUDED.status, config = EXCLUDED.config, supported_languages = EXCLUDED.supported_languages;

DELETE FROM public.feature_flags;
DELETE FROM public.remote_config;
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible) VALUES
  ('test.global_on', NULL, true, 100, true),
  ('test.server_only', NULL, true, 100, false),
  ('test.country_override', NULL, false, 100, true),
  ('test.country_override', 'NG', true, 100, true),
  ('test.partial', NULL, true, 50, true);
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('min_supported_app_version', NULL, '{"android": "1.2.3", "ios": "1.2.0"}', true),
  ('server.secret_setting', NULL, '"do-not-leak"', false);

INSERT INTO auth.users (id, phone, raw_user_meta_data) VALUES
  ('44444444-4444-4444-8444-444444444444', '2348000000004', '{"country_code": "NG"}'),
  ('55555555-5555-4555-8555-555555555555', '2348000000005', '{"country_code": "NG"}'),
  ('66666666-6666-4666-8666-666666666666', '2348000000006', '{"country_code": "NG"}');
INSERT INTO public.admin_users (user_id, roles, disabled_at) VALUES
  ('55555555-5555-4555-8555-555555555555', ARRAY['finance_officer', 'dispute_officer']::public.admin_role[], NULL),
  ('66666666-6666-4666-8666-666666666666', ARRAY['super_admin']::public.admin_role[], now());

-- ---- custom access token hook ----------------------------------------------
SELECT is(
  private.custom_access_token_hook('{"user_id": "44444444-4444-4444-8444-444444444444", "claims": {"sub": "x"}}') #>> '{claims,active_mode}',
  'customer', 'the access token carries the active mode');
SELECT ok(
  NOT (private.custom_access_token_hook('{"user_id": "44444444-4444-4444-8444-444444444444", "claims": {"admin_roles": ["super_admin"]}}') -> 'claims' ? 'admin_roles'),
  'a non-admin gets no admin_roles claim, even if one was supplied');
SELECT is(
  private.custom_access_token_hook('{"user_id": "55555555-5555-4555-8555-555555555555", "claims": {}}') #> '{claims,admin_roles}',
  '["finance_officer", "dispute_officer"]'::jsonb, 'an admin gets their roles as a claim');
SELECT ok(
  NOT (private.custom_access_token_hook('{"user_id": "66666666-6666-4666-8666-666666666666", "claims": {}}') -> 'claims' ? 'admin_roles'),
  'a disabled admin gets no admin_roles claim');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT private.custom_access_token_hook('{}')$$, '42501', NULL,
  'clients cannot call the access token hook');
RESET ROLE;
SELECT ok(has_function_privilege('supabase_auth_admin', 'private.custom_access_token_hook(jsonb)', 'EXECUTE'),
  'the auth service can call the access token hook');

-- ---- before user created hook ---------------------------------------------
SELECT is(private.before_user_created_hook('{"user": {"phone": "+2348012345678"}}'), '{}'::jsonb,
  'a phone number in a live country may sign up');
SELECT is(private.before_user_created_hook('{"user": {"phone": "256712345678"}}'), '{}'::jsonb,
  'a phone number in a beta country may sign up');
SELECT is(private.before_user_created_hook('{"user": {"phone": "+14155550100"}}') #>> '{error,message}',
  'ERR_COUNTRY_NOT_SUPPORTED', 'a phone number outside supported countries is refused before any SMS');
SELECT is(private.before_user_created_hook('{"user": {"phone": "+233201234567"}}') #>> '{error,http_code}',
  '403', 'a phone number in a disabled country is refused');
SELECT is(private.before_user_created_hook('{"user": {"email": "ada@example.com"}}'), '{}'::jsonb,
  'email sign-ups are not affected');

-- ---- get_bootstrap as anon ---------------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
CREATE TEMP TABLE boot AS SELECT public.get_bootstrap('NG', 'android') AS b;
RESET ROLE;

SELECT ok(
  NOT EXISTS (SELECT 1 FROM boot, jsonb_array_elements(b -> 'countries') c WHERE c ->> 'code' = 'GH'),
  'disabled countries are not offered');
SELECT is((SELECT b #>> '{country_pack,currency,exponent}' FROM boot), '2',
  'the country pack carries the currency exponent');
SELECT is((SELECT b #> '{country_pack,client}' FROM boot), '{"accepted_id_types": ["nin"]}'::jsonb,
  'the client section of the country pack is served');
SELECT ok((SELECT b::text NOT LIKE '%server-only-value%' AND b::text NOT LIKE '%do-not-leak%' FROM boot),
  'server-only country config and remote config never leave the database');
SELECT is((SELECT b -> 'feature_flags' FROM boot),
  '{"test.global_on": true, "test.country_override": true, "test.partial": false}'::jsonb,
  'flags: server-only hidden, country override applied, partial rollout off for anonymous callers');
SELECT is((SELECT b ->> 'min_supported_app_version' FROM boot), '1.2.3',
  'the minimum app version is per platform');
SELECT ok((SELECT (b ->> 'server_time')::timestamptz IS NOT NULL AND b -> 'user' = 'null'::jsonb FROM boot),
  'server_time is present and there is no user for anonymous callers');

SET LOCAL ROLE anon;
SELECT is(public.get_bootstrap('UG', 'ios') #>> '{country_pack,currency,exponent}', '0',
  'UGX is served with exponent 0');
RESET ROLE;

-- ---- get_bootstrap as a signed-in user ------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "44444444-4444-4444-8444-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.get_bootstrap('UG', 'android') #>> '{country_pack,code}', 'NG',
  'a signed-in user gets their profile''s country, not the one requested');
SELECT is(public.get_bootstrap(NULL, 'android') #>> '{user,active_mode}', 'customer',
  'a signed-in user gets their profile summary');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
