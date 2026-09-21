-- The KYC spine: sessions, steps, the officer queue, and the deny cases the RLS matrix names
-- (ERD §4; RLS matrix §4; PRD PR-02…PR-08, PR-14, AD-08).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(41);

INSERT INTO auth.users (id, phone) VALUES
  ('6b111111-1111-4111-8111-ffffffffffff', '2348000000151'),   -- a provider applicant
  ('6b222222-2222-4222-8222-ffffffffffff', '2348000000152'),   -- someone with the same ID number
  ('6b333333-3333-4333-8333-ffffffffffff', '2348000000153'),   -- verification officer
  ('6b444444-4444-4444-8444-ffffffffffff', '2348000000154');   -- support agent
UPDATE public.profiles SET country_code = 'NG', active_mode = 'provider'
WHERE user_id IN ('6b111111-1111-4111-8111-ffffffffffff',
                  '6b222222-2222-4222-8222-ffffffffffff');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('6b333333-3333-4333-8333-ffffffffffff',
                  '6b444444-4444-4444-8444-ffffffffffff');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('6b333333-3333-4333-8333-ffffffffffff',
   ARRAY['verification_officer']::public.admin_role[]),
  ('6b444444-4444-4444-8444-ffffffffffff',
   ARRAY['support_agent']::public.admin_role[]);

-- The applicant has a provider profile, so the last assertion about `is_active_provider`
-- tests the verification rather than the absence of a row.
INSERT INTO public.provider_profiles (user_id) VALUES ('6b111111-1111-4111-8111-ffffffffffff');

CREATE TEMP TABLE ky (name text PRIMARY KEY, id uuid);
GRANT ALL ON ky TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Nothing starts without consent (SH-07).
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "6b111111-1111-4111-8111-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.start_verification_session('provider_facial')$$,
  'P0001', 'ERR_CONSENT_REQUIRED', 'a facial check needs biometric consent first');
SELECT public.record_consent('biometric', true, 'key-ky-consent-bio-00001');
INSERT INTO ky VALUES ('sess', public.start_verification_session('provider_facial'));
SELECT ok((SELECT id FROM ky WHERE name = 'sess') IS NOT NULL,
  'with consent recorded, a session starts');
SELECT is((SELECT count(*)::int FROM public.get_my_kyc_profile() WHERE required), 4,
  'a provider in Nigeria has four required steps');
SELECT is((SELECT status FROM public.get_my_kyc_profile() WHERE kind = 'provider_facial'),
  'not_started'::public.kyc_step_status, 'none of them started yet');
RESET ROLE;

-- The vendor's answer arrives through the seam, never from the app.
SELECT is(private.record_vendor_check((SELECT id FROM ky WHERE name = 'sess'),
            'smile_id', 'job-123', 'success'),
  'verified'::public.kyc_step_status, 'a successful check verifies the facial step');
SELECT is((SELECT provider_verification FROM public.profiles
           WHERE user_id = '6b111111-1111-4111-8111-ffffffffffff'),
  'pending'::public.verification_status,
  'and the standing moves to pending: one step done, three to go');

-- ---------------------------------------------------------------------------
-- One identity, one account.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "6b111111-1111-4111-8111-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.submit_identity_document('key-ky-id-a-0000000000001', 'nin',
            '\xdeadbeef'::bytea, sha256('12345678901'::bytea)) IS NOT NULL,
  'a provider submits their national ID');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "6b222222-2222-4222-8222-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.submit_identity_document('key-ky-id-b-0000000000001', 'nin',
      '\xfeedface'::bytea, sha256('12345678901'::bytea))$$,
  'P0001', 'ERR_IDENTITY_ALREADY_REGISTERED',
  'the same number cannot back a second account — matched on the blind index, read by nobody');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Submitting documents for review.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "6b111111-1111-4111-8111-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.submit_kyc_step('key-ky-step-a-000000001', 'id_document_capture',
            ARRAY['6b111111-1111-4111-8111-ffffffffffff/nin-front.jpg']),
  'in_review'::public.kyc_step_status, 'an uploaded document goes to the queue');
