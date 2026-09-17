-- App Attest keys: service_role only, one owner per key, bound to user + iOS device, counters
-- only move forward.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(15);

INSERT INTO auth.users (id, phone) VALUES
  ('a1111111-1111-4111-8111-111111111111', '2348000000011'),
  ('a2222222-2222-4222-8222-222222222222', '2348000000012');
INSERT INTO public.user_devices (id, user_id, platform, device_fingerprint_hash) VALUES
  ('d1111111-1111-4111-8111-111111111111', 'a1111111-1111-4111-8111-111111111111', 'ios', '\x11'),
  ('d2222222-2222-4222-8222-222222222222', 'a2222222-2222-4222-8222-222222222222', 'ios', '\x12'),
  ('d3333333-3333-4333-8333-333333333333', 'a1111111-1111-4111-8111-111111111111', 'android', '\x13');

CREATE TEMP TABLE k (key_id text, public_key text, receipt text);
INSERT INTO k VALUES (
  encode(sha256('key-one'::bytea), 'base64'),
  encode('\x04'::bytea || sha256('x'::bytea) || sha256('y'::bytea), 'base64'),
  encode('receipt'::bytea, 'base64'));
GRANT SELECT ON k TO service_role, authenticated;

-- Client roles cannot reach any of it.
SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111',
      (SELECT key_id FROM k), (SELECT public_key FROM k), (SELECT receipt FROM k), 'production')$$,
  '42501', NULL, 'a client cannot register its own attested key');
SELECT throws_ok(
  $$SELECT public.app_attest_record_assertion('a1111111-1111-4111-8111-111111111111', (SELECT key_id FROM k), 99)$$,
  '42501', NULL, 'a client cannot move its own counter');
SELECT throws_ok($$SELECT count(*) FROM private.app_attest_keys$$, '42501', NULL,
  'a client cannot read attested keys');
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT ok(
  public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111',
    (SELECT key_id FROM k), (SELECT public_key FROM k), (SELECT receipt FROM k), 'production', 4, '1.0.0'),
  'the Edge Function registers a verified key for the user''s iOS device');
SELECT ok(
  NOT public.app_attest_register_key('a2222222-2222-4222-8222-222222222222', 'd2222222-2222-4222-8222-222222222222',
    (SELECT key_id FROM k), (SELECT public_key FROM k), (SELECT receipt FROM k), 'production'),
  'the same key cannot be registered again, for another user or the same one');
SELECT throws_ok(
  $$SELECT public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd3333333-3333-4333-8333-333333333333',
      encode(sha256('key-two'::bytea), 'base64'), (SELECT public_key FROM k), (SELECT receipt FROM k), 'production')$$,
  'P0001', 'ERR_DEVICE_NOT_FOUND', 'App Attest keys belong to iOS devices only');
SELECT throws_ok(
  $$SELECT public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd2222222-2222-4222-8222-222222222222',
      encode(sha256('key-two'::bytea), 'base64'), (SELECT public_key FROM k), (SELECT receipt FROM k), 'production')$$,
  'P0001', 'ERR_DEVICE_NOT_FOUND', 'a key cannot be registered on someone else''s device');
SELECT throws_ok(
  $$SELECT public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111',
      'not base64!!', (SELECT public_key FROM k), (SELECT receipt FROM k), 'production')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a malformed key id is refused');
SELECT throws_ok(
  $$SELECT public.app_attest_register_key('a1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111',
      encode(sha256('key-two'::bytea), 'base64'), encode('\x05'::bytea || sha256('x'::bytea) || sha256('y'::bytea), 'base64'),
      (SELECT receipt FROM k), 'production')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a public key that is not an uncompressed point is refused');

SELECT is(
  public.app_attest_key_for_assertion('a1111111-1111-4111-8111-111111111111', 'd1111111-1111-4111-8111-111111111111',
    (SELECT key_id FROM k)),
  jsonb_build_object('public_key', (SELECT replace(public_key, E'\n', '') FROM k), 'sign_count', 0, 'environment', 'production'),
  'the key is returned to its owner on its device, as single-line base64');
SELECT is(
  public.app_attest_key_for_assertion('a2222222-2222-4222-8222-222222222222', 'd2222222-2222-4222-8222-222222222222',
    (SELECT key_id FROM k)),
  NULL, 'another user gets nothing for the key');

SELECT ok(public.app_attest_record_assertion('a1111111-1111-4111-8111-111111111111', (SELECT key_id FROM k), 1),
  'the first assertion advances the counter');
SELECT ok(NOT public.app_attest_record_assertion('a1111111-1111-4111-8111-111111111111', (SELECT key_id FROM k), 1),
  'replaying the same counter is refused');
SELECT ok(NOT public.app_attest_record_assertion('a2222222-2222-4222-8222-222222222222', (SELECT key_id FROM k), 5),
  'another user cannot advance the counter');
RESET ROLE;

SELECT is((SELECT sign_count FROM private.app_attest_keys), 1::bigint, 'the stored counter is the last accepted one');

SELECT * FROM finish();
ROLLBACK;
