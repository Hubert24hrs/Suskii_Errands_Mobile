-- Payments, the webhook intake and the postings a job's money produces (ERD §6;
-- `docs/plan/money-flows.md` 1a–1c; job transitions 7, 8, 18; RLS matrix §6).
--
-- A ₦5,000.00 job: 12.5% commission is 625.00, net 4,375.00, and the gateway's 145.00 fee comes
-- out of the provider's share (ADR-0003), leaving them 4,230.00.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(42);

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-777777777777', '2348000000221'),   -- customer
  ('d2222222-2222-4222-8222-777777777777', '2348000000222'),   -- provider
  ('d3333333-3333-4333-8333-777777777777', '2348000000223');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-777777777777';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'd2222222-2222-4222-8222-777777777777';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'd3333333-3333-4333-8333-777777777777';
INSERT INTO public.provider_profiles (user_id) VALUES ('d2222222-2222-4222-8222-777777777777');

CREATE TEMP TABLE pm (name text PRIMARY KEY, id uuid);
GRANT ALL ON pm TO authenticated, service_role;

-- A negotiated job, ready to pay for.
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pm VALUES ('r', public.create_request(
  'key-pm-create-req-000000001', 'personal_assistance', 'Deliver a parcel to Victoria Island',
  'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711));
SELECT public.publish_request((SELECT id FROM pm WHERE name = 'r'), 'key-pm-publish-000000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pm VALUES ('o', public.create_offer(
  'key-pm-offer-p-0000000001', (SELECT id FROM pm WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-pm-accept-c-000000001', (SELECT id FROM pm WHERE name = 'o'));
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM pm WHERE name = 'r')),
  'agreed'::public.job_status, 'the price is agreed, and nothing has been paid');

-- ---------------------------------------------------------------------------
-- Transition 7: the intent, and the money snapshot taken with it.
-- ---------------------------------------------------------------------------
INSERT INTO pm VALUES ('p', (SELECT payment_id FROM public.start_payment(
  'key-pm-start-c-0000000001', (SELECT id FROM pm WHERE name = 'r'), 'card')));
SELECT ok((SELECT id FROM pm WHERE name = 'p') IS NOT NULL, 'the customer starts a payment');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM pm WHERE name = 'r')),
  'payment_pending'::public.job_status, 'and the job moves to payment_pending');
SELECT is((SELECT payment_id FROM public.start_payment(
             'key-pm-start-c-0000000002', (SELECT id FROM pm WHERE name = 'r'), 'card')),
  (SELECT id FROM pm WHERE name = 'p'),
  'starting again returns the same intent: a customer who came back should not owe twice');
SELECT is((SELECT count(*)::int FROM public.payments), 1, 'so there is one payment');
RESET ROLE;

SELECT is((SELECT commission_rate_bps FROM public.jobs
           WHERE request_id = (SELECT id FROM pm WHERE name = 'r')), 1250,
  'the rate is snapshotted at 12.5% (OD-06, and the NG pack''s verified 0.125)');
SELECT is((SELECT commission_minor FROM public.jobs
           WHERE request_id = (SELECT id FROM pm WHERE name = 'r')), 62500::bigint,
  'commission on 5,000.00 is 625.00');
SELECT is((SELECT net_minor FROM public.jobs
           WHERE request_id = (SELECT id FROM pm WHERE name = 'r')), 437500::bigint,
  'and net is 4,375.00 — computed once, never recomputed');
SELECT is((SELECT count(*)::int FROM private.outbox WHERE event_type = 'payment.requested'), 1,
  'the worker that owns the gateway credentials is told once');
SELECT is((SELECT checkout_url FROM public.payments), NULL,
  'with no checkout URL, because no gateway account exists to make one');

-- ---------------------------------------------------------------------------
-- The client cannot confirm its own payment. This is the control the whole phase rests on.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'private' AND p.proname = 'confirm_payment'
             AND has_function_privilege('authenticated', p.oid, 'EXECUTE')), 0,
  'no client role may execute confirm_payment: the only way into paid_held is a webhook');

SELECT set_config('request.jwt.claims',
  '{"sub": "d3333333-3333-4333-8333-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments), 0,
  'and a stranger sees no payment at all');
SELECT throws_ok(
  format($$SELECT public.start_payment('key-pm-start-x-0000000001', %L)$$,
    (SELECT id FROM pm WHERE name = 'r')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'nor can they pay for somebody else''s job');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The webhook intake: raw first, de-duplicated, and an invalid signature kept as evidence.
-- ---------------------------------------------------------------------------
SELECT ok(private.record_gateway_checkout((SELECT id FROM pm WHERE name = 'p'),
            'flutterwave', 'FLW-REF-0001', 'https://checkout.invalid/FLW-REF-0001'),
  'the worker writes the checkout back through the seam');
SELECT ok(private.ingest_webhook('flutterwave', 'evt-0001', true,
            '{"event": "charge.completed"}'::jsonb) IS NOT NULL,
  'a webhook is stored raw, before anything acts on it');
SELECT is(private.ingest_webhook('flutterwave', 'evt-0001', true,
            '{"event": "charge.completed"}'::jsonb), NULL,
  'and the gateway''s retry of the same event id is recognised, not processed twice');
SELECT ok(private.ingest_webhook('flutterwave', 'evt-forged', false,
            '{"event": "charge.completed"}'::jsonb) IS NOT NULL,
  'a forged signature is stored rather than discarded: it is evidence somebody tried');
SELECT is((SELECT error FROM public.webhook_events WHERE gateway_event_id = 'evt-forged'),
  'ERR_INVALID_PAYLOAD', 'marked as refused, and never acted on');

-- ---------------------------------------------------------------------------
-- Transition 8 and money-flows 1a.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT private.confirm_payment('flutterwave', 'FLW-REF-0001', 499999, 14500)$$,
  'P0001', 'ERR_PAYMENT_FAILED',
  'a charge for the wrong amount is not a payment for this job');
