-- Offers and negotiation: alternation, round limits, the competitive invariant and the S-10
-- acceptance transaction (RLS matrix §6; the offer and negotiation state machine).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(46);

INSERT INTO auth.users (id, phone) VALUES
  ('a1111111-1111-4111-8111-111111111111', '2348000000051'),   -- customer
  ('a2222222-2222-4222-8222-222222222222', '2348000000052'),   -- provider A
  ('a3333333-3333-4333-8333-333333333333', '2348000000053'),   -- provider B
  ('a4444444-4444-4444-8444-444444444444', '2348000000054');   -- an unverified provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'a1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('a2222222-2222-4222-8222-222222222222',
                  'a3333333-3333-4333-8333-333333333333');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'a4444444-4444-4444-8444-444444444444';

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
GRANT ALL ON ids TO authenticated, service_role;

-- A published request to negotiate on.
SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('r1', public.create_request(
  'key-o-create-req-00000000001', 'errands_delivery', 'Collect a parcel from Yaba market',
  'Yaba market stall 14'));
SELECT public.publish_request((SELECT id FROM ids WHERE name = 'r1'), 'key-o-publish-req-000000001');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A provider offers.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o1', public.create_offer(
  'key-o-offer-a-0000000000001', (SELECT id FROM ids WHERE name = 'r1'), 650000,
  'I dey Yaba now, I fit carry am.'));

