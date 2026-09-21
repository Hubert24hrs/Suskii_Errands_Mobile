-- Payout accounts, payouts and withdrawals (`docs/plan/money-flows.md` postings 1d, 7, 8 and 9;
-- ERD §6; country pack `payments.*`; OD-10).
--
-- A 100.00 job leaves the provider owed 84.60. Paying it out costs a 0.50 transfer fee they bear;
-- a referral withdrawal costs one the platform bears. A reversal puts the whole 84.60 back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(44);

INSERT INTO auth.users (id, phone) VALUES
  ('c9111111-1111-4111-8111-222222222222', '2348000000271'),   -- customer
  ('c9222222-2222-4222-8222-222222222222', '2348000000272'),   -- provider
  ('c9333333-3333-4333-8333-222222222222', '2348000000273'),   -- finance officer
  ('c9444444-4444-4444-8444-222222222222', '2348000000274'),   -- second finance officer
  ('c9555555-5555-4555-8555-222222222222', '2348000000275');   -- shares a bank account
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'c9111111-1111-4111-8111-222222222222';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'c9222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('c9333333-3333-4333-8333-222222222222',
                  'c9444444-4444-4444-8444-222222222222',
                  'c9555555-5555-4555-8555-222222222222');
INSERT INTO public.provider_profiles (user_id) VALUES ('c9222222-2222-4222-8222-222222222222');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('c9333333-3333-4333-8333-222222222222', ARRAY['finance_officer']::public.admin_role[]),
  ('c9444444-4444-4444-8444-222222222222', ARRAY['finance_officer']::public.admin_role[]);

CREATE TEMP TABLE po (name text PRIMARY KEY, id uuid);
GRANT ALL ON po TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Where money is sent.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c9222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.add_payout_account('key-po-acct-bad-00001', 'bank', '058', 'A Provider',
      '\xdeadbeef'::bytea, '\x1234'::bytea)$$,
  '22023', 'ERR_INVALID_ARGUMENT',
  'a blind index that is not 32 bytes was not produced by the key we expect');
INSERT INTO po VALUES ('acct', public.add_payout_account('key-po-acct-p-000001', 'bank', '058',
  'A Provider', '\xdeadbeef'::bytea, sha256('0123456789'::bytea)));
SELECT ok((SELECT id FROM po WHERE name = 'acct') IS NOT NULL,
  'the provider registers where to be paid');
SELECT is((SELECT verified_at FROM public.payout_accounts
           WHERE id = (SELECT id FROM po WHERE name = 'acct')), NULL,
  'unverified until the bank says whose account it is');
SELECT throws_ok($$SELECT account_ciphertext FROM public.payout_accounts LIMIT 1$$,
  '42501', NULL,
  'and nobody reads the number back, not even the person who typed it');
RESET ROLE;

-- Somebody else registering the same account is flagged, not refused: two people may genuinely
-- share one, and refusing would strand somebody with no way to be paid.
SELECT set_config('request.jwt.claims',
  '{"sub": "c9555555-5555-4555-8555-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.add_payout_account('key-po-acct-x-000001', 'bank', '058', 'Someone Else',
  '\xfeedface'::bytea, sha256('0123456789'::bytea)) IS NOT NULL,
  'a shared account is accepted');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.fraud_flags WHERE rule_key = 'payout_account_reuse'),
  1, 'and the risk engine is told, which is its whole posture (OD-25)');

-- ---------------------------------------------------------------------------
-- A job, settled.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.settled_job(p_tag text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_customer constant text :=
    '{"sub": "c9111111-1111-4111-8111-222222222222", "role": "authenticated", "aal": "aal1"}';
  v_provider constant text :=
    '{"sub": "c9222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}';
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', v_customer, true);
  v_request := public.create_request('key-po-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-po-pub-' || p_tag);
  PERFORM set_config('request.jwt.claims', v_provider, true);
  v_offer := public.create_offer('key-po-off-' || p_tag, v_request, p_amount, NULL);
  PERFORM set_config('request.jwt.claims', v_customer, true);
  PERFORM public.accept_offer('key-po-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment FROM public.start_payment('key-po-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLW-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-' || p_tag, p_amount, 290);
  PERFORM private.record_gateway_settlement(v_payment, p_amount - 290);
  UPDATE public.requests SET status = 'confirmed' WHERE id = v_request;
  UPDATE public.jobs SET confirmed_at = now() - interval '2 days' WHERE request_id = v_request;
  PERFORM private.recognise_due_earnings();
  RETURN v_request;
END $fn$;

INSERT INTO po VALUES ('r', pg_temp.settled_job('r-00000001', 10000));
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c9222222-2222-4222-8222-222222222222'
             AND a.account_type = 'provider_earnings'), 8460::bigint,
  'the provider is owed 84.60');

