-- The nearest providers first (ADR-0022): matching orders by distance band before score, the
-- search widens when nobody is close, offers say how far their provider is, and the customer sees
-- how many providers are near and roughly where, never a provider's position. Nigeria's service
-- areas are its 36 states and the FCT.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(16);

SELECT is((SELECT count(*)::int FROM public.cities WHERE country_code = 'NG'), 37,
  'Nigeria has 37 service areas: 36 states and the FCT');
SELECT ok(EXISTS (SELECT 1 FROM public.cities WHERE country_code = 'NG' AND code = 'kano')
          AND EXISTS (SELECT 1 FROM public.cities WHERE country_code = 'NG' AND code = 'akwa-ibom'),
  'including Kano and Akwa Ibom');

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-606060606060', '2348000006001'),   -- customer
  ('d2222222-2222-4222-8222-606060606060', '2348000006002'),   -- 230 m away, new
  ('d3333333-3333-4333-8333-606060606060', '2348000006003'),   -- 1.2 km away, five stars
  ('d4444444-4444-4444-8444-606060606060', '2348000006004'),   -- near, same cell as the first
  ('d5555555-5555-4555-8555-606060606060', '2348000006005');   -- near, same cell as the first
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'd1111111-1111-4111-8111-606060606060';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('d2222222-2222-4222-8222-606060606060', 'd3333333-3333-4333-8333-606060606060',
                  'd4444444-4444-4444-8444-606060606060', 'd5555555-5555-4555-8555-606060606060');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('d2222222-2222-4222-8222-606060606060'), ('d3333333-3333-4333-8333-606060606060'),
  ('d4444444-4444-4444-8444-606060606060'), ('d5555555-5555-4555-8555-606060606060');
UPDATE public.provider_profiles
SET rating_avg_milli = 5000, rating_count = 50, completion_rate_bps = 10000, response_time_p50_s = 30
WHERE user_id = 'd3333333-3333-4333-8333-606060606060';
UPDATE public.provider_profiles SET completion_rate_bps = 6000
WHERE user_id = 'd2222222-2222-4222-8222-606060606060';

CREATE TEMP TABLE nr (name text PRIMARY KEY, id uuid);
GRANT ALL ON nr TO authenticated, service_role;
CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;
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
SELECT pg_temp.online('d2222222-2222-4222-8222-606060606060', 6.4480, 3.4750);
SELECT pg_temp.online('d3333333-3333-4333-8333-606060606060', 6.4570, 3.4750);
SELECT pg_temp.online('d4444444-4444-4444-8444-606060606060', 6.4485, 3.4755);
SELECT pg_temp.online('d5555555-5555-4555-8555-606060606060', 6.4490, 3.4760);

SELECT pg_temp.act('d1111111-1111-4111-8111-606060606060');
SET LOCAL ROLE authenticated;
INSERT INTO nr VALUES ('near', public.create_request(
  'key-nr-create-near-0000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
RESET ROLE;

-- Matching: nearest first, the score only orders providers who are about as near.
SELECT ok((SELECT distance_m < 500 FROM private.match_providers((SELECT id FROM nr WHERE name = 'near'))
           LIMIT 1), 'the first provider matched is within 500 m');
SELECT is((SELECT count(*)::int FROM (
             SELECT provider_id, row_number() OVER () AS rn
             FROM private.match_providers((SELECT id FROM nr WHERE name = 'near'))) m
           WHERE m.provider_id = 'd3333333-3333-4333-8333-606060606060' AND m.rn = 4), 1,
  'the five-star provider 1.2 km away comes after all three who are round the corner');
SELECT ok((SELECT score_milli FROM private.match_providers((SELECT id FROM nr WHERE name = 'near'))
           WHERE provider_id = 'd3333333-3333-4333-8333-606060606060')
          > (SELECT score_milli FROM private.match_providers((SELECT id FROM nr WHERE name = 'near'))
             WHERE provider_id = 'd2222222-2222-4222-8222-606060606060'),
  'although their score is higher: distance decides first');

-- Nobody within 5 km: the search widens instead of announcing to nobody.
SELECT pg_temp.act('d1111111-1111-4111-8111-606060606060');
SET LOCAL ROLE authenticated;
INSERT INTO nr VALUES ('far', public.create_request(
  'key-nr-create-far-00000001', 'errands_delivery', 'Collect a parcel in Ikota',
  'Ikota Shopping Complex', 'standard', false, NULL, NULL, 6.4459, 3.5600));
SELECT public.publish_request((SELECT id FROM nr WHERE name = 'far'), 'key-nr-publish-far-0000001');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.match_providers((SELECT id FROM nr WHERE name = 'far'))),
  0, 'nobody is within 5 km of the second request');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE kind = 'request_matched'
             AND params ->> 'request_id' = (SELECT id FROM nr WHERE name = 'far')::text), 4,
  'so publishing told the four providers about 9 km away, inside the 15 km rung');
