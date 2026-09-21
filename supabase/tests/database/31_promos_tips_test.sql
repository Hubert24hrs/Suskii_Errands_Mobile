-- Promo codes and tips (`docs/plan/money-flows.md` postings 2, 4a and 4b; ERD §6).
--
-- The numbers are the doc's own: a 100.00 job with a 10.00 promo, charged at 90.00 with a 2.61
-- gateway fee. Commission is still 12.50 on the full price and the provider still gets 84.89, so
-- the platform's 10.00 discount is the platform's own expense.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(33);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-555555555555', '2348000000241'),   -- customer
  ('f2222222-2222-4222-8222-555555555555', '2348000000242'),   -- provider
  ('f3333333-3333-4333-8333-555555555555', '2348000000243');   -- another customer
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id IN ('f1111111-1111-4111-8111-555555555555',
                  'f3333333-3333-4333-8333-555555555555');
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'f2222222-2222-4222-8222-555555555555';
INSERT INTO public.provider_profiles (user_id) VALUES ('f2222222-2222-4222-8222-555555555555');

INSERT INTO public.promo_codes
  (code, country_code, currency, discount_kind, discount_value, budget_minor, per_user_limit)
VALUES ('WELCOME10', 'NG', 'NGN', 'fixed', 1000, 1500, 1);
INSERT INTO public.promo_codes
  (code, country_code, currency, discount_kind, discount_value, max_discount_minor)
VALUES ('HALFCAP', 'NG', 'NGN', 'percent', 5000, 800);
INSERT INTO public.promo_codes
  (code, country_code, currency, discount_kind, discount_value, ends_at)
VALUES ('LASTYEAR', 'NG', 'NGN', 'fixed', 500, now() - interval '1 day');

CREATE TEMP TABLE pt (name text PRIMARY KEY, id uuid);
GRANT ALL ON pt TO authenticated, service_role;

CREATE FUNCTION pg_temp.agreed_job(p_tag text, p_customer text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_request uuid;
  v_offer   uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    format('{"sub": "%s", "role": "authenticated", "aal": "aal1"}', p_customer), true);
  v_request := public.create_request('key-pt-req-' || p_tag, 'personal_assistance',
    'Collect a package', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-pt-pub-' || p_tag);

  PERFORM set_config('request.jwt.claims',
    '{"sub": "f2222222-2222-4222-8222-555555555555", "role": "authenticated", "aal": "aal1"}',
    true);
  v_offer := public.create_offer('key-pt-off-' || p_tag, v_request, p_amount, NULL);

  PERFORM set_config('request.jwt.claims',
    format('{"sub": "%s", "role": "authenticated", "aal": "aal1"}', p_customer), true);
  PERFORM public.accept_offer('key-pt-acc-' || p_tag, v_offer);
  RETURN v_request;
END $fn$;

-- ---------------------------------------------------------------------------
-- What the customer is told before they commit.
-- ---------------------------------------------------------------------------
INSERT INTO pt VALUES ('r', pg_temp.agreed_job('r-00000001',
  'f1111111-1111-4111-8111-555555555555', 10000));
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT discount_minor FROM public.preview_promo('WELCOME10',
             (SELECT id FROM pt WHERE name = 'r'))), 1000::bigint,
  'a fixed promo is worth its face value');
SELECT is((SELECT discount_minor FROM public.preview_promo('halfcap',
             (SELECT id FROM pt WHERE name = 'r'))), 800::bigint,
  'a percentage promo is capped where the campaign caps it — 50% of 100.00, capped at 8.00');
SELECT throws_ok(
  format($$SELECT public.preview_promo('NOSUCHCODE', %L)$$, (SELECT id FROM pt WHERE name = 'r')),
  'P0001', 'ERR_PROMO_INVALID', 'a code that does not exist says so');
SELECT throws_ok(
  format($$SELECT public.preview_promo('LASTYEAR', %L)$$, (SELECT id FROM pt WHERE name = 'r')),
  'P0001', 'ERR_PROMO_INVALID', 'and so does one that has expired');
SELECT is((SELECT count(code)::int FROM public.promo_codes), 2,
  'an expired code is not even listed: the read policy hides it');

-- ---------------------------------------------------------------------------
-- 4a: the charge is reduced.
-- ---------------------------------------------------------------------------
INSERT INTO pt VALUES ('p', (SELECT payment_id FROM public.start_payment(
  'key-pt-pay-r-00000001', (SELECT id FROM pt WHERE name = 'r'), 'card', 'WELCOME10')));
SELECT is((SELECT amount_minor FROM public.payments WHERE id = (SELECT id FROM pt WHERE name = 'p')),
  9000::bigint, '4a: the customer is charged 90.00, not 100.00');
SELECT is((SELECT discount_minor FROM public.payments
           WHERE id = (SELECT id FROM pt WHERE name = 'p')), 1000::bigint,
  'and the discount is recorded on the payment, not inferred later');
SELECT is((SELECT count(*)::int FROM public.promo_redemptions), 1, 'the redemption is recorded');
RESET ROLE;
SELECT is((SELECT spent_minor FROM public.promo_codes WHERE code = 'WELCOME10'), 1000::bigint,
  'and the budget moved in the same transaction');
