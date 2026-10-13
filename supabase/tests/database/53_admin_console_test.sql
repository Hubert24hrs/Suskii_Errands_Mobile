-- The admin console's backend (audit Z.8): the dashboard, the audit log, staff, the two new
-- four-eyes targets, the dispute quote and the promo list.
--
-- The spine is the money-flows 6a case again: a 100.00 job, 40% back to the customer, so the
-- quote must say 40.00 refunded, 7.50 commission on the 60.00 kept, the provider's 2.90 fee and
-- 49.60 to the provider — the same numbers `resolve_dispute` posts.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(65);

INSERT INTO auth.users (id, phone, email) VALUES
  ('a1111111-1111-4111-8111-535353535353', '2348000005301', NULL),                 -- customer
  ('a2222222-2222-4222-8222-535353535353', '2348000005302', NULL),                 -- provider
  ('a3333333-3333-4333-8333-535353535353', NULL, 'amina.super@suskii.test'),       -- super A
  ('a4444444-4444-4444-8444-535353535353', NULL, 'bayo.super@suskii.test'),        -- super B
  ('a5555555-5555-4555-8555-535353535353', NULL, 'chidi.support@suskii.test'),     -- support
  ('a6666666-6666-4666-8666-535353535353', NULL, 'dupe.finance@suskii.test'),      -- finance, KE
  ('a7777777-7777-4777-8777-535353535353', NULL, 'efe.dispute@suskii.test'),       -- dispute
  ('a8888888-8888-4888-8888-535353535353', NULL, 'funmi.new@suskii.test');         -- not staff yet
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified',
       display_name = 'Adaeze Okonkwo'
WHERE user_id = 'a1111111-1111-4111-8111-535353535353';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'a2222222-2222-4222-8222-535353535353';
UPDATE public.profiles SET country_code = 'NG', display_name = 'Amina Bello'
WHERE user_id = 'a3333333-3333-4333-8333-535353535353';
INSERT INTO public.provider_profiles (user_id) VALUES ('a2222222-2222-4222-8222-535353535353');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('a3333333-3333-4333-8333-535353535353', ARRAY['super_admin']::public.admin_role[], NULL),
  ('a4444444-4444-4444-8444-535353535353', ARRAY['super_admin']::public.admin_role[], NULL),
  ('a5555555-5555-4555-8555-535353535353', ARRAY['support_agent']::public.admin_role[], NULL),
  ('a6666666-6666-4666-8666-535353535353', ARRAY['finance_officer']::public.admin_role[],
   ARRAY['KE']::char(2)[]),
  ('a7777777-7777-4777-8777-535353535353', ARRAY['dispute_officer']::public.admin_role[], NULL);

CREATE TEMP TABLE ac (name text PRIMARY KEY, val text);
GRANT ALL ON ac TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- A paid, confirmed job the customer then disputes: what `resolve_dispute` acts on.
CREATE FUNCTION pg_temp.disputed_job(p_tag text, p_amount bigint) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM pg_temp.act('a1111111-1111-4111-8111-535353535353', 'aal1');
  v_request := public.create_request('key-ac-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-ac-pub-' || p_tag);
  PERFORM pg_temp.act('a2222222-2222-4222-8222-535353535353', 'aal1');
  v_offer := public.create_offer('key-ac-off-' || p_tag, v_request, p_amount, NULL);
  PERFORM pg_temp.act('a1111111-1111-4111-8111-535353535353', 'aal1');
  PERFORM public.accept_offer('key-ac-acc-' || p_tag, v_offer);
  SELECT payment_id INTO v_payment FROM public.start_payment('key-ac-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLW-AC-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLW-AC-' || p_tag, p_amount, 290);
  UPDATE public.requests SET status = 'confirmed' WHERE id = v_request;
  UPDATE public.jobs SET confirmed_at = now() - interval '1 day' WHERE request_id = v_request;
  PERFORM pg_temp.act('a1111111-1111-4111-8111-535353535353', 'aal1');
  INSERT INTO ac VALUES ('dispute-' || p_tag,
    public.open_dispute('key-ac-dsp-' || p_tag, v_request, 'never_arrived', 'Nothing came.'));
  RETURN v_request;
