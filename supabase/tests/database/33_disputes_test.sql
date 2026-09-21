-- Disputes (ERD §10; RLS matrix §9; `docs/plan/money-flows.md` posting 6a).
--
-- The doc's own case: a 100.00 job where the officer sends 40.00 back. Commission is taken on the
-- 60.00 kept, the provider still bears the 2.90 collection fee, and they are left with 49.60.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(38);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-333333333333', '2348000000261'),   -- customer
  ('b2222222-2222-4222-8222-333333333333', '2348000000262'),   -- provider
  ('b3333333-3333-4333-8333-333333333333', '2348000000263'),   -- dispute officer
  ('b4444444-4444-4444-8444-333333333333', '2348000000264'),   -- a stranger
  ('b5555555-5555-4555-8555-333333333333', '2348000000265');   -- support agent
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'b1111111-1111-4111-8111-333333333333';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'b2222222-2222-4222-8222-333333333333';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('b3333333-3333-4333-8333-333333333333',
                  'b4444444-4444-4444-8444-333333333333',
                  'b5555555-5555-4555-8555-333333333333');
INSERT INTO public.provider_profiles (user_id) VALUES ('b2222222-2222-4222-8222-333333333333');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('b3333333-3333-4333-8333-333333333333', ARRAY['dispute_officer']::public.admin_role[]),
  ('b5555555-5555-4555-8555-333333333333', ARRAY['support_agent']::public.admin_role[]),
  -- The provider is *also* an officer, which is the only way to test that being one does not let
  -- them decide their own case.
  ('b2222222-2222-4222-8222-333333333333', ARRAY['dispute_officer']::public.admin_role[]);

CREATE TEMP TABLE dp (name text PRIMARY KEY, id uuid);
GRANT ALL ON dp TO authenticated, service_role;

CREATE FUNCTION pg_temp.paid_job(p_tag text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_customer constant text :=
    '{"sub": "b1111111-1111-4111-8111-333333333333", "role": "authenticated", "aal": "aal1"}';
  v_provider constant text :=
    '{"sub": "b2222222-2222-4222-8222-333333333333", "role": "authenticated", "aal": "aal1"}';
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', v_customer, true);
  v_request := public.create_request('key-dp-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-dp-pub-' || p_tag);
  PERFORM set_config('request.jwt.claims', v_provider, true);
  v_offer := public.create_offer('key-dp-off-' || p_tag, v_request, p_amount, NULL);
  PERFORM set_config('request.jwt.claims', v_customer, true);
  PERFORM public.accept_offer('key-dp-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment
  FROM public.start_payment('key-dp-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLW-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-' || p_tag, p_amount, 290);
  RETURN v_request;
END $fn$;

INSERT INTO dp VALUES ('r', pg_temp.paid_job('r-00000001', 10000));
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM dp WHERE name = 'r');
UPDATE public.jobs SET confirmed_at = now() - interval '2 days'
WHERE request_id = (SELECT id FROM dp WHERE name = 'r');

-- ---------------------------------------------------------------------------
-- Opening one, and the freeze it puts on the money.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b4444444-4444-4444-8444-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.open_dispute('key-dp-open-x-000001', %L, 'never_arrived')$$,
    (SELECT id FROM dp WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'a stranger has nothing to dispute');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dp VALUES ('d', public.open_dispute('key-dp-open-c-000001',
  (SELECT id FROM dp WHERE name = 'r'), 'never_arrived', 'The parcel never came.'));
SELECT ok((SELECT id FROM dp WHERE name = 'd') IS NOT NULL, 'the customer opens a dispute');
SELECT throws_ok(
  format($$SELECT public.open_dispute('key-dp-open-c-000002', %L, 'never_arrived')$$,
    (SELECT id FROM dp WHERE name = 'r')),
  'P0001', 'ERR_DISPUTE_ALREADY_OPEN',
  'two arguments about the same job are one argument');
RESET ROLE;

SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dp WHERE name = 'r')),
  'disputed'::public.job_status, 'the job is frozen');
SELECT is((SELECT frozen_from FROM public.disputes WHERE id = (SELECT id FROM dp WHERE name = 'd')),
  'confirmed'::public.job_status,
  'and the dispute remembers what it froze, so withdrawing can put it back');
SELECT is(private.recognise_due_earnings(), 0,
  'the settlement sweep leaves it alone: money released mid-argument is money to claw back');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE params ->> 'dispute_id' IS NOT NULL), 2,
  'both sides are told — a dispute is not a complaint made behind somebody''s back');

-- ---------------------------------------------------------------------------
-- Evidence. Each side sees their own.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.submit_dispute_evidence('key-dp-ev-empty-00001', %L, 'note')$$,
    (SELECT id FROM dp WHERE name = 'd')),
  '22023', 'ERR_INVALID_ARGUMENT', 'evidence has to be something');
SELECT throws_ok(
  format($$SELECT public.submit_dispute_evidence('key-dp-ev-path-000001', %L, 'photo',
      'somebody-elses-folder/photo.jpg')$$,
    (SELECT id FROM dp WHERE name = 'd')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and it lives under this job''s own folder');
SELECT ok(public.submit_dispute_evidence('key-dp-ev-c-00000001',
            (SELECT id FROM dp WHERE name = 'd'), 'note', NULL, '{}'::jsonb,
            'Nothing was ever delivered.') IS NOT NULL, 'the customer files a note');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.submit_dispute_evidence('key-dp-ev-p-00000001',
            (SELECT id FROM dp WHERE name = 'd'), 'photo',
            (SELECT id::text || '/doorstep.jpg' FROM dp WHERE name = 'r')) IS NOT NULL,
  'and the provider files a photo');
SELECT is((SELECT count(*)::int FROM public.dispute_evidence), 1,
  'each side reads their own submission and not the other''s: evidence you can read before you
   answer it is evidence you can tailor a story around');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The officer's desk, and the scope it opens.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b5555555-5555-4555-8555-333333333333", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.dispute_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'support does not work the dispute queue');
SELECT is((SELECT count(*)::int FROM public.disputes), 1,
  'though they can see that a case exists, which is what a support call about it needs');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.dispute_queue()), 1, 'the officer sees the case');
