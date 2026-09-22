-- Businesses, fleets, dispatch and zone rules (PRD BU-01…BU-09; ERD §3; spec phase 3).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(35);

INSERT INTO auth.users (id, phone) VALUES
  ('aaaaaaaa-1111-4111-8111-bbbbbbbbbbbb', '2348000000121'),   -- customer
  ('aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb', '2348000000122'),   -- business owner
  ('aaaaaaaa-3333-4333-8333-bbbbbbbbbbbb', '2348000000123'),   -- dispatcher
  ('aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb', '2348000000124'),   -- worker on a motorcycle
  ('aaaaaaaa-5555-4555-8555-bbbbbbbbbbbb', '2348000000125');   -- an outsider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'aaaaaaaa-1111-4111-8111-bbbbbbbbbbbb';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb',
                  'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('aaaaaaaa-3333-4333-8333-bbbbbbbbbbbb',
                  'aaaaaaaa-5555-4555-8555-bbbbbbbbbbbb');

CREATE TEMP TABLE bz (name text PRIMARY KEY, id uuid);
GRANT ALL ON bz TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- BU-01: registering the business.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO bz VALUES ('org', public.register_organization(
  'key-bz-register-000000001', 'Lekki Logistics Ltd',
  '\x0102030405'::bytea, sha256('RC123456'::bytea)));
SELECT ok((SELECT id FROM bz WHERE name = 'org') IS NOT NULL, 'an owner registers a business');
SELECT is((SELECT role FROM public.organization_members
           WHERE organization_id = (SELECT id FROM bz WHERE name = 'org')
             AND user_id = 'aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb'),
  'owner'::public.business_role, 'and is its owner from the first moment');
SELECT is((SELECT organization_id FROM public.provider_profiles
           WHERE user_id = 'aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb'),
  (SELECT id FROM bz WHERE name = 'org'), 'their provider profile belongs to it');
SELECT throws_ok(
  $$SELECT public.register_organization('key-bz-register-000000002', 'Copycat Ltd',
      '\x0908'::bytea, sha256('RC123456'::bytea))$$,
  '23505', NULL, 'one registration number cannot back two businesses in a country');
RESET ROLE;
-- Read as the test role: `org_can_bid` is internal, and `authenticated` has no execute on it.
SELECT ok(NOT (SELECT private.org_can_bid((SELECT id FROM bz WHERE name = 'org'))),
  'and it cannot bid until it is verified, which is Phase 4 work');

-- ---------------------------------------------------------------------------
-- BU-03: members, roles, and consent to join.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.invite_member('key-bz-inv-dispatch-01',
            (SELECT id FROM bz WHERE name = 'org'),
            'aaaaaaaa-3333-4333-8333-bbbbbbbbbbbb', 'dispatcher'), 'the owner invites a dispatcher');
SELECT ok(public.invite_member('key-bz-inv-worker-001',
            (SELECT id FROM bz WHERE name = 'org'),
            'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb', 'worker'), 'and a worker');
RESET ROLE;

SELECT is((SELECT private.org_role((SELECT id FROM bz WHERE name = 'org'),
             'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb')), NULL,
  'an invitation is not membership: nobody is added to a business without accepting');

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-5555-4555-8555-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.invite_member('key-bz-inv-outsider-1', %L,
             'aaaaaaaa-1111-4111-8111-bbbbbbbbbbbb', 'worker')$$,
    (SELECT id FROM bz WHERE name = 'org')),
  'P0001', 'ERR_ORG_ROLE_REQUIRED', 'an outsider cannot add people to somebody else''s business');
SELECT is((SELECT count(*)::int FROM public.organizations), 0,
  'and cannot even see that it exists');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_organization_invite('key-bz-accept-worker1',
            (SELECT id FROM bz WHERE name = 'org')),
  'worker'::public.business_role, 'the worker accepts and joins');
-- A retry after a lost response used to be told the business did not exist, because the UPDATE
-- matches on `status = 'invited'` and the first call had already changed it (audit N.1).
SELECT is(public.accept_organization_invite('key-bz-accept-worker1',
            (SELECT id FROM bz WHERE name = 'org')),
  'worker'::public.business_role, 'and the same key replays the answer rather than raising');
SELECT is((SELECT count(*)::int FROM public.organizations), 1, 'now they can see the business');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-3333-4333-8333-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_organization_invite('key-bz-accept-disp-01',
            (SELECT id FROM bz WHERE name = 'org')),
  'dispatcher'::public.business_role, 'so does the dispatcher');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- BU-08: the vehicle register.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO bz VALUES ('veh', public.register_vehicle(
  'key-bz-vehicle-0000000001', 'motorcycle', '\x1122'::bytea, sha256('LAG-123-XY'::bytea),
  (SELECT id FROM bz WHERE name = 'org'), 'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb',
  (now() + interval '90 days')::date));
SELECT ok((SELECT id FROM bz WHERE name = 'veh') IS NOT NULL, 'the owner registers a motorcycle');
SELECT throws_ok(
  format($$SELECT public.register_vehicle('key-bz-vehicle-0000000002', 'car', '\x33'::bytea,
            %L::bytea, %L)$$, sha256('LAG-123-XY'::bytea), (SELECT id FROM bz WHERE name = 'org')),
  '23505', NULL, 'and the same plate cannot be registered twice');
RESET ROLE;

-- The worker rides that motorcycle.
UPDATE public.provider_profiles SET vehicle_type = 'motorcycle'
WHERE user_id = 'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb';
UPDATE public.provider_profiles SET organization_id = (SELECT id FROM bz WHERE name = 'org')
WHERE user_id = 'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb';

