-- The item float top-up (OD-04, answered 2026-10-12; money-flows 3d).
--
-- Five shopping errands, each a 20.00 job with a 30.00 float, each a different ending: approved
-- and paid, declined, never answered, approved and never paid, and paid then cancelled. The
-- claim under test is the decision's: nothing is ever charged without the customer's tap, the
-- provider is reimbursed exactly what they spent when the customer agrees, and the whole float
-- (and a dispute for the rest) when they do not.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(49);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-555555555555', '2348000006001'),   -- customer
  ('f2222222-2222-4222-8222-555555555501', '2348000006011'),   -- provider, job 1
  ('f2222222-2222-4222-8222-555555555502', '2348000006012'),   -- provider, job 2
  ('f2222222-2222-4222-8222-555555555503', '2348000006013'),   -- provider, job 3
  ('f2222222-2222-4222-8222-555555555504', '2348000006014'),   -- provider, job 4
  ('f2222222-2222-4222-8222-555555555505', '2348000006015'),   -- provider, job 5
  ('f3333333-3333-4333-8333-555555555555', '2348000006021');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'f1111111-1111-4111-8111-555555555555';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id::text LIKE 'f2222222-%';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'f3333333-3333-4333-8333-555555555555';
INSERT INTO public.provider_profiles (user_id)
SELECT user_id FROM public.profiles WHERE user_id::text LIKE 'f2222222-%';

CREATE TEMP TABLE tu (name text PRIMARY KEY, id uuid);
GRANT ALL ON tu TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

-- A paid shopping errand in progress: 20.00 job, 30.00 float, charged 50.90, fee 1.48.
CREATE FUNCTION pg_temp.shopping_job(p_tag text, p_provider text) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_req uuid; v_offer uuid; v_pay uuid;
BEGIN
  PERFORM pg_temp.act('f1111111-1111-4111-8111-555555555555');
  v_req := public.create_request('key-tu-create-' || p_tag || '-000000', 'personal_assistance',
    'Buy groceries from the market', 'Mile 12 Market', p_pickup_lat => 6.5833,
    p_pickup_lng => 3.3833, p_item_float_minor => 3000);
  PERFORM public.publish_request(v_req, 'key-tu-publish-' || p_tag || '-00000');
  PERFORM pg_temp.act(p_provider);
  v_offer := public.create_offer('key-tu-offer-' || p_tag || '-0000000', v_req, 2000, NULL);
  PERFORM pg_temp.act('f1111111-1111-4111-8111-555555555555');
  PERFORM public.accept_offer('key-tu-accept-' || p_tag || '-000000', v_offer);
  SELECT payment_id INTO v_pay FROM public.start_payment('key-tu-pay-' || p_tag || '-000000000',
    v_req, 'card');
  PERFORM private.record_gateway_checkout(v_pay, 'flutterwave', 'FLW-TU-JOB-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-TU-JOB-' || p_tag, 5090, 148);
  UPDATE public.requests SET status = 'in_progress' WHERE id = v_req;
  RETURN v_req;
END $fn$;

CREATE FUNCTION pg_temp.float_balance(p_req uuid) RETURNS bigint
LANGUAGE sql AS $fn$
  SELECT coalesce(sum(e.amount_minor), 0)::bigint
  FROM ledger.entries e
  JOIN ledger.transactions t ON t.id = e.transaction_id
  JOIN ledger.accounts a ON a.id = e.account_id
  WHERE t.request_id = p_req AND a.account_type = 'item_float';
$fn$;

INSERT INTO tu VALUES
  ('r1', pg_temp.shopping_job('j1', 'f2222222-2222-4222-8222-555555555501')),
  ('r2', pg_temp.shopping_job('j2', 'f2222222-2222-4222-8222-555555555502')),
  ('r3', pg_temp.shopping_job('j3', 'f2222222-2222-4222-8222-555555555503')),
  ('r4', pg_temp.shopping_job('j4', 'f2222222-2222-4222-8222-555555555504')),
  ('r5', pg_temp.shopping_job('j5', 'f2222222-2222-4222-8222-555555555505'));
SELECT is(pg_temp.float_balance((SELECT id FROM tu WHERE name = 'r1')), -3000::bigint,
  'a paid shopping errand holds its 30.00 float');