SELECT ok((SELECT min((params ->> 'distance_m')::int) FROM public.notifications
           WHERE kind = 'request_matched'
             AND params ->> 'request_id' = (SELECT id FROM nr WHERE name = 'far')::text) > 5000,
  'each told how far it is');

-- An offer says how far its provider is from the pickup.
SELECT pg_temp.act('d1111111-1111-4111-8111-606060606060');
SET LOCAL ROLE authenticated;
SELECT public.publish_request((SELECT id FROM nr WHERE name = 'near'), 'key-nr-publish-near-000001');
RESET ROLE;
SELECT pg_temp.act('d3333333-3333-4333-8333-606060606060');
SET LOCAL ROLE authenticated;
SELECT public.create_offer('key-nr-offer-d3-000000001', (SELECT id FROM nr WHERE name = 'near'),
  500000, NULL);
RESET ROLE;
SELECT pg_temp.act('d1111111-1111-4111-8111-606060606060');
SET LOCAL ROLE authenticated;
SELECT is((SELECT distance_km FROM public.rank_offers((SELECT id FROM nr WHERE name = 'near'))),
  1.0::numeric, 'the offer shows 1.0 km: rounded to the half kilometre');
RESET ROLE;

-- Nearby providers: a count and blurred cells, never a position.
SELECT ok(NOT has_function_privilege('anon',
  'public.nearby_providers(double precision, double precision, text, integer)', 'EXECUTE'),
  'nobody signed out can ask');
SELECT pg_temp.act('d1111111-1111-4111-8111-606060606060');
SET LOCAL ROLE authenticated;
SELECT is((SELECT total FROM public.nearby_providers(6.4459, 3.4750, 'errands_delivery')), 4,
  'four providers offering the service are within 5 km');
SELECT is((SELECT jsonb_array_length(areas) FROM public.nearby_providers(6.4459, 3.4750)), 1,
  'one cell is shown: the three providers round the corner; the one alone is not');
SELECT is((SELECT (areas -> 0 ->> 'providers')::int FROM public.nearby_providers(6.4459, 3.4750)), 3,
  'and it says three');
SELECT is((SELECT round((areas -> 0 ->> 'lat')::numeric, 3) || ',' || round((areas -> 0 ->> 'lng')::numeric, 3)
           FROM public.nearby_providers(6.4459, 3.4750)), '6.445,3.475',
  'at the centre of its grid cell, which is where none of them is');
SELECT is((SELECT total FROM public.nearby_providers(6.4459, 3.4750, 'plumbing')), 0,
  'nobody offers plumbing here');
RESET ROLE;

INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('d1111111-1111-4111-8111-606060606060', 'd4444444-4444-4444-8444-606060606060');
SET LOCAL ROLE authenticated;
SELECT is((SELECT jsonb_array_length(areas) FROM public.nearby_providers(6.4459, 3.4750)), 0,
  'a blocked provider is not counted, and two in a cell is below the floor');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