SELECT is(private.confirm_payment('flutterwave', 'FLW-REF-0001', 500000, 14500),
  'assigned'::public.job_status, 'the verified webhook holds the money and assigns the job');
SELECT is((SELECT status FROM public.payments WHERE id = (SELECT id FROM pm WHERE name = 'p')),
  'held'::public.payment_status, 'the payment is held');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'held_funds'), 500000::bigint,
  '1a: the platform now owes the customer''s 5,000.00 to somebody');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_pending'), 485500::bigint,
  'and expects 4,855.00 from the gateway, the fee having been kept');
SELECT is(private.confirm_payment('flutterwave', 'FLW-REF-0001', 500000, 14500),
  'assigned'::public.job_status,
  'a replayed webhook is not an error — the gateway retries by design');
SELECT is((SELECT count(*)::int FROM ledger.transactions WHERE kind = 'payment_captured'), 1,
  'and the money is not captured twice');

-- 1b: the gateway settles.
SELECT ok(private.record_gateway_settlement((SELECT id FROM pm WHERE name = 'p'), 485500) > 0,
  '1b: the settlement report moves it into the merchant balance');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_pending'), 0::bigint, 'leaving nothing pending');

-- ---------------------------------------------------------------------------
-- Transition 18 and money-flows 1c. The job is confirmed directly here: the full
-- en_route → arrived → in_progress → completed chain is 14_jobs_test's subject, not this file's.
-- ---------------------------------------------------------------------------
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM pm WHERE name = 'r');
UPDATE public.jobs SET confirmed_at = now() WHERE request_id = (SELECT id FROM pm WHERE name = 'r');
SELECT is(private.recognise_due_earnings(), 0,
  'a job confirmed a moment ago is inside the dispute window, and its money stays held');
UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT id FROM pm WHERE name = 'r');
SELECT is(private.recognise_due_earnings(), 1, 'once the window has passed, earnings are released');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM pm WHERE name = 'r')),
  'settlement_pending'::public.job_status, 'and the job moves on');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'd2222222-2222-4222-8222-777777777777'
             AND a.account_type = 'provider_earnings'), 423000::bigint,
  'the provider is owed 4,230.00 — net less the fee they bear (ADR-0003)');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 62500::bigint,
  'the platform recognised 625.00');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'held_funds'), 0::bigint, 'and the hold is fully released');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0,
  'every posting on this job sums to zero');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0,
  'and the balances still match the entries');
SELECT is(private.recognise_due_earnings(), 0,
  'a settled job is not settled again');

-- The provider can see what is being held and paid on their own job.
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments), 1,
  'the provider reads the payment on their job, and nothing else');
SELECT is((SELECT (SELECT balance_minor FROM public.my_balances()
                   WHERE account_type = 'provider_earnings')), 423000::bigint,
  'and their own balance, positive: it is money owed to them, not a credit in our books');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A payment nobody completed.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pm VALUES ('r2', public.create_request(
  'key-pm-create-req-000000002', 'personal_assistance', 'Collect a document from the registry',
  'Ikoyi', 'standard', false, NULL, NULL, 6.4541, 3.4348));
SELECT public.publish_request((SELECT id FROM pm WHERE name = 'r2'), 'key-pm-publish-000000002');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pm VALUES ('o2', public.create_offer(
  'key-pm-offer-p-0000000002', (SELECT id FROM pm WHERE name = 'r2'), 300000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-777777777777", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-pm-accept-c-000000002', (SELECT id FROM pm WHERE name = 'o2'));
SELECT public.start_payment('key-pm-start-c-0000000003', (SELECT id FROM pm WHERE name = 'r2'));
RESET ROLE;
SELECT is(private.expire_payments(), 0, 'a fresh intent has not expired');
UPDATE public.payments SET expires_at = now() - interval '1 minute'
WHERE request_id = (SELECT id FROM pm WHERE name = 'r2');
SELECT is(private.expire_payments(), 1, 'one that ran out of time has');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM pm WHERE name = 'r2')),
  'agreed'::public.job_status,
  'and the job goes back to agreed, so the customer keeps the price they negotiated');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM pm WHERE name = 'r2')
             AND reason_code = 'payment_ttl_expired'), 1,
  'with the reason in the job''s own event log, like every other state change');

SELECT * FROM finish();
ROLLBACK;
