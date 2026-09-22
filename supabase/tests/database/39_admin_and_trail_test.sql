-- The trip trail and the admin verbs for people and businesses (RLS matrix §1 and §9; spec
-- phase 8, "Admin functions for users, businesses, verification…").
--
-- `location_samples` is the most sensitive table in the schema, so most of what is asserted here
-- is what it refuses: a provider between jobs is not recorded at all, a customer sees the route
-- only after the job is done, and support — who can read a ticketed job's chat — cannot read
-- where anybody went.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(41);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-666666666666', '2348000000701'),   -- customer
  ('f2222222-2222-4222-8222-666666666666', '2348000000702'),   -- provider
  ('f3333333-3333-4333-8333-666666666666', '2348000000703'),   -- support agent
  ('f4444444-4444-4444-8444-666666666666', '2348000000704'),   -- dispute officer
  ('f5555555-5555-4555-8555-666666666666', '2348000000705'),   -- verification officer
  ('f6666666-6666-4666-8666-666666666666', '2348000000706'),   -- super admin
  ('f7777777-7777-4777-8777-666666666666', '2348000000707');   -- business owner, also an officer
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified',
       display_name = 'Adaeze Okonkwo'
WHERE user_id = 'f1111111-1111-4111-8111-666666666666';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'f2222222-2222-4222-8222-666666666666';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('f3333333-3333-4333-8333-666666666666',
                  'f4444444-4444-4444-8444-666666666666',
                  'f5555555-5555-4555-8555-666666666666',
                  'f6666666-6666-4666-8666-666666666666',
                  'f7777777-7777-4777-8777-666666666666');
INSERT INTO public.provider_profiles (user_id) VALUES ('f2222222-2222-4222-8222-666666666666');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('f3333333-3333-4333-8333-666666666666', ARRAY['support_agent']::public.admin_role[]),
  ('f4444444-4444-4444-8444-666666666666', ARRAY['dispute_officer']::public.admin_role[]),
  ('f5555555-5555-4555-8555-666666666666', ARRAY['verification_officer']::public.admin_role[]),
  ('f6666666-6666-4666-8666-666666666666', ARRAY['super_admin']::public.admin_role[]),
  ('f7777777-7777-4777-8777-666666666666', ARRAY['verification_officer']::public.admin_role[]);

CREATE TEMP TABLE ad (name text PRIMARY KEY, val text);
GRANT ALL ON ad TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- A provider who is not on a job leaves no trail at all.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.set_online(true), 'the provider goes online');
SELECT ok(public.heartbeat(6.5100, 3.3700), 'and moves');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.location_samples), 0,
  'nothing is recorded: a provider between jobs is not tracked, which is the whole difference '
  'between a trip trail and surveillance');

-- ---------------------------------------------------------------------------
-- A job, and the trail it does leave.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f1111111-1111-4111-8111-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO ad VALUES ('req', public.create_request('key-ad-req-000000001',
  'personal_assistance', 'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL,
  6.5095, 3.3711)::text);
SELECT ok(public.publish_request((SELECT val FROM ad WHERE name = 'req')::uuid,
  'key-ad-pub-000000001') IS NOT NULL, 'a request is published');
RESET ROLE;

SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO ad VALUES ('offer', public.create_offer('key-ad-off-000000001',
  (SELECT val FROM ad WHERE name = 'req')::uuid, 10000, NULL)::text);
RESET ROLE;
SELECT pg_temp.act('f1111111-1111-4111-8111-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.accept_offer('key-ad-acc-000000001',
  (SELECT val FROM ad WHERE name = 'offer')::uuid) IS NOT NULL, 'and accepted');
RESET ROLE;
UPDATE public.requests SET status = 'en_route'
WHERE id = (SELECT val FROM ad WHERE name = 'req')::uuid;

SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.heartbeat(6.5200, 3.3800), 'the provider sets off');
SELECT ok(public.heartbeat(6.5300, 3.3900), 'and keeps going');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.location_samples
           WHERE request_id = (SELECT val FROM ad WHERE name = 'req')::uuid), 2,
  'now the trail is recorded, against the job and only the job');