SELECT is(private.pay_out_settled_jobs(), 0,
  'nothing is paid to an unverified account: a typo there becomes a stranger''s windfall');
SELECT ok(private.record_payout_account_verification((SELECT id FROM po WHERE name = 'acct'),
            true, 'A PROVIDER'), 'the bank confirms whose account it is');
SELECT is(private.pay_out_settled_jobs(), 1, 'and now the payout is instructed');
SELECT is((SELECT status FROM public.payouts WHERE request_id = (SELECT id FROM po WHERE name = 'r')),
  'requested'::public.payout_status,
  'as an instruction, not a transfer: nothing here calls a bank');
INSERT INTO po VALUES ('pay', (SELECT id FROM public.payouts
                               WHERE request_id = (SELECT id FROM po WHERE name = 'r')));

-- ---------------------------------------------------------------------------
-- 1d: it lands.
-- ---------------------------------------------------------------------------
SELECT is(private.record_payout_result((SELECT id FROM po WHERE name = 'pay'), 'succeeded',
            'flutterwave', 'FLW-PAYOUT-01', 50),
  'succeeded'::public.payout_status, '1d: the transfer succeeds');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c9222222-2222-4222-8222-222222222222'
             AND a.account_type = 'provider_earnings'), 0::bigint,
  'the provider is owed nothing more');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_available'), 1250::bigint,
  'and the platform is left holding exactly its 12.50 — the provider bore the 0.50 fee (OD-10)');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM po WHERE name = 'r')),
  'settled'::public.job_status, 'the job is settled');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- ---------------------------------------------------------------------------
-- 8: the bank sends it back hours later.
-- ---------------------------------------------------------------------------
SELECT is(private.record_payout_result((SELECT id FROM po WHERE name = 'pay'), 'reversed',
            NULL, NULL, 0, 'account_closed'),
  'reversed'::public.payout_status, '8: the transfer reverses');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c9222222-2222-4222-8222-222222222222'
             AND a.account_type = 'provider_earnings'), 8460::bigint,
  'the provider is owed the whole 84.60 again');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 50::bigint,
  'and the platform absorbs the 0.50 it cost to fail, because they did nothing wrong');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- ---------------------------------------------------------------------------
-- Withdrawals, and the approvals the country pack asks for.
-- ---------------------------------------------------------------------------
-- A referral balance, posted directly: referrals themselves are not built yet.
SELECT ok(ledger.post('adjustment', 'NGN', 'key-po-seed-referral-1', jsonb_build_array(
    jsonb_build_object('owner_kind', 'user', 'owner_id', 'c9222222-2222-4222-8222-222222222222',
                       'account_type', 'referral_earnings', 'amount_minor', -60000000),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_referral_expense',
                       'amount_minor', 60000000))) > 0,
  'a referral balance of 600,000.00 is seeded for the withdrawal tests');

SELECT set_config('request.jwt.claims',
  '{"sub": "c9222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.available_balance('referral_earnings', 'NGN'), 60000000::bigint,
  'and the provider can see it');
SELECT throws_ok(
  format($$SELECT public.request_withdrawal('key-po-wd-small-00001', 'referral_earnings', 500, %L)$$,
    (SELECT id FROM po WHERE name = 'acct')),
  'P0001', 'ERR_WITHDRAWAL_BELOW_MINIMUM', 'a withdrawal below the country minimum is refused');
SELECT throws_ok(
  format($$SELECT public.request_withdrawal('key-po-wd-big-000001', 'referral_earnings',
      99000000, %L)$$, (SELECT id FROM po WHERE name = 'acct')),
  'P0001', 'ERR_INSUFFICIENT_BALANCE', 'and one above the balance is too');
