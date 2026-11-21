-- Direct payment (ADR-0025): Confirm hire instead of Pay, no money moving through the app, a
-- goods cap on errands that involve buying something, cancellation without refunds, and a
-- go-live check that does not ask a direct country for providers it does not use.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(47);

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-111111111111', '2348000000711'),   -- customer
  ('d2222222-2222-4222-8222-222222222222', '2348000000712'),   -- provider
  ('d3333333-3333-4333-8333-333333333333', '2348000000713');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'd2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'd3333333-3333-4333-8333-333333333333';
INSERT INTO public.provider_profiles (user_id) VALUES ('d2222222-2222-4222-8222-222222222222');

CREATE TEMP TABLE dids (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE dpins (name text PRIMARY KEY, pin text);
GRANT ALL ON dids, dpins TO authenticated, service_role;

-- The dev seed leaves Nigeria paying in the app; this file runs it in direct mode.
UPDATE public.countries SET config = jsonb_set(config, '{client,payment_mode}', '"direct"')
WHERE code = 'NG';

SELECT throws_ok(
  $$UPDATE public.countries SET config = jsonb_set(config, '{client,payment_mode}', '"cash"')
    WHERE code = 'KE'$$,
  '23514', NULL, 'a payment mode is in_app or direct, nothing else');
SELECT throws_ok(
  $$UPDATE public.countries SET config = jsonb_set(config, '{client,sign_in_methods}', '["sms"]')
    WHERE code = 'KE'$$,
  '23514', NULL, 'and sign-in methods come from a known list');

-- ---------------------------------------------------------------------------
-- Four errands, each agreed at a price.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dids VALUES ('hire', public.create_request(
  p_idempotency_key => 'key-d-create-hire-000000001', p_category_key => 'personal_assistance',
  p_description => 'Queue at the bank for me', p_pickup_label => 'Allen Avenue'));
INSERT INTO dids VALUES ('goods', public.create_request(
  p_idempotency_key => 'key-d-create-goods-00000001', p_category_key => 'personal_assistance',
  p_description => 'Buy a gas refill and bring it', p_pickup_label => 'Opebi Road',
  p_item_float_minor => 500000));
INSERT INTO dids VALUES ('cancel', public.create_request(
  p_idempotency_key => 'key-d-create-cancel-0000001', p_category_key => 'personal_assistance',
  p_description => 'Collect my dry cleaning', p_pickup_label => 'Toyin Street'));
INSERT INTO dids VALUES ('inapp', public.create_request(
  p_idempotency_key => 'key-d-create-inapp-00000001', p_category_key => 'personal_assistance',
  p_description => 'Pick up a parcel from the post office', p_pickup_label => 'Obafemi Awolowo Way'));
SELECT public.publish_request((SELECT id FROM dids WHERE name = 'hire'), 'key-d-publish-hire-0000001');
SELECT public.publish_request((SELECT id FROM dids WHERE name = 'goods'), 'key-d-publish-goods-000001');
SELECT public.publish_request((SELECT id FROM dids WHERE name = 'cancel'), 'key-d-publish-cancel-00001');
SELECT public.publish_request((SELECT id FROM dids WHERE name = 'inapp'), 'key-d-publish-inapp-000001');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dids VALUES ('hire_o', public.create_offer('key-d-offer-hire-0000000001',
  (SELECT id FROM dids WHERE name = 'hire'), 300000));
INSERT INTO dids VALUES ('goods_o', public.create_offer('key-d-offer-goods-000000001',
  (SELECT id FROM dids WHERE name = 'goods'), 200000));
INSERT INTO dids VALUES ('cancel_o', public.create_offer('key-d-offer-cancel-00000001',
  (SELECT id FROM dids WHERE name = 'cancel'), 250000));
INSERT INTO dids VALUES ('inapp_o', public.create_offer('key-d-offer-inapp-000000001',
  (SELECT id FROM dids WHERE name = 'inapp'), 150000));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_offer('key-d-accept-hire-000000001', (SELECT id FROM dids WHERE name = 'hire_o')),
  'agreed'::public.job_status, 'the price is agreed as it always was');
SELECT public.accept_offer('key-d-accept-goods-00000001', (SELECT id FROM dids WHERE name = 'goods_o'));
SELECT public.accept_offer('key-d-accept-cancel-0000001', (SELECT id FROM dids WHERE name = 'cancel_o'));
SELECT public.accept_offer('key-d-accept-inapp-00000001', (SELECT id FROM dids WHERE name = 'inapp_o'));

