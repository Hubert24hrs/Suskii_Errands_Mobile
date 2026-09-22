-- The Participant column of the RLS matrix, section 5 (`AUDIT-2026-09-22c.md`, V.1).
--
-- The claim under test is not "a provider can read requests" -- that would be the market, and
-- the whole point of `provider_feed` is that no provider enumerates it. It is that **the
-- provider working a funded job reads that job's request, and nobody else's, and not a moment
-- before the money is held**.
--
-- So the deny half matters more than the allow half here, and three different providers exist
-- below for it: one assigned, one who only bid, and one whose offer was accepted but whose
-- customer never paid.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(30);

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-111111111111', '2348000002001'),   -- customer
  ('d2222222-2222-4222-8222-222222222222', '2348000002002'),   -- provider, assigned
  ('d3333333-3333-4333-8333-333333333333', '2348000002003'),   -- provider, bid only
  ('d4444444-4444-4444-8444-444444444444', '2348000002004'),   -- provider, accepted, unpaid
  ('d5555555-5555-4555-8555-555555555555', '2348000002005'),   -- a stranger
  ('d6666666-6666-4666-8666-666666666666', '2348000002006'),   -- support, scoped NG
  ('d7777777-7777-4777-8777-777777777777', '2547000002007'),   -- support, scoped KE
  ('d8888888-8888-4888-8888-888888888888', '2348000002008');   -- super admin

UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('d2222222-2222-4222-8222-222222222222',
                  'd3333333-3333-4333-8333-333333333333',
                  'd4444444-4444-4444-8444-444444444444');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('d5555555-5555-4555-8555-555555555555',
                  'd6666666-6666-4666-8666-666666666666',
                  'd8888888-8888-4888-8888-888888888888');
