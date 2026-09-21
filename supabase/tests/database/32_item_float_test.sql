-- The item float (`docs/plan/money-flows.md` postings 3a, 3b and 3c; OD-04).
--
-- The doc's own shopping errand: a 20.00 job with a 30.00 float, charged at 50.90 because the
-- customer covers the gateway's fee on the goods money. The gateway takes 1.48 of that; 0.90 was
-- the surcharge, so only 0.58 is a fee for the provider to bear on the job itself.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(28);

INSERT INTO auth.users (id, phone) VALUES
  ('a9111111-1111-4111-8111-444444444444', '2348000000251'),   -- customer
  ('a9222222-2222-4222-8222-444444444444', '2348000000252');   -- provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'a9111111-1111-4111-8111-444444444444';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'a9222222-2222-4222-8222-444444444444';
INSERT INTO public.provider_profiles (user_id) VALUES ('a9222222-2222-4222-8222-444444444444');

CREATE TEMP TABLE fl (name text PRIMARY KEY, id uuid);
GRANT ALL ON fl TO authenticated, service_role;

SELECT set_config('request.jwt.claims',
  '{"sub": "a9111111-1111-4111-8111-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO fl VALUES ('r', public.create_request(
  'key-if-create-req-000001', 'personal_assistance', 'Buy groceries from the market',
  'Mile 12 Market', p_pickup_lat => 6.5833, p_pickup_lng => 3.3833,
  p_item_float_minor => 3000));
SELECT public.publish_request((SELECT id FROM fl WHERE name = 'r'), 'key-if-publish-000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "a9222222-2222-4222-8222-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO fl VALUES ('o', public.create_offer(
  'key-if-offer-p-00000001', (SELECT id FROM fl WHERE name = 'r'), 2000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "a9111111-1111-4111-8111-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-if-accept-c-0000001', (SELECT id FROM fl WHERE name = 'o'));

-- ---------------------------------------------------------------------------
-- 3a: one charge, three parts.
-- ---------------------------------------------------------------------------
INSERT INTO fl VALUES ('p', (SELECT payment_id FROM public.start_payment(
  'key-if-pay-c-000000001', (SELECT id FROM fl WHERE name = 'r'), 'card')));
SELECT is((SELECT amount_minor FROM public.payments WHERE id = (SELECT id FROM fl WHERE name = 'p')),
  5090::bigint, 'the customer is charged 50.90: 20.00 job, 30.00 goods, 0.90 fee on the goods');
SELECT is((SELECT job_amount_minor FROM public.payments
           WHERE id = (SELECT id FROM fl WHERE name = 'p')), 2000::bigint,
  'and the charge says how it divides, so nothing has to re-derive it later');
SELECT is((SELECT float_surcharge_minor FROM public.payments
           WHERE id = (SELECT id FROM fl WHERE name = 'p')), 90::bigint,
  'the surcharge is 3% of the float — the only estimate in the money path, and it is config');
RESET ROLE;

SELECT ok(private.record_gateway_checkout((SELECT id FROM fl WHERE name = 'p'),
            'flutterwave', 'FLW-FLOAT-01', NULL), 'the checkout is written back');
SELECT is(private.confirm_payment('flutterwave', 'FLW-FLOAT-01', 5090, 148),
  'assigned'::public.job_status, 'the gateway takes 1.48 of it and the rest is captured');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'held_funds'), 2000::bigint,
  '3a: 20.00 is held against the job');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'item_float'), 3000::bigint,
  'and 30.00 sits in the float, which is not the platform''s money and carries no commission');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 58::bigint,
  'only 0.58 is a fee to recover: the customer''s 0.90 surcharge covered the rest');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- ---------------------------------------------------------------------------
