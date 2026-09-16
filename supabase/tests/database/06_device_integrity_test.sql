-- Integrity nonces: issued to the device owner, single use, bound to user, expiring.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(10);

INSERT INTO auth.users (id, phone) VALUES
  ('77777777-7777-4777-8777-777777777777', '2348000000007'),
  ('88888888-8888-4888-8888-888888888888', '2348000000008');
INSERT INTO public.user_devices (id, user_id, platform, device_fingerprint_hash) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '77777777-7777-4777-8777-777777777777', 'android', '\x01'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '88888888-8888-4888-8888-888888888888', 'ios', '\x02');

SELECT set_config('request.jwt.claims',
  '{"sub": "77777777-7777-4777-8777-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE issued AS
  SELECT public.request_integrity_nonce('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'go_online') AS nonce;
GRANT SELECT ON issued TO service_role;
SELECT ok((SELECT nonce ~ '^[A-Za-z0-9_-]{43}$' FROM issued),
  'the nonce is 43 characters of unpadded base64url');
SELECT throws_ok($$SELECT public.request_integrity_nonce('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'go_online')$$,
  'P0001', 'ERR_DEVICE_NOT_FOUND', 'a nonce cannot be requested for someone else''s device');
SELECT throws_ok($$SELECT public.request_integrity_nonce('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'anything')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'unknown purposes are refused');
SELECT throws_ok($$SELECT public.consume_integrity_nonce('x', '77777777-7777-4777-8777-777777777777')$$,
  '42501', NULL, 'clients cannot consume nonces themselves');
RESET ROLE;

SELECT throws_ok(
  format($$SELECT public.consume_integrity_nonce(%L, '88888888-8888-4888-8888-888888888888')$$, (SELECT nonce FROM issued)),
  'P0001', 'ERR_INTEGRITY_NONCE_INVALID', 'a nonce cannot be consumed for a different user');

SET LOCAL ROLE service_role;
SELECT is(
  public.consume_integrity_nonce((SELECT nonce FROM issued), '77777777-7777-4777-8777-777777777777'),
  '{"device_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "purpose": "go_online", "platform": "android"}'::jsonb,
  'the Edge Function consumes a nonce and learns the device, purpose and platform');
SELECT throws_ok(
  format($$SELECT public.consume_integrity_nonce(%L, '77777777-7777-4777-8777-777777777777')$$, (SELECT nonce FROM issued)),
  'P0001', 'ERR_INTEGRITY_NONCE_INVALID', 'a nonce is single use');
RESET ROLE;

INSERT INTO private.integrity_nonces (nonce, user_id, device_id, purpose, expires_at)
VALUES ('expired-nonce-000000000000000000000000000000', '77777777-7777-4777-8777-777777777777',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'payment', now() - interval '1 second');
SELECT throws_ok($$SELECT public.consume_integrity_nonce('expired-nonce-000000000000000000000000000000', '77777777-7777-4777-8777-777777777777')$$,
  'P0001', 'ERR_INTEGRITY_NONCE_INVALID', 'an expired nonce is refused');

SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.request_integrity_nonce('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'go_online')$$,
  '42501', NULL, 'anon cannot request nonces');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.request_integrity_nonce('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'go_online')$$,
  '28000', 'ERR_UNAUTHENTICATED', 'a request without a subject is unauthenticated');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
