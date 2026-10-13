-- Kimi's change requests, closed on the server (20261012130000, -130100, -130200).
--
-- CR-06 and CR-08: plaintext in, sealed at rest, masked for display, blind-indexed where a lookup
-- needs it, and opened for nobody but the functions that must. CR-10: KYC payloads sealed and read
-- by an officer only through an audited door; submit-for-review refuses an incomplete profile and
-- decides nothing. CR-01, -03, -05: the link, the wallet feed, what is pending, and the provider
-- home card.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(50);

INSERT INTO auth.users (id, phone) VALUES
  ('c5211111-1111-4111-8111-000000000001', '2348000007001'),   -- customer
  ('c5222222-2222-4222-8222-000000000002', '2348000007002'),   -- provider in onboarding
  ('c5233333-3333-4333-8333-000000000003', '2348000007003'),   -- verification officer
  ('c5244444-4444-4444-8444-000000000004', '2348000007004');   -- working provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'c5211111-1111-4111-8111-000000000001';
UPDATE public.profiles SET country_code = 'NG', active_mode = 'provider'
WHERE user_id = 'c5222222-2222-4222-8222-000000000002';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'c5233333-3333-4333-8333-000000000003';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
                           active_mode = 'provider'
WHERE user_id = 'c5244444-4444-4444-8444-000000000004';
INSERT INTO public.provider_profiles (user_id) VALUES
  ('c5222222-2222-4222-8222-000000000002'), ('c5244444-4444-4444-8444-000000000004');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('c5233333-3333-4333-8333-000000000003', ARRAY['verification_officer']::public.admin_role[]);

CREATE TEMP TABLE cr (name text PRIMARY KEY, val text);
GRANT ALL ON cr TO authenticated;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- CR-06: a trusted contact's number, sealed.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5211111-1111-4111-8111-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO cr VALUES ('tc', public.add_trusted_contact('key-cr-contact-0000001', 'Mama',
  '+234 803 123 4567', 'mother')::text);
SELECT ok((SELECT val FROM cr WHERE name = 'tc') IS NOT NULL,
  'a customer adds a trusted contact by typing the number');
SELECT is((SELECT phone_masked FROM public.trusted_contacts), '+234••••••4567',
  'and their list shows the country and the last four, nothing more');