-- The receipt.
-- ---------------------------------------------------------------------------
UPDATE public.requests SET status = 'in_progress' WHERE id = (SELECT id FROM fl WHERE name = 'r');
SELECT set_config('request.jwt.claims',
  '{"sub": "a9111111-1111-4111-8111-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.submit_float_receipt('key-if-rcpt-c-00000001', %L, 2640, %L)$$,
    (SELECT id FROM fl WHERE name = 'r'),
    (SELECT id::text || '/receipt.jpg' FROM fl WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_FOUND',
  'the customer does not file the receipt: they were not the one at the till');
SELECT throws_ok(
  format($$SELECT public.approve_float_receipt('key-if-appr-early-001', %L)$$,
    (SELECT id FROM fl WHERE name = 'r')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and cannot approve one that does not exist yet');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "a9222222-2222-4222-8222-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.submit_float_receipt('key-if-rcpt-over-0001', %L, 3500, %L)$$,
    (SELECT id FROM fl WHERE name = 'r'),
    (SELECT id::text || '/receipt.jpg' FROM fl WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'spending more than was prepaid is a conversation, not an automatic top-up');
SELECT throws_ok(
  format($$SELECT public.submit_float_receipt('key-if-rcpt-path-0001', %L, 2640,
      'somebody-elses-folder/receipt.jpg')$$,
    (SELECT id FROM fl WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and the receipt lives under this job''s own folder');
SELECT is(public.submit_float_receipt('key-if-rcpt-p-00000001',
            (SELECT id FROM fl WHERE name = 'r'), 2640,
            (SELECT id::text || '/receipt.jpg' FROM fl WHERE name = 'r')), 2640::bigint,
  'the provider files a receipt for 26.40 of the 30.00');
RESET ROLE;
-- Counted by what the notification carries, not by kind: moving the job to `in_progress` above
-- sends its own `job_status` notification, and a test that counts kinds counts that too.
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'a9111111-1111-4111-8111-444444444444'
             AND params ->> 'spent_minor' IS NOT NULL), 1,
  'and the customer is asked to look at it, with what was spent in the message');

-- Settling the job around an unapproved float would strand somebody's money.
SELECT throws_ok(
  format($$SELECT private.recognise_earnings(%L)$$, (SELECT id FROM fl WHERE name = 'r')),
  'P0001', 'ERR_ITEM_FLOAT_PENDING',
  'earnings cannot be recognised while the float is still waiting on approval');

-- ---------------------------------------------------------------------------
-- 3b: the float is released.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "a9111111-1111-4111-8111-444444444444", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.approve_float_receipt('key-if-approve-c-00001',
            (SELECT id FROM fl WHERE name = 'r')) > 0, 'the customer approves it');
RESET ROLE;
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'item_float'), 0::bigint, '3b: the float is emptied');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'a9222222-2222-4222-8222-444444444444'
             AND a.account_type = 'provider_earnings'), 2640::bigint,
  'the provider is reimbursed exactly what they spent — no commission on groceries');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'refunds_payable'), 360::bigint,
  'and the 3.60 they did not spend is owed back to the customer');
SELECT is((SELECT amount_minor FROM public.refunds WHERE reason_code = 'item_float_unused'),
  360::bigint, 'as a refund with its own reason, not a silent adjustment');

-- ---------------------------------------------------------------------------
-- 3c: the job's own money, once the dispute window has passed.
-- ---------------------------------------------------------------------------
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM fl WHERE name = 'r');
UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT id FROM fl WHERE name = 'r');
SELECT is(private.recognise_due_earnings(), 1, 'now the job settles');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 250::bigint,
  '3c: commission is 2.50 — 12.5% of the job price, and nothing of the goods money');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'a9222222-2222-4222-8222-444444444444'
             AND a.account_type = 'provider_earnings'), 4332::bigint,
  'the provider ends with 43.32: 26.40 reimbursed and 16.92 earned');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 0::bigint,
  'and the job''s share of the fee is recovered, leaving nothing absorbed');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0, 'and reconciles');
SELECT is((SELECT sum(e.amount_minor)::bigint FROM ledger.entries e), 0::bigint,
  'the whole book still sums to zero');

SELECT * FROM finish();
ROLLBACK;