SELECT is((SELECT count(*)::int FROM public.dispute_evidence), 2,
  'and both sides of the evidence, which is the point of an adjudicator');
SELECT is((SELECT count(*)::int FROM public.conversations), 1,
  'the case opens the job''s chat to them — the case is the reason, not the role');
SELECT throws_ok(
  format($$SELECT public.assign_dispute('key-dp-asg-bad-00001', %L,
      'b4444444-4444-4444-8444-333333333333')$$, (SELECT id FROM dp WHERE name = 'd')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'it cannot be assigned to somebody who cannot work the queue');
SELECT throws_ok(
  format($$SELECT public.assign_dispute('key-dp-asg-self-0001', %L,
      'b2222222-2222-4222-8222-333333333333')$$, (SELECT id FROM dp WHERE name = 'd')),
  '42501', 'ERR_PERMISSION_DENIED',
  'nor to an officer who was on the job, however senior');
SELECT is(public.assign_dispute('key-dp-asg-ok-000001', (SELECT id FROM dp WHERE name = 'd'),
            'b3333333-3333-4333-8333-333333333333'),
  'under_review'::public.dispute_status, 'the officer takes it');
RESET ROLE;

-- The provider is an officer too, and still cannot decide their own case.
SELECT set_config('request.jwt.claims',
  '{"sub": "b2222222-2222-4222-8222-333333333333", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.resolve_dispute('key-dp-res-self-0001', %L, 'in_favour_of_provider',
      0, 'Nothing wrong here.')$$, (SELECT id FROM dp WHERE name = 'd')),
  '42501', 'ERR_PERMISSION_DENIED', 'and cannot resolve one about a job they were on');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6a: resolved with a partial refund.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.resolve_dispute('key-dp-res-note-0001', %L, 'partial_refund', 4000, '  ')$$,
    (SELECT id FROM dp WHERE name = 'd')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'a resolution with no written reason is not one anybody can defend later');
SELECT throws_ok(
  format($$SELECT public.resolve_dispute('key-dp-res-over-0001', %L, 'partial_refund', 99999,
      'More than was ever paid.')$$, (SELECT id FROM dp WHERE name = 'd')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and cannot send back more than is held');
SELECT is(public.resolve_dispute('key-dp-res-ok-000001', (SELECT id FROM dp WHERE name = 'd'),
            'partial_refund', 4000, 'Parcel arrived late and damaged; half the fee returned.'),
  'resolved'::public.dispute_status, 'the officer resolves it with 40.00 back');
RESET ROLE;

SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'refunds_payable'), 4000::bigint,
  '6a: 40.00 is owed back to the customer');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), 750::bigint,
  'commission is 7.50 — on the 60.00 kept, not on the price that was agreed');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'b2222222-2222-4222-8222-333333333333'
             AND a.account_type = 'provider_earnings'), 4960::bigint,
  'and the provider is left with 49.60, still bearing the 2.90 the gateway took either way');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'held_funds'), 0::bigint, 'nothing is left held');
SELECT is((SELECT status FROM public.payments
           WHERE request_id = (SELECT id FROM dp WHERE name = 'r')),
  'partially_refunded'::public.payment_status, 'the payment says partially refunded');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dp WHERE name = 'r')),
  'settlement_pending'::public.job_status, 'and the job moves on');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'it balances');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0, 'and reconciles');
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'dispute.resolve'), 1,
  'the decision is in the hash-chained log');

-- ---------------------------------------------------------------------------
-- Withdrawing one, and the status it restores.
-- ---------------------------------------------------------------------------
INSERT INTO dp VALUES ('r2', pg_temp.paid_job('r2-0000001', 10000));
UPDATE public.requests SET status = 'in_progress' WHERE id = (SELECT id FROM dp WHERE name = 'r2');
SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dp VALUES ('d2', public.open_dispute('key-dp-open-c-000003',
  (SELECT id FROM dp WHERE name = 'r2'), 'provider_unreachable'));
SELECT is(public.withdraw_dispute('key-dp-wd-c-00000001', (SELECT id FROM dp WHERE name = 'd2')),
  'withdrawn'::public.dispute_status, 'the person who opened it can drop it');
RESET ROLE;
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM dp WHERE name = 'r2')),
  'in_progress'::public.job_status,
  'and the job goes back to exactly where it was — not to `confirmed`, which would mark
   unfinished work finished and release its money');

-- An overdue case is shouted about, once.
INSERT INTO dp VALUES ('r3', pg_temp.paid_job('r3-0000001', 10000));
SELECT set_config('request.jwt.claims',
  '{"sub": "b1111111-1111-4111-8111-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO dp VALUES ('d3', public.open_dispute('key-dp-open-c-000004',
  (SELECT id FROM dp WHERE name = 'r3'), 'wrong_item'));
RESET ROLE;
SELECT is(private.escalate_overdue_disputes(), 0, 'a fresh case is not overdue');
UPDATE public.disputes SET sla_due_at = now() - interval '1 hour'
WHERE id = (SELECT id FROM dp WHERE name = 'd3');
SELECT is(private.escalate_overdue_disputes(), 1, 'one past its SLA is');
SELECT is(private.escalate_overdue_disputes(), 0, 'and is escalated once, not every hour');

SELECT * FROM finish();
ROLLBACK;
