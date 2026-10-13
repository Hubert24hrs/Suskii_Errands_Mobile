-- The business console and the provider tools (audit 2026-10-13, Z.9 and Z.15): an owner invites
-- by phone, sees who works for the business, gives a vehicle to a worker and dispatches a funded
-- job; a provider keeps a week of availability, an earnings goal and their own insights.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(49);

INSERT INTO auth.users (id, phone) VALUES
  ('c1111111-1111-4111-8111-545454545454', '2348000005401'),   -- customer
  ('c2222222-2222-4222-8222-545454545454', '2348000005402'),   -- owner (a business provider)
  ('c3333333-3333-4333-8333-545454545454', '2348000005403'),   -- worker
  ('c4444444-4444-4444-8444-545454545454', '2348000005404'),   -- dispatcher
  ('c5555555-5555-4555-8555-545454545454', '2348000005405');   -- a stranger provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified',
       display_name = 'Ada Customer'
WHERE user_id = 'c1111111-1111-4111-8111-545454545454';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
       customer_verification = 'verified'
WHERE user_id IN ('c2222222-2222-4222-8222-545454545454', 'c3333333-3333-4333-8333-545454545454',
                  'c4444444-4444-4444-8444-545454545454', 'c5555555-5555-4555-8555-545454545454');
UPDATE public.profiles SET display_name = 'Olu Owner'
WHERE user_id = 'c2222222-2222-4222-8222-545454545454';
UPDATE public.profiles SET display_name = 'Wale Worker'
WHERE user_id = 'c3333333-3333-4333-8333-545454545454';
UPDATE public.profiles SET display_name = 'Dami Dispatcher'
WHERE user_id = 'c4444444-4444-4444-8444-545454545454';
INSERT INTO public.provider_profiles (user_id, kind) VALUES
  ('c2222222-2222-4222-8222-545454545454', 'business'),
  ('c3333333-3333-4333-8333-545454545454', 'individual'),
  ('c4444444-4444-4444-8444-545454545454', 'individual'),
  ('c5555555-5555-4555-8555-545454545454', 'individual');

CREATE TEMP TABLE bc (name text PRIMARY KEY, val text);
GRANT ALL ON bc TO authenticated, service_role;
-- What the owner should see for a member who has not accepted yet.
INSERT INTO bc VALUES ('masked', private.mask_phone('+2348000005403'));

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

-- The owner registers the business.
SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
INSERT INTO bc VALUES ('org', public.register_organization('key-bc-org-000000001',
  'Olu Logistics Ltd', 'RC123456')::text);
SELECT is((SELECT name || ':' || my_role::text || ':' || member_count::text
           FROM public.my_organization()), 'Olu Logistics Ltd:owner:1',
  'the owner sees the business, their role and one member: themselves');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Inviting by phone.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5555555-5555-4555-8555-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.invite_member_by_phone('key-bc-inv-x-0000001', %L, '+2348000005403',
           'worker')$$, (SELECT val FROM bc WHERE name = 'org')),
  'P0001', 'ERR_ORG_ROLE_REQUIRED', 'a stranger cannot invite into somebody else''s business');
SELECT is((SELECT count(*)::int FROM public.my_organization()), 0,
  'and has no business to show');
SELECT throws_ok($$SELECT * FROM public.my_organization_members()$$, 'P0001', 'ERR_ORG_NOT_FOUND',
  'nor a member list');
SELECT throws_ok(
  $$SELECT public.register_organization('key-bc-org-dup-000001', 'Copycat Ltd', 'rc 123456')$$,
  'P0001', 'ERR_ORGANIZATION_ALREADY_REGISTERED',
  'a registration number already on the platform is named, however it is typed');
RESET ROLE;

SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.invite_member_by_phone('key-bc-inv-bad-000001', %L, '0803 not a phone',
           'worker')$$, (SELECT val FROM bc WHERE name = 'org')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a number is E.164');