SELECT is((SELECT status FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1')),
  'pending'::public.offer_status, 'a new offer is live and awaiting the customer');
SELECT is((SELECT round FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1')),
  1::smallint, 'the first offer in a thread is round 1');
SELECT is((SELECT currency FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1')),
  'NGN'::char(3), 'the amount is in the request currency, never one the client chose');
SELECT is(
  public.create_offer('key-o-offer-a-0000000000001', (SELECT id FROM ids WHERE name = 'r1'),
    650000, 'I dey Yaba now, I fit carry am.'),
  (SELECT id FROM ids WHERE name = 'o1'), 'a repeated key replays the first offer');
SELECT throws_ok(
  format($$SELECT public.create_offer('key-o-offer-a-0000000000002', %L, 600000)$$,
    (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_OFFER_ALREADY_PENDING',
  'a provider with a live offer counters or withdraws, rather than stacking offers');
SELECT throws_ok(
  format($$SELECT public.create_offer('key-o-offer-a-0000000000003', %L, 60000000)$$,
    (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_PRICE_OUT_OF_RANGE', 'an amount above the country hard maximum is refused');
SELECT is((SELECT count(*)::int FROM public.offers), 1, 'the provider sees their own offer');
-- Read as the test role: a provider cannot select `requests` at all, which the next assertion
-- would otherwise trip over rather than test.
RESET ROLE;
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM ids WHERE name = 'r1')),
  'offers_received'::public.job_status, 'the first offer moves the request out of published');

-- A rival offers. Neither provider may see the other's amount (the competitive invariant).
SELECT set_config('request.jwt.claims',
  '{"sub": "a3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o2', public.create_offer(
  'key-o-offer-b-0000000000001', (SELECT id FROM ids WHERE name = 'r1'), 700000, NULL));
SELECT is((SELECT count(*)::int FROM public.offers), 1,
  'a provider sees only their own thread, never the whole board');
SELECT is((SELECT count(*)::int FROM public.offers o
           WHERE o.provider_id = 'a2222222-2222-4222-8222-222222222222'), 0,
  'a provider cannot read a rival offer at all, so cannot read its amount');
SELECT is((SELECT count(*)::int FROM public.offer_threads), 1,
  'and sees only their own thread on the request');
RESET ROLE;

-- An unverified provider cannot offer at all.
SELECT set_config('request.jwt.claims',
  '{"sub": "a4444444-4444-4444-8444-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.create_offer('key-o-offer-x-0000000000001', %L, 500000)$$,
    (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_PROVIDER_NOT_VERIFIED', 'an unverified provider cannot offer');
SELECT is((SELECT count(*)::int FROM public.offers), 0,
  'and sees nothing of the offers on a request that is not theirs');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The customer's side: the whole board, and the alternation rule.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.offers), 2, 'the customer sees every offer on theirs');
SELECT throws_ok(
  format($$SELECT public.create_offer('key-o-offer-self-000000001', %L, 400000)$$,
    (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_SELF_DEALING_BLOCKED', 'nobody may bid on their own request');
INSERT INTO ids VALUES ('o1c', public.counter_offer(
  'key-o-counter-c-000000001', (SELECT id FROM ids WHERE name = 'o1'), 600000, 'Make e be 6k.'));
SELECT is((SELECT author_side FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1c')),
  'customer'::public.user_mode, 'a counter is authored by the side that sent it');
SELECT is((SELECT round FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1c')),
  2::smallint, 'and counts as the next round in the thread');
SELECT is((SELECT status FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o1')),
  'countered'::public.offer_status, 'the offer it answers is superseded, not rewritten');
SELECT is((SELECT supersedes_offer_id FROM public.offers
           WHERE id = (SELECT id FROM ids WHERE name = 'o1c')),
  (SELECT id FROM ids WHERE name = 'o1'), 'the history keeps the link between the two');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM ids WHERE name = 'r1')),
  'negotiating'::public.job_status, 'a counter moves the request to negotiating');
SELECT throws_ok(
  format($$SELECT public.counter_offer('key-o-counter-c-000000002', %L, 550000)$$,
    (SELECT id FROM ids WHERE name = 'o1c')),
  'P0001', 'ERR_OFFER_NOT_YOUR_TURN', 'the same side may not counter twice in a row');
SELECT throws_ok(
  format($$SELECT public.accept_offer('key-o-accept-self-00000001', %L)$$,
    (SELECT id FROM ids WHERE name = 'o1c')),
  'P0001', 'ERR_OFFER_NOT_YOUR_TURN', 'nor accept its own offer');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Acceptance: the S-10 transaction.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_offer('key-o-accept-a-00000000001', (SELECT id FROM ids WHERE name = 'o1c')),
  'agreed'::public.job_status, 'the counterparty accepts, and the request is agreed');
SELECT is(public.accept_offer('key-o-accept-a-00000000001', (SELECT id FROM ids WHERE name = 'o1c')),
  'agreed'::public.job_status, 'a replayed acceptance returns the first result');
RESET ROLE;

SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM ids WHERE name = 'r1')),
  'agreed'::public.job_status, 'the request is agreed exactly once');
SELECT is((SELECT status FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o2')),
  'expired'::public.offer_status, 'a losing offer expires in the same transaction');
SELECT is((SELECT status_reason FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o2')),
  'sibling_accepted', 'and says why, so the provider can be told');
SELECT is((SELECT count(*)::int FROM public.offers o
           WHERE o.request_id = (SELECT id FROM ids WHERE name = 'r1') AND o.status = 'accepted'),
  1, 'exactly one accepted offer per request, ever');
SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE aggregate_id = (SELECT id::text FROM ids WHERE name = 'r1')
             AND event_type = 'offer.accepted'),
  1, 'exactly one acceptance event, however many times the call is retried');
SELECT is((SELECT count(*)::int FROM public.offer_threads t
           WHERE t.request_id = (SELECT id FROM ids WHERE name = 'r1') AND t.status = 'open'),
  0, 'every thread on the request closes when one of them wins');

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.accept_offer('key-o-accept-late-0000001', %L)$$,
    (SELECT id FROM ids WHERE name = 'o2')),
  'P0001', 'ERR_OFFER_NOT_ACTIVE', 'the losing provider''s offer cannot be accepted afterwards');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM public.offers$$,
  '42501', NULL, 'anon has no access to offers at all');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Rounds and TTL, on a second request.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('r2', public.create_request(
  'key-o-create-req-00000000002', 'errands_delivery', 'Take documents to Ikoyi', 'Home'));
SELECT public.publish_request((SELECT id FROM ids WHERE name = 'r2'), 'key-o-publish-req-000000002');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "a2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o3', public.create_offer(
  'key-o-offer-a-0000000000004', (SELECT id FROM ids WHERE name = 'r2'), 500000, NULL));
RESET ROLE;

-- The round limit comes from the category (5 by default); take the thread to it directly rather
-- than acting out five rounds.
UPDATE public.offer_threads t SET round_count = 5
WHERE t.request_id = (SELECT id FROM ids WHERE name = 'r2');

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.counter_offer('key-o-counter-c-000000003', %L, 450000)$$,
    (SELECT id FROM ids WHERE name = 'o3')),
  'P0001', 'ERR_OFFER_ROUNDS_EXHAUSTED',
  'on the round limit only accept, decline and withdraw remain');