SELECT is((SELECT count(*)::int FROM public.location_samples WHERE request_id IS NULL), 0,
  'and a sample always names the job it belongs to');

-- The movement gate applies to the trail too: S-06 measured write rate as the limit.
SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is(public.heartbeat(6.5300, 3.3900), false, 'a provider who has not moved writes nothing');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.location_samples), 2,
  'so the trail does not grow on every tick');

-- ---------------------------------------------------------------------------
-- Who may read it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f1111111-1111-4111-8111-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.location_samples), 0,
  'the customer sees nothing while the job is live: the map gets one point from realtime, '
  'and the route is history');
SELECT throws_ok(
  format($$SELECT * FROM public.job_trail(%L)$$, (SELECT val FROM ad WHERE name = 'req')),
  '42501', NULL, 'and cannot ask for it either');
RESET ROLE;

SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.location_samples), 2,
  'the provider reads their own movement whenever they like — it is theirs');
RESET ROLE;

SELECT pg_temp.act('f3333333-3333-4333-8333-666666666666');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.location_samples), 0,
  'support reads no trail at all: the matrix gives them no cell here, ticket or no ticket');
RESET ROLE;

SELECT pg_temp.act('f4444444-4444-4444-8444-666666666666');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.location_samples), 0,
  'and a dispute officer reads none before there is a case');
RESET ROLE;

-- The job finishes, and the customer gets their replay.
UPDATE public.requests SET status = 'confirmed'
WHERE id = (SELECT val FROM ad WHERE name = 'req')::uuid;
SELECT pg_temp.act('f1111111-1111-4111-8111-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_trail(
             (SELECT val FROM ad WHERE name = 'req')::uuid)), 2,
  'afterwards the customer can replay the trip');
RESET ROLE;

-- A dispute opens the evidence, and reading it leaves a record.
UPDATE public.requests SET status = 'disputed'
WHERE id = (SELECT val FROM ad WHERE name = 'req')::uuid;
INSERT INTO public.disputes (request_id, opened_by, reason_code, description, frozen_from,
                             sla_due_at)
VALUES ((SELECT val FROM ad WHERE name = 'req')::uuid,
        'f1111111-1111-4111-8111-666666666666', 'not_delivered',
        'The parcel never arrived.', 'confirmed', now() + interval '48 hours');
SELECT pg_temp.act('f4444444-4444-4444-8444-666666666666');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_trail(
             (SELECT val FROM ad WHERE name = 'req')::uuid)), 2,
  'the officer reads the trail the case is about');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'location.trail_read'), 1,
  'and reading somebody''s movements is on the record, as reading their documents is');

-- ---------------------------------------------------------------------------
-- Business verification — a column that has existed since Phase 3 with nothing behind it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f7777777-7777-4777-8777-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO ad VALUES ('org', public.register_organization('key-ad-org-000000001',
  'Okonkwo Logistics Ltd', '\xdeadbeef'::bytea, sha256('RC123456'::bytea))::text);
RESET ROLE;
SELECT is((SELECT verification_status FROM public.organizations
           WHERE id = (SELECT val FROM ad WHERE name = 'org')::uuid),
  'unverified'::public.verification_status,
  'a new business starts unverified, as it always did');

SELECT pg_temp.act('f5555555-5555-4555-8555-666666666666');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.business_verification_queue()), 1,
  'and now it is in a queue somebody can work');
SELECT throws_ok(
  $$SELECT public.decide_business_verification('key-ad-dec-bad-0000001',
      '00000000-0000-0000-0000-000000000000', true)$$,
  'P0001', 'ERR_ORGANIZATION_NOT_FOUND', 'a business that does not exist cannot be verified');
SELECT is(public.decide_business_verification('key-ad-dec-000000001',
            (SELECT val FROM ad WHERE name = 'org')::uuid, true),
  'verified'::public.verification_status, 'the officer verifies it');
RESET ROLE;
SELECT isnt((SELECT verified_at FROM public.organizations
             WHERE id = (SELECT val FROM ad WHERE name = 'org')::uuid), NULL,
  'with a date and a reviewer against it');
