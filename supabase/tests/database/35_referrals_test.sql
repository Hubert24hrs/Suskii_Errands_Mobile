-- The referral programme (spec `referral_program`; `docs/plan/money-flows.md` postings 1c, 6a and
-- 7; OD-01, OD-02, OD-03).
--
-- The spine is the spec's own worked example, which the ledger has been asserting since part 1
-- with nobody on the other end of it: a 100.00 job, 12.50 commission, 87.50 net, and 2.5% of
-- that — 2.19, half-even — owed to whoever introduced the customer, funded by the platform so
-- the provider's 84.60 is untouched.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(54);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-222222222222', '2348000000301'),   -- customer (referred)
  ('e2222222-2222-4222-8222-222222222222', '2348000000302'),   -- provider
  ('e3333333-3333-4333-8333-222222222222', '2348000000303'),   -- referrer of the customer
  ('e4444444-4444-4444-8444-222222222222', '2348000000304'),   -- referrer of the provider
  ('e5555555-5555-4555-8555-222222222222', '2348000000305'),   -- shares a handset with e3
  ('e6666666-6666-4666-8666-222222222222', '2348000000306'),   -- dispute officer
  ('e7777777-7777-4777-8777-222222222222', '2348000000307');   -- second customer
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id IN ('e1111111-1111-4111-8111-222222222222',
                  'e7777777-7777-4777-8777-222222222222');
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'e2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('e3333333-3333-4333-8333-222222222222',
                  'e4444444-4444-4444-8444-222222222222',
                  'e5555555-5555-4555-8555-222222222222',
                  'e6666666-6666-4666-8666-222222222222');
INSERT INTO public.provider_profiles (user_id) VALUES ('e2222222-2222-4222-8222-222222222222');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('e6666666-6666-4666-8666-222222222222', ARRAY['dispute_officer']::public.admin_role[]);

CREATE TEMP TABLE rf (name text PRIMARY KEY, val text);
GRANT ALL ON rf TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Codes.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rf VALUES ('code3', public.my_referral_code());
SELECT matches((SELECT val FROM rf WHERE name = 'code3'), '^[A-HJ-NP-Z2-9]{8}$',
  'a code is eight characters with no letter that can be read as a digit');
SELECT is(public.my_referral_code(), (SELECT val FROM rf WHERE name = 'code3'),
  'asking twice gives the same code, not a second one');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e4444444-4444-4444-8444-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rf VALUES ('code4', public.my_referral_code());
RESET ROLE;
SELECT isnt((SELECT val FROM rf WHERE name = 'code4'), (SELECT val FROM rf WHERE name = 'code3'),
  'two people do not share a code');

-- Nobody browses the table by code: that would make it a directory of who invited whom.
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.referral_codes), 0,
  'and nobody can read anybody else''s');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Attribution.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.claim_referral_code('key-ref-self-00000001', %L)$$,
         (SELECT val FROM rf WHERE name = 'code3')),
  'P0001', 'ERR_REFERRAL_SELF', 'nobody refers themselves');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.claim_referral_code('key-ref-junk-00000001', 'ZZZZZZZZ')$$,
  'P0001', 'ERR_REFERRAL_CODE_NOT_FOUND', 'a code nobody owns is not a code');
INSERT INTO rf VALUES ('ref1', public.claim_referral_code('key-ref-c1-000000001',
  (SELECT val FROM rf WHERE name = 'code3'))::text);
SELECT ok((SELECT val FROM rf WHERE name = 'ref1') IS NOT NULL,
  'the customer is attributed to their referrer');
SELECT throws_ok(
  format($$SELECT public.claim_referral_code('key-ref-c1-000000002', %L)$$,
         (SELECT val FROM rf WHERE name = 'code4')),
  'P0001', 'ERR_REFERRAL_ALREADY_ATTRIBUTED',
  'and cannot be re-attributed, which is what makes single-level structural');
RESET ROLE;

