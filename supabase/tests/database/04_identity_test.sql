-- Identity: profile creation, RLS, column grants, set_active_mode, consents, devices,
-- notification preferences, admin re-check with aal2. RLS matrix §2; PRD SH-01/05/07/08/16.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(28);

INSERT INTO public.countries (code, name, status, currency_code, calling_code, default_language, supported_languages)
VALUES ('NG', 'Nigeria', 'live', 'NGN', '234', 'en', ARRAY['en', 'pcm'])
ON CONFLICT (code) DO UPDATE SET status = 'live', supported_languages = ARRAY['en', 'pcm'];

INSERT INTO auth.users (id, phone, raw_user_meta_data) VALUES
  ('11111111-1111-4111-8111-111111111111', '2348000000001', '{"country_code": "ng", "language": "pcm"}'),
  ('22222222-2222-4222-8222-222222222222', '2348000000002', '{"country_code": "XX", "language": "fr"}'),
  ('33333333-3333-4333-8333-333333333333', '2348000000003', '{"country_code": "NG"}');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('33333333-3333-4333-8333-333333333333', ARRAY['support_agent']::public.admin_role[]);

SELECT ok(
  (SELECT country_code = 'NG' AND language = 'pcm' AND active_mode = 'customer' AND trust_level = 'new'
   FROM public.profiles WHERE user_id = '11111111-1111-4111-8111-111111111111'),
  'a profile is created on sign-up from validated metadata');

SELECT ok(
  (SELECT country_code IS NULL AND language = 'en'
   FROM public.profiles WHERE user_id = '22222222-2222-4222-8222-222222222222'),
  'unknown country and unsupported language in metadata are not trusted');

-- ---- as user 1 --------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "11111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;

SELECT is((SELECT count(*)::int FROM public.profiles), 1, 'a user sees only their own profile');
SELECT lives_ok($$UPDATE public.profiles SET display_name = 'Ada' WHERE user_id = auth.uid()$$,
  'a user may update their display name');
SELECT throws_ok($$UPDATE public.profiles SET trust_level = 'elite' WHERE user_id = auth.uid()$$,
  '42501', NULL, 'a user cannot update their trust level');
SELECT throws_ok($$UPDATE public.profiles SET customer_verification = 'verified' WHERE user_id = auth.uid()$$,
  '42501', NULL, 'a user cannot mark themselves verified');
SELECT throws_ok($$UPDATE public.profiles SET active_mode = 'provider' WHERE user_id = auth.uid()$$,
  '42501', NULL, 'a user cannot change mode by direct update');
UPDATE public.profiles SET display_name = 'Hijack' WHERE user_id = '22222222-2222-4222-8222-222222222222';
RESET ROLE;
SELECT is((SELECT display_name FROM public.profiles WHERE user_id = '22222222-2222-4222-8222-222222222222'), '',
  'a user cannot update another user''s profile');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$UPDATE public.profiles SET language = 'fr' WHERE user_id = auth.uid()$$,
  '22023', 'ERR_LANGUAGE_NOT_SUPPORTED', 'language must be supported by the user''s country');
SELECT throws_ok($$SELECT public.set_active_mode('provider')$$,
  'P0001', 'ERR_PROVIDER_NOT_VERIFIED', 'provider mode requires provider verification');

SELECT is((public.record_consent('biometric', true, 'consent-key-000000001') ->> 'granted')::boolean, true,
  'record_consent records a grant');
SELECT is(
  public.record_consent('biometric', true, 'consent-key-000000001') ->> 'id',
  (SELECT id::text FROM public.consents WHERE user_id = auth.uid() ORDER BY id LIMIT 1),
  'retrying record_consent with the same key replays the first result');
SELECT is((SELECT count(*)::int FROM public.consents WHERE user_id = auth.uid()), 1,
  'the retry did not record a second consent');
SELECT throws_ok($$UPDATE public.consents SET granted = false$$, '42501', NULL,
  'consents cannot be updated by clients');

CREATE TEMP TABLE device_ids (id uuid);
GRANT ALL ON device_ids TO authenticated;
INSERT INTO device_ids SELECT public.register_device('android', 'fingerprint-android-0001', '1.0.0', 'fcm-token');
INSERT INTO device_ids SELECT public.register_device('android', 'fingerprint-android-0001', '1.0.1');
SELECT is((SELECT count(DISTINCT id)::int FROM device_ids), 1,
  'registering the same device twice updates one row');
SELECT throws_ok($$SELECT public.register_device('android', 'fingerprint-android-0002', '1.0.0', NULL, 'voip-token')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'VoIP tokens are refused on Android');
SELECT throws_ok($$SELECT push_token FROM public.user_devices$$, '42501', NULL,
  'push tokens are not readable by clients');

SELECT lives_ok(
  $$INSERT INTO public.notification_preferences (user_id, channel, category, enabled)
    VALUES (auth.uid(), 'push', 'marketing', false)$$,
  'a user may create their own notification preference');
SELECT throws_ok(
  $$INSERT INTO public.notification_preferences (user_id, channel, category, enabled)
    VALUES ('22222222-2222-4222-8222-222222222222', 'push', 'marketing', false)$$,
  '42501', NULL, 'a user cannot create preferences for someone else');
RESET ROLE;

-- ---- server-side changes, then user 1 again --------------------------------
SELECT throws_ok($$UPDATE public.consents SET granted = false$$, '42501', 'ERR_AUDIT_APPEND_ONLY',
  'consents are append-only even for the owner');

UPDATE public.profiles SET provider_verification = 'verified'
WHERE user_id = '11111111-1111-4111-8111-111111111111';

SET LOCAL ROLE authenticated;
SELECT is(public.set_active_mode('provider'), 'provider'::public.user_mode,
  'a verified provider may switch to provider mode');
SELECT lives_ok($$SELECT public.record_consent('biometric', false, 'consent-key-000000002')$$,
  'withdrawing consent records a new row');
RESET ROLE;

SELECT ok(
  EXISTS (SELECT 1 FROM private.outbox WHERE event_type = 'profile.mode_changed'
          AND aggregate_id = '11111111-1111-4111-8111-111111111111'),
  'a mode change emits an outbox event');
SELECT is(private.has_consent('11111111-1111-4111-8111-111111111111', 'biometric'), false,
  'the latest consent row wins');

-- ---- anon and claim-less callers ------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM public.profiles$$, '42501', NULL, 'anon cannot read profiles');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_active_mode('customer')$$, '28000', 'ERR_UNAUTHENTICATED',
  'a call without a subject fails as unauthenticated, not as a cast error');
RESET ROLE;

-- ---- admin re-check requires aal2 ----------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "33333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles), 1, 'an admin without MFA sees only their own profile');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "33333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) FROM public.profiles) >= 3, 'an admin with MFA can read profiles in scope');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