SELECT throws_ok(
  $$SELECT public.add_trusted_contact('key-cr-contact-0000002', 'Bad', '0803 123')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a number that is not E.164 is refused');
RESET ROLE;
SELECT ok((SELECT position(convert_to('2348031234567', 'UTF8') IN phone_ciphertext) = 0
           FROM public.trusted_contacts WHERE id = (SELECT val FROM cr WHERE name = 'tc')::uuid),
  'what is stored is not the number');
SELECT is((SELECT private.open('trusted_contact_phone', phone_ciphertext, 'trusted_contact:' || id)
           FROM public.trusted_contacts WHERE id = (SELECT val FROM cr WHERE name = 'tc')::uuid),
  '+2348031234567', 'it opens, normalised, with its own key and its own row');
SELECT ok((SELECT phone_blind_index = private.blind_index('trusted_contact_phone', '+2348031234567')
           FROM public.trusted_contacts WHERE id = (SELECT val FROM cr WHERE name = 'tc')::uuid),
  'and its index is the keyed one the database computes, not the client');
SELECT is(private.collect_personal_data('c5211111-1111-4111-8111-000000000001')
            -> 'trusted_contacts' -> 0 ->> 'phone', '+2348031234567',
  'a data export gives the owner their contact''s number back');

-- ---------------------------------------------------------------------------
-- CR-08: an ID number and a police certificate, sealed.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
INSERT INTO cr VALUES ('id', public.submit_identity_document('key-cr-id-00000000001', 'nin',
  '1234 5678 901')::text);
SELECT is(public.submit_identity_document('key-cr-id-00000000002', 'nin', '12345678901')::text,
  (SELECT val FROM cr WHERE name = 'id'),
  'the same person sending the same number again updates the one document');
SELECT throws_ok(
  $$SELECT public.submit_police_clearance('key-cr-pc-00000000001', 'PC/2026/77',
      (now() - interval '1 month')::date, (now() + interval '5 months')::date,
      'c5211111-1111-4111-8111-000000000001/pc.pdf')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a certificate upload has to be in your own folder');
SELECT public.record_consent('criminal_record_check', true, 'key-cr-consent-crc-0001');
SELECT is(public.submit_police_clearance('key-cr-pc-00000000002', 'PC/2026/77',
            (now() - interval '1 month')::date, (now() + interval '5 months')::date,
            'c5222222-2222-4222-8222-000000000002/pc.pdf'),
  'in_review'::public.kyc_step_status, 'a police clearance goes to the queue');
RESET ROLE;
SELECT is((SELECT private.open('identity_number', id_number_ciphertext, 'identity_document:' || id)
           FROM kyc.identity_documents WHERE id = (SELECT val FROM cr WHERE name = 'id')::uuid),
  '12345678901', 'the ID number is sealed and opens only server-side');
SELECT is((SELECT private.open('police_certificate', certificate_number_ciphertext,
                               'police_clearance:' || id)
           FROM kyc.police_clearances WHERE user_id = 'c5222222-2222-4222-8222-000000000002'),
  'PC202677', 'and so is the certificate number');

-- ---------------------------------------------------------------------------
-- Y.19: a business and its vehicle, registered with plaintext.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
INSERT INTO cr VALUES ('org', public.register_organization('key-cr-org-0000000001',
  'Ikeja Movers Ltd', 'RC-778 899')::text);
INSERT INTO cr VALUES ('veh', public.register_vehicle('key-cr-veh-0000000001', 'motorcycle',
  'kja 482 ab', (SELECT val FROM cr WHERE name = 'org')::uuid)::text);
SELECT is((SELECT registration_masked FROM public.organizations
           WHERE id = (SELECT val FROM cr WHERE name = 'org')::uuid), '••••8899',
  'the business shows a masked registration number');
SELECT is((SELECT plate_masked FROM public.vehicles
           WHERE id = (SELECT val FROM cr WHERE name = 'veh')::uuid), '•••••2AB',
  'and its vehicle a masked plate');
RESET ROLE;
SELECT is((SELECT private.open('organization_registration', registration_number_ciphertext,
                               'organization:' || id)
           FROM public.organizations WHERE id = (SELECT val FROM cr WHERE name = 'org')::uuid),
  'RC778899', 'the registration number is sealed');
SELECT is((SELECT private.open('vehicle_plate', plate_ciphertext, 'vehicle:' || id)
           FROM public.vehicles WHERE id = (SELECT val FROM cr WHERE name = 'veh')::uuid),
  'KJA482AB', 'and the plate');

-- ---------------------------------------------------------------------------
-- CR-10 (a): answer steps take a payload, sealed, and read by an officer through an audited door.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(public.submit_kyc_step('key-cr-addr-000000001', 'address', NULL,
            '{"line1": "12 Allen Avenue", "city": "Ikeja", "state": "Lagos",
              "landmark": "Opposite the bank"}'::jsonb),
  'in_review'::public.kyc_step_status, 'an address goes to review with what the person typed');
SELECT throws_ok(
  $$SELECT public.submit_kyc_step('key-cr-addr-000000002', 'address', NULL,
      '{"line1": "1 Road", "city": "Ikeja", "state": "Lagos", "bvn": "22200011122"}'::jsonb)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a key the kind does not define is refused, not stored');
SELECT throws_ok(
  $$SELECT public.submit_kyc_step('key-cr-addr-000000003', 'address', NULL,
      '{"line1": "1 Road"}'::jsonb)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'so is an address without a city and state');
SELECT throws_ok(
  $$SELECT public.submit_kyc_step('key-cr-addr-000000004', 'address')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'and an address step with no address at all');
SELECT throws_ok(
  $$SELECT public.submit_kyc_step('key-cr-capt-000000001', 'id_document_capture',
      ARRAY['c5222222-2222-4222-8222-000000000002/front.jpg'], '{"x": "y"}'::jsonb)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'an upload step never carries a payload');
SELECT is(public.submit_kyc_step('key-cr-guar-000000001', 'guarantor', NULL,
            '{"name": "Bola Ade", "phone_e164": "+234 805 000 1111", "relationship": "uncle"}'::jsonb),
  'in_review'::public.kyc_step_status, 'a guarantor goes to review');
RESET ROLE;
INSERT INTO cr SELECT 'guar_step', s.id::text FROM kyc.kyc_steps s
WHERE s.user_id = 'c5222222-2222-4222-8222-000000000002' AND s.kind = 'guarantor';
SELECT ok((SELECT position(convert_to('Allen Avenue', 'UTF8') IN payload_ciphertext) = 0
           FROM kyc.kyc_step_payloads
           WHERE user_id = 'c5222222-2222-4222-8222-000000000002' AND kind = 'address'),
  'the address is sealed at rest');
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.get_kyc_step_payload(%L, 'curious')$$,
         (SELECT val FROM cr WHERE name = 'guar_step')),
  '42501', 'ERR_PERMISSION_DENIED', 'the applicant does not read payloads through the officer door');
RESET ROLE;
SELECT pg_temp.act('c5233333-3333-4333-8333-000000000003', 'aal2');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.get_kyc_step_payload(%L, '')$$,
         (SELECT val FROM cr WHERE name = 'guar_step')),
  '22023', 'ERR_INVALID_ARGUMENT', 'an officer has to say why');
