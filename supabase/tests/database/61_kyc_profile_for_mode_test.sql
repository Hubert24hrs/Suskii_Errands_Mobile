-- A provider applicant is in customer mode until verified (set_active_mode refuses otherwise),
-- so their verification screen asks for the provider list by name (audit 2026-10-24, AA.2).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(7);

INSERT INTO auth.users (id, phone, raw_user_meta_data)
VALUES ('a1111111-1111-4111-8111-616161616161', '2348000006101', '{"country_code": "NG"}');
INSERT INTO public.provider_profiles (user_id) VALUES ('a1111111-1111-4111-8111-616161616161');

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-616161616161", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_active_mode('provider')$$, 'P0001', 'ERR_PROVIDER_NOT_VERIFIED',
  'an applicant cannot switch to provider mode, so they stay a customer while they apply');
SELECT is((SELECT count(*)::int FROM public.get_my_kyc_profile() WHERE kind <> 'customer_facial'), 0,
  'without a mode, the list is the customer one: nothing a provider has to do');
SELECT is((SELECT array_agg(kind::text ORDER BY kind::text) FROM public.get_my_kyc_profile('provider')
           WHERE required),
  ARRAY['government_id', 'id_document_capture', 'police_clearance', 'provider_facial'],
  'asked for the provider list, the four steps the review checks are all there');
SELECT is((SELECT DISTINCT status FROM public.get_my_kyc_profile('provider')),
  'not_started'::public.kyc_step_status, 'none of them started');
SELECT is((SELECT DISTINCT overall_status FROM public.get_my_kyc_profile('provider')),
  'unverified'::public.verification_status, 'and the standing shown is the provider one');
SELECT throws_ok($$SELECT public.submit_kyc_for_review('key-aa2-review-000001')$$, 'P0001',
  'ERR_KYC_INCOMPLETE', 'review still refuses until those same steps are in');
RESET ROLE;

SELECT ok(NOT has_function_privilege('anon', 'public.get_my_kyc_profile(public.user_mode)', 'EXECUTE'),
  'nobody signed out reads a verification profile');

SELECT * FROM finish();
ROLLBACK;