END $fn$;

INSERT INTO ac VALUES ('req', pg_temp.disputed_job('00000001', 10000)::text);
INSERT INTO public.sos_incidents (request_id, raised_by, point, status)
VALUES ((SELECT val FROM ac WHERE name = 'req')::uuid, 'a1111111-1111-4111-8111-535353535353',
        extensions.st_setsrid(extensions.st_makepoint(3.3711, 6.5095), 4326)::extensions.geography,
        'open');
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash, last_seen_at)
VALUES ('a1111111-1111-4111-8111-535353535353', 'android', 'fp-ac-0001', now());

-- ---------------------------------------------------------------------------
-- admin_overview
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a1111111-1111-4111-8111-535353535353', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_overview()$$, '42501', 'ERR_PERMISSION_DENIED',
  'a customer has no dashboard');
RESET ROLE;
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_overview()$$, '42501', 'ERR_PERMISSION_DENIED',
  'nor does a staff member who has not passed the second factor');
RESET ROLE;

SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT open_disputes FROM public.admin_overview() WHERE country_code = 'NG'), 1,
  'support sees the open dispute');
SELECT is((SELECT open_sos FROM public.admin_overview() WHERE country_code = 'NG'), 1,
  'and the open SOS');
SELECT is((SELECT active_users FROM public.admin_overview() WHERE country_code = 'NG'), 1,
  'and who was active in the last day, counted by device');
SELECT ok((SELECT held_minor IS NULL AND gmv_30d_minor IS NULL
           FROM public.admin_overview() WHERE country_code = 'NG'),
  'but not the money: support may not read it through the KPIs, so not through the dashboard');
RESET ROLE;

SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT held_minor FROM public.admin_overview() WHERE country_code = 'NG'), 10000::bigint,
  'a super admin sees the 100.00 held for the disputed job');
SELECT is((SELECT count(*)::int FROM public.admin_overview()),
  (SELECT count(*)::int FROM public.countries WHERE status <> 'disabled'),
  'and every country that is not switched off');
RESET ROLE;

SELECT pg_temp.act('a6666666-6666-4666-8666-535353535353');
SET LOCAL ROLE authenticated;
SELECT results_eq($$SELECT country_code::text FROM public.admin_overview()$$,
  ARRAY['KE'], 'a finance officer scoped to Kenya sees Kenya and nothing else');
SELECT is((SELECT held_minor FROM public.admin_overview()), 0::bigint,
  'with the money, because finance may read it');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Z.14: the roles the matrix gives R:scope can read, still by country.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a7777777-7777-4777-8777-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests
           WHERE id = (SELECT val FROM ac WHERE name = 'req')::uuid), 1,
  'a dispute officer reads the request a dispute is about (it was support-only)');
SELECT ok((SELECT count(*) FROM public.offers
           WHERE request_id = (SELECT val FROM ac WHERE name = 'req')::uuid) > 0,
  'and its offers');
RESET ROLE;
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments
           WHERE request_id = (SELECT val FROM ac WHERE name = 'req')::uuid AND kind = 'job'), 1,
  'support reads the payment, as the matrix has always said');
RESET ROLE;
SELECT pg_temp.act('a6666666-6666-4666-8666-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments
           WHERE request_id = (SELECT val FROM ac WHERE name = 'req')::uuid), 0,
  'and the scope still holds: a finance officer scoped to Kenya does not read a Nigerian payment');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- audit_search
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.audit_search()$$, '42501', 'ERR_PERMISSION_DENIED',
  'support cannot read the audit log');
RESET ROLE;

SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.audit_search(NULL, 10, NULL, 'DROP TABLE')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'an action filter is an action name, not free text');
INSERT INTO ac VALUES ('first', (SELECT max(id) FROM public.audit_search(NULL, 500))::text);
SELECT is((SELECT action FROM public.audit_search(NULL, 1)), 'audit.search',
  'reading the log is the newest thing in it');
SELECT is((SELECT actor_name FROM public.audit_search(NULL, 1)), 'Amina Bello',
  'named by display name');
