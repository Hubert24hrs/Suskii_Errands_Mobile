-- What the audit of 2026-09-22 found, asserted so it cannot come back
-- (`docs/audit/AUDIT-2026-09-22.md`, findings T.1 to T.5).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(22);

-- ---------------------------------------------------------------------------
-- T.1 — every partitioned table has partitions ahead of it, and something watches.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT coalesce(array_agg(parent ORDER BY parent), '{}')
   FROM private.partition_health() WHERE months_ahead = 0),
  '{}'::text[],
  'every partitioned table has next month''s partition: the one that did not was webhook_events, '
  'and a gateway webhook arriving without one stops every payment');
SELECT ok((SELECT count(*)::int FROM private.partition_health()) >= 5,
  'and the check looks at all of them, not at audit.log alone');
SELECT is(private.record_partition_health(), 'ok',
  'so the health check is green rather than silent');
SELECT is((SELECT status FROM private.health_checks
           WHERE check_key = 'partitions' ORDER BY id DESC LIMIT 1), 'ok',
  'and it leaves a row somebody can read');

-- ---------------------------------------------------------------------------
-- Fixtures: a paid job, and a second one for the chargeback cases.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-555555555555', '2348000000601'),   -- customer
  ('d2222222-2222-4222-8222-555555555555', '2348000000602'),   -- provider
  ('d3333333-3333-4333-8333-555555555555', '2348000000603');   -- referrer
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-555555555555';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'd2222222-2222-4222-8222-555555555555';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'd3333333-3333-4333-8333-555555555555';
INSERT INTO public.provider_profiles (user_id) VALUES ('d2222222-2222-4222-8222-555555555555');

CREATE TEMP TABLE hd (name text PRIMARY KEY, val text);
GRANT ALL ON hd TO authenticated, service_role;

CREATE FUNCTION pg_temp.paid_job(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd1111111-1111-4111-8111-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_request := public.create_request('key-hd-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-hd-pub-' || p_tag);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd2222222-2222-4222-8222-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_offer := public.create_offer('key-hd-off-' || p_tag, v_request, 10000, NULL);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd1111111-1111-4111-8111-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  PERFORM public.accept_offer('key-hd-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment FROM public.start_payment('key-hd-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLWH-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLWH-' || p_tag, 10000, 290);
  RETURN v_request;
END $fn$;

INSERT INTO hd VALUES ('job1', pg_temp.paid_job('a-00000001')::text);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- T.2 — a refund asks to be paid, whichever function created it.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE event_type = 'refund.requested'), 0, 'no refund has been asked for yet');

-- A refund created by hand, as `resolve_dispute` and `release_item_float` both do: no function
-- emits anything, and the row alone has to be enough.
INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code,
                            requested_by)
SELECT p.id, p.request_id, 4000, p.currency, 'dispute_partial',
       'd1111111-1111-4111-8111-555555555555'
FROM public.payments p WHERE p.request_id = (SELECT val FROM hd WHERE name = 'job1')::uuid;

SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE event_type = 'refund.requested'), 1,
  'creating a refund row is what asks for it — no author has to remember');
SELECT is((SELECT (payload ->> 'amount_minor')::bigint FROM private.outbox
           WHERE event_type = 'refund.requested'), 4000::bigint,
  'and the event carries what to pay');
SELECT is((SELECT count(*)::int FROM private.claim_outbox(ARRAY['payment'], 50)
           WHERE event_type = 'refund.requested'), 1,
  'the worker claims it, rather than completing it unread');

-- ---------------------------------------------------------------------------
-- T.3 — a chargeback before settlement reverses only what was posted.
-- ---------------------------------------------------------------------------
INSERT INTO hd VALUES ('job2', pg_temp.paid_job('b-00000001')::text);
RESET ROLE;
INSERT INTO hd VALUES ('pay2', (SELECT p.id::text FROM public.payments p
                                WHERE p.request_id = (SELECT val FROM hd WHERE name = 'job2')::uuid));

SELECT ok(private.record_chargeback((SELECT val FROM hd WHERE name = 'pay2')::uuid, 1500,
            'issuer_dispute') IS NOT NULL,
  'the card issuer takes the money back before the job ever settled');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'd2222222-2222-4222-8222-555555555555'
             AND a.account_type = 'provider_earnings'), 0::bigint,
  'the provider owes nothing: they were never paid, so there is nothing to claw back');