SELECT is(public.request_withdrawal('key-po-wd-ok-0000001', 'referral_earnings', 60000000,
            (SELECT id FROM po WHERE name = 'acct')),
  'awaiting_approval'::public.withdrawal_status,
  '600,000.00 is over the single-approver threshold, so it waits for a person');
SELECT is(public.available_balance('referral_earnings', 'NGN'), 0::bigint,
  'and the money is no longer available: in flight is not available again');
RESET ROLE;
INSERT INTO po VALUES ('wd', (SELECT id FROM public.withdrawals LIMIT 1));

SELECT set_config('request.jwt.claims',
  '{"sub": "c9222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.approve_withdrawal('key-po-appr-self-0001', %L, true)$$,
    (SELECT id FROM po WHERE name = 'wd')),
  '42501', 'ERR_PERMISSION_DENIED', 'the person withdrawing does not approve their own');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c9333333-3333-4333-8333-222222222222", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.approve_withdrawal('key-po-appr-f1-000001', (SELECT id FROM po WHERE name = 'wd'),
            true), 'approved'::public.withdrawal_status, 'one finance officer signs it off');
SELECT throws_ok(
  format($$SELECT public.approve_withdrawal('key-po-appr-f1-000002', %L, true)$$,
    (SELECT id FROM po WHERE name = 'wd')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and it cannot be approved twice');
RESET ROLE;

SELECT is(private.dispatch_approved_withdrawals(), 1, 'the approved withdrawal becomes a payout');
SELECT is((SELECT status FROM public.withdrawals WHERE id = (SELECT id FROM po WHERE name = 'wd')),
  'processing'::public.withdrawal_status, 'and the withdrawal is processing');
INSERT INTO po VALUES ('wpay', (SELECT id FROM public.payouts
                                WHERE withdrawal_id = (SELECT id FROM po WHERE name = 'wd')));

-- ---------------------------------------------------------------------------
-- 9: a referral payout, where the platform pays the transfer fee.
-- ---------------------------------------------------------------------------
SELECT is(private.record_payout_result((SELECT id FROM po WHERE name = 'wpay'), 'succeeded',
            'flutterwave', 'FLW-PAYOUT-02', 5000),
  'succeeded'::public.payout_status, '9: the referral payout lands');
SELECT is((SELECT status FROM public.withdrawals WHERE id = (SELECT id FROM po WHERE name = 'wd')),
  'paid'::public.withdrawal_status, 'the withdrawal is paid');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c9222222-2222-4222-8222-222222222222'
             AND a.account_type = 'referral_earnings'), 0::bigint,
  'the referrer''s balance clears');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 5050::bigint,
  'and the platform absorbed this transfer fee too — a referral payout is small enough that the
   fee would eat it (OD-10)');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0, 'and reconciles');

-- ---------------------------------------------------------------------------
-- 7: a chargeback, after everything has been paid.
-- ---------------------------------------------------------------------------
INSERT INTO po VALUES ('r2', pg_temp.settled_job('r2-0000001', 10000));
SELECT ok(private.record_chargeback(
    (SELECT id FROM public.payments WHERE request_id = (SELECT id FROM po WHERE name = 'r2')),
    1500, 'customer_claims_fraud') > 0, '7: the gateway takes the charge back, plus its own fee');
SELECT is((SELECT count(*)::int FROM public.fraud_flags WHERE rule_key = 'payment_chargeback'), 1,
  'the payer is flagged for a person to look at, and not banned');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');
SELECT is((SELECT sum(e.amount_minor)::bigint FROM ledger.entries e), 0::bigint,
  'and the whole book still sums to zero');

-- ---------------------------------------------------------------------------
-- Who sees what.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c9555555-5555-4555-8555-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payouts), 0,
  'somebody else''s payouts are not visible');
SELECT is((SELECT count(*)::int FROM public.withdrawals), 0, 'nor their withdrawals');
SELECT is((SELECT count(*)::int FROM public.payout_accounts), 1,
  'and they see only the account they registered themselves');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
