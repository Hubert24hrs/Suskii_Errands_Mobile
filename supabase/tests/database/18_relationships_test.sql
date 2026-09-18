-- Favourites, blocks and reports, and the one rule the spec states plainly: a blocked pair is
-- never matched again (ERD §2 and §5; spec phase 3).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(23);

INSERT INTO auth.users (id, phone) VALUES
  ('11111111-1111-4111-8111-aaaaaaaaaaaa', '2348000000111'),   -- customer
  ('22222222-2222-4222-8222-aaaaaaaaaaaa', '2348000000112'),   -- provider, later blocked
  ('33333333-3333-4333-8333-aaaaaaaaaaaa', '2348000000113');   -- another provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = '11111111-1111-4111-8111-aaaaaaaaaaaa';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('22222222-2222-4222-8222-aaaaaaaaaaaa',
                  '33333333-3333-4333-8333-aaaaaaaaaaaa');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('22222222-2222-4222-8222-aaaaaaaaaaaa'),
  ('33333333-3333-4333-8333-aaaaaaaaaaaa');

CREATE TEMP TABLE rel (name text PRIMARY KEY, id uuid);
GRANT ALL ON rel TO authenticated, service_role;

-- Both providers are online beside the same request.
SELECT set_config('request.jwt.claims',
  '{"sub": "22222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(6.4460, 3.4751);
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "33333333-3333-4333-8333-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(6.4461, 3.4752);
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "11111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rel VALUES ('r', public.create_request(
  'key-rel-create-req-000000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM rel WHERE name = 'r'), 'key-rel-publish-000000001');

-- ---------------------------------------------------------------------------
-- Favourites.
-- ---------------------------------------------------------------------------
SELECT ok(public.favorite_provider('22222222-2222-4222-8222-aaaaaaaaaaaa'),
  'a customer keeps a provider they liked');
SELECT is((SELECT count(*)::int FROM public.favorites), 1, 'and sees their own list');
SELECT throws_ok(
  $$SELECT public.favorite_provider('11111111-1111-4111-8111-aaaaaaaaaaaa')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'nobody favourites themselves');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "22222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.favorites), 0,
  'a provider is not told who favourited them: it is a list, not a score');
RESET ROLE;

-- The favourite counts for something, but not for much.
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM rel WHERE name = 'r'), 20, 20000)), 2,
  'both providers match the request');
SELECT is((SELECT provider_id FROM private.match_providers(
             (SELECT id FROM rel WHERE name = 'r'), 20, 20000) LIMIT 1),
  '22222222-2222-4222-8222-aaaaaaaaaaaa'::uuid,
  'and the favoured one is ranked first, the two being otherwise alike');

-- ---------------------------------------------------------------------------
-- Blocks.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "11111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.block_user('22222222-2222-4222-8222-aaaaaaaaaaaa', 'made_me_uncomfortable'),
  'the customer blocks that provider');
SELECT is((SELECT count(*)::int FROM public.favorites), 0,
  'which drops the favourite: blocking someone you favour is a contradiction');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM rel WHERE name = 'r'), 20, 20000)), 1,
  'a blocked pair is never matched again — the spec rule, in the matching function');
SELECT is((SELECT provider_id FROM private.match_providers(
             (SELECT id FROM rel WHERE name = 'r'), 20, 20000)),
  '33333333-3333-4333-8333-aaaaaaaaaaaa'::uuid, 'the other provider still matches');

SELECT set_config('request.jwt.claims',
  '{"sub": "22222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.provider_feed(20, 20000)), 0,
  'and the request is simply not in their feed');
SELECT is((SELECT count(*)::int FROM public.blocks), 0,
  'the blocked provider is never shown that they were blocked');
SELECT throws_ok(
  format($$SELECT public.create_offer('key-rel-offer-blocked-0001', %L, 500000)$$,
    (SELECT id FROM rel WHERE name = 'r')),
  'P0001', 'ERR_BLOCKED',
  'and an offer is refused at the table, not merely hidden from the feed');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "33333333-3333-4333-8333-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.provider_feed(20, 20000)), 1,
  'the provider who was not blocked still sees the work');
RESET ROLE;

-- The block works the other way round too: whoever pressed it, neither side is matched.
SELECT set_config('request.jwt.claims',
  '{"sub": "11111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.unblock_user('22222222-2222-4222-8222-aaaaaaaaaaaa'), 'the customer relents');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "22222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.block_user('11111111-1111-4111-8111-aaaaaaaaaaaa'),
  'but now the provider blocks the customer');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.match_providers(
             (SELECT id FROM rel WHERE name = 'r'), 20, 20000)), 1,
  'a block in either direction has the same effect');

-- ---------------------------------------------------------------------------
-- Reports.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "11111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rel VALUES ('rep', public.report_user('key-rel-report-000000001',
  'harassment', '22222222-2222-4222-8222-aaaaaaaaaaaa',
  (SELECT id FROM rel WHERE name = 'r'), 'Kept calling after I said no.'));
SELECT ok((SELECT id FROM rel WHERE name = 'rep') IS NOT NULL, 'a customer reports someone');
SELECT is((SELECT status FROM public.reports WHERE id = (SELECT id FROM rel WHERE name = 'rep')),
  'open'::public.report_status, 'and it lands in a human queue, judged by nobody here');
SELECT is(
  public.report_user('key-rel-report-000000001', 'harassment',
    '22222222-2222-4222-8222-aaaaaaaaaaaa', (SELECT id FROM rel WHERE name = 'r'),
    'Kept calling after I said no.'),
  (SELECT id FROM rel WHERE name = 'rep'), 'a repeated key replays rather than reporting twice');
SELECT is((SELECT count(*)::int FROM public.reports), 1, 'the reporter sees their own report');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "22222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.reports), 0,
  'and the person reported is never shown it, which is the point of a report button');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM public.reports$$,
  '42501', NULL, 'anon reaches none of it');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