SELECT throws_ok(
  format($$SELECT public.invite_member_by_phone('key-bc-inv-own-000001', %L, '+2348000005403',
           'owner')$$, (SELECT val FROM bc WHERE name = 'org')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a business has one owner');
SELECT throws_ok(
  format($$SELECT public.invite_member_by_phone('key-bc-inv-none-00001', %L, '+2348000009999',
           'worker')$$, (SELECT val FROM bc WHERE name = 'org')),
  'P0001', 'ERR_PROFILE_NOT_FOUND', 'the person signs up with the number first');
SELECT is(public.invite_member_by_phone('key-bc-inv-wrk-000001',
  (SELECT val FROM bc WHERE name = 'org')::uuid, '+234 800 000 5403', 'worker')::text,
  'c3333333-3333-4333-8333-545454545454', 'the owner invites a worker by the number they have');
SELECT is(public.invite_member_by_phone('key-bc-inv-wrk-000001',
  (SELECT val FROM bc WHERE name = 'org')::uuid, '+234 800 000 5403', 'worker')::text,
  'c3333333-3333-4333-8333-545454545454', 'and a retry is the same invitation');
SELECT ok(public.invite_member_by_phone('key-bc-inv-dsp-000001',
  (SELECT val FROM bc WHERE name = 'org')::uuid, '+2348000005404', 'dispatcher') IS NOT NULL,
  'and a dispatcher');
SELECT is((SELECT display_name FROM public.my_organization_members()
           WHERE user_id = 'c3333333-3333-4333-8333-545454545454'),
  (SELECT val FROM bc WHERE name = 'masked'),
  'before accepting, the worker shows as the masked number, not their name');
RESET ROLE;

SELECT pg_temp.act('c3333333-3333-4333-8333-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.organizations), 0,
  'an invitee cannot read the business through the table');
SELECT is((SELECT name || ':' || role::text FROM public.my_organization_invitations()),
  'Olu Logistics Ltd:worker', 'but sees who invited them and as what');
SELECT is(public.accept_organization_invite('key-bc-acc-wrk-000001',
  (SELECT val FROM bc WHERE name = 'org')::uuid), 'worker'::public.business_role,
  'the worker accepts');
SELECT is((SELECT count(*)::int FROM public.my_organization_invitations()), 0,
  'and the invitation is gone once accepted');
RESET ROLE;
SELECT pg_temp.act('c4444444-4444-4444-8444-545454545454');
SET LOCAL ROLE authenticated;
SELECT is(public.accept_organization_invite('key-bc-acc-dsp-000001',
  (SELECT val FROM bc WHERE name = 'org')::uuid), 'dispatcher'::public.business_role,
  'and so does the dispatcher');
RESET ROLE;

SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT display_name FROM public.my_organization_members()
           WHERE user_id = 'c3333333-3333-4333-8333-545454545454'), 'Wale Worker',
  'once a member, the owner sees their name: profiles alone never showed it');
SELECT is((SELECT count(*)::int FROM public.my_organization_members()), 3,
  'three people in the business');
SELECT ok((SELECT bool_and(earnings_minor IS NOT NULL) FROM public.my_organization_members()),
  'the owner sees earnings to date');
RESET ROLE;
SELECT pg_temp.act('c4444444-4444-4444-8444-545454545454');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT bool_and(earnings_minor IS NULL) FROM public.my_organization_members()),
  'a dispatcher sees the people but not what they earn');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Vehicles.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
INSERT INTO bc VALUES ('vehicle', public.register_vehicle('key-bc-veh-000000001', 'motorcycle',
  'LND-123-AA', (SELECT val FROM bc WHERE name = 'org')::uuid)::text);