SELECT is((SELECT blocked_at FROM public.referrals
           WHERE id = (SELECT val FROM rf WHERE name = 'ref1')::uuid), NULL,
  'a clean attribution is not blocked');
SELECT is((SELECT expires_at FROM public.referrals
           WHERE id = (SELECT val FROM rf WHERE name = 'ref1')::uuid), NULL,
  'and runs for the lifetime of the account, which is OD-02''s default');

-- The provider's own referrer, so one job can owe two people (OD-03).
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.claim_referral_code('key-ref-p1-000000001',
  (SELECT val FROM rf WHERE name = 'code4')) IS NOT NULL,
  'the provider was introduced by somebody too');
RESET ROLE;

-- Self-referral through two accounts on one handset. Accepted and silently blocked: the record
-- is the point, and telling somebody which signal caught them is a free oracle.
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash) VALUES
  ('e3333333-3333-4333-8333-222222222222', 'android', sha256('one-handset'::bytea)),
  ('e5555555-5555-4555-8555-222222222222', 'android', sha256('one-handset'::bytea));
SELECT set_config('request.jwt.claims',
  '{"sub": "e5555555-5555-4555-8555-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.claim_referral_code('key-ref-dev-00000001',
  (SELECT val FROM rf WHERE name = 'code3')) IS NOT NULL,
  'a shared handset is accepted, not refused');
RESET ROLE;
SELECT is((SELECT blocked_reason_key FROM public.referrals
           WHERE referee_id = 'e5555555-5555-4555-8555-222222222222'),
  'referral_shared_device', 'and blocked, so it earns nothing');
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE rule_key = 'referral_shared_device'), 1,
  'with the risk engine told, which is its whole posture (OD-25)');

-- ---------------------------------------------------------------------------
-- A job, settled, and the spec's own arithmetic.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.settled_job(p_tag text, p_customer text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_provider constant text :=
    '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}';
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_customer, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_request := public.create_request('key-rf-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-rf-pub-' || p_tag);
  PERFORM set_config('request.jwt.claims', v_provider, true);
  v_offer := public.create_offer('key-rf-off-' || p_tag, v_request, p_amount, NULL);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_customer, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  PERFORM public.accept_offer('key-rf-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment FROM public.start_payment('key-rf-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLWR-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLWR-' || p_tag, p_amount, 290);
  RETURN v_request;
END $fn$;

INSERT INTO rf VALUES ('job1', pg_temp.settled_job('a-00000001',
  'e1111111-1111-4111-8111-222222222222', 10000)::text);
RESET ROLE;

-- The trigger, on the transition that paid for the job.
SELECT is((SELECT count(*)::int FROM public.referral_commissions
           WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND status = 'pending'), 2,
  'both sides were introduced, so two commissions are anticipated (OD-03)');
SELECT is((SELECT count(*)::int FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND rc.posted_at IS NOT NULL), 0,
  'and nothing is on the books yet: the job has not been done');

UPDATE public.requests SET status = 'confirmed'
WHERE id = (SELECT val FROM rf WHERE name = 'job1')::uuid;
INSERT INTO public.job_events (request_id, from_status, to_status, actor_kind)
VALUES ((SELECT val FROM rf WHERE name = 'job1')::uuid, 'completed_by_provider', 'confirmed',
        'customer');
SELECT is((SELECT count(*)::int FROM public.referral_commissions
           WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND status = 'earned'), 2,
  'confirming the job earns them, which is the spec''s second state');

UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid;
SELECT is(private.recognise_due_earnings(), 1, 'the dispute window passes and earnings settle');

-- ---------------------------------------------------------------------------
-- money-flows 1c, with its last two lines.
-- ---------------------------------------------------------------------------
SELECT is((SELECT amount_minor FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND rc.referrer_id = 'e3333333-3333-4333-8333-222222222222'), 219::bigint,
  '2.19: 2.5% of the 87.50 net, half-even — the spec''s own worked example');
SELECT is((SELECT base_minor FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND rc.referrer_id = 'e3333333-3333-4333-8333-222222222222'), 8750::bigint,
  'and the base is net — gross less commission — not net less the gateway fee');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'e3333333-3333-4333-8333-222222222222'
             AND a.account_type = 'referral_earnings'), 219::bigint,
  'the referrer is owed it');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_referral_expense'), 438::bigint,
  'the platform funded both of them — 4.38, OD-01''s default');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'e2222222-2222-4222-8222-222222222222'
             AND a.account_type = 'provider_earnings'), 8460::bigint,
  'and the provider still has exactly 84.60: a referral never comes out of their share');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 1250::bigint,
  'commission is still 12.50 on the books; 10.31 of it survives the two referrals');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');