-- ---------------------------------------------------------------------------
-- Paying in the app refuses; confirming the hire is the commitment instead.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  format($$SELECT public.start_payment('key-d-pay-hire-00000000001', %L)$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_DIRECT_PAYMENT_ONLY', 'nothing is paid through the app in a direct country');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dids WHERE name = 'hire')),
  'agreed'::public.job_status, 'and the refusal leaves the job where it was');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.confirm_hire('key-d-hire-by-p-0000000001', %L)$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_REQUEST_NOT_FOUND',
  'a provider cannot hire themselves: the address opens only when the customer says so');
SELECT is((SELECT count(*)::int FROM public.requests
           WHERE id = (SELECT id FROM dids WHERE name = 'hire')), 0,
  'and before the hire the provider cannot read the request at all');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.confirm_hire('key-d-hire-c-00000000000001', (SELECT id FROM dids WHERE name = 'hire')),
  'assigned'::public.job_status, 'the customer confirms the hire and the provider is assigned');
SELECT is(public.confirm_hire('key-d-hire-c-00000000000001', (SELECT id FROM dids WHERE name = 'hire')),
  'assigned'::public.job_status, 'a replayed hire returns the same answer');
SELECT throws_ok(
  format($$SELECT public.confirm_hire('key-d-hire-c-00000000000002', %L)$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and a second hire of the same job is refused');
RESET ROLE;

SELECT ok((SELECT direct_payment AND assigned_at IS NOT NULL AND commission_minor IS NULL
           FROM public.jobs WHERE request_id = (SELECT id FROM dids WHERE name = 'hire')),
  'the job is marked direct, assigned, and carries no money snapshot');
SELECT is((SELECT count(*)::int FROM private.job_pins
           WHERE request_id = (SELECT id FROM dids WHERE name = 'hire') AND kind = 'pickup'), 1,
  'the pickup PIN exists from the hire, as it does from a payment');
SELECT is((SELECT actor_kind FROM public.job_events
           WHERE request_id = (SELECT id FROM dids WHERE name = 'hire')
             AND from_status = 'agreed' AND to_status = 'assigned'),
  'customer'::public.job_actor_kind, 'the history says the customer made the hire');
SELECT ok(private.chat_is_open((SELECT id FROM dids WHERE name = 'hire')),
  'chat and calls open at the hire');
SELECT is((SELECT count(*)::int FROM public.payments
           WHERE request_id = (SELECT id FROM dids WHERE name = 'hire')), 0,
  'and no payment row exists');

SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT pickup_label FROM public.requests
           WHERE id = (SELECT id FROM dids WHERE name = 'hire')), 'Allen Avenue',
  'the hired provider can now read where to go');
RESET ROLE;

-- A country that takes payment in the app does not offer the shortcut.
UPDATE public.countries SET config = jsonb_set(config, '{client,payment_mode}', '"in_app"')
WHERE code = 'NG';
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.confirm_hire('key-d-hire-inapp-0000000001', %L)$$,
    (SELECT id FROM dids WHERE name = 'inapp')),
  'P0001', 'ERR_PAYMENT_REQUIRED', 'in an in-app country the customer pays instead');
RESET ROLE;
UPDATE public.countries SET config = jsonb_set(config, '{client,payment_mode}', '"direct"')
WHERE code = 'NG';

-- ---------------------------------------------------------------------------
-- The work, done and confirmed, then closed once the chat window has passed.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-d-enroute-hire-00000001', (SELECT id FROM dids WHERE name = 'hire'),
  'en_route');
SELECT public.set_job_status('key-d-arrive-hire-000000001', (SELECT id FROM dids WHERE name = 'hire'),
  'arrived', 'gps_unavailable');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dpins VALUES ('hire', public.reveal_job_pin((SELECT id FROM dids WHERE name = 'hire')));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((public.verify_pin('key-d-pin-hire-00000000001', (SELECT id FROM dids WHERE name = 'hire'),
             (SELECT pin FROM dpins WHERE name = 'hire')) ->> 'status'),
  'in_progress', 'the pickup PIN starts the work, unchanged');
