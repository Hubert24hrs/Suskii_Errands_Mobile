-- The three gaps the matrix-coverage check found (`AUDIT-2026-09-22d.md`, W.1 to W.3).
--
-- W.1 and W.2 are U.1 all over again on two tables the second pass missed, so the assertions are
-- the same shape: a scoped admin sees their own country and not another, and super admin sees
-- everything. W.3 is a capability that was readable by the wrong person.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(21);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-111111111111', '2348000003001'),   -- NG customer
  ('e2222222-2222-4222-8222-222222222222', '2547000003002'),   -- KE customer
  ('e3333333-3333-4333-8333-333333333333', '2348000003003'),   -- NG provider
  ('e4444444-4444-4444-8444-444444444444', '2348000003004'),   -- support, scoped NG
  ('e5555555-5555-4555-8555-555555555555', '2547000003005'),   -- finance, scoped KE
  ('e6666666-6666-4666-8666-666666666666', '2348000003006');   -- super admin

UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'KE' WHERE user_id = 'e2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'e3333333-3333-4333-8333-333333333333';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('e4444444-4444-4444-8444-444444444444', 'e6666666-6666-4666-8666-666666666666');
UPDATE public.profiles SET country_code = 'KE' WHERE user_id = 'e5555555-5555-4555-8555-555555555555';
INSERT INTO public.provider_profiles (user_id) VALUES ('e3333333-3333-4333-8333-333333333333');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('e4444444-4444-4444-8444-444444444444', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('e5555555-5555-4555-8555-555555555555', ARRAY['finance_officer']::public.admin_role[],
   ARRAY['KE']::char(2)[]),
  ('e6666666-6666-4666-8666-666666666666', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- W.1 -- profiles. Was `is_any_admin()`: every role, every country.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('e4444444-4444-4444-8444-444444444444', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 1,
  'a support agent scoped to NG reads a Nigerian profile');
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 0,
  'and does not read a Kenyan one, which is what is_any_admin() used to allow');
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e4444444-4444-4444-8444-444444444444'), 1,
  'and still reads their own profile');
RESET ROLE;

SELECT pg_temp.act('e5555555-5555-4555-8555-555555555555', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 1,
  'a finance officer scoped to KE reads a Kenyan profile: the matrix gives finance R:scope too');
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 0,
  'and not a Nigerian one');
RESET ROLE;

SELECT pg_temp.act('e6666666-6666-4666-8666-666666666666', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id IN ('e1111111-1111-4111-8111-111111111111',
                             'e2222222-2222-4222-8222-222222222222')), 2,
  'a super admin carrying a country scope still reads both: the matrix gives it plain R');
RESET ROLE;

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 0,
  'an ordinary user reads no stranger''s profile, as before');
SELECT is((SELECT count(*)::int FROM public.profiles
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 1, 'only their own');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- W.2 -- approvals. Was `is_any_admin()`, so a support agent read every withdrawal approval in
-- every country.
-- ---------------------------------------------------------------------------
INSERT INTO public.approvals (subject_kind, subject_id, action, requested_by, level)
VALUES ('config_change', gen_random_uuid()::text, 'apply',
        'e1111111-1111-4111-8111-111111111111', 1);

SELECT ok(private.approval_subject_country('withdrawal', 'not-a-uuid') IS NULL,
  'a subject id that is not a uuid resolves to NULL rather than raising inside a policy');
SELECT ok(private.approval_subject_country('promo_budget', gen_random_uuid()::text) IS NULL,
  'and so does a subject kind nothing writes yet');

SELECT pg_temp.act('e4444444-4444-4444-8444-444444444444', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.approvals), 0,
  'a support agent reads no approvals at all now: the matrix gives them to approvers');
RESET ROLE;

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.approvals), 1,
  'the requester still reads their own request');
RESET ROLE;

SELECT pg_temp.act('e6666666-6666-4666-8666-666666666666', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.approvals), 1,
  'and a super admin reads a global config change, which resolves to no country');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- W.3 -- payments.checkout_url is a capability, and the provider on the job could read it.
-- ---------------------------------------------------------------------------
-- These are the Postgres built-ins, not pgTAP assertions, so they are wrapped in ok().
SELECT ok(NOT has_column_privilege('authenticated', 'public.payments', 'checkout_url', 'SELECT'),
  'authenticated cannot select payments.checkout_url: it is a capability, not a reference');
SELECT ok(has_column_privilege('authenticated', 'public.payments', 'status', 'SELECT'),
  'but status is still readable');
SELECT ok(has_column_privilege('authenticated', 'public.payments', 'amount_minor', 'SELECT'),
  'and so is the amount');
SELECT ok(has_column_privilege('authenticated', 'public.payments', 'job_amount_minor', 'SELECT'),
  'and the breakdown a provider needs to understand their own earnings');

SELECT ok(has_function_privilege('authenticated', 'public.get_payment_checkout(uuid)', 'EXECUTE'),
  'the payer reaches the URL through a function that checks who is asking');
SELECT ok(NOT has_function_privilege('anon', 'public.get_payment_checkout(uuid)', 'EXECUTE'),
  'and anon does not');

-- The function answers only the payer. There is no payment here, so the claim under test is that
-- a non-payer gets nothing rather than somebody else's row.
SELECT pg_temp.act('e3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.get_payment_checkout(gen_random_uuid())), 0,
  'a provider asking for a checkout URL gets no row');
RESET ROLE;

-- `RESET ROLE` does not clear the JWT claim, so without this the "unauthenticated" caller is
-- still whoever acted last.
SELECT set_config('request.jwt.claims', NULL, true);
SELECT throws_ok(
  $$SELECT * FROM public.get_payment_checkout('00000000-0000-4000-8000-000000000000')$$,
  '28000', NULL, 'and a caller with no identity is refused outright');

SELECT * FROM finish();
ROLLBACK;
