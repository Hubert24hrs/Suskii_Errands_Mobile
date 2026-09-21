-- Cancelling a paid job, and refunds (`docs/plan/money-flows.md` 5a, 5b, 5c; OD-08, OD-19).
--
-- Two ₦5,000.00 jobs and a third: one cancelled early, one cancelled after the provider set off,
-- one cancelled by the provider. Who cancels, and when, decides who pays.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(31);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-666666666666', '2348000000231'),   -- customer
  ('e2222222-2222-4222-8222-666666666666', '2348000000232'),   -- provider
  ('e3333333-3333-4333-8333-666666666666', '2348000000233');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e1111111-1111-4111-8111-666666666666';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'e2222222-2222-4222-8222-666666666666';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'e3333333-3333-4333-8333-666666666666';
INSERT INTO public.provider_profiles (user_id) VALUES ('e2222222-2222-4222-8222-666666666666');

CREATE TEMP TABLE cn (name text PRIMARY KEY, id uuid);
GRANT ALL ON cn TO authenticated, service_role;

-- A helper for the shape repeated four times: request → offer → accept → pay → held. No role
-- switching in it, deliberately: every function it calls is SECURITY DEFINER, so who the caller
-- is comes from `request.jwt.claims` and not from the session role. The role blocks below are
-- where RLS is actually under test.
CREATE FUNCTION pg_temp.paid_job(p_tag text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_customer constant text :=
    '{"sub": "e1111111-1111-4111-8111-666666666666", "role": "authenticated", "aal": "aal1"}';
  v_provider constant text :=
    '{"sub": "e2222222-2222-4222-8222-666666666666", "role": "authenticated", "aal": "aal1"}';
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', v_customer, true);
  v_request := public.create_request('key-cn-req-' || p_tag, 'personal_assistance',
    'Deliver documents across town', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-cn-pub-' || p_tag);

  PERFORM set_config('request.jwt.claims', v_provider, true);
  v_offer := public.create_offer('key-cn-off-' || p_tag, v_request, p_amount, NULL);

  PERFORM set_config('request.jwt.claims', v_customer, true);
  PERFORM public.accept_offer('key-cn-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment
  FROM public.start_payment('key-cn-pay-' || p_tag, v_request);

  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLW-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-' || p_tag, p_amount, 14500);
  RETURN v_request;
END $fn$;

-- ---------------------------------------------------------------------------
-- 5b: the customer changes their mind before the provider has gone anywhere.
-- ---------------------------------------------------------------------------
INSERT INTO cn VALUES ('early', pg_temp.paid_job('early-00001', 500000));
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cn WHERE name = 'early')),
  'assigned'::public.job_status, 'a paid job, assigned and not yet under way');

SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.cancel_job('key-cn-x-000000000001', %L, 'changed_my_mind')$$,
    (SELECT id FROM cn WHERE name = 'early')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'a stranger cannot cancel somebody else''s job');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.cancel_job('key-cn-bad-00000000001', %L, 'Changed My Mind!')$$,
    (SELECT id FROM cn WHERE name = 'early')),
  '22023', 'ERR_INVALID_ARGUMENT', 'the reason is a key, not a sentence somebody typed');
SELECT is((SELECT fee_minor FROM public.cancel_job('key-cn-early-000000001',
             (SELECT id FROM cn WHERE name = 'early'), 'changed_my_mind')), 0::bigint,
  'cancelling before the provider sets off costs the customer nothing (OD-19)');
SELECT is((SELECT refund_minor FROM public.cancel_job('key-cn-early-000000001',
             (SELECT id FROM cn WHERE name = 'early'), 'changed_my_mind')), 500000::bigint,
  'and the whole 5,000.00 goes back — the replay of the key answering the same');
RESET ROLE;

SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cn WHERE name = 'early')),
  'cancelled'::public.job_status, 'the job is cancelled');
SELECT is((SELECT status FROM public.payments
           WHERE request_id = (SELECT id FROM cn WHERE name = 'early')),
  'refunded'::public.payment_status, 'the payment is marked refunded');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'refunds_payable'), 500000::bigint,
  '5b: the platform owes the customer 5,000.00 from the moment it cancelled');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 14500::bigint,
  'and the 145.00 collection fee stays a platform cost, because nobody was at fault (OD-08)');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- 5c: the gateway confirms the money actually went back.
SELECT ok(private.execute_refund((SELECT id FROM public.refunds LIMIT 1), 'FLW-RFND-0001') > 0,
  '5c: the refund executes at the gateway');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'refunds_payable'), 0::bigint,
  'and the platform no longer owes it');
