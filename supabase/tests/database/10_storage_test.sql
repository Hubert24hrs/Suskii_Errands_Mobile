-- Storage buckets and policies: private buckets, one folder per user, and KYC documents that go
-- in but never come back out to a client.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-111111111111', '2348000000031'),
  ('e2222222-2222-4222-8222-222222222222', '2348000000032');

SELECT is(
  (SELECT count(*)::int FROM storage.buckets WHERE id IN ('avatars', 'kyc-docs') AND public),
  0, 'neither bucket is public');
SELECT set_eq(
  $$SELECT id FROM storage.buckets WHERE id IN ('avatars', 'kyc-docs')$$,
  ARRAY['avatars', 'kyc-docs'],
  'both buckets exist');
SELECT ok(
  (SELECT file_size_limit FROM storage.buckets WHERE id = 'kyc-docs') > 0,
  'kyc-docs has an upload size limit');
SELECT ok(
  'application/pdf' = ANY ((SELECT allowed_mime_types FROM storage.buckets WHERE id = 'kyc-docs')),
  'kyc-docs accepts PDFs as well as photos');
SELECT ok(
  NOT ('application/pdf' = ANY ((SELECT allowed_mime_types FROM storage.buckets WHERE id = 'avatars'))),
  'avatars accepts images only');

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('avatars', 'e1111111-1111-4111-8111-111111111111/me.jpg')$$,
  'a user uploads into their own avatar folder');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('avatars', 'e2222222-2222-4222-8222-222222222222/me.jpg')$$,
  '42501', NULL, 'a user cannot write into someone else''s avatar folder');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name) VALUES ('avatars', 'me.jpg')$$,
  '42501', NULL, 'an object outside any user folder is refused');

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('kyc-docs', 'e1111111-1111-4111-8111-111111111111/nin-front.jpg')$$,
  'a user uploads their own identity document');
SELECT is(
  (SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'kyc-docs'),
  0, 'nobody reads kyc-docs back through the API, not even the owner');
SELECT is(
  (SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'avatars'),
  1, 'the owner still sees their own avatar');
RESET ROLE;

-- Another user is shown neither.
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*)::int FROM storage.objects),
  0, 'another user sees no objects at all');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
