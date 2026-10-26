-- The nearest-provider query and matching agree with private.is_active_provider and
-- private.is_blocked_pair, which they now write out as joins instead of calling per row.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

INSERT INTO auth.users (id, phone) VALUES
  ('e6000000-0000-4000-8000-000000000001', '2348000006601'),   -- customer
  ('e6000000-0000-4000-8000-000000000002', '2348000006602'),   -- active
  ('e6000000-0000-4000-8000-000000000003', '2348000006603'),   -- suspended
  ('e6000000-0000-4000-8000-000000000004', '2348000006604'),   -- not verified
  ('e6000000-0000-4000-8000-000000000005', '2348000006605'),   -- works for a suspended business
  ('e6000000-0000-4000-8000-000000000006', '2348000006606'),   -- the customer blocked them
  ('e6000000-0000-4000-8000-000000000007', '2348000006607'),   -- they blocked the customer
  ('e6000000-0000-4000-8000-000000000008', '2348000006608'),   -- a car, where the zone allows motorcycles
  ('e6000000-0000-4000-8000-000000000009', '2348000006609');   -- a motorcycle there: allowed
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e6000000-0000-4000-8000-000000000001';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id::text LIKE 'e6000000-0000-4000-8000-00000000000%'
  AND user_id <> 'e6000000-0000-4000-8000-000000000001';
INSERT INTO public.provider_profiles (user_id, vehicle_type)
SELECT user_id, CASE user_id
  WHEN 'e6000000-0000-4000-8000-000000000008' THEN 'car'::public.vehicle_type
  WHEN 'e6000000-0000-4000-8000-000000000009' THEN 'motorcycle'::public.vehicle_type END
FROM public.profiles
WHERE user_id::text LIKE 'e6000000-0000-4000-8000-00000000000%'
  AND user_id <> 'e6000000-0000-4000-8000-000000000001';

CREATE TEMP TABLE ms (name text PRIMARY KEY, id uuid);
GRANT ALL ON ms TO authenticated, service_role;
CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;
-- Everyone goes online while still active, the way they would have been before anything happened.
CREATE FUNCTION pg_temp.online(p_user text, p_lat float8, p_lng float8) RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.act(p_user);
  SET LOCAL ROLE authenticated;
  PERFORM public.update_provider_services(ARRAY['errands_delivery']);
  PERFORM public.set_online(true);
  PERFORM public.heartbeat(p_lat, p_lng);
  RESET ROLE;
END $fn$;
SELECT pg_temp.online(u::text, 6.4462 + n * 0.0002, 3.4752)
FROM (SELECT user_id AS u, row_number() OVER (ORDER BY user_id) AS n FROM public.provider_profiles
      WHERE user_id::text LIKE 'e6000000-0000-4000-8000-00000000000%') p;

-- Then each one's reason not to be found.
UPDATE public.profiles SET provider_verification = 'unverified'
WHERE user_id = 'e6000000-0000-4000-8000-000000000004';
UPDATE public.provider_profiles SET suspended_until = now() + interval '7 days'
WHERE user_id = 'e6000000-0000-4000-8000-000000000003';
INSERT INTO public.organizations (id, legal_name, country_code, registration_number_ciphertext,
                                  registration_blind_index, created_by, suspended_until)
VALUES ('e6000000-0000-4000-8000-0000000000aa', 'Suspended Couriers Ltd', 'NG', '\x01', '\x66aa',
        'e6000000-0000-4000-8000-000000000005', now() + interval '7 days');
INSERT INTO public.organization_members (organization_id, user_id, role, status, joined_at)
VALUES ('e6000000-0000-4000-8000-0000000000aa', 'e6000000-0000-4000-8000-000000000005', 'worker', 'active', now());
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES
  ('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000006'),
  ('e6000000-0000-4000-8000-000000000007', 'e6000000-0000-4000-8000-000000000001');
INSERT INTO public.zones (city_id, code, name, boundary, allowed_vehicle_types)
SELECT c.id, 'TEST-66', 'Motorcycles only',
       extensions.ST_Multi(extensions.ST_Buffer(
         extensions.ST_SetSRID(extensions.ST_MakePoint(3.4750, 6.4459), 4326)::extensions.geography, 2000)::extensions.geometry
       )::extensions.geography,
       ARRAY['motorcycle']::public.vehicle_type[]
FROM public.cities c WHERE c.country_code = 'NG' AND c.code = 'lagos';

-- The rule, from the functions that define it.
CREATE TEMP TABLE expected AS
SELECT pp.user_id FROM public.provider_profiles pp
WHERE pp.user_id::text LIKE 'e6000000-0000-4000-8000-00000000000%'
  AND private.is_active_provider(pp.user_id)
  AND NOT private.is_blocked_pair('e6000000-0000-4000-8000-000000000001', pp.user_id);
GRANT SELECT ON expected TO authenticated;
SELECT is((SELECT count(*)::int FROM expected), 3,
  'three of eight pass is_active_provider and is_blocked_pair: the active one, the car and the motorcycle');
SELECT ok(NOT EXISTS (SELECT 1 FROM expected WHERE user_id IN (
            'e6000000-0000-4000-8000-000000000003', 'e6000000-0000-4000-8000-000000000004',
            'e6000000-0000-4000-8000-000000000005', 'e6000000-0000-4000-8000-000000000006',
            'e6000000-0000-4000-8000-000000000007')),
  'none of the five with a reason is among them');

SELECT pg_temp.act('e6000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT total FROM public.nearby_providers(6.4459, 3.4750, 'errands_delivery')),
  (SELECT count(*)::int FROM expected),
  'nearby_providers counts exactly the providers the two rules allow');
INSERT INTO ms VALUES ('r', public.create_request(
  'key-ms-create-000000000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
RESET ROLE;

CREATE TEMP TABLE matched AS
SELECT m.provider_id FROM private.match_providers((SELECT id FROM ms WHERE name = 'r')) m;
SELECT ok(EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000002'),
  'the active provider is matched');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000003'),
  'a suspended provider is not');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000004'),
  'nor one no longer verified');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000005'),
  'nor a worker whose business is suspended, which matching used to miss');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched WHERE provider_id IN (
            'e6000000-0000-4000-8000-000000000006', 'e6000000-0000-4000-8000-000000000007')),
  'nor anyone blocked, in either direction');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000008'),
  'nor a car inside a motorcycles-only zone');
SELECT ok(EXISTS (SELECT 1 FROM matched WHERE provider_id = 'e6000000-0000-4000-8000-000000000009'),
  'while a motorcycle there is');
SELECT ok(NOT EXISTS (SELECT 1 FROM matched m WHERE NOT private.is_active_provider(m.provider_id)),
  'everyone matched is an active provider by the definition');
SELECT is((SELECT count(*)::int FROM matched), 2,
  'two matched: the active provider and the motorcycle');

SELECT * FROM finish();
ROLLBACK;