-- ---------------------------------------------------------------------------
-- Asking. Job 1: the receipt is 35.00 against a 30.00 float.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-555555555501');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.request_float_top_up('key-tu-req-small-00001', %L, 3000, %L)$$,
    (SELECT id FROM tu WHERE name = 'r1'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a receipt inside the float is a normal receipt, not a top-up');
SELECT throws_ok(
  format($$SELECT public.request_float_top_up('key-tu-req-large-00001', %L, 6001, %L)$$,
    (SELECT id FROM tu WHERE name = 'r1'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  'P0001', 'ERR_FLOAT_TOP_UP_TOO_LARGE', 'more than the float again is a dispute, not a top-up');
SELECT throws_ok(
  format($$SELECT public.request_float_top_up('key-tu-req-path-000001', %L, 3500, 'elsewhere/receipt.jpg')$$,
    (SELECT id FROM tu WHERE name = 'r1')),
  '22023', 'ERR_INVALID_ARGUMENT', 'the receipt lives under this job''s own folder');
INSERT INTO tu VALUES ('t1', public.request_float_top_up('key-tu-req-j1-000000001',
  (SELECT id FROM tu WHERE name = 'r1'), 3500, (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')));
SELECT is(public.request_float_top_up('key-tu-req-j1-000000001',
            (SELECT id FROM tu WHERE name = 'r1'), 3500,
            (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  (SELECT id FROM tu WHERE name = 't1'), 'a retry returns the same top-up');
SELECT is((SELECT amount_minor::text || '/' || status FROM public.float_top_ups
           WHERE id = (SELECT id FROM tu WHERE name = 't1')), '500/requested',
  'the provider asks for the 5.00 they are short, and it waits for the customer');
SELECT throws_ok(
  format($$SELECT public.request_float_top_up('key-tu-req-j1-again-001', %L, 3600, %L)$$,
    (SELECT id FROM tu WHERE name = 'r1'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  'P0001', 'ERR_FLOAT_TOP_UP_EXISTS', 'one top-up per job');
SELECT throws_ok(
  format($$SELECT public.submit_float_receipt('key-tu-rcpt-j1-0000001', %L, 2900, %L)$$,
    (SELECT id FROM tu WHERE name = 'r1'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and no other receipt can be filed while it is open');
SELECT throws_ok(
  format($$SELECT public.respond_float_top_up('key-tu-resp-prov-00001', %L, true)$$,
    (SELECT id FROM tu WHERE name = 't1')),
  'P0001', 'ERR_FLOAT_TOP_UP_NOT_FOUND', 'the provider cannot answer their own request');
SELECT is((SELECT count(*)::int FROM public.float_top_ups), 1, 'the provider reads their top-up');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'f1111111-1111-4111-8111-555555555555'
             AND params ->> 'top_up_id' = (SELECT id::text FROM tu WHERE name = 't1')), 1,
  'the customer is asked, with the top-up in the message');

SELECT pg_temp.act('f3333333-3333-4333-8333-555555555555');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.float_top_ups), 0, 'a stranger reads no top-ups');
SELECT throws_ok(
  format($$SELECT public.request_float_top_up('key-tu-req-strange-001', %L, 3500, %L)$$,
    (SELECT id FROM tu WHERE name = 'r2'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r2')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'and cannot ask for one on somebody else''s job');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Approved and paid (3d).
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.approve_float_receipt('key-tu-appr-early-0001', %L)$$,
    (SELECT id FROM tu WHERE name = 'r1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'the float is not released while the top-up is open');
INSERT INTO tu VALUES ('p1', public.respond_float_top_up('key-tu-resp-j1-00000001',
  (SELECT id FROM tu WHERE name = 't1'), true));
SELECT is(public.respond_float_top_up('key-tu-resp-j1-00000001', (SELECT id FROM tu WHERE name = 't1'), true),
  (SELECT id FROM tu WHERE name = 'p1'), 'a retry of the approval returns the same payment');
SELECT is((SELECT kind || ' ' || amount_minor || ' = ' || float_minor || ' + ' || float_surcharge_minor
           FROM public.payments WHERE id = (SELECT id FROM tu WHERE name = 'p1')),
  'float_top_up 515 = 500 + 15',
  'approving creates its own payment: 5.00 plus the same 3% fee surcharge as the float');
SELECT is((SELECT status FROM public.float_top_ups WHERE id = (SELECT id FROM tu WHERE name = 't1')),
  'approved', 'and the top-up waits for that payment');
SELECT is((SELECT count(*)::int FROM public.float_top_ups), 1, 'the customer reads it too');
RESET ROLE;

SELECT is(pg_temp.float_balance((SELECT id FROM tu WHERE name = 'r1')), -3000::bigint,
  'nothing is booked on approval alone: approval is not payment');
SELECT ok(private.record_gateway_checkout((SELECT id FROM tu WHERE name = 'p1'), 'flutterwave',
  'FLW-TU-TOPUP-1', NULL), 'the checkout is written back');
SELECT is(private.confirm_payment('flutterwave', 'FLW-TU-TOPUP-1', 515, 15),
  'in_progress'::public.job_status, 'the gateway confirms it, and the job does not move');
SELECT is((SELECT status FROM public.float_top_ups WHERE id = (SELECT id FROM tu WHERE name = 't1')),
  'paid', 'the top-up is paid');
SELECT is((SELECT item_float_spent_minor FROM public.jobs WHERE request_id = (SELECT id FROM tu WHERE name = 'r1')),
  3500::bigint, 'and its receipt becomes the job''s receipt');
SELECT is(pg_temp.float_balance((SELECT id FROM tu WHERE name = 'r1')), -3500::bigint,
  '3d: the float now holds 35.00');
SELECT is((SELECT coalesce(sum(e.amount_minor), 0)::bigint FROM ledger.entries e
           JOIN ledger.transactions t ON t.id = e.transaction_id
           JOIN ledger.accounts a ON a.id = e.account_id
           WHERE t.idempotency_key = 'float_top_up:' || (SELECT id::text FROM tu WHERE name = 'p1')
             AND a.account_type = 'gateway_fees'), 0::bigint,
  'the 0.15 surcharge covered the 0.15 fee, so the provider bears none of it');

SELECT pg_temp.act('f2222222-2222-4222-8222-555555555501');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.submit_float_receipt('key-tu-rcpt-j1-0000002', %L, 2900, %L)$$,
    (SELECT id FROM tu WHERE name = 'r1'), (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a paid top-up fixes the receipt: it cannot be swapped');
RESET ROLE;

SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
SET LOCAL ROLE authenticated;
SELECT ok(public.approve_float_receipt('key-tu-appr-j1-00000001', (SELECT id FROM tu WHERE name = 'r1')) > 0,
  'the customer approves the receipt');
RESET ROLE;
SELECT is(pg_temp.float_balance((SELECT id FROM tu WHERE name = 'r1')), 0::bigint,
  'the whole 35.00 leaves the float');
SELECT is((SELECT -sum(e.amount_minor)::bigint FROM ledger.entries e
           JOIN ledger.transactions t ON t.id = e.transaction_id
           JOIN ledger.accounts a ON a.id = e.account_id
           WHERE t.request_id = (SELECT id FROM tu WHERE name = 'r1') AND t.kind = 'float_released'
             AND a.account_type = 'provider_earnings'), 3500::bigint,
  'and the provider is reimbursed exactly the 35.00 they spent');
SELECT is((SELECT count(*)::int FROM public.refunds
           WHERE request_id = (SELECT id FROM tu WHERE name = 'r1') AND reason_code = 'item_float_unused'), 0,
  'with nothing unused to refund');

-- ---------------------------------------------------------------------------
-- Declined. Job 2: the receipt is 40.00.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-555555555502');
INSERT INTO tu VALUES ('t2', public.request_float_top_up('key-tu-req-j2-000000001',
  (SELECT id FROM tu WHERE name = 'r2'), 4000, (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r2')));
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
SET LOCAL ROLE authenticated;
SELECT is(public.respond_float_top_up('key-tu-resp-j2-00000001', (SELECT id FROM tu WHERE name = 't2'), false),
  NULL::uuid, 'the customer declines, and no payment is created');
SELECT throws_ok(
  format($$SELECT public.respond_float_top_up('key-tu-resp-j2-again-01', %L, true)$$,
    (SELECT id FROM tu WHERE name = 't2')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a decline is final');
RESET ROLE;
SELECT is((SELECT status FROM public.float_top_ups WHERE id = (SELECT id FROM tu WHERE name = 't2')),
  'declined', 'the top-up is declined');
SELECT is((SELECT item_float_spent_minor FROM public.jobs WHERE request_id = (SELECT id FROM tu WHERE name = 'r2')),
  3000::bigint, 'the provider''s receipt is taken at the whole float');
SELECT is((SELECT (params ->> 'disputable_minor')::bigint FROM public.notifications
           WHERE user_id = 'f2222222-2222-4222-8222-555555555502'
             AND params ->> 'top_up_id' = (SELECT id::text FROM tu WHERE name = 't2')), 1000::bigint,
  'and they are told the 10.00 beyond it is theirs to dispute');
SELECT is((SELECT count(*)::int FROM public.payments
           WHERE request_id = (SELECT id FROM tu WHERE name = 'r2') AND kind = 'float_top_up'), 0,
  'nothing was charged');

-- ---------------------------------------------------------------------------
-- Never answered. Job 3.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-555555555503');
INSERT INTO tu VALUES ('t3', public.request_float_top_up('key-tu-req-j3-000000001',
  (SELECT id FROM tu WHERE name = 'r3'), 3300, (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r3')));
SELECT is(private.expire_float_top_ups(), 0, 'nothing expires before the deadline');
UPDATE public.float_top_ups SET respond_by = now() - interval '1 minute'
WHERE id = (SELECT id FROM tu WHERE name = 't3');
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.respond_float_top_up('key-tu-resp-j3-late-001', %L, true)$$,
    (SELECT id FROM tu WHERE name = 't3')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'an answer after the deadline is refused');
RESET ROLE;
SELECT is(private.expire_float_top_ups(), 1, 'the sweep expires it');
SELECT is((SELECT t.status || ' ' || j.item_float_spent_minor FROM public.float_top_ups t
           JOIN public.jobs j ON j.request_id = t.request_id
           WHERE t.id = (SELECT id FROM tu WHERE name = 't3')), 'expired 3000',
  'and silence is treated as a decline: the whole float, and a dispute for the rest');

-- ---------------------------------------------------------------------------
-- Approved and never paid. Job 4.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-555555555504');
INSERT INTO tu VALUES ('t4', public.request_float_top_up('key-tu-req-j4-000000001',
  (SELECT id FROM tu WHERE name = 'r4'), 3400, (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r4')));
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
INSERT INTO tu VALUES ('p4', public.respond_float_top_up('key-tu-resp-j4-00000001',
  (SELECT id FROM tu WHERE name = 't4'), true));
UPDATE public.payments SET expires_at = now() - interval '1 minute'
WHERE id = (SELECT id FROM tu WHERE name = 'p4');
SELECT ok(private.expire_payments() >= 1, 'the unpaid top-up payment expires like any other');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM tu WHERE name = 'r4')),
  'in_progress'::public.job_status, 'and an expired top-up payment does not move the job');
SELECT is(private.expire_float_top_ups(), 1, 'the sweep then settles the top-up');
SELECT is((SELECT t.status || ' ' || j.item_float_spent_minor FROM public.float_top_ups t
           JOIN public.jobs j ON j.request_id = t.request_id
           WHERE t.id = (SELECT id FROM tu WHERE name = 't4')), 'expired 3000',
  'as unpaid: the whole float, and a dispute for the rest');

-- ---------------------------------------------------------------------------
-- Paid, then the job is cancelled. Job 5.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f2222222-2222-4222-8222-555555555505');
INSERT INTO tu VALUES ('t5', public.request_float_top_up('key-tu-req-j5-000000001',
  (SELECT id FROM tu WHERE name = 'r5'), 3200, (SELECT id::text || '/receipt.jpg' FROM tu WHERE name = 'r5')));
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
INSERT INTO tu VALUES ('p5', public.respond_float_top_up('key-tu-resp-j5-00000001',
  (SELECT id FROM tu WHERE name = 't5'), true));
SELECT private.record_gateway_checkout((SELECT id FROM tu WHERE name = 'p5'), 'flutterwave', 'FLW-TU-TOPUP-5', NULL);
SELECT private.confirm_payment('flutterwave', 'FLW-TU-TOPUP-5', 206, 6);
SELECT pg_temp.act('f1111111-1111-4111-8111-555555555555');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$SELECT public.cancel_job('key-tu-cancel-j5-000001', %L, 'changed_mind')$$,
    (SELECT id FROM tu WHERE name = 'r5')),
  'the customer cancels the job before the float is released');
RESET ROLE;
SELECT is((SELECT t.status || ' ' || p.status FROM public.float_top_ups t
           JOIN public.payments p ON p.id = t.payment_id
           WHERE t.id = (SELECT id FROM tu WHERE name = 't5')), 'refunded refunded',
  'the paid top-up is refunded with it');
SELECT is((SELECT amount_minor FROM public.refunds
           WHERE payment_id = (SELECT id FROM tu WHERE name = 'p5')), 200::bigint,
  'in full: the 2.00 top-up, its surcharge having paid its fee');
SELECT is(pg_temp.float_balance((SELECT id FROM tu WHERE name = 'r5')), 0::bigint,
  'and nothing is left in the float');

SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0,
  'every posting in all five errands balances');

SELECT * FROM finish();
ROLLBACK;