SELECT is(public.set_job_status('key-d-done-hire-0000000001', (SELECT id FROM dids WHERE name = 'hire'),
            'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'the provider marks it done');
SELECT throws_ok(
  format($$SELECT public.open_dispute('key-d-dispute-hire-00000001', %L, 'not_done')$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_DIRECT_PAYMENT_ONLY',
  'there is no held money to dispute: a complaint goes to support instead');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.cancel_job('key-d-cancel-done-000000001', %L, 'changed_mind')$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_JOB_NOT_CANCELLABLE',
  'once the provider says it is done, cancelling is not a way out of paying');
SELECT is(public.confirm_completion('key-d-confirm-hire-0000001', (SELECT id FROM dids WHERE name = 'hire')),
  'confirmed'::public.job_status, 'the customer confirms, having paid the provider in person');
SELECT throws_ok(
  format($$SELECT public.add_tip('key-d-tip-hire-00000000001', %L, 50000)$$,
    (SELECT id FROM dids WHERE name = 'hire')),
  'P0001', 'ERR_DIRECT_PAYMENT_ONLY', 'a tip is money through the app too, so it refuses');
RESET ROLE;

SELECT is(private.close_direct_jobs(), 0, 'nothing closes while the chat window is open');
SELECT ok(private.chat_is_open((SELECT id FROM dids WHERE name = 'hire')),
  'so the two can still talk about the money');
UPDATE public.jobs SET confirmed_at = now() - interval '25 hours'
WHERE request_id = (SELECT id FROM dids WHERE name = 'hire');
SELECT is(private.close_direct_jobs(), 1, 'after the window the job closes');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dids WHERE name = 'hire')),
  'closed'::public.job_status, 'with no settlement in between');

-- ---------------------------------------------------------------------------
-- Goods: the provider says what they spent, within the cap, before saying it is done.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.confirm_hire('key-d-hire-goods-0000000001', (SELECT id FROM dids WHERE name = 'goods'));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.record_goods_receipt('key-d-goods-early-000000001', %L, 300000, %L)$$,
    (SELECT id FROM dids WHERE name = 'goods'), (SELECT id FROM dids WHERE name = 'goods') || '/r.jpg'),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'goods are recorded once the work has started');
SELECT public.set_job_status('key-d-enroute-goods-0000001', (SELECT id FROM dids WHERE name = 'goods'),
  'en_route');
SELECT public.set_job_status('key-d-arrive-goods-00000001', (SELECT id FROM dids WHERE name = 'goods'),
  'arrived', 'gps_unavailable');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dpins VALUES ('goods', public.reveal_job_pin((SELECT id FROM dids WHERE name = 'goods')));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.verify_pin('key-d-pin-goods-0000000001', (SELECT id FROM dids WHERE name = 'goods'),
  (SELECT pin FROM dpins WHERE name = 'goods'));
SELECT throws_ok(
  format($$SELECT public.set_job_status('key-d-done-goods-early-0001', %L, 'completed_by_provider')$$,
    (SELECT id FROM dids WHERE name = 'goods')),
  'P0001', 'ERR_PROOF_REQUIRED', 'a job with a goods cap is not done until the goods are recorded');
SELECT throws_ok(
  format($$SELECT public.record_goods_receipt('key-d-goods-over-0000000001', %L, 500001, %L)$$,
    (SELECT id FROM dids WHERE name = 'goods'), (SELECT id FROM dids WHERE name = 'goods') || '/r.jpg'),
  'P0001', 'ERR_GOODS_OVER_CAP', 'the provider cannot spend past what the customer agreed to');