SELECT throws_ok(
  $$SELECT public.submit_kyc_step('key-ky-step-a-000000002', 'government_id',
      ARRAY['6b222222-2222-4222-8222-ffffffffffff/someone-else.jpg'])$$,
  '22023', 'ERR_INVALID_ARGUMENT',
  'and it has to be in your own folder, not somebody else''s');
SELECT throws_ok(
  $$SELECT public.submit_police_clearance('key-ky-pc-a-0000000001', '\x01'::bytea,
      sha256('PC-1'::bytea), (now() - interval '2 years')::date,
      (now() + interval '1 year')::date)$$,
  'P0001', 'ERR_CONSENT_REQUIRED', 'a police clearance needs its own consent');
SELECT public.record_consent('criminal_record_check', true,
  'key-ky-consent-crc-00001');
SELECT throws_ok(
  $$SELECT public.submit_police_clearance('key-ky-pc-a-0000000002', '\x01'::bytea,
      sha256('PC-1'::bytea), (now() - interval '2 years')::date,
      (now() + interval '1 year')::date)$$,
  'P0001', 'ERR_KYC_STEP_INVALID',
  'a certificate issued two years ago is not evidence of anything current (OD-09)');
SELECT is(public.submit_police_clearance('key-ky-pc-a-0000000003', '\x01'::bytea,
            sha256('PC-1'::bytea), (now() - interval '1 month')::date,
            (now() + interval '2 months')::date, '6b111111-1111-4111-8111-ffffffffffff/pc.pdf'),
  'in_review'::public.kyc_step_status, 'a recent one is accepted for review');
SELECT is((SELECT status FROM public.get_my_kyc_profile() WHERE kind = 'police_clearance'),
  'in_review'::public.kyc_step_status, 'and the applicant can see where it is');
SELECT is((SELECT count(*)::int FROM public.get_my_kyc_profile()
           WHERE rejection_reason_key IS NOT NULL), 0, 'with nothing rejected yet');
RESET ROLE;

-- The applicant cannot reach the tables, or the queue.
SELECT set_config('request.jwt.claims',
  '{"sub": "6b111111-1111-4111-8111-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT count(*) FROM kyc.kyc_steps$$,
  '42501', NULL, 'no role has table privileges on kyc: not even your own rows');
SELECT throws_ok($$SELECT public.kyc_review_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and an applicant is not a reviewer');
SELECT throws_ok(
  $$SELECT public.request_document_access(
      '6b111111-1111-4111-8111-ffffffffffff/nin-front.jpg', 'review')$$,
  '42501', 'ERR_PERMISSION_DENIED',
  'a user cannot read back their own upload: the bucket is write-only for clients');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The officer. Admin roles need MFA on the session, which is why these claims say aal2.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "6b333333-3333-4333-8333-ffffffffffff", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.kyc_review_queue()), 2,
  'the officer sees both submitted steps');
INSERT INTO ky VALUES ('step', (SELECT step_id FROM public.kyc_review_queue()
                                WHERE kind = 'id_document_capture'));
SELECT throws_ok(
  format($$SELECT public.decide_kyc_step('key-ky-dec-o-000000001', %L, 'rejected')$$,
    (SELECT id FROM ky WHERE name = 'step')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'a rejection without a reason key is refused: the applicant could not act on it');
SELECT is(public.decide_kyc_step('key-ky-dec-o-000000002',
            (SELECT id FROM ky WHERE name = 'step'), 'rejected', 'document_blurry'),
  'rejected'::public.kyc_step_status, 'a reasoned rejection is recorded');
SELECT is(public.request_document_access(
            '6b111111-1111-4111-8111-ffffffffffff/nin-front.jpg', 'kyc_review'),
  '6b111111-1111-4111-8111-ffffffffffff/nin-front.jpg',
  'the officer may ask for a document');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM audit.kyc_access
           WHERE officer_id = '6b333333-3333-4333-8333-ffffffffffff'), 1,
  'and asking is logged before any URL exists');
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'kyc.decide_step'), 1,
  'the decision is in the hash-chained log');
SELECT throws_ok(
  $$UPDATE audit.kyc_access SET reason_code = 'rewritten'$$,
  '42501', 'ERR_AUDIT_APPEND_ONLY', 'and the access log cannot be rewritten');