SELECT ok((SELECT count(*) > 0 AND bool_and(action LIKE 'audit.%')
           FROM public.audit_search(NULL, 100, NULL, 'audit.')),
  'an action prefix narrows it');
SELECT ok((SELECT bool_and(id < (SELECT val FROM ac WHERE name = 'first')::bigint)
           FROM public.audit_search((SELECT val FROM ac WHERE name = 'first')::bigint, 50)),
  'and before_id pages backwards');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_staff_list()$$, '42501', 'ERR_PERMISSION_DENIED',
  'only a super admin lists staff');
SELECT throws_ok($$SELECT * FROM public.admin_staff_lookup('funmi.new@suskii.test')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'or looks anyone up');
RESET ROLE;

SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.admin_staff_list()), 5, 'five staff');
SELECT is((SELECT email FROM public.admin_staff_list()
           WHERE user_id = 'a6666666-6666-4666-8666-535353535353'),
  'dupe.finance@suskii.test', 'with their email');
SELECT is((SELECT mfa_enrolled FROM public.admin_staff_list()
           WHERE user_id = 'a6666666-6666-4666-8666-535353535353'), false,
  'and no second factor yet');
RESET ROLE;
INSERT INTO auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at,
                              updated_at)
VALUES (gen_random_uuid(), 'a6666666-6666-4666-8666-535353535353', 'phone', 'totp', 'verified',
        now(), now());
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT mfa_enrolled FROM public.admin_staff_list()
           WHERE user_id = 'a6666666-6666-4666-8666-535353535353'), true,
  'enrolment is read from the verified factor itself');
SELECT throws_ok($$SELECT * FROM public.admin_staff_lookup('nobody@suskii.test')$$,
  'P0001', 'ERR_PROFILE_NOT_FOUND', 'an address with no account finds nothing');
SELECT throws_ok($$SELECT * FROM public.admin_staff_lookup('not an email')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'and a lookup is by a whole address');
SELECT is((SELECT is_staff FROM public.admin_staff_lookup('FUNMI.new@suskii.test')), false,
  'an existing account is found, case aside, and is not staff yet');

-- ---------------------------------------------------------------------------
-- Staff changes are four-eyes config changes.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-staff-self-0001', 'admin_user',
      'a3333333-3333-4333-8333-535353535353', '{"roles": ["support_agent"]}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'nobody proposes a change to their own access');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-staff-bad-00001', 'admin_user',
      'a8888888-8888-4888-8888-535353535353', '{"roles": ["overlord"]}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a role that does not exist is refused');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-staff-new-norl1', 'admin_user',
      'a8888888-8888-4888-8888-535353535353', '{"active": true}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a new staff member needs a role');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-staff-ghost-001', 'admin_user',
      'a9999999-9999-4999-8999-535353535353', '{"roles": ["support_agent"]}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'and has to have an account');
INSERT INTO ac VALUES ('grant', public.propose_config_change('key-ac-staff-grant-001',
  'admin_user', 'a8888888-8888-4888-8888-535353535353',
  '{"roles": ["verification_officer"], "country_scope": ["NG"]}')::text);
SELECT throws_ok(
  format($$SELECT public.review_config_change('key-ac-staff-own-00001', %L, true)$$,
    (SELECT val FROM ac WHERE name = 'grant')),
  '42501', 'ERR_PERMISSION_DENIED', 'the proposer does not sign their own proposal');
RESET ROLE;

SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-staff-supp-0001', 'admin_user',
      'a8888888-8888-4888-8888-535353535353', '{"roles": ["super_admin"]}')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'support cannot grant roles at all');
RESET ROLE;

SELECT pg_temp.act('a4444444-4444-4444-8444-535353535353');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-ac-staff-revw-0001',
  (SELECT val FROM ac WHERE name = 'grant')::uuid, true), 'applied',
  'a second super admin signs, and the grant applies');
RESET ROLE;
SELECT is((SELECT roles FROM public.admin_users
           WHERE user_id = 'a8888888-8888-4888-8888-535353535353'),
  ARRAY['verification_officer']::public.admin_role[], 'the new officer has the role');