RESET ROLE;

UPDATE public.offers o SET expires_at = now() - interval '1 minute'
WHERE o.id = (SELECT id FROM ids WHERE name = 'o3');

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.accept_offer('key-o-accept-expired-00001', %L)$$,
    (SELECT id FROM ids WHERE name = 'o3')),
  'P0001', 'ERR_OFFER_EXPIRED', 'an offer past its TTL cannot be accepted, even before the job runs');
RESET ROLE;

SELECT is(private.expire_offers(), 1, 'the expiry job closes an offer nobody answered');
SELECT is((SELECT status FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o3')),
  'expired'::public.offer_status, 'and marks it expired');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM ids WHERE name = 'r2')),
  'published'::public.job_status,
  'a request left with no live offer goes back into the feed, not stuck looking busy');
SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE aggregate_id = (SELECT id::text FROM ids WHERE name = 'r2')
             AND event_type = 'offer.expired'),
  1, 'the author is told, once');

-- ---------------------------------------------------------------------------
-- Withdrawal, decline, and a cancelled request taking its offers with it.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('r3', public.create_request(
  'key-o-create-req-00000000003', 'errands_delivery', 'Buy a cake in Lekki', 'Admiralty Way'));
SELECT public.publish_request((SELECT id FROM ids WHERE name = 'r3'), 'key-o-publish-req-000000003');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "a2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o4', public.create_offer(
  'key-o-offer-a-0000000000005', (SELECT id FROM ids WHERE name = 'r3'), 900000, NULL));
SELECT is(public.withdraw_offer('key-o-withdraw-a-000000001', (SELECT id FROM ids WHERE name = 'o4')),
  'withdrawn'::public.offer_status, 'an author may pull their own offer');
RESET ROLE;
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM ids WHERE name = 'r3')),
  'published'::public.job_status, 'and the request is open again');

-- The thread stays open, so the same provider may come back at a different price.
SELECT set_config('request.jwt.claims',
  '{"sub": "a2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o5', public.create_offer(
  'key-o-offer-a-0000000000006', (SELECT id FROM ids WHERE name = 'r3'), 800000, NULL));
SELECT is((SELECT round FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o5')),
  2::smallint, 'a re-offer continues the same thread, and counts as a round');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  public.decline_offer('key-o-decline-c-000000001', (SELECT id FROM ids WHERE name = 'o5'),
    'too_expensive'),
  'declined'::public.offer_status, 'the customer declines an offer');
RESET ROLE;
SELECT is((SELECT status FROM public.offer_threads t
           WHERE t.request_id = (SELECT id FROM ids WHERE name = 'r3')),
  'closed'::public.offer_thread_status, 'declining closes that thread');

SELECT set_config('request.jwt.claims',
  '{"sub": "a3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o6', public.create_offer(
  'key-o-offer-b-0000000000002', (SELECT id FROM ids WHERE name = 'r3'), 850000, NULL));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "a1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.cancel_request((SELECT id FROM ids WHERE name = 'r3'), 'key-o-cancel-c-0000000001'),
  'cancelled'::public.job_status, 'the customer cancels a request under negotiation');
RESET ROLE;
SELECT is((SELECT status FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o6')),
  'expired'::public.offer_status, 'a cancelled request takes its live offers with it');
SELECT is((SELECT status_reason FROM public.offers WHERE id = (SELECT id FROM ids WHERE name = 'o6')),
  'request_cancelled', 'and the provider is told why');

SELECT * FROM finish();
ROLLBACK;