SELECT throws_ok(
  format($$SELECT public.record_goods_receipt('key-d-goods-path-0000000001', %L, 300000, 'elsewhere/r.jpg')$$,
    (SELECT id FROM dids WHERE name = 'goods')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a receipt must be filed in this job''s own folder');
SELECT throws_ok(
  format($$SELECT public.record_goods_receipt('key-d-goods-none-0000000001', %L, 300000)$$,
    (SELECT id FROM dids WHERE name = 'goods')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and money spent needs a receipt');
SELECT is((public.record_goods_receipt('key-d-goods-ok-000000000001', (SELECT id FROM dids WHERE name = 'goods'),
             325000, (SELECT id FROM dids WHERE name = 'goods') || '/r.jpg') ->> 'total_due_minor')::bigint,
  525000::bigint, 'the customer owes the agreed price plus what the goods cost');
SELECT is(public.set_job_status('key-d-done-goods-00000001', (SELECT id FROM dids WHERE name = 'goods'),
            'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'and now the job can be marked done');
RESET ROLE;

SELECT is((SELECT title_key FROM public.notifications
           WHERE user_id = 'd1111111-1111-4111-8111-111111111111'
             AND params ->> 'request_id' = (SELECT id FROM dids WHERE name = 'goods')::text
             AND title_key = 'notifGoodsReceiptTitle'),
  'notifGoodsReceiptTitle', 'the customer is told what the goods cost before the provider arrives');
SELECT is((SELECT goods_spent_minor FROM public.jobs
           WHERE request_id = (SELECT id FROM dids WHERE name = 'goods')), 325000::bigint,
  'the amount is on the job for both of them to see');
SELECT is((SELECT count(*)::int FROM public.jobs
           WHERE request_id = (SELECT id FROM dids WHERE name = 'goods')
             AND item_float_spent_minor IS NULL AND item_float_approved_at IS NULL), 1,
  'and the in-app float, which has a release sweep of its own, is untouched');

SELECT set_config('request.jwt.claims',
  '{"sub": "d3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.record_goods_receipt('key-d-goods-stranger-00001', %L, 1, %L)$$,
    (SELECT id FROM dids WHERE name = 'goods'), (SELECT id FROM dids WHERE name = 'goods') || '/r.jpg'),
  'P0001', 'ERR_JOB_NOT_FOUND', 'a stranger cannot record anything on the job');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Cancelling a direct job refunds nothing, because nothing was paid.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.confirm_hire('key-d-hire-cancel-000000001', (SELECT id FROM dids WHERE name = 'cancel'));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-d-enroute-cancel-000001', (SELECT id FROM dids WHERE name = 'cancel'),
  'en_route');
SELECT results_eq(
  format($$SELECT refund_minor, fee_minor FROM public.cancel_job('key-d-cancel-p-000000000001', %L, 'vehicle_broke_down')$$,
    (SELECT id FROM dids WHERE name = 'cancel')),
  $$VALUES (0::bigint, 0::bigint)$$, 'the provider cancels; there is no refund and no fee');
RESET ROLE;
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dids WHERE name = 'cancel')),
  'cancelled'::public.job_status, 'the job is cancelled');
SELECT is((SELECT actor_kind FROM public.job_events
           WHERE request_id = (SELECT id FROM dids WHERE name = 'cancel') AND to_status = 'cancelled'),
  'provider'::public.job_actor_kind, 'and it counts against the provider who walked away');
SELECT is((SELECT count(*)::int FROM public.refunds
           WHERE request_id = (SELECT id FROM dids WHERE name = 'cancel')), 0,
  'no refund row exists');

-- ---------------------------------------------------------------------------
-- The app learns the mode from bootstrap.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.get_bootstrap() -> 'country_pack' -> 'client' ->> 'payment_mode', 'direct',
  'bootstrap tells the app this country pays directly');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The go-live check asks a country only for what it uses.
-- ---------------------------------------------------------------------------
UPDATE public.countries
SET config = jsonb_build_object(
  'client', (config -> 'client') || '{"payment_mode": "direct", "sign_in_methods": ["email", "google"]}'::jsonb,
  'server', '{}'::jsonb)
WHERE code = 'NG';
SELECT is(private.country_pack_gaps('NG'), '{}'::text[],
  'direct payment and email or Google sign-in need no payment, payout or SMS provider');
UPDATE public.countries SET config = jsonb_set(config, '{client,payment_mode}', '"in_app"')
WHERE code = 'NG';
SELECT is(private.country_pack_gaps('NG'),
  ARRAY['config.server.payment_providers', 'config.server.payout_providers'],
  'an in-app country still needs its payment and payout providers');
UPDATE public.countries SET config = config #- '{client,sign_in_methods}' WHERE code = 'NG';
SELECT ok('config.server.sms_providers' = ANY (private.country_pack_gaps('NG')),
  'and a country offering phone sign-in still needs an SMS provider');
UPDATE public.countries
SET config = jsonb_build_object(
  'client', jsonb_set(config -> 'client', '{payment_mode}', '"direct"'),
  'server', '{"payment_providers": ["console"]}'::jsonb)
WHERE code = 'NG';
SELECT ok(NOT ('config.server.payment_providers.console_only' = ANY (private.country_pack_gaps('NG'))),
  'a development payment route is irrelevant where nothing is paid in the app');

SELECT * FROM finish();
ROLLBACK;