SELECT throws_ok(
  format($$SELECT public.assign_vehicle('key-bc-veh-x-00000001', %L,
           'c5555555-5555-4555-8555-545454545454')$$, (SELECT val FROM bc WHERE name = 'vehicle')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a vehicle goes to a worker of the same business');
SELECT throws_ok(
  format($$SELECT public.assign_vehicle('key-bc-veh-d-00000001', %L,
           'c4444444-4444-4444-8444-545454545454')$$, (SELECT val FROM bc WHERE name = 'vehicle')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and to a worker, not a dispatcher');
SELECT ok(public.assign_vehicle('key-bc-veh-a-00000001',
  (SELECT val FROM bc WHERE name = 'vehicle')::uuid, 'c3333333-3333-4333-8333-545454545454')
  IS NOT NULL, 'the owner gives the motorcycle to the worker');
RESET ROLE;
SELECT is((SELECT assigned_worker_id::text FROM public.vehicles
           WHERE id = (SELECT val FROM bc WHERE name = 'vehicle')::uuid),
  'c3333333-3333-4333-8333-545454545454', 'and it is theirs');
SELECT pg_temp.act('c3333333-3333-4333-8333-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.assign_vehicle('key-bc-veh-w-00000001', %L, NULL)$$,
    (SELECT val FROM bc WHERE name = 'vehicle')),
  'P0001', 'ERR_ORG_ROLE_REQUIRED', 'a worker cannot take a vehicle off themselves');
RESET ROLE;
SELECT pg_temp.act('c4444444-4444-4444-8444-545454545454');
SET LOCAL ROLE authenticated;
SELECT ok(public.assign_vehicle('key-bc-veh-n-00000001',
  (SELECT val FROM bc WHERE name = 'vehicle')::uuid, NULL) IS NOT NULL,
  'a dispatcher can take it back');
RESET ROLE;
SELECT ok((SELECT assigned_worker_id IS NULL FROM public.vehicles
           WHERE id = (SELECT val FROM bc WHERE name = 'vehicle')::uuid), 'unassigned');

-- ---------------------------------------------------------------------------
-- A funded job the business accepted, waiting to be dispatched.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c1111111-1111-4111-8111-545454545454');
SET LOCAL ROLE authenticated;
INSERT INTO bc VALUES ('req', public.create_request('key-bc-req-000000001', 'personal_assistance',
  'Deliver a parcel', 'Yaba', 'standard', false, NULL, 'Blue gate', 6.5095, 3.3711)::text);
SELECT ok(public.publish_request((SELECT val FROM bc WHERE name = 'req')::uuid,
  'key-bc-pub-000000001') IS NOT NULL, 'the customer publishes');
RESET ROLE;
SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
INSERT INTO bc VALUES ('offer', public.create_offer('key-bc-off-000000001',
  (SELECT val FROM bc WHERE name = 'req')::uuid, 10000, NULL)::text);
RESET ROLE;
SELECT pg_temp.act('c1111111-1111-4111-8111-545454545454');
SET LOCAL ROLE authenticated;
SELECT ok(public.accept_offer('key-bc-acc-000000001', (SELECT val FROM bc WHERE name = 'offer')::uuid)
  IS NOT NULL, 'and accepts the business''s offer');
INSERT INTO bc SELECT 'payment', payment_id::text
  FROM public.start_payment('key-bc-pay-000000001', (SELECT val FROM bc WHERE name = 'req')::uuid);
RESET ROLE;
SELECT private.record_gateway_checkout((SELECT val FROM bc WHERE name = 'payment')::uuid,
  'flutterwave', 'FLW-BC-00000001', NULL);
SELECT private.confirm_payment('flutterwave', 'FLW-BC-00000001', 10000, 290);

SELECT pg_temp.act('c4444444-4444-4444-8444-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.org_assignable_jobs()), 1,
  'the dispatcher sees the funded job the business accepted');
SELECT is((SELECT r ->> 'id' FROM public.org_assignable_jobs() r),
  (SELECT val FROM bc WHERE name = 'req'), 'as the request row the apps map');
SELECT is((SELECT (r -> 'jobs' ->> 'agreed_amount_minor')::bigint FROM public.org_assignable_jobs() r),
  10000::bigint, 'with the agreed price');
SELECT ok((SELECT NOT (r ? 'pickup_landmark_note') FROM public.org_assignable_jobs() r),
  'and without the landmark note, which the worker gets on assignment');
RESET ROLE;
SELECT pg_temp.act('c3333333-3333-4333-8333-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.org_assignable_jobs()$$, 'P0001', 'ERR_ORG_ROLE_REQUIRED',
  'a worker does not dispatch');
RESET ROLE;
SELECT pg_temp.act('c4444444-4444-4444-8444-545454545454');
SET LOCAL ROLE authenticated;
SELECT ok(public.dispatch_job('key-bc-dsp-000000001', (SELECT val FROM bc WHERE name = 'req')::uuid,
  'c3333333-3333-4333-8333-545454545454') IS NOT NULL, 'the dispatcher sends the worker');
SELECT is((SELECT count(*)::int FROM public.org_assignable_jobs()), 0,
  'and the job leaves the list');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Availability, goals, insights.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c3333333-3333-4333-8333-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.set_availability('key-bc-av-bad-0000001',
      '[{"weekday": 1, "start_minutes": 1020, "end_minutes": 540}]')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a window starts before it ends');
SELECT is(public.set_availability('key-bc-av-000000001',
  '[{"weekday": 1, "start_minutes": 540, "end_minutes": 1020}]'), 1, 'Monday nine to five');
SELECT is(public.set_availability('key-bc-av-000000002',
  '[{"weekday": 1, "start_minutes": 480, "end_minutes": 720},
    {"weekday": 6, "start_minutes": 600, "end_minutes": 1440}]'), 2,
  'saving again replaces the week rather than adding to it');
SELECT is((SELECT string_agg(weekday || ' ' || start_time || '-' || end_time, ', '
                             ORDER BY weekday) FROM public.availability_schedules),
  '1 08:00:00-12:00:00, 6 10:00:00-23:59:59', 'the worker reads their own week');
RESET ROLE;
SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.availability_schedules
           WHERE provider_id = 'c3333333-3333-4333-8333-545454545454'), 2,
  'the owner reads a worker''s week (RLS matrix §3, R:org)');
RESET ROLE;
SELECT pg_temp.act('c5555555-5555-4555-8555-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.availability_schedules), 0,
  'a stranger does not');
RESET ROLE;

SELECT pg_temp.act('c1111111-1111-4111-8111-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_earnings_goal('key-bc-goal-c-000001', 50000, 'weekly')$$,
  'P0001', 'ERR_PROVIDER_NOT_FOUND', 'a customer has no earnings goal');
RESET ROLE;
SELECT pg_temp.act('c3333333-3333-4333-8333-545454545454');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_earnings_goal('key-bc-goal-x-000001', 50000, 'daily')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a goal is weekly or monthly');
SELECT is(public.set_earnings_goal('key-bc-goal-000000001', 5000000, 'weekly'), 5000000::bigint,
  'the worker sets a weekly goal');
SELECT is((SELECT target_minor::text || ' ' || currency || ' ' || period || ' '
                  || progress_minor::text FROM public.my_earnings_goal()),
  '5000000 NGN weekly 0', 'in naira, with nothing earned yet this week');
RESET ROLE;

SELECT pg_temp.act('c2222222-2222-4222-8222-545454545454');
SET LOCAL ROLE authenticated;
SELECT is((SELECT acceptance_rate FROM public.my_provider_insights()), 1.0000::numeric,
  'the owner made one offer and it was accepted');
SELECT is((SELECT period_days FROM public.my_provider_insights(7)), 7, 'over the window asked for');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