SELECT is((SELECT count(*)::int FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue' AND b.balance_minor > 0), 0,
  'and no commission is reversed, because none was ever recognised');
SELECT is((SELECT coalesce(sum(e.amount_minor), 0)::bigint
           FROM ledger.entries e
           JOIN ledger.accounts a ON a.id = e.account_id
           JOIN ledger.transactions t ON t.id = e.transaction_id
           WHERE a.account_type = 'held_funds'
             AND t.request_id = (SELECT val FROM hd WHERE name = 'job2')::uuid), 0::bigint,
  'the hold is released, because the money is gone — leaving it would say the platform '
  'still owes a customer their bank has already repaid');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'chargeback_losses'), 1500::bigint,
  'the gateway''s chargeback fee is a loss');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'and it balances');

-- The other half of the same finding: a refund and a chargeback on one payment is an ops case.
SELECT throws_ok(
  format($$SELECT private.record_chargeback(
             (SELECT p.id FROM public.payments p WHERE p.request_id = %L), 1500, 'again')$$,
         (SELECT val FROM hd WHERE name = 'job1')),
  'P0001', 'ERR_CHARGEBACK_NEEDS_REVIEW',
  'a payment already refunded and now charged back needs a person, not arithmetic');

-- ---------------------------------------------------------------------------
-- T.4 — a promo that does not stack pays no referral.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  jsonb_build_object('sub', 'd3333333-3333-4333-8333-555555555555',
                     'role', 'authenticated', 'aal', 'aal1')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO hd VALUES ('code', public.my_referral_code());
RESET ROLE;

INSERT INTO auth.users (id, phone) VALUES
  ('d4444444-4444-4444-8444-555555555555', '2348000000604');
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd4444444-4444-4444-8444-555555555555';
SELECT set_config('request.jwt.claims',
  jsonb_build_object('sub', 'd4444444-4444-4444-8444-555555555555',
                     'role', 'authenticated', 'aal', 'aal1')::text, true);
SET LOCAL ROLE authenticated;
SELECT ok(public.claim_referral_code('key-hd-ref-000000001',
  (SELECT val FROM hd WHERE name = 'code')) IS NOT NULL,
  'a customer is introduced by somebody');
RESET ROLE;

CREATE FUNCTION pg_temp.promo_job(p_tag text, p_promo text) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd4444444-4444-4444-8444-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_request := public.create_request('key-hd-preq-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-hd-ppub-' || p_tag);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd2222222-2222-4222-8222-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_offer := public.create_offer('key-hd-poff-' || p_tag, v_request, 10000, NULL);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', 'd4444444-4444-4444-8444-555555555555',
                       'role', 'authenticated', 'aal', 'aal1')::text, true);
  PERFORM public.accept_offer('key-hd-pacc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment
  FROM public.start_payment('key-hd-ppay-' || p_tag, v_request, NULL, p_promo);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLWP-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLWP-' || p_tag, 9000, 261);
  UPDATE public.requests SET status = 'confirmed' WHERE id = v_request;
  UPDATE public.jobs SET confirmed_at = now() - interval '2 days' WHERE request_id = v_request;
  PERFORM private.recognise_due_earnings();
  RETURN v_request;
END $fn$;

INSERT INTO public.promo_codes (code, country_code, currency, discount_kind, discount_value,
                                stacks_with_referral, starts_at, ends_at, active)
VALUES ('NOSTACK10', 'NG', 'NGN', 'fixed', 1000, false,
        now() - interval '1 day', now() + interval '30 days', true);

INSERT INTO hd VALUES ('promojob', pg_temp.promo_job('c-00000001', 'NOSTACK10')::text);
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM hd WHERE name = 'promojob')::uuid
             AND rc.status = 'holding'), 0,
  'a promo whose rule says it does not stack pays no referral — until now the column said '
  'that of every promo and every promo stacked anyway');
SELECT is((SELECT status FROM public.referral_commissions rc
           WHERE rc.request_id = (SELECT val FROM hd WHERE name = 'promojob')::uuid),
  'reversed'::public.referral_commission_status,
  'and the anticipated row is closed out rather than left to mature');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it still balances');

-- ---------------------------------------------------------------------------
-- T.5 — an exporter that has never run is not stale.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM analytics.export_health(0)), 0,
  'nothing has exported, so nothing is late: a warning for something nobody switched on is '
  'how a health check stops being read');
SELECT lives_ok($$SELECT analytics.record_export('jobs_daily', current_date - 30, 3)$$,
  'the worker ships a window');
SELECT is((SELECT count(*)::int FROM analytics.export_health(1)
           WHERE view_name = 'jobs_daily'), 1,
  'and now that it has run and stopped, it is late');

SELECT * FROM finish();
ROLLBACK;