SELECT is((SELECT count(*)::int FROM audit.log
           WHERE action = 'admin.decide_business_verification'), 1,
  'and an audit row, because a verification is a decision');

-- The owner is also an officer, which is exactly the case the rule exists for.
SELECT pg_temp.act('f7777777-7777-4777-8777-666666666666');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.decide_business_verification('key-ad-dec-self-000001', %L, true)$$,
         (SELECT val FROM ad WHERE name = 'org')),
  '42501', NULL, 'nobody verifies a business they are part of, however senior they are');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Suspending a business stops its workers taking work.
-- ---------------------------------------------------------------------------
INSERT INTO public.organization_members (organization_id, user_id, role, status, joined_at)
VALUES ((SELECT val FROM ad WHERE name = 'org')::uuid,
        'f2222222-2222-4222-8222-666666666666', 'worker', 'active', now());
SELECT is(private.is_active_provider('f2222222-2222-4222-8222-666666666666'), true,
  'the worker is eligible while their business is in good standing');

SELECT pg_temp.act('f6666666-6666-4666-8666-666666666666');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.suspend_organization('key-ad-susp-bad-000001', %L, 'fraud', NULL)$$,
         (SELECT val FROM ad WHERE name = 'org')),
  '22023', NULL, 'a suspension needs an end date: closing a company for ever is not one call');
SELECT isnt(public.suspend_organization('key-ad-susp-000000001',
  (SELECT val FROM ad WHERE name = 'org')::uuid, 'under_investigation',
  now() + interval '30 days'), NULL, 'the business is suspended, bounded and reasoned');
RESET ROLE;
SELECT is(private.is_active_provider('f2222222-2222-4222-8222-666666666666'), false,
  'and nobody it sends can take a job — enforced where eligibility is decided, not in each '
  'caller that might remember');
SELECT is((SELECT online FROM public.provider_profiles
           WHERE user_id = 'f2222222-2222-4222-8222-666666666666'), false,
  'its workers go offline with it, rather than being shown jobs they cannot take');

SELECT pg_temp.act('f6666666-6666-4666-8666-666666666666');
SET LOCAL ROLE authenticated;
SELECT ok(public.reinstate_organization('key-ad-rein-000000001',
  (SELECT val FROM ad WHERE name = 'org')::uuid, 'cleared'), 'and it can be reinstated');
RESET ROLE;
SELECT is(private.is_active_provider('f2222222-2222-4222-8222-666666666666'), true,
  'which gives the worker their eligibility back');

-- ---------------------------------------------------------------------------
-- Finding a person, and reading their standing.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f3333333-3333-4333-8333-666666666666');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_user_search('ad')$$,
  '22023', NULL, 'a two-letter search is a browse, and browsing is what the scopes exist to stop');
SELECT is((SELECT count(*)::int FROM public.admin_user_search('0701')), 1,
  'the last digits of a number confirm an account somebody already has');
SELECT is((SELECT count(*)::int FROM public.admin_user_search('Adaeze')), 1,
  'and a name prefix finds them');
SELECT is((SELECT count(*)::int FROM public.admin_user_search('Okonkwo')), 0,
  'but not a substring: a search that matches the middle of every name is a directory dump');
SELECT is((SELECT display_name FROM public.admin_user_summary(
             'f1111111-1111-4111-8111-666666666666')), 'Adaeze Okonkwo',
  'and their standing can be read');
SELECT is((SELECT requests FROM public.admin_user_summary(
             'f1111111-1111-4111-8111-666666666666')), 1,
  'as counts rather than contents: three open disputes is standing, what is in them is not');
RESET ROLE;
SELECT ok((SELECT count(*) FROM audit.log WHERE action IN ('admin.user_search',
                                                           'admin.read_user')) >= 2,
  'every lookup is on the record, which is the control — not that staff cannot look');

SELECT pg_temp.act('f2222222-2222-4222-8222-666666666666', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_user_search('0701')$$,
  '42501', NULL, 'and somebody with no admin role finds nobody');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