SELECT is((SELECT country_scope FROM public.admin_users
           WHERE user_id = 'a8888888-8888-4888-8888-535353535353'),
  ARRAY['NG']::char(2)[], 'scoped to Nigeria');

-- A change to B's access, which B must not be the one to sign.
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
INSERT INTO ac VALUES ('widen', public.propose_config_change('key-ac-staff-widen-01',
  'admin_user', 'a4444444-4444-4444-8444-535353535353',
  '{"roles": ["super_admin", "finance_officer"]}')::text);
RESET ROLE;
SELECT pg_temp.act('a4444444-4444-4444-8444-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.review_config_change('key-ac-staff-widen-02', %L, true)$$,
    (SELECT val FROM ac WHERE name = 'widen')),
  '42501', 'ERR_PERMISSION_DENIED', 'nobody signs a change to their own access');
RESET ROLE;

-- Disabling, which also ends their sessions.
INSERT INTO auth.sessions (id, user_id, created_at, updated_at, aal)
VALUES (gen_random_uuid(), 'a5555555-5555-4555-8555-535353535353', now(), now(), 'aal2');
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
INSERT INTO ac VALUES ('disable', public.propose_config_change('key-ac-staff-off-00001',
  'admin_user', 'a5555555-5555-4555-8555-535353535353', '{"active": false}')::text);
RESET ROLE;
SELECT pg_temp.act('a4444444-4444-4444-8444-535353535353');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-ac-staff-off-00002',
  (SELECT val FROM ac WHERE name = 'disable')::uuid, true), 'applied',
  'disabling a colleague takes a second signature too');
RESET ROLE;
SELECT ok((SELECT disabled_at IS NOT NULL FROM public.admin_users
           WHERE user_id = 'a5555555-5555-4555-8555-535353535353'), 'the agent is disabled');
SELECT is((SELECT count(*)::int FROM auth.sessions
           WHERE user_id = 'a5555555-5555-4555-8555-535353535353'), 0,
  'and signed out everywhere, so a token minted before the change does not outlive it');
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_overview()$$, '42501', 'ERR_PERMISSION_DENIED',
  'and a token they still hold opens nothing');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Promo codes are four-eyes config changes as well.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-promo-bad-00001', 'promo_code', 'new',
      '{"code": "x", "discount_kind": "percent", "discount_value": 1000}', 'NG')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a code is four to twenty-four capitals');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-promo-ccy-00001', 'promo_code', 'new',
      '{"code": "WELCOME10", "currency": "KES", "discount_kind": "percent",
        "discount_value": 1000}', 'NG')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a Nigerian promo is in naira');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-promo-pct-00001', 'promo_code', 'new',
      '{"code": "WELCOME10", "discount_kind": "percent", "discount_value": 20000}', 'NG')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a percentage is at most 100%');
SELECT throws_ok(
  $$SELECT public.propose_config_change('key-ac-promo-ctry-0001', 'promo_code', 'new',
      '{"code": "WELCOME10", "discount_kind": "percent", "discount_value": 1000}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'and belongs to a country');
INSERT INTO ac VALUES ('promo', public.propose_config_change('key-ac-promo-new-00001',
  'promo_code', 'new',
  '{"code": "WELCOME10", "discount_kind": "percent", "discount_value": 1000,
    "max_discount_minor": 200000, "budget_minor": 5000000, "max_uses": 500,
    "ends_at": "2099-01-01T00:00:00Z"}', 'NG')::text);
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.promo_codes WHERE code = 'WELCOME10'), 0,
  'nothing exists until somebody else signs: a promo is a budget');
SELECT pg_temp.act('a4444444-4444-4444-8444-535353535353');
SET LOCAL ROLE authenticated;
SELECT is(public.review_config_change('key-ac-promo-new-00002',
  (SELECT val FROM ac WHERE name = 'promo')::uuid, true), 'applied', 'and then it applies');
RESET ROLE;
SELECT is((SELECT currency::text || ':' || budget_minor::text FROM public.promo_codes
           WHERE code = 'WELCOME10'), 'NGN:5000000', 'in naira, with its budget');

SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.propose_config_change('key-ac-promo-terms-001', 'promo_code', %L,
      '{"discount_value": 5000}')$$,
    (SELECT id FROM public.promo_codes WHERE code = 'WELCOME10')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'a live promo''s terms do not change under the customers who have seen them');