-- ---------------------------------------------------------------------------
-- BU-09: the zone rule. The Lagos polygons are the client's to draw, so this is a test zone —
-- the mechanism is ours, the map is not.
-- ---------------------------------------------------------------------------
INSERT INTO public.zones (city_id, code, name, boundary, allowed_vehicle_types)
SELECT c.id, 'LOS-TEST-NOBIKE', 'Test restriction',
       ST_GeogFromText('MULTIPOLYGON(((3.40 6.40, 3.60 6.40, 3.60 6.60, 3.40 6.60, 3.40 6.40)))'),
       ARRAY['walking', 'bicycle', 'car', 'van', 'truck']::public.vehicle_type[]
FROM public.cities c WHERE c.country_code = 'NG' AND c.code = 'lagos';

SELECT ok(NOT (SELECT private.vehicle_allowed_at(
            ST_GeogFromText('POINT(3.4750 6.4459)'), 'motorcycle')),
  'a motorcycle is refused inside a zone that bans it');
SELECT ok((SELECT private.vehicle_allowed_at(
            ST_GeogFromText('POINT(3.4750 6.4459)'), 'car')),
  'a car in the same place is fine');
SELECT ok((SELECT private.vehicle_allowed_at(
            ST_GeogFromText('POINT(7.4951 9.0579)'), 'motorcycle')),
  'and outside any zone, every vehicle is allowed: an empty map bans nobody');

-- ---------------------------------------------------------------------------
-- The rule reaches the feed and matching.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO bz VALUES ('r', public.create_request(
  'key-bz-create-req-00000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM bz WHERE name = 'r'), 'key-bz-publish-00000001');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(6.4460, 3.4751);
SELECT is((SELECT count(*)::int FROM public.provider_feed(20, 20000)), 0,
  'the rider does not see work they would be turned away from');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM bz WHERE name = 'r'), 20, 20000)), 0,
  'nor is the request offered to them by matching');

UPDATE public.provider_profiles SET vehicle_type = 'car'
WHERE user_id = 'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb';
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM bz WHERE name = 'r'), 20, 20000)), 1,
  'in a car, the same person matches the same job');

-- ---------------------------------------------------------------------------
-- BU-05 and BU-06: the business bids, the dispatcher assigns.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO bz VALUES ('o', public.create_offer(
  'key-bz-offer-000000000001', (SELECT id FROM bz WHERE name = 'r'), 700000, NULL));
RESET ROLE;
SELECT is((SELECT organization_id FROM public.offer_threads
           WHERE request_id = (SELECT id FROM bz WHERE name = 'r')),
  (SELECT id FROM bz WHERE name = 'org'),
  'the offer carries the business name, not just the person who typed it');

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-bz-accept-000000001', (SELECT id FROM bz WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM bz WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is paid and assigned to the owner by default');

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-5555-4555-8555-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.dispatch_job('key-bz-dispatch-outsider1', %L,
            'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb')$$, (SELECT id FROM bz WHERE name = 'r')),
  'P0001', 'ERR_ORG_ROLE_REQUIRED', 'an outsider cannot dispatch the business''s work');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-3333-4333-8333-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.dispatch_job('key-bz-dispatch-outside2', %L,
            'aaaaaaaa-5555-4555-8555-bbbbbbbbbbbb')$$, (SELECT id FROM bz WHERE name = 'r')),
  'P0001', 'ERR_WORKER_NOT_ELIGIBLE', 'and a dispatcher cannot send someone who is not a worker');
SELECT is(public.dispatch_job('key-bz-dispatch-0000001', (SELECT id FROM bz WHERE name = 'r'),
            'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb'),
  'assigned'::public.job_status, 'the dispatcher assigns the verified worker');
RESET ROLE;
SELECT is((SELECT worker_id FROM public.jobs WHERE request_id = (SELECT id FROM bz WHERE name = 'r')),
  'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb'::uuid, 'and the job now names them');
SELECT ok((SELECT count(*) FROM public.job_events
           WHERE request_id = (SELECT id FROM bz WHERE name = 'r')
             AND reason_code = 'reassigned') >= 1, 'reassignment is logged, as BU-06 asks');

-- ---------------------------------------------------------------------------
-- BU-07: self-accept, and BU-03's rule that removal ends access at once.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.claim_job('key-bz-claim-00000000001', %L)$$,
    (SELECT id FROM bz WHERE name = 'r')),
  'P0001', 'ERR_ORG_ROLE_REQUIRED',
  'a worker cannot take a job for themselves unless the owner allowed it');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.set_member_options((SELECT id FROM bz WHERE name = 'org'),
            'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb', NULL, true),
  'the owner turns self-accept on for a trusted worker');
SELECT ok(public.remove_member((SELECT id FROM bz WHERE name = 'org'),
            'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb'), 'and later removes them');
SELECT throws_ok(
  format($$SELECT public.remove_member(%L, 'aaaaaaaa-2222-4222-8222-bbbbbbbbbbbb')$$,
    (SELECT id FROM bz WHERE name = 'org')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'an owner cannot remove themselves and leave nobody in charge');
RESET ROLE;

SELECT is((SELECT private.org_role((SELECT id FROM bz WHERE name = 'org'),
             'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb')), NULL,
  'removal takes effect at once');
SELECT ok(NOT (SELECT online FROM public.provider_profiles
               WHERE user_id = 'aaaaaaaa-4444-4444-8444-bbbbbbbbbbbb'),
  'and takes them off shift with it, rather than leaving them online for a business they left');

SELECT * FROM finish();
ROLLBACK;