UPDATE public.profiles SET country_code = 'KE'
WHERE user_id = 'd7777777-7777-4777-8777-777777777777';
INSERT INTO public.provider_profiles (user_id) VALUES
  ('d2222222-2222-4222-8222-222222222222'),
  ('d3333333-3333-4333-8333-333333333333'),
  ('d4444444-4444-4444-8444-444444444444');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('d6666666-6666-4666-8666-666666666666', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('d7777777-7777-4777-8777-777777777777', ARRAY['support_agent']::public.admin_role[],
   ARRAY['KE']::char(2)[]),
  ('d8888888-8888-4888-8888-888888888888', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE TEMP TABLE vids (name text PRIMARY KEY, id uuid);
GRANT ALL ON vids TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- r1 goes all the way to assigned. r2 stops at agreed, because nobody paid.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO vids VALUES ('r1', public.create_request(
  'key-v-create-r1-000000000001', 'errands_delivery', 'Take a parcel to Ikoyi',
  '12 Admiralty Way', 'standard', false, NULL, 'Blue gate, ask for Tunde',
  6.4459, 3.4750, '4 Awolowo Road, Flat 3B', 'Ring twice', 6.4531, 3.4356,
  p_media_paths := ARRAY['d1111111-1111-4111-8111-111111111111/parcel.jpg']));
SELECT public.publish_request((SELECT id FROM vids WHERE name = 'r1'),
  'key-v-publish-r1-00000000001');
INSERT INTO vids VALUES ('r2', public.create_request(
  'key-v-create-r2-000000000001', 'errands_delivery', 'A second parcel',
  '9 Glover Road', 'standard', false, NULL, NULL, 6.4460, 3.4751, '1 Kingsway', NULL,
  6.4532, 3.4357));
SELECT public.publish_request((SELECT id FROM vids WHERE name = 'r2'),
  'key-v-publish-r2-00000000001');
RESET ROLE;

SELECT pg_temp.act('d2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
INSERT INTO vids VALUES ('o1', public.create_offer(
  'key-v-offer-d2-00000000000001', (SELECT id FROM vids WHERE name = 'r1'), 800000, NULL));
RESET ROLE;

SELECT pg_temp.act('d3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
INSERT INTO vids VALUES ('o2', public.create_offer(
  'key-v-offer-d3-00000000000001', (SELECT id FROM vids WHERE name = 'r1'), 850000, NULL));
RESET ROLE;

SELECT pg_temp.act('d4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
INSERT INTO vids VALUES ('o3', public.create_offer(
  'key-v-offer-d4-00000000000001', (SELECT id FROM vids WHERE name = 'r2'), 700000, NULL));
RESET ROLE;

SELECT pg_temp.act('d1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-v-accept-o1-0000000001', (SELECT id FROM vids WHERE name = 'o1'));
SELECT public.accept_offer('key-v-accept-o3-0000000001', (SELECT id FROM vids WHERE name = 'o3'));
RESET ROLE;

-- Only r1 is funded.
SELECT is(private.mark_paid_held((SELECT id FROM vids WHERE name = 'r1')),
  'assigned'::public.job_status, 'r1 is funded and assigned');
SELECT ok((SELECT assigned_at IS NULL FROM public.jobs
           WHERE request_id = (SELECT id FROM vids WHERE name = 'r2')),
  'r2 has a job but no assignment: the customer never paid');

-- ---------------------------------------------------------------------------
-- The helpers, on their own, before any policy reads them.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT ok(private.is_assigned_job_provider((SELECT id FROM vids WHERE name = 'r1')),
  'the assigned provider is one');
SELECT ok(NOT private.is_assigned_job_provider((SELECT id FROM vids WHERE name = 'r2')),
  'and is not one on somebody else''s job');
RESET ROLE;

SELECT pg_temp.act('d4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT ok(NOT private.is_assigned_job_provider((SELECT id FROM vids WHERE name = 'r2')),
  'an accepted offer is not an assignment: the gate is the money, not the handshake');
RESET ROLE;

SELECT pg_temp.act('d3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT ok(private.is_matched_provider((SELECT id FROM vids WHERE name = 'r1')),
  'a provider who opened a negotiation is matched');
SELECT ok(NOT private.is_matched_provider((SELECT id FROM vids WHERE name = 'r2')),
  'and is not matched to a request they never bid on');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- requests. The allow half is one row and the address on it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 2,
  'the customer still reads both of their own requests');
RESET ROLE;

SELECT pg_temp.act('d2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 1,
  'the assigned provider reads exactly one request: the one they are working');
SELECT is((SELECT destination_label FROM public.requests
           WHERE id = (SELECT id FROM vids WHERE name = 'r1')), '4 Awolowo Road, Flat 3B',
  'and can see where they are taking it, which they could not before this migration');
SELECT is((SELECT destination_landmark_note FROM public.requests
           WHERE id = (SELECT id FROM vids WHERE name = 'r1')), 'Ring twice',
  'including the landmark note, which is the part that gets a parcel to a door');
SELECT is((SELECT count(*)::int FROM public.requests
           WHERE id = (SELECT id FROM vids WHERE name = 'r2')), 0,
  'and not the other job on the platform');
RESET ROLE;

-- The deny half: bidding is not assignment, and acceptance is not payment.
SELECT pg_temp.act('d3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 0,
  'a provider who bid and lost reads no request: the feed card was the offer they answered');
RESET ROLE;

SELECT pg_temp.act('d4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 0,
  'and a provider whose offer was accepted but never paid for reads nothing either -- '
  'otherwise accepting and walking away is a way to collect addresses (R-05)');
RESET ROLE;

SELECT pg_temp.act('d5555555-5555-4555-8555-555555555555');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 0, 'a stranger reads none of it');
RESET ROLE;

-- The gate is `assigned_at`, not the status, and this is the case that proves it: r2 is
-- cancelled without ever having been funded, so its status is no longer `agreed`.
UPDATE public.requests SET status = 'cancelled'
WHERE id = (SELECT id FROM vids WHERE name = 'r2');
SELECT pg_temp.act('d4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 0,
  'cancelling an unfunded job does not hand the address over on the way out');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- request_media. The matched provider is the feed card the matrix already promised.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 1,
  'the customer reads the photo they attached');
RESET ROLE;

SELECT pg_temp.act('d2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 1,
  'so does the assigned provider');
RESET ROLE;

SELECT pg_temp.act('d3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 1,
  'and so does a matched provider, whose feed card lists this path and could not fetch it');
SELECT ok(private.may_read_request_media('d1111111-1111-4111-8111-111111111111/parcel.jpg'),
  'the storage side agrees, or the row would describe an object the same person cannot open');
RESET ROLE;

SELECT pg_temp.act('d4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 0,
  'a provider matched to a different request reads no media here');
SELECT ok(NOT private.may_read_request_media('d1111111-1111-4111-8111-111111111111/parcel.jpg'),
  'and cannot open the object either');
RESET ROLE;

SELECT pg_temp.act('d5555555-5555-4555-8555-555555555555');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 0, 'nor does a stranger');
RESET ROLE;

-- Staff: the S.1 rule, which the rows never got. Support reads a job's media when a ticket
-- names it, not because they are support.
SELECT pg_temp.act('d6666666-6666-4666-8666-666666666666', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 0,
  'a support agent with no ticket on this job reads no media, in scope or not');
RESET ROLE;

SELECT pg_temp.act('d7777777-7777-4777-8777-777777777777', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 0,
  'and one in another country certainly does not');
RESET ROLE;

SELECT pg_temp.act('d8888888-8888-4888-8888-888888888888', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.request_media), 1,
  'a super admin reads it, because somebody has to be able to');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- job_events -- limb (d). This was already broken and no test had ever asked: the provider
-- clause sat inside a subquery on `public.requests`, which a policy evaluates with the
-- caller's own permissions, so it could only be true for somebody who could already read the
-- request.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT cmp_ok((SELECT count(*)::int FROM public.job_events
               WHERE request_id = (SELECT id FROM vids WHERE name = 'r1')), '>=', 3,
  'the assigned provider reads their own job''s history: agreed, paid_held, assigned');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM vids WHERE name = 'r2')), 0,
  'and none of anybody else''s');
RESET ROLE;

SELECT pg_temp.act('d1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT cmp_ok((SELECT count(*)::int FROM public.job_events), '>=', 4, 'the customer still reads theirs');
RESET ROLE;

SELECT pg_temp.act('d5555555-5555-4555-8555-555555555555');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_events), 0, 'a stranger reads no history');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