SELECT is(public.get_kyc_step_payload((SELECT val FROM cr WHERE name = 'guar_step')::uuid,
            'kyc_review') ->> 'phone_e164',
  '+2348050001111', 'an officer reads the guarantor, the phone number normalised');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM audit.kyc_access
           WHERE subject_id = 'c5222222-2222-4222-8222-000000000002'
             AND upload_ref = 'payload:guarantor'),
  1, 'and the read was written down before it was returned');

-- ---------------------------------------------------------------------------
-- CR-10 (b), (d): "I'm done", and the profile with its dates.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.submit_kyc_for_review('key-cr-review-00000001')$$,
  'P0001', 'ERR_KYC_INCOMPLETE', 'submit for review refuses while required steps are missing');
SELECT is(public.submit_kyc_step('key-cr-capt-000000002', 'id_document_capture',
            ARRAY['c5222222-2222-4222-8222-000000000002/front.jpg']),
  'in_review'::public.kyc_step_status, 'the ID photo goes in');
RESET ROLE;
-- The vendor's half: the liveness check is running and the ID lookup came back (CR-09 waits on
-- the vendor, so the test stands in for it).
INSERT INTO kyc.kyc_steps (user_id, kind, status, attempt_count, submitted_at) VALUES
  ('c5222222-2222-4222-8222-000000000002', 'provider_facial', 'in_progress', 1, now()),
  ('c5222222-2222-4222-8222-000000000002', 'government_id', 'verified', 1, now());
SELECT pg_temp.act('c5222222-2222-4222-8222-000000000002');
SET LOCAL ROLE authenticated;
SELECT is(public.submit_kyc_for_review('key-cr-review-00000002'),
  'in_review'::public.verification_status,
  'with every required step in, the profile is submitted, and it is in review, not verified');
SELECT ok((SELECT bool_and(submitted_for_review_at IS NOT NULL)
           FROM public.get_my_kyc_profile()),
  'the profile says when it was submitted');
SELECT ok((SELECT submitted_at IS NOT NULL AND overall_status = 'in_review'
           FROM public.get_my_kyc_profile() WHERE kind = 'police_clearance'),
  'and each step carries its own date and the overall status');

-- (e) business_name, but not kind.
SELECT lives_ok(
  $$UPDATE public.provider_profiles SET business_name = 'Ikeja Movers'
    WHERE user_id = 'c5222222-2222-4222-8222-000000000002'$$,
  'a provider names their business');
SELECT throws_ok(
  $$UPDATE public.provider_profiles SET kind = 'individual'
    WHERE user_id = 'c5222222-2222-4222-8222-000000000002'$$,
  '42501', NULL, 'but kind changes only by registering an organisation');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A paid job for the working provider, for the link, the feed and the home card.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.paid_job() RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_req uuid; v_offer uuid; v_pay uuid; v_amount bigint;