SELECT ok(public.propose_config_change('key-ac-promo-pause-001', 'promo_code',
  (SELECT id FROM public.promo_codes WHERE code = 'WELCOME10')::text,
  '{"active": false}') IS NOT NULL, 'its on/off switch may');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- admin_promo_codes
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a1111111-1111-4111-8111-535353535353', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.admin_promo_codes()$$, '42501', 'ERR_PERMISSION_DENIED',
  'a customer does not get the budget');
RESET ROLE;
SELECT pg_temp.act('a6666666-6666-4666-8666-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.admin_promo_codes()), 0,
  'a finance officer scoped to Kenya does not see a Nigerian promo');
RESET ROLE;
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT budget_minor::text || ':' || uses::text FROM public.admin_promo_codes('NG')
           WHERE code = 'WELCOME10'), '5000000:0', 'a super admin sees it, budget and uses');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- dispute_resolution_quote
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a5555555-5555-4555-8555-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT * FROM public.dispute_resolution_quote(%L, 4000)$$,
    (SELECT val FROM ac WHERE name = 'dispute-00000001')),
  '42501', 'ERR_PERMISSION_DENIED', 'support does not quote a resolution');
RESET ROLE;
SELECT pg_temp.act('a7777777-7777-4777-8777-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT * FROM public.dispute_resolution_quote(%L, 10001)$$,
    (SELECT val FROM ac WHERE name = 'dispute-00000001')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a refund is at most everything');
SELECT results_eq(
  format($$SELECT held_minor, refund_minor, commission_minor, gateway_fee_minor, provider_minor
           FROM public.dispute_resolution_quote(%L, 4000)$$,
    (SELECT val FROM ac WHERE name = 'dispute-00000001')),
  $$VALUES (10000::bigint, 4000::bigint, 750::bigint, 290::bigint, 4960::bigint)$$,
  'money-flows 6a: 40.00 back, 7.50 commission on what is kept, the 2.90 fee, 49.60 to the provider');
SELECT is((SELECT provider_minor FROM public.dispute_resolution_quote(
             (SELECT val FROM ac WHERE name = 'dispute-00000001')::uuid, 0)),
  8460::bigint, 'nothing refunded is the ordinary settlement: 84.60');
SELECT is(public.resolve_dispute('key-ac-resolve-000001',
  (SELECT val FROM ac WHERE name = 'dispute-00000001')::uuid, 'partial_refund',
  (SELECT refund_minor FROM public.dispute_resolution_quote(
     (SELECT val FROM ac WHERE name = 'dispute-00000001')::uuid, 4000)),
  'Arrived damaged; partial refund agreed.'), 'resolved'::public.dispute_status,
  'the quoted refund resolves the case');
RESET ROLE;
SELECT is((SELECT refund_minor FROM public.disputes
           WHERE id = (SELECT val FROM ac WHERE name = 'dispute-00000001')::uuid),
  4000::bigint, 'with exactly the amount quoted');
SELECT pg_temp.act('a7777777-7777-4777-8777-535353535353');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT * FROM public.dispute_resolution_quote(%L, 4000)$$,
    (SELECT val FROM ac WHERE name = 'dispute-00000001')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and a resolved case has nothing left to quote');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- analytics_report respects country scope.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('a6666666-6666-4666-8666-535353535353');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.analytics_report('jobs_daily') r
           WHERE r ->> 'country_code' <> 'KE'), 0,
  'a finance officer scoped to Kenya reads Kenya''s analytics and no other country''s');
SELECT throws_ok($$SELECT * FROM public.analytics_report('ledger_daily')$$,
  '42501', 'ERR_PERMISSION_DENIED',
  'and a view with no country column is refused rather than shown whole');
RESET ROLE;
SELECT pg_temp.act('a3333333-3333-4333-8333-535353535353');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) > 0 FROM public.analytics_report('jobs_daily') r
           WHERE r ->> 'country_code' = 'NG'),
  'a super admin is not scoped and sees the Nigerian job');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