SELECT is(private.execute_refund((SELECT id FROM public.refunds LIMIT 1), 'FLW-RFND-0001'), NULL,
  'a retried confirmation moves nothing a second time');

-- ---------------------------------------------------------------------------
-- 5a: the customer cancels after the provider has set off.
-- ---------------------------------------------------------------------------
INSERT INTO cn VALUES ('late', pg_temp.paid_job('late-000001', 500000));
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.set_job_status('key-cn-enroute-0000001', (SELECT id FROM cn WHERE name = 'late'),
            'en_route'), 'en_route'::public.job_status, 'the provider sets off');
RESET ROLE;

SELECT is(private.cancellation_fee_minor(500000, 'assigned', false), 0::bigint,
  'the fee is a function of when, not of who asked');
SELECT is(private.cancellation_fee_minor(500000, 'en_route', false), 50000::bigint,
  '10% once the trip has started (OD-19''s default, and it is remote_config)');
SELECT is(private.cancellation_fee_minor(500000, 'en_route', true), 0::bigint,
  'and nothing at all when the provider is the one cancelling');

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT refund_minor FROM public.cancel_job('key-cn-late-0000000001',
             (SELECT id FROM cn WHERE name = 'late'), 'no_longer_needed')), 435500::bigint,
  '5a: 5,000.00 less the 500.00 fee and the 145.00 gateway fee comes back');
RESET ROLE;
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 6250::bigint,
  'the platform takes its 12.5% of the compensation — 62.50 (OD-19)');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'e2222222-2222-4222-8222-666666666666'
             AND a.account_type = 'provider_earnings'), 43750::bigint,
  'and the provider keeps 437.50 for the trip they actually made');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 14500::bigint,
  'the second job''s collection fee is recovered from the refund, so only the first remains a cost');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'and it balances');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0,
  'with the balances still matching the entries');

-- ---------------------------------------------------------------------------
-- The provider cancels. The customer pays nothing for a job that did not happen.
-- ---------------------------------------------------------------------------
INSERT INTO cn VALUES ('byprov', pg_temp.paid_job('byprov-0001', 500000));
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-cn-enroute-0000002', (SELECT id FROM cn WHERE name = 'byprov'),
  'en_route');
SELECT is((SELECT refund_minor FROM public.cancel_job('key-cn-prov-0000000001',
             (SELECT id FROM cn WHERE name = 'byprov'), 'vehicle_broke_down')), 500000::bigint,
  'a provider who abandons a job refunds the customer in full, however late it is');
RESET ROLE;
SELECT is((SELECT (payload ->> 'fee_minor')::bigint FROM public.job_events
           WHERE request_id = (SELECT id FROM cn WHERE name = 'byprov')
             AND to_status = 'cancelled'), 0::bigint,
  'and charges nothing — the cancellation rate is the consequence, not a fee');
SELECT is((SELECT actor_kind FROM public.job_events
           WHERE request_id = (SELECT id FROM cn WHERE name = 'byprov')
             AND to_status = 'cancelled'), 'provider'::public.job_actor_kind,
  'the event records who did it, which is what the reputation job reads');

-- ---------------------------------------------------------------------------
-- What cancellation is not for.
-- ---------------------------------------------------------------------------
INSERT INTO cn VALUES ('done', pg_temp.paid_job('done-000001', 500000));
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM cn WHERE name = 'done');
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.cancel_job('key-cn-done-0000000001', %L, 'i_changed_my_mind')$$,
    (SELECT id FROM cn WHERE name = 'done')),
  'P0001', 'ERR_JOB_NOT_CANCELLABLE',
  'once the work is confirmed, cancelling is not the remedy — a dispute is');
RESET ROLE;

-- A refund the gateway could not make. The platform still owes it, which is the truthful
-- position; the ledger does not pretend otherwise.
SELECT ok(private.fail_refund(
    (SELECT id FROM public.refunds WHERE status = 'pending' ORDER BY created_at LIMIT 1),
    'gateway_declined'), 'a refund can fail at the gateway');
SELECT is((SELECT count(*)::int FROM ledger.transactions WHERE kind = 'refund'), 1,
  'and nothing is posted for it: the money has not moved, so the books do not say it has');

-- The people it concerns can read it.
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) FROM public.refunds) >= 3, 'the customer sees their own refunds');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-666666666666", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.refunds), 0, 'and a stranger sees none of them');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
