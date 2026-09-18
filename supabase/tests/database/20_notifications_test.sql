-- Notifications and the matching fan-out: who is told what, once (ERD §8; spec phase 3,
-- "PostGIS matching and provider notification fan-out").
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(20);

INSERT INTO auth.users (id, phone) VALUES
  ('cccccccc-1111-4111-8111-dddddddddddd', '2348000000131'),   -- customer
  ('cccccccc-2222-4222-8222-dddddddddddd', '2348000000132'),   -- provider nearby
  ('cccccccc-3333-4333-8333-dddddddddddd', '2348000000133');   -- provider far away
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'cccccccc-1111-4111-8111-dddddddddddd';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('cccccccc-2222-4222-8222-dddddddddddd',
                  'cccccccc-3333-4333-8333-dddddddddddd');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('cccccccc-2222-4222-8222-dddddddddddd'),
  ('cccccccc-3333-4333-8333-dddddddddddd');

CREATE TEMP TABLE nf (name text PRIMARY KEY, id uuid);
GRANT ALL ON nf TO authenticated, service_role;

SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(6.4460, 3.4751);
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-3333-4333-8333-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(9.0579, 7.4951);   -- Abuja, several hundred kilometres off
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Publishing tells the people who could take it.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO nf VALUES ('r', public.create_request(
  'key-nf-create-req-000000001', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM nf WHERE name = 'r'), 'key-nf-publish-000000001');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd' AND kind = 'request_matched'), 1,
  'the nearby provider is told about the work');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-3333-4333-8333-dddddddddddd'), 0,
  'the one in another city is not');
SELECT is((SELECT title_key FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd' LIMIT 1),
  'notifRequestMatchedTitle',
  'the notification carries keys, not a sentence the server chose a language for');
SELECT ok((SELECT (params ->> 'distance_m')::int FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd' LIMIT 1) BETWEEN 0 AND 2000,
  'with the distance in its params');

-- Running the sweep again does not tell them twice.
SELECT is(private.fan_out_request((SELECT id FROM nf WHERE name = 'r')), 0,
  'a second fan-out adds nobody: someone who saw it and did not bid is not nagged');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd'), 1, 'so there is still one');

-- ---------------------------------------------------------------------------
-- Each side hears about what the other does.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO nf VALUES ('o', public.create_offer(
  'key-nf-offer-p-0000000001', (SELECT id FROM nf WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-1111-4111-8111-dddddddddddd' AND kind = 'offer_received'), 1,
  'the customer hears about the offer');

SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.counter_offer('key-nf-counter-c-000000001', (SELECT id FROM nf WHERE name = 'o'),
  450000, 'Can you do 4,500?');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd' AND kind = 'offer_countered'), 1,
  'and the provider hears about the counter');

SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-nf-accept-p-00000001',
  (SELECT o.id FROM public.offers o WHERE o.request_id = (SELECT id FROM nf WHERE name = 'r')
   AND o.author_side = 'customer' LIMIT 1));
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-2222-4222-8222-dddddddddddd' AND kind = 'offer_accepted'), 1,
  'accepting tells the provider they won');

SELECT is(private.mark_paid_held((SELECT id FROM nf WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE kind = 'job_assigned'), 2, 'which tells both sides, each in their own words');

-- ---------------------------------------------------------------------------
-- Job steps, and chat.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-nf-enroute-p-000001', (SELECT id FROM nf WHERE name = 'r'),
  'en_route');
SELECT public.send_message('key-nf-msg-p-00000000001', (SELECT id FROM nf WHERE name = 'r'),
  'On my way.');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-1111-4111-8111-dddddddddddd' AND kind = 'job_status'), 1,
  'the customer is told the provider set off');
SELECT is((SELECT params ->> 'status' FROM public.notifications
           WHERE kind = 'job_status' LIMIT 1), 'en_route', 'the status is in params');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'cccccccc-1111-4111-8111-dddddddddddd' AND kind = 'chat_message'), 1,
  'and about the message');
SELECT ok((SELECT NOT (params ? 'body') FROM public.notifications
           WHERE kind = 'chat_message' LIMIT 1),
  'which does not carry the text: a preview on a lock screen is a message read by whoever holds the phone');

-- ---------------------------------------------------------------------------
-- Reading them.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "cccccccc-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) FROM public.notifications) >= 3, 'the customer sees their own');
SELECT ok((SELECT count(*) FROM public.notifications
           WHERE user_id <> 'cccccccc-1111-4111-8111-dddddddddddd') = 0,
  'and nobody else''s, which is all a notification list should ever be');
SELECT ok(public.mark_notifications_read() >= 3, 'marking them read returns how many were');
SELECT is((SELECT count(*)::int FROM public.notifications WHERE read_at IS NULL), 0,
  'and none are left unread');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM public.notifications$$,
  '42501', NULL, 'anon has no notifications, and no access to anyone else''s');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
