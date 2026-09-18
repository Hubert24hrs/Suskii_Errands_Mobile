-- The provider side and matching: who may go online, the movement gate on heartbeats, and the
-- feed — the only way a provider sees open work (RLS matrix §3 and §5; ADR-0009; S-06).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(39);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-111111111111', '2348000000061'),   -- customer, Lagos
  ('b2222222-2222-4222-8222-222222222222', '2348000000062'),   -- provider A, close by
  ('b3333333-3333-4333-8333-333333333333', '2348000000063'),   -- provider B, further away
  ('b4444444-4444-4444-8444-444444444444', '2348000000064'),   -- unverified provider
  ('b5555555-5555-4555-8555-555555555555', '254700000065');    -- a Kenyan provider

UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'b1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('b2222222-2222-4222-8222-222222222222',
                  'b3333333-3333-4333-8333-333333333333');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'b4444444-4444-4444-8444-444444444444';
UPDATE public.profiles SET country_code = 'KE', provider_verification = 'verified'
WHERE user_id = 'b5555555-5555-4555-8555-555555555555';

-- ---------------------------------------------------------------------------
-- Going online.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b4444444-4444-4444-8444-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_online(true)$$,
  'P0001', 'ERR_PROVIDER_NOT_VERIFIED', 'an unverified provider cannot go online');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.set_online(true), true, 'a verified provider goes online');
SELECT ok((SELECT online_since IS NOT NULL FROM public.provider_profiles
           WHERE user_id = 'b2222222-2222-4222-8222-222222222222'),
  'and the shift is timestamped');
SELECT is((SELECT count(*)::int FROM public.provider_profiles), 1,
  'a provider reads their own profile and nobody else''s');
SELECT throws_ok($$SELECT count(*) FROM public.provider_live_location$$,
  '42501', NULL, 'no client role may read live positions, not even their own');
RESET ROLE;

-- A suspension stops everything, including going online.
UPDATE public.provider_profiles SET suspended_until = now() + interval '1 day',
  suspension_reason_key = 'documents_expired'
WHERE user_id = 'b3333333-3333-4333-8333-333333333333';
SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.set_online(true)$$,
  'P0001', 'ERR_PROVIDER_SUSPENDED', 'a suspended provider is told so, not called unverified');
RESET ROLE;
UPDATE public.provider_profiles SET suspended_until = NULL, suspension_reason_key = NULL
WHERE user_id = 'b3333333-3333-4333-8333-333333333333';

-- ---------------------------------------------------------------------------
-- Services and service areas.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.update_provider_services(ARRAY['errands_delivery', 'shopping']), 2,
  'a provider registers the categories they work in');
SELECT is(public.update_provider_services(ARRAY['errands_delivery']), 1,
  'the call replaces the set rather than adding to it');
SELECT throws_ok($$SELECT public.update_provider_services(ARRAY['no_such_category'])$$,
  'P0001', 'ERR_CATEGORY_NOT_FOUND', 'an unknown category is refused');
SELECT is(public.update_provider_service_areas(ARRAY['lagos']), 1,
  'and the cities they serve');
SELECT throws_ok($$SELECT public.update_provider_service_areas(ARRAY['nairobi'])$$,
  'P0001', 'ERR_CITY_NOT_FOUND',
  'a city outside the provider''s own country is not a service area');

-- ---------------------------------------------------------------------------
-- Heartbeats: movement-gated (ADR-0009, S-06 finding 1).
-- ---------------------------------------------------------------------------
SELECT is(public.heartbeat(6.4460, 3.4751), true, 'the first fix is written');
SELECT is(public.heartbeat(6.44601, 3.47511), false,
  'a provider who has not moved does not write again');
SELECT is(public.heartbeat(6.4600, 3.4900), true, 'real movement writes a new position');
SELECT is((SELECT count(*)::int FROM public.provider_live_location l
           WHERE l.provider_id = 'b2222222-2222-4222-8222-222222222222'), 1,
  'one row per provider, updated in place');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b4444444-4444-4444-8444-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.heartbeat(6.4460, 3.4751)$$,
  'P0001', 'ERR_PROVIDER_NOT_VERIFIED', 'an unverified provider cannot report a position');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The feed.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE pids (name text PRIMARY KEY, id uuid);