-- ---------------------------------------------------------------------------
-- The hold, and what it is for.
-- ---------------------------------------------------------------------------
SELECT is((SELECT status FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND rc.referrer_id = 'e3333333-3333-4333-8333-222222222222'),
  'holding'::public.referral_commission_status,
  'posted, and holding: the money is owed before it is withdrawable');
SELECT is(private.available_minor('e3333333-3333-4333-8333-222222222222',
                                  'referral_earnings', 'NGN'), 0::bigint,
  'so none of it is available yet — otherwise the fraud hold would be a label');
SELECT is(private.mature_referral_commissions(), 0, 'and it does not mature early');

UPDATE public.referral_commissions SET available_at = now() - interval '1 minute'
WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid;
SELECT is(private.mature_referral_commissions(), 2, 'after 72 hours it matures');
SELECT is(private.available_minor('e3333333-3333-4333-8333-222222222222',
                                  'referral_earnings', 'NGN'), 219::bigint,
  'and now it can be withdrawn — posting 9 finally has something to pay out');

-- A flag raised after the money was posted is exactly what the hold exists for.
SELECT is((SELECT count(*)::int FROM public.referral_commissions
           WHERE referrer_id = 'e4444444-4444-4444-8444-222222222222'
             AND status = 'available'), 1, 'the second referrer matured too');

-- ---------------------------------------------------------------------------
-- Clawback: money-flows 7.
-- ---------------------------------------------------------------------------
SELECT ok(private.record_chargeback(
  (SELECT id FROM public.payments
   WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid AND kind = 'job'),
  1500, 'chargeback') IS NOT NULL, '7: the card issuer takes the money back');
SELECT is((SELECT count(*)::int FROM public.referral_commissions
           WHERE request_id = (SELECT val FROM rf WHERE name = 'job1')::uuid
             AND status = 'reversed'), 2, 'both commissions are clawed back');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'e3333333-3333-4333-8333-222222222222'
             AND a.account_type = 'referral_earnings'), 0::bigint,
  'and the referrer is owed nothing');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_referral_expense'), 0::bigint,
  'the expense is reversed with it');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'and it balances');

-- ---------------------------------------------------------------------------
-- A campaign, and the budget it cannot exceed.
-- ---------------------------------------------------------------------------
INSERT INTO public.referral_campaigns (country_code, name, rate_bps, currency, budget_minor,
                                       starts_at, ends_at)
VALUES ('NG', 'Launch boost', 1000, 'NGN', 300, now() - interval '1 day',
        now() + interval '30 days');
SELECT is((SELECT rate_bps FROM private.referral_rate('NG', 'NGN')), 1000,
  'a live campaign beats the country pack''s rate');

SELECT set_config('request.jwt.claims',
  '{"sub": "e7777777-7777-4777-8777-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.claim_referral_code('key-ref-c2-000000001',
  (SELECT val FROM rf WHERE name = 'code3')) IS NOT NULL, 'a second customer joins');
RESET ROLE;

INSERT INTO rf VALUES ('job2', pg_temp.settled_job('b-00000001',
  'e7777777-7777-4777-8777-222222222222', 10000)::text);