BEGIN
  PERFORM pg_temp.act('c5211111-1111-4111-8111-000000000001');
  v_req := public.create_request('key-cr-create-00000001', 'personal_assistance',
    'Pick up a parcel from the post office', 'Ikeja GRA', p_pickup_lat => 6.5833,
    p_pickup_lng => 3.3500);
  PERFORM public.publish_request(v_req, 'key-cr-publish-0000001');
  PERFORM pg_temp.act('c5244444-4444-4444-8444-000000000004');
  v_offer := public.create_offer('key-cr-offer-000000001', v_req, 2000, NULL);
  PERFORM pg_temp.act('c5211111-1111-4111-8111-000000000001');
  PERFORM public.accept_offer('key-cr-accept-00000001', v_offer);
  SELECT payment_id INTO v_pay FROM public.start_payment('key-cr-pay-000000000001', v_req, 'card');
  SELECT p.amount_minor INTO v_amount FROM public.payments p WHERE p.id = v_pay;
  PERFORM private.record_gateway_checkout(v_pay, 'flutterwave', 'FLW-CR-JOB-1', NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-CR-JOB-1', v_amount, 60);
  RETURN v_req;
END $fn$;
INSERT INTO cr VALUES ('job', pg_temp.paid_job()::text);

-- ---------------------------------------------------------------------------
-- CR-01: the link.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c5211111-1111-4111-8111-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO cr VALUES ('share1', public.create_trip_share('key-cr-share-0000001',
  (SELECT val FROM cr WHERE name = 'job')::uuid)::text);
SELECT ok(((SELECT val FROM cr WHERE name = 'share1')::jsonb ->> 'url') IS NULL
          AND ((SELECT val FROM cr WHERE name = 'share1')::jsonb ->> 'token') ~ '^[0-9a-f]{64}$',
  'with no share base configured the link has a token and no invented host');
RESET ROLE;
UPDATE public.remote_config SET value = '"https://share.suskii.test/t/"'
WHERE key = 'trip_share_base_url' AND country_code IS NULL;
SELECT pg_temp.act('c5211111-1111-4111-8111-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO cr VALUES ('share2', public.create_trip_share('key-cr-share-0000002',
  (SELECT val FROM cr WHERE name = 'job')::uuid)::text);
SELECT is((SELECT val FROM cr WHERE name = 'share2')::jsonb ->> 'url',
  'https://share.suskii.test/t/' || ((SELECT val FROM cr WHERE name = 'share2')::jsonb ->> 'token'),
  'once configured, the link is the base and the token');
SELECT is((public.create_trip_share('key-cr-share-0000002',
             (SELECT val FROM cr WHERE name = 'job')::uuid) ->> 'share_id'),
  (SELECT val FROM cr WHERE name = 'share2')::jsonb ->> 'share_id',
  'a replay returns the same link id and never the token again');
RESET ROLE;
SELECT is(((SELECT val FROM cr WHERE name = 'share2')::jsonb ->> 'expires_at')::timestamptz,
  (SELECT l.expires_at FROM public.trip_share_links l
   WHERE l.id = ((SELECT val FROM cr WHERE name = 'share2')::jsonb ->> 'share_id')::uuid),
  'and its expiry is the one on the row, not a guess');

-- ---------------------------------------------------------------------------
-- CR-03: pending, the feed, and what each side can see.
-- ---------------------------------------------------------------------------
-- What the provider is owed: the net after commission, less the gateway's fee once it is known,
-- which is what `recognise_earnings` posts.
INSERT INTO cr SELECT 'net', (j.net_minor - coalesce(j.actual_gateway_fee_minor, 0))::text
FROM public.jobs j
WHERE j.request_id = (SELECT val FROM cr WHERE name = 'job')::uuid;
SELECT pg_temp.act('c5244444-4444-4444-8444-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(public.my_pending_balance('provider_earnings', 'NGN'),
  (SELECT val FROM cr WHERE name = 'net')::bigint,
  'a paid job the provider has not been paid for yet is pending, at what it will pay');
