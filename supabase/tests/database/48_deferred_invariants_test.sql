-- The deferred invariants fire as the calling role at COMMIT (audit 2026-09-27 Y.28). A test
-- transaction rolls back, so without `SET CONSTRAINTS ALL IMMEDIATE` these triggers never run in
-- pgTAP at all — which is how "permission denied for schema ledger" on every real payment went
-- unseen. Here they are forced to fire as the role that made the call, as COMMIT would.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(6);

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-484848484848', '2348000000481'),   -- customer
  ('d2222222-2222-4222-8222-484848484848', '2348000000482');   -- provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-484848484848';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'd2222222-2222-4222-8222-484848484848';
INSERT INTO public.provider_profiles (user_id) VALUES ('d2222222-2222-4222-8222-484848484848');

CREATE TEMP TABLE di (name text PRIMARY KEY, id uuid);
GRANT ALL ON di TO authenticated, service_role;

SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-484848484848", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO di VALUES ('r', public.create_request(
  'key-di-create-req-000000001', 'personal_assistance', 'A parcel to Victoria Island',
  'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711));
SELECT public.publish_request((SELECT id FROM di WHERE name = 'r'), 'key-di-publish-000000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-484848484848", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO di VALUES ('o', public.create_offer(
  'key-di-offer-p-0000000001', (SELECT id FROM di WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-484848484848", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-di-accept-c-000000001', (SELECT id FROM di WHERE name = 'o'));
INSERT INTO di VALUES ('p', (SELECT payment_id FROM public.start_payment(
  'key-di-start-c-0000000001', (SELECT id FROM di WHERE name = 'r'), 'card')));
RESET ROLE;

-- The payments webhook, exactly as the Edge Function calls it: as service_role.
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.gateway_record_checkout((SELECT id FROM di WHERE name = 'p'), 'flutterwave',
  'di-ref-000000001', 'https://checkout.example/di-ref-000000001');
SELECT is(public.gateway_confirm_payment('flutterwave', 'di-ref-000000001', 500000, 14500),
  'assigned'::public.job_status, 'the webhook confirms the payment');
SELECT lives_ok('SET CONSTRAINTS ALL IMMEDIATE',
  'and the ledger''s balance check passes when it fires as service_role, as COMMIT fires it');
RESET ROLE;

SELECT ok((SELECT prosecdef FROM pg_proc WHERE oid = 'ledger.assert_balanced()'::regprocedure),
  'the balance check runs as its owner, whoever commits');
SELECT ok((SELECT prosecdef FROM pg_proc
           WHERE oid = 'private.assert_refunds_within_payment()'::regprocedure),
  'and so does the refunds invariant');

-- The refunds invariant must see every refund, not the ones the committing role may read: a
-- refund larger than the payment is refused even when the transaction is a client's.
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code, status)
VALUES ((SELECT id FROM di WHERE name = 'p'), (SELECT id FROM di WHERE name = 'r'), 400000, 'NGN', 'customer_cancelled_early', 'pending');
INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code, status)
VALUES ((SELECT id FROM di WHERE name = 'p'), (SELECT id FROM di WHERE name = 'r'), 200000, 'NGN', 'customer_cancelled_early', 'pending');
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-484848484848", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok('SET CONSTRAINTS ALL IMMEDIATE', 'P0001', 'ERR_REFUND_EXCEEDS_PAYMENT',
  'refunds beyond the payment are refused whoever commits them');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0,
  'and the books balance');

SELECT * FROM finish();
ROLLBACK;