RESET ROLE;
UPDATE public.requests SET status = 'confirmed'
WHERE id = (SELECT val FROM rf WHERE name = 'job2')::uuid;
UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT val FROM rf WHERE name = 'job2')::uuid;
SELECT is(private.recognise_due_earnings(), 1, 'and their job settles');

-- 10% of 87.50 is 8.75, but the campaign only has 3.00 left. It pays 3.00 and stops.
SELECT is((SELECT amount_minor FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job2')::uuid
             AND rc.referrer_id = 'e3333333-3333-4333-8333-222222222222'), 300::bigint,
  'a campaign pays what is left of its budget and not a unit more');
SELECT is((SELECT spent_minor FROM public.referral_campaigns), 300::bigint,
  'the budget is spent exactly, enforced by the table not by a convention');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it still balances');

-- The rate is resolved per referrer, so the campaign exhausting partway through one job leaves
-- the second referrer on the country pack's 2.5%. That is the honest answer: a campaign that has
-- run out is not a campaign, and the programme underneath it has not stopped.
SELECT is((SELECT amount_minor FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM rf WHERE name = 'job2')::uuid
             AND rc.referrer_id = 'e4444444-4444-4444-8444-222222222222'), 219::bigint,
  'and once it is spent the country pack''s rate takes over again');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_referral_expense'), 519::bigint,
  'so the platform funded 3.00 at the boosted rate and 2.19 at the base one');

-- ---------------------------------------------------------------------------
-- Who may see what.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.referral_commissions), 0,
  'a referee cannot see what their referrer earned from them');
SELECT is((SELECT count(*)::int FROM public.referrals), 1,
  'but can see that they were attributed, which is a fact about them');
SELECT throws_ok($$SELECT budget_minor FROM public.referral_campaigns LIMIT 1$$,
  '42501', NULL, 'and nobody reads a campaign''s budget: it says when to hurry');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.my_referrals()), 2,
  'the referrer sees their two live invitations');
SELECT is((SELECT count(*)::int FROM public.my_referrals()
           WHERE referral_id IN (SELECT id FROM public.referrals
                                 WHERE referee_id = 'e5555555-5555-4555-8555-222222222222')), 0,
  'and not the blocked one, which would tell them which rule caught it');
SELECT ok((SELECT count(*)::int FROM public.my_referral_summary()) > 0,
  'and their earnings, grouped the way the dashboard shows them');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Too late.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('e8888888-8888-4888-8888-222222222222', '2348000000308');
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e8888888-8888-4888-8888-222222222222';
SELECT set_config('request.jwt.claims',
  '{"sub": "e8888888-8888-4888-8888-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.publish_request(
  public.create_request('key-rf-late-000000001', 'personal_assistance', 'Deliver a parcel',
                        'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711),
  'key-rf-latep-00000001');
SELECT throws_ok(
  format($$SELECT public.claim_referral_code('key-ref-late-00000001', %L)$$,
         (SELECT val FROM rf WHERE name = 'code3')),
  'P0001', 'ERR_REFERRAL_TOO_LATE',
  'a code typed after a first errand is somebody backdating an invitation');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.claim_referral_code('key-ref-late-00000002', %L)$$,
         (SELECT val FROM rf WHERE name = 'code3')),
  'P0001', 'ERR_REFERRAL_ALREADY_ATTRIBUTED',
  'and somebody already attributed stays with the person who introduced them');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Structure.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.referrals (referrer_id, referee_id, code)
    VALUES ('e3333333-3333-4333-8333-222222222222',
            'e3333333-3333-4333-8333-222222222222', 'AAAAAAAA')$$,
  '23514', NULL, 'the table itself refuses a self-referral');
SELECT throws_ok(
  $$UPDATE public.referral_campaigns SET spent_minor = budget_minor + 1$$,
  '23514', NULL, 'and a campaign cannot be pushed past its budget by any path');

SELECT * FROM finish();
ROLLBACK;
