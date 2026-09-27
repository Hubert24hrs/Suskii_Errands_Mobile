-- Account lifecycle: self-serve deletion with a grace period, erasure that keeps the records the
-- law requires, and data export requests (CR-20260923-07; audit 2026-09-27 Y.9).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(30);

INSERT INTO auth.users (id, phone, email) VALUES
  ('e1111111-1111-4111-8111-111111111111', '2348000000461', 'leaving@example.test'),
  ('e2222222-2222-4222-8222-222222222222', '2348000000462', NULL);
UPDATE public.profiles SET country_code = 'NG', display_name = 'Ada Leaving',
       customer_verification = 'verified'
WHERE user_id = 'e1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', display_name = 'Bola Staying'
WHERE user_id = 'e2222222-2222-4222-8222-222222222222';
INSERT INTO auth.sessions (id, user_id, created_at) VALUES
  ('e1111111-0000-4000-8000-000000000001', 'e1111111-1111-4111-8111-111111111111', now()),
  ('e1111111-0000-4000-8000-000000000002', 'e1111111-1111-4111-8111-111111111111', now());
INSERT INTO public.trusted_contacts (user_id, name, phone_ciphertext, phone_blind_index)
VALUES ('e1111111-1111-4111-8111-111111111111', 'Mum', '\x01'::bytea, '\x02'::bytea);

CREATE TEMP TABLE al (name text PRIMARY KEY, v text);
GRANT ALL ON al TO authenticated, service_role;

SELECT ok((SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
           WHERE oid = 'public.account_deletion_requests'::regclass),
  'deletion requests have row level security, forced');
SELECT ok((SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
           WHERE oid = 'public.data_export_requests'::regclass),
  'export requests have row level security, forced');
SELECT ok(NOT has_function_privilege('authenticated', 'private.process_account_deletions(integer)', 'EXECUTE'),
  'no app can run the erasure sweep');
SELECT ok(NOT has_function_privilege('authenticated', 'private.collect_personal_data(uuid)', 'EXECUTE'),
  'and no app can ask for everything about a person');

-- ---------------------------------------------------------------------------
-- Requesting, replaying, and the grace period.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO al VALUES ('when', public.request_account_deletion('key-al-delete-000000000001')::text);
SELECT ok((SELECT v::timestamptz FROM al WHERE name = 'when')
            BETWEEN now() + interval '29 days' AND now() + interval '31 days',
  'deletion is scheduled after the configured grace period');
SELECT is(public.request_account_deletion('key-al-delete-000000000001'),
  (SELECT v::timestamptz FROM al WHERE name = 'when'), 'a repeated key replays the same date');
SELECT is(public.request_account_deletion('key-al-delete-000000000002'),
  (SELECT v::timestamptz FROM al WHERE name = 'when'),
  'asking again with a new key is not a second deletion');
SELECT is((SELECT count(*)::int FROM public.account_deletion_requests), 1,
  'the user sees exactly one request: their own');
SELECT is((public.get_bootstrap() -> 'user' ->> 'deletion_scheduled_for')::timestamptz,
  (SELECT v::timestamptz FROM al WHERE name = 'when'),
  'bootstrap carries the date, so the app can offer to keep the account');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM auth.sessions
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 0,
  'requesting deletion signs the account out on every device');

SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.account_deletion_requests), 0,
  'nobody else can see that somebody is leaving');
SELECT ok((public.get_bootstrap() -> 'user' ->> 'deletion_scheduled_for') IS NULL,
  'and a user with nothing scheduled sees no date');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Changing one's mind.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.cancel_account_deletion('key-al-cancel-000000000001'), true,
  'signing back in and cancelling keeps the account');
SELECT is(public.cancel_account_deletion('key-al-cancel-000000000001'), true,
  'a repeated key replays the answer');
SELECT is(public.cancel_account_deletion('key-al-cancel-000000000002'), false,
  'cancelling with nothing scheduled says so rather than failing');
SELECT is((SELECT status::text FROM public.account_deletion_requests), 'cancelled',
  'the request is kept as the record of what was asked');

-- Asking again later schedules afresh; a published request is an obligation still open.
SELECT public.request_account_deletion('key-al-delete-000000000003');
INSERT INTO al VALUES ('req', public.create_request(
  'key-al-create-req-0000000001', 'errands_delivery', 'A parcel to Yaba', 'Lekki Phase 1',
  'standard', false, NULL, NULL, 6.4459, 3.4750)::text);
SELECT public.publish_request((SELECT v::uuid FROM al WHERE name = 'req'), 'key-al-publish-0000000001');
RESET ROLE;

UPDATE public.account_deletion_requests SET scheduled_for = requested_at
WHERE user_id = 'e1111111-1111-4111-8111-111111111111' AND status = 'scheduled';
SELECT is(private.process_account_deletions(), 0, 'nothing is erased while a request is still live');
SELECT is((SELECT blocked_reason FROM public.account_deletion_requests
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111' AND status = 'scheduled'),
  'active_job', 'and support can see why');
SELECT is((SELECT display_name FROM public.profiles
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 'Ada Leaving',
  'the account is untouched while it waits');

-- ---------------------------------------------------------------------------
-- Erasure.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_request((SELECT v::uuid FROM al WHERE name = 'req'), 'key-al-cancel-req-0000001');
RESET ROLE;

SELECT is(private.process_account_deletions(), 1, 'with the obligation gone, the sweep erases');
-- One transaction means one now(), so the rows are told apart by status rather than by time.
SELECT is((SELECT count(*)::int FROM public.account_deletion_requests
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111' AND status = 'completed'
             AND completed_at IS NOT NULL AND blocked_reason IS NULL),
  1, 'the request is completed');
SELECT is((SELECT display_name FROM public.profiles
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), '',
  'the name is gone');
SELECT ok((SELECT phone IS NULL AND email IS NULL FROM auth.users
           WHERE id = 'e1111111-1111-4111-8111-111111111111'),
  'so are the phone number and the email address');
SELECT ok((SELECT banned_until = 'infinity'::timestamptz AND deleted_at IS NOT NULL FROM auth.users
           WHERE id = 'e1111111-1111-4111-8111-111111111111'),
  'and nobody can sign in as them again');
SELECT is((SELECT count(*)::int FROM public.trusted_contacts
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 0,
  'the people they trusted are no longer on file');
SELECT is((SELECT count(*)::int FROM public.requests
           WHERE customer_id = 'e1111111-1111-4111-8111-111111111111'), 1,
  'the marketplace record the law requires is kept, without the name');
SELECT is((SELECT display_name FROM public.profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 'Bola Staying',
  'and nobody else is touched');

-- ---------------------------------------------------------------------------
-- Data export.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO al VALUES ('ref', public.request_data_export('key-al-export-000000000001'));
SELECT matches((SELECT v FROM al WHERE name = 'ref'), '^EXP-[0-9A-F]{10}$',
  'an export request returns a reference the user can quote');
SELECT is(public.request_data_export('key-al-export-000000000002'), (SELECT v FROM al WHERE name = 'ref'),
  'while one is open, asking again returns the same reference');
RESET ROLE;

SELECT is(private.collect_personal_data('e2222222-2222-4222-8222-222222222222') -> 'profile' ->> 'display_name',
  'Bola Staying', 'the export document carries the profile');

SELECT * FROM finish();
ROLLBACK;