RESET ROLE;
SELECT ok(ledger.post('earnings_recognised', 'NGN', 'key-cr-1c-000000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', (SELECT val FROM cr WHERE name = 'net')::bigint),
    jsonb_build_object('owner_kind', 'user', 'owner_id', 'c5244444-4444-4444-8444-000000000004',
                       'account_type', 'provider_earnings',
                       'amount_minor', -(SELECT val FROM cr WHERE name = 'net')::bigint)),
  (SELECT val FROM cr WHERE name = 'job')::uuid) > 0, 'the earnings are recognised');
INSERT INTO public.payout_accounts (id, user_id, country_code, rail, account_ciphertext,
                                    account_blind_index, institution_code, holder_name, is_default)
VALUES ('c52a0000-0000-4000-8000-000000000001', 'c5244444-4444-4444-8444-000000000004', 'NG',
        'bank', '\x01', '\x02', '058', 'Tunde Bello', true);
INSERT INTO public.withdrawals (user_id, source_account, payout_account_id, amount_minor,
                                currency, status, approvals_required, created_at)
VALUES ('c5244444-4444-4444-8444-000000000004', 'provider_earnings',
        'c52a0000-0000-4000-8000-000000000001', 500, 'NGN', 'awaiting_approval', 1,
        now() + interval '1 second');
SELECT pg_temp.act('c5244444-4444-4444-8444-000000000004');
SET LOCAL ROLE authenticated;
SELECT is(public.my_pending_balance('provider_earnings', 'NGN'), 0::bigint,
  'once recognised it is no longer pending');
SELECT is((SELECT kind || '|' || status || '|' || amount_minor || '|' || description_key
           FROM public.my_wallet_transactions('provider_earnings') LIMIT 1),
  'payout|pending|-500|txnWithdrawalAwaitingApproval',
  'the newest line is the withdrawal waiting on approval, as money going out');
SELECT is((SELECT kind || '|' || status || '|' || amount_minor || '|' || description_key
           FROM public.my_wallet_transactions('provider_earnings', now() + interval '1 second')),
  'credit|completed|' || (SELECT val FROM cr WHERE name = 'net') || '|txnJobEarnings',
  'and before it, the job''s earnings as money coming in');
SELECT is((SELECT reference_id::text FROM public.my_wallet_transactions('provider_earnings')
           WHERE kind = 'credit'),
  (SELECT val FROM cr WHERE name = 'job'), 'a ledger line names the job it came from');
SELECT throws_ok($$SELECT * FROM public.my_wallet_transactions('platform_revenue')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'nobody reads a platform account through the feed');
RESET ROLE;
SELECT pg_temp.act('c5211111-1111-4111-8111-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.my_wallet_transactions('provider_earnings')), 0,
  'and the customer sees none of the provider''s lines');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- CR-05: the provider home card.
-- ---------------------------------------------------------------------------
UPDATE public.jobs SET completed_at = now()
WHERE request_id = (SELECT val FROM cr WHERE name = 'job')::uuid;
INSERT INTO kyc.kyc_steps (user_id, kind, status, attempt_count, submitted_at, expires_at) VALUES
  ('c5244444-4444-4444-8444-000000000004', 'police_clearance', 'verified', 1, now(),
   now() + interval '10 days');
SELECT pg_temp.act('c5244444-4444-4444-8444-000000000004');
SET LOCAL ROLE authenticated;
SELECT is((SELECT completed_today FROM public.provider_home_summary()), 1,
  'the home card counts today''s completed job');
SELECT is((SELECT today_earnings_minor FROM public.provider_home_summary()),
  (SELECT j.net_minor - coalesce(j.actual_gateway_fee_minor, 0) FROM public.jobs j
   WHERE j.request_id = (SELECT val FROM cr WHERE name = 'job')::uuid),
  'and what it earned, in the provider''s own currency');
SELECT ok((SELECT document_warnings @> '[{"document_type_key": "docPoliceClearance",
                                           "days_remaining": 10}]'::jsonb
           FROM public.provider_home_summary()),
  'a document ten days from expiry is on the card');
SELECT is((SELECT nearby_open_requests FROM public.provider_home_summary()), 0,
  'a provider with no known location sees zero nearby, not an error');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