GRANT ALL ON pids TO authenticated, service_role;
-- Lekki, a few hundred metres from provider A's first fix.
INSERT INTO pids VALUES ('near', public.create_request(
  'key-p-create-req-00000000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM pids WHERE name = 'near'), 'key-p-publish-00000000001');
-- Abuja: the same country, far outside any sane radius.
INSERT INTO pids VALUES ('far', public.create_request(
  'key-p-create-req-00000000002', 'errands_delivery', 'Collect a parcel in Abuja',
  'Wuse market', 'standard', false, NULL, NULL, 9.0579, 7.4951));
SELECT public.publish_request((SELECT id FROM pids WHERE name = 'far'), 'key-p-publish-00000000002');
-- A category provider A has not registered.
INSERT INTO pids VALUES ('other', public.create_request(
  'key-p-create-req-00000000003', 'cleaning_laundry', 'Clean a two-bedroom flat',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM pids WHERE name = 'other'), 'key-p-publish-00000000003');
RESET ROLE;

-- Put provider A back beside the request.
SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.heartbeat(6.4550, 3.4850), true, 'the provider reports where they are now');

SELECT is((SELECT count(*)::int FROM public.provider_feed()), 1,
  'the feed carries the nearby request in a registered category, and nothing else');
SELECT is((SELECT request_id FROM public.provider_feed()),
  (SELECT id FROM pids WHERE name = 'near'), 'and it is the right one');
SELECT ok((SELECT distance_m FROM public.provider_feed()) BETWEEN 0 AND 2000,
  'the card carries a distance, not the customer''s coordinates');
SELECT is((SELECT already_offered FROM public.provider_feed()), false,
  'nothing offered on it yet');
SELECT is((SELECT count(*)::int FROM public.provider_feed(20, 100)), 0,
  'a tighter radius excludes it, so the radius is real');

-- Offering flips the flag, and the feed still shows the request rather than hiding it.
INSERT INTO pids VALUES ('offer', public.create_offer(
  'key-p-offer-a-00000000000001', (SELECT id FROM pids WHERE name = 'near'), 700000, NULL));
SELECT is((SELECT already_offered FROM public.provider_feed()), true,
  'once they have offered, the card says so');
RESET ROLE;

-- A provider in another country sees none of it, however close the map says they are.
SELECT set_config('request.jwt.claims',
  '{"sub": "b5555555-5555-4555-8555-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.update_provider_services(ARRAY['errands_delivery']), 1,
  'the Kenyan provider registers the same category');
SELECT is(public.set_online(true), true, 'and goes online');
SELECT is(public.heartbeat(6.4550, 3.4850), true, 'even reporting a position in Lagos');
SELECT is((SELECT count(*)::int FROM public.provider_feed()), 0,
  'a provider only ever sees work in their own country');
RESET ROLE;

-- A provider with neither a fresh fix nor a service area has nothing to measure from.
SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.update_provider_services(ARRAY['errands_delivery']), 1,
  'provider B registers the category');
SELECT throws_ok($$SELECT count(*) FROM public.provider_feed()$$,
  'P0001', 'ERR_LOCATION_UNAVAILABLE',
  'without a position or a service area, the feed says so rather than showing the country');
SELECT is(public.update_provider_service_areas(ARRAY['lagos']), 1, 'they add Lagos');
SELECT is((SELECT count(*)::int FROM public.provider_feed(20, 50000)), 1,
  'and the city centre stands in for a live position');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Matching: who gets told about a new request.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_online(true);
SELECT public.heartbeat(6.4700, 3.5000);   -- a few kilometres out
RESET ROLE;

-- Provider A already has a thread on 'near', so the fan-out skips them: being notified about a
-- request you have already bid on is noise.
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM pids WHERE name = 'near'), 20, 20000)), 1,
  'matching skips a provider who already has a thread on the request');
SELECT is((SELECT provider_id FROM private.match_providers(
             (SELECT id FROM pids WHERE name = 'near'), 20, 20000)),
  'b3333333-3333-4333-8333-333333333333'::uuid, 'and returns the one who does not');
SELECT ok((SELECT score_milli FROM private.match_providers(
             (SELECT id FROM pids WHERE name = 'near'), 20, 20000)) > 0,
  'the score is a number the fan-out can rank by');

SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.set_online(false), false, 'a provider goes off shift');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.provider_live_location l
           WHERE l.provider_id = 'b3333333-3333-4333-8333-333333333333'), 0,
  'going offline drops the last position, so a stale point is never matched');
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM pids WHERE name = 'near'), 20, 20000)), 0,
  'and an offline provider is not matched at all');

-- ---------------------------------------------------------------------------
-- Suspension reaches the negotiation functions too.
-- ---------------------------------------------------------------------------
UPDATE public.provider_profiles SET suspended_until = now() + interval '1 day'
WHERE user_id = 'b2222222-2222-4222-8222-222222222222';
SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.create_offer('key-p-offer-a-00000000000002', %L, 650000)$$,
    (SELECT id FROM pids WHERE name = 'other')),
  'P0001', 'ERR_PROVIDER_SUSPENDED', 'a suspended provider cannot offer');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.accept_offer('key-p-accept-c-0000000001', %L)$$,
    (SELECT id FROM pids WHERE name = 'offer')),
  'P0001', 'ERR_PROVIDER_SUSPENDED',
  'nor win one that was live before the suspension');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