SELECT is((SELECT commission_minor FROM public.jobs
           WHERE request_id = (SELECT id FROM pt WHERE name = 'r')), 1250::bigint,
  'commission is snapshotted on the full 100.00: the provider negotiated that, not 90.00');

-- The same customer cannot use it twice, and the budget stops the next person.
INSERT INTO pt VALUES ('r2', pg_temp.agreed_job('r2-0000001',
  'f1111111-1111-4111-8111-555555555555', 10000));
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.start_payment('key-pt-pay-r2-0000001', %L, 'card', 'WELCOME10')$$,
    (SELECT id FROM pt WHERE name = 'r2')),
  'P0001', 'ERR_PROMO_INVALID', 'one use per customer, and this one has used it');
RESET ROLE;
INSERT INTO pt VALUES ('r3', pg_temp.agreed_job('r3-0000001',
  'f3333333-3333-4333-8333-555555555555', 10000));
SELECT set_config('request.jwt.claims',
  '{"sub": "f3333333-3333-4333-8333-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.start_payment('key-pt-pay-r3-0000001', %L, 'card', 'WELCOME10')$$,
    (SELECT id FROM pt WHERE name = 'r3')),
  'P0001', 'ERR_PROMO_INVALID',
  'and the 15.00 budget has only 5.00 left, which will not cover another 10.00');
SELECT is((SELECT count(*)::int FROM public.promo_redemptions), 0,
  'a refused promo redeems nothing — this customer has none');
RESET ROLE;
SELECT is((SELECT spent_minor FROM public.promo_codes WHERE code = 'WELCOME10'), 1000::bigint,
  'and the budget is untouched by the attempt');

-- ---------------------------------------------------------------------------
-- 4b: the platform funds the discount, and the provider is paid on the full price.
-- ---------------------------------------------------------------------------
SELECT ok(private.record_gateway_checkout((SELECT id FROM pt WHERE name = 'p'),
            'flutterwave', 'FLW-PROMO-01', NULL), 'the checkout is written back');
SELECT is(private.confirm_payment('flutterwave', 'FLW-PROMO-01', 9000, 261),
  'assigned'::public.job_status, 'the 90.00 is captured and held');
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM pt WHERE name = 'r');
UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT id FROM pt WHERE name = 'r');
SELECT is(private.recognise_due_earnings(), 1, 'the dispute window passes and earnings release');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_promo_expense'), 1000::bigint,
  '4b: the 10.00 discount is the platform''s expense');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 1250::bigint,
  'commission is still 12.50, on the price that was negotiated');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'f2222222-2222-4222-8222-555555555555'
             AND a.account_type = 'provider_earnings'), 8489::bigint,
  'and the provider gets 84.89 — a promo never reduces provider earnings (spec)');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- ---------------------------------------------------------------------------
-- Posting 2: a tip, after the work, commission-free.
-- ---------------------------------------------------------------------------
INSERT INTO pt VALUES ('r4', pg_temp.agreed_job('r4-0000001',
  'f1111111-1111-4111-8111-555555555555', 10000));
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.add_tip('key-pt-tip-early-0001', %L, 500)$$,
    (SELECT id FROM pt WHERE name = 'r4')),
  'P0001', 'ERR_ILLEGAL_TRANSITION',
  'a tip before the work is a price negotiation conducted outside the offer');
SELECT throws_ok(
  format($$SELECT public.add_tip('key-pt-tip-zero-00001', %L, 0)$$,
    (SELECT id FROM pt WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and a tip of nothing is not a tip');
INSERT INTO pt VALUES ('tip', public.add_tip('key-pt-tip-00000001',
  (SELECT id FROM pt WHERE name = 'r'), 500));
SELECT is((SELECT kind FROM public.payments WHERE id = (SELECT id FROM pt WHERE name = 'tip')),
  'tip', 'a tip is its own charge, alongside the job''s');
RESET ROLE;

SELECT ok(private.record_gateway_checkout((SELECT id FROM pt WHERE name = 'tip'),
            'flutterwave', 'FLW-TIP-0001', NULL), 'with its own checkout');
SELECT is(private.confirm_payment('flutterwave', 'FLW-TIP-0001', 500, 15),
  'settlement_pending'::public.job_status,
  'confirming it moves no job state: the work was already over');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'f2222222-2222-4222-8222-555555555555'
             AND a.account_type = 'provider_earnings'), 8974::bigint,
  'the provider keeps 4.85 of the 5.00 tip — no commission, but the gateway still took its fee');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), -1250::bigint,
  'and the platform took nothing from it (spec: tips are commission-free)');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0, 'and reconciles');

-- Who sees the tip.
SELECT set_config('request.jwt.claims',
  '{"sub": "f2222222-2222-4222-8222-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.tips), 1, 'the provider sees they were tipped');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "f3333333-3333-4333-8333-555555555555", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.tips), 0, 'and nobody else does');
SELECT throws_ok($$SELECT spent_minor FROM public.promo_codes LIMIT 1$$,
  '42501', NULL,
  'a customer cannot read a promo''s budget, which would tell them exactly when to hurry');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
