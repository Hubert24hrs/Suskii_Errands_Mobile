-- Sessions (SH-38): a user sees only their own sessions, can sign out one or all others, and
-- cannot touch anyone else's. Revocation is audit-logged.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-111111111111', '2348000000021'),
  ('b2222222-2222-4222-8222-222222222222', '2348000000022');

INSERT INTO auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal, user_agent, ip) VALUES
  ('c1111111-1111-4111-8111-111111111111', 'b1111111-1111-4111-8111-111111111111',
   now() - interval '3 days', now(), (now() - interval '1 hour')::timestamp, 'aal1', 'Suskii/0.1 (Android 14)', '102.89.1.1'),
  ('c2222222-2222-4222-8222-222222222222', 'b1111111-1111-4111-8111-111111111111',
   now() - interval '10 days', now(), (now() - interval '9 days')::timestamp, 'aal2', 'Suskii/0.1 (iOS 17)', '105.112.2.2'),
  ('c3333333-3333-4333-8333-333333333333', 'b2222222-2222-4222-8222-222222222222',
   now(), now(), now()::timestamp, 'aal1', 'Suskii/0.1 (Android 13)', '41.58.3.3');

-- Signed in on the newest session of user one.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', 'b1111111-1111-4111-8111-111111111111', 'role', 'authenticated', 'aal', 'aal1',
  'session_id', 'c1111111-1111-4111-8111-111111111111')::text, true);
SET LOCAL ROLE authenticated;

SELECT set_eq(
  $$SELECT id FROM public.list_sessions()$$,
  ARRAY['c1111111-1111-4111-8111-111111111111', 'c2222222-2222-4222-8222-222222222222']::uuid[],
  'a user sees their own sessions and nobody else''s');
SELECT is(
  (SELECT count(*)::int FROM public.list_sessions() WHERE is_current),
  1, 'exactly one session is marked as the current one');
SELECT is(
  (SELECT id FROM public.list_sessions() LIMIT 1),
  'c1111111-1111-4111-8111-111111111111'::uuid,
  'the most recently refreshed session comes first');
SELECT is(
  (SELECT ip FROM public.list_sessions() WHERE is_current),
  '102.89.1.1', 'the IP is returned as text, not inet');
SELECT is(
  (SELECT aal FROM public.list_sessions() WHERE NOT is_current),
  'aal2', 'the assurance level is returned as text');

SELECT throws_ok(
  $$SELECT public.revoke_session('c3333333-3333-4333-8333-333333333333')$$,
  'P0001', 'ERR_SESSION_NOT_FOUND', 'a user cannot revoke someone else''s session');
SELECT throws_ok(
  $$SELECT public.revoke_session('c9999999-9999-4999-8999-999999999999')$$,
  'P0001', 'ERR_SESSION_NOT_FOUND', 'an unknown session id is refused');
SELECT is((SELECT count(*)::int FROM auth.sessions), 3, 'nothing was deleted by the refused calls');

SELECT lives_ok(
  $$SELECT public.revoke_session('c2222222-2222-4222-8222-222222222222')$$,
  'a user signs out their other session');
SELECT set_eq(
  $$SELECT id FROM public.list_sessions()$$,
  ARRAY['c1111111-1111-4111-8111-111111111111']::uuid[],
  'the revoked session is gone; the current one remains');

-- Sign out everywhere else, from a second session of the same user.
INSERT INTO auth.sessions (id, user_id, created_at, updated_at, aal)
VALUES ('c4444444-4444-4444-8444-444444444444', 'b1111111-1111-4111-8111-111111111111', now(), now(), 'aal1');
SELECT is(public.revoke_other_sessions(), 1, 'sign out everywhere else reports what it removed');
SELECT set_eq(
  $$SELECT id FROM public.list_sessions()$$,
  ARRAY['c1111111-1111-4111-8111-111111111111']::uuid[],
  'only the caller''s own session survives');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