-- The applicant is told, and can act on it.
SELECT set_config('request.jwt.claims',
  '{"sub": "6b111111-1111-4111-8111-ffffffffffff", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT rejection_reason_key FROM public.get_my_kyc_profile()
           WHERE kind = 'id_document_capture'), 'document_blurry',
  'the applicant sees the reason key, which is all a screen needs');
SELECT is((SELECT count(*)::int FROM public.notifications WHERE kind = 'system'), 1,
  'and was told');
SELECT is(public.submit_kyc_step('key-ky-step-a-000000003', 'id_document_capture',
            ARRAY['6b111111-1111-4111-8111-ffffffffffff/nin-front-2.jpg']),
  'in_review'::public.kyc_step_status, 'resubmitting puts it back in the queue');
SELECT is((SELECT attempt_count FROM public.get_my_kyc_profile()
           WHERE kind = 'id_document_capture'), 2::smallint, 'and counts the attempt');
RESET ROLE;

-- Nobody reviews themselves (a named deny case in the RLS matrix).
INSERT INTO kyc.kyc_steps (user_id, kind, status, submitted_at)
VALUES ('6b333333-3333-4333-8333-ffffffffffff', 'government_id', 'in_review', now());
SELECT set_config('request.jwt.claims',
  '{"sub": "6b333333-3333-4333-8333-ffffffffffff", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.kyc_review_queue()
           WHERE user_id = '6b333333-3333-4333-8333-ffffffffffff'), 0,
  'an officer''s own step never appears in their queue');
SELECT throws_ok(
  format($$SELECT public.decide_kyc_step('key-ky-dec-self-00000001', %L, 'approved')$$,
    (SELECT s.id FROM kyc.kyc_steps s
     WHERE s.user_id = '6b333333-3333-4333-8333-ffffffffffff')),
  '42501', 'ERR_PERMISSION_DENIED', 'and they cannot decide it by id either');
RESET ROLE;

-- Support sees status, never documents (RLS matrix §4).
SELECT set_config('request.jwt.claims',
  '{"sub": "6b444444-4444-4444-8444-ffffffffffff", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) FROM public.verification_summary(
            '6b111111-1111-4111-8111-ffffffffffff')) >= 3,
  'support can read verification status');
SELECT throws_ok(
  $$SELECT public.request_document_access(
      '6b111111-1111-4111-8111-ffffffffffff/nin-front.jpg', 'curiosity')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'but never a document');
SELECT throws_ok($$SELECT public.kyc_review_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and does not work the verification queue');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- PR-14: expiry, reminders, and the standing that lapses.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "6b333333-3333-4333-8333-ffffffffffff", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.decide_kyc_step('key-ky-dec-pc-000000001',
            (SELECT step_id FROM public.kyc_review_queue() WHERE kind = 'police_clearance'),
            'approved'),
  'verified'::public.kyc_step_status, 'the police clearance is approved');
RESET ROLE;
SELECT ok((SELECT decision FROM kyc.police_clearances
           WHERE user_id = '6b111111-1111-4111-8111-ffffffffffff') = 'approved',
  'and the certificate carries the decision');

SELECT is(private.expire_kyc_documents(), 0, 'nothing has expired yet');
UPDATE kyc.kyc_steps SET expires_at = now() - interval '1 day'
WHERE user_id = '6b111111-1111-4111-8111-ffffffffffff' AND kind = 'police_clearance';
SELECT is(private.expire_kyc_documents(), 1, 'the day it lapses, it lapses');
SELECT is((SELECT status FROM kyc.kyc_steps
           WHERE user_id = '6b111111-1111-4111-8111-ffffffffffff' AND kind = 'police_clearance'),
  'expired'::public.kyc_step_status, 'the step is expired');
SELECT is((SELECT provider_verification FROM public.profiles
           WHERE user_id = '6b111111-1111-4111-8111-ffffffffffff'),
  'expired'::public.verification_status,
  'and the provider''s standing with it — which is what stops them taking new work');
SELECT ok(NOT (SELECT private.is_active_provider('6b111111-1111-4111-8111-ffffffffffff')),
  'is_active_provider agrees, so offers and dispatch refuse them');

SELECT * FROM finish();
ROLLBACK;
