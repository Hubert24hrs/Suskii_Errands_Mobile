-- The country scope on the two queues whose subject is polymorphic (`AUDIT-2026-09-22b.md`,
-- U.1's remainder).
--
-- The interesting case is a subject that belongs to **two** countries: a device reuse flag exists
-- because one handset has been several accounts, and those accounts may not be in the same place.
-- Hiding it from either officer would hide it from somebody whose problem it is.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(23);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-aaaaaaaaaaaa', '2348000001001'),   -- NG customer
  ('b2222222-2222-4222-8222-aaaaaaaaaaaa', '2547000001002'),   -- KE customer
  ('b3333333-3333-4333-8333-aaaaaaaaaaaa', '2348000001003'),   -- support, scoped to NG
  ('b4444444-4444-4444-8444-aaaaaaaaaaaa', '2547000001004'),   -- support, scoped to KE
  ('b5555555-5555-4555-8555-aaaaaaaaaaaa', '2338000001005'),   -- support, scoped to GH
  ('b6666666-6666-4666-8666-aaaaaaaaaaaa', '2348000001006');   -- super admin, scoped to NG
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'b1111111-1111-4111-8111-aaaaaaaaaaaa';
UPDATE public.profiles SET country_code = 'KE', customer_verification = 'verified'
WHERE user_id = 'b2222222-2222-4222-8222-aaaaaaaaaaaa';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('b3333333-3333-4333-8333-aaaaaaaaaaaa', 'b6666666-6666-4666-8666-aaaaaaaaaaaa');
UPDATE public.profiles SET country_code = 'KE'
WHERE user_id = 'b4444444-4444-4444-8444-aaaaaaaaaaaa';
UPDATE public.profiles SET country_code = 'GH'
WHERE user_id = 'b5555555-5555-4555-8555-aaaaaaaaaaaa';
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('b3333333-3333-4333-8333-aaaaaaaaaaaa', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('b4444444-4444-4444-8444-aaaaaaaaaaaa', ARRAY['support_agent']::public.admin_role[],
   ARRAY['KE']::char(2)[]),
  ('b5555555-5555-4555-8555-aaaaaaaaaaaa', ARRAY['support_agent']::public.admin_role[],
   ARRAY['GH']::char(2)[]),
  ('b6666666-6666-4666-8666-aaaaaaaaaaaa', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- Each subject kind resolves to the right country, or to none.
-- ---------------------------------------------------------------------------
SELECT is(private.fraud_subject_countries('user', 'b1111111-1111-4111-8111-aaaaaaaaaaaa'),
  ARRAY['NG']::char(2)[], 'a user subject resolves through their profile');
SELECT is(private.fraud_subject_countries('user', 'not-a-uuid'), '{}'::char(2)[],
  'and an id that is not a uuid resolves to nothing rather than raising');
SELECT is(private.fraud_subject_countries('pair',
  'b1111111-1111-4111-8111-aaaaaaaaaaaa:b2222222-2222-4222-8222-aaaaaaaaaaaa'),
  ARRAY['KE', 'NG']::char(2)[],
  'a collusive pair spanning two countries resolves to both — it is both officers'' problem');

INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash) VALUES
  ('b1111111-1111-4111-8111-aaaaaaaaaaaa', 'android', sha256('one-handset'::bytea)),
  ('b2222222-2222-4222-8222-aaaaaaaaaaaa', 'android', sha256('one-handset'::bytea));
SELECT is(private.fraud_subject_countries('device', encode(sha256('one-handset'::bytea), 'hex')),
  ARRAY['KE', 'NG']::char(2)[],
  'and so does the handset they shared, which is the whole reason the flag exists');
SELECT is(private.fraud_subject_countries('device', 'zzzz'), '{}'::char(2)[],
  'a fingerprint that is not hex resolves to nothing, rather than erroring inside a policy');

-- ---------------------------------------------------------------------------
-- The policy, and the queue that reads around it.
-- ---------------------------------------------------------------------------
SELECT ok(private.raise_fraud_flag('user', 'b1111111-1111-4111-8111-aaaaaaaaaaaa',
  'velocity_requests', 60::smallint) IS NOT NULL, 'a Nigerian user is flagged');
SELECT ok(private.raise_fraud_flag('user', 'b2222222-2222-4222-8222-aaaaaaaaaaaa',
  'velocity_requests', 60::smallint) IS NOT NULL, 'and a Kenyan one');
SELECT ok(private.raise_fraud_flag('device', encode(sha256('one-handset'::bytea), 'hex'),
  'device_reuse', 55::smallint) IS NOT NULL, 'and the handset they share');

SELECT pg_temp.act('b3333333-3333-4333-8333-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 2,
  'the Nigerian officer sees their own user and the shared handset');
SELECT is((SELECT count(*)::int FROM public.fraud_queue()), 2,
  'and the queue agrees with the table — a queue is a SECURITY DEFINER function, so the scope '
  'has to be stated twice or the two disagree');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 2,
  'the Kenyan officer sees their own user and the same handset');
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE subject_id = 'b1111111-1111-4111-8111-aaaaaaaaaaaa'), 0,
  'and not the Nigerian user');
RESET ROLE;

SELECT pg_temp.act('b5555555-5555-4555-8555-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 0,
  'an officer in a third country sees none of it');
SELECT is((SELECT count(*)::int FROM public.fraud_queue()), 0, 'nor in their queue');
RESET ROLE;

SELECT pg_temp.act('b6666666-6666-4666-8666-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 3,
  'a super admin carrying a scope still reads all three: the matrix gives it plain R');
RESET ROLE;

-- A subject nobody can place is left to super admin, which is the fail-closed rule everywhere.
SELECT ok(private.raise_fraud_flag('device', 'deadbeef', 'device_reuse', 55::smallint)
  IS NOT NULL, 'a flag on a fingerprint nobody has registered');
SELECT pg_temp.act('b3333333-3333-4333-8333-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags WHERE subject_id = 'deadbeef'), 0,
  'is not shown to a scoped officer');
RESET ROLE;
SELECT pg_temp.act('b6666666-6666-4666-8666-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags WHERE subject_id = 'deadbeef'), 1,
  'and is reachable, because somebody has to be able to look at it');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Moderation, which answers through its author.
-- ---------------------------------------------------------------------------
INSERT INTO public.moderation_cases (subject_kind, subject_id, author_id, action, source) VALUES
  ('request', gen_random_uuid()::text, 'b1111111-1111-4111-8111-aaaaaaaaaaaa', 'hold', 'rules'),
  ('request', gen_random_uuid()::text, 'b2222222-2222-4222-8222-aaaaaaaaaaaa', 'hold', 'rules');

SELECT is(private.moderation_subject_countries('request', gen_random_uuid()::text,
            'b1111111-1111-4111-8111-aaaaaaaaaaaa'), ARRAY['NG']::char(2)[],
  'a case answers through its author, which is cheaper than chasing a partitioned subject');

SELECT pg_temp.act('b3333333-3333-4333-8333-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 1,
  'so the Nigerian officer reviews what a Nigerian wrote');
SELECT is((SELECT count(*)::int FROM public.moderation_queue()), 1, 'and the queue matches');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-aaaaaaaaaaaa');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 1, 'the Kenyan one, the other');
RESET ROLE;

SELECT pg_temp.act('b1111111-1111-4111-8111-aaaaaaaaaaaa', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 1,
  'and an author still reads the case about their own content, which the scope must not take away');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
