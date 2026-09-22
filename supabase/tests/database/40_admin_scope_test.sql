-- `R:scope` made real (`docs/audit/AUDIT-2026-09-22b.md`, findings U.1 to U.4), and the provider
-- card the RLS matrix has named since Phase 1.
--
-- One support agent scoped to Nigeria, one to Kenya, one global, and the same rows underneath
-- all three. Before this, all three saw everything.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(29);

INSERT INTO auth.users (id, phone) VALUES
  ('91111111-1111-4111-8111-777777777777', '2348000000801'),   -- NG customer
  ('92222222-2222-4222-8222-777777777777', '2348000000802'),   -- NG provider
  ('93333333-3333-4333-8333-777777777777', '2547000000803'),   -- KE customer
  ('94444444-4444-4444-8444-777777777777', '2348000000804'),   -- support, scoped to NG
  ('95555555-5555-4555-8555-777777777777', '2348000000805'),   -- support, scoped to KE
  ('96666666-6666-4666-8666-777777777777', '2348000000806'),   -- support, global
  ('97777777-7777-4777-8777-777777777777', '2348000000807'),   -- finance, scoped to NG
  ('98888888-8888-4888-8888-777777777777', '2348000000808');   -- super admin
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified',
       display_name = 'Adaeze Okonkwo'
WHERE user_id = '91111111-1111-4111-8111-777777777777';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
       display_name = 'Emeka Deliveries'
WHERE user_id = '92222222-2222-4222-8222-777777777777';
UPDATE public.profiles SET country_code = 'KE', customer_verification = 'verified'
WHERE user_id = '93333333-3333-4333-8333-777777777777';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('94444444-4444-4444-8444-777777777777',
                  '95555555-5555-4555-8555-777777777777',
                  '96666666-6666-4666-8666-777777777777',
                  '97777777-7777-4777-8777-777777777777',
                  '98888888-8888-4888-8888-777777777777');
INSERT INTO public.provider_profiles (user_id) VALUES ('92222222-2222-4222-8222-777777777777');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('94444444-4444-4444-8444-777777777777', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('95555555-5555-4555-8555-777777777777', ARRAY['support_agent']::public.admin_role[],
   ARRAY['KE']::char(2)[]),
  ('96666666-6666-4666-8666-777777777777', ARRAY['support_agent']::public.admin_role[], NULL),
  ('97777777-7777-4777-8777-777777777777', ARRAY['finance_officer']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('98888888-8888-4888-8888-777777777777', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE TEMP TABLE sc (name text PRIMARY KEY, val text);
GRANT ALL ON sc TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- One request in each country, and a paid job on the Nigerian one.
SELECT pg_temp.act('91111111-1111-4111-8111-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO sc VALUES ('ng', public.create_request('key-sc-req-ng-000001', 'personal_assistance',
  'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711)::text);
SELECT ok(public.publish_request((SELECT val FROM sc WHERE name = 'ng')::uuid,
  'key-sc-pub-ng-000001') IS NOT NULL, 'a Nigerian request is published');
RESET ROLE;

SELECT pg_temp.act('93333333-3333-4333-8333-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO sc VALUES ('ke', public.create_request('key-sc-req-ke-000001', 'personal_assistance',
  'Deliver a parcel', 'Westlands', 'standard', false, NULL, NULL, -1.2921, 36.8219)::text);
SELECT ok(public.publish_request((SELECT val FROM sc WHERE name = 'ke')::uuid,
  'key-sc-pub-ke-000001') IS NOT NULL, 'and a Kenyan one');
RESET ROLE;
SELECT is((SELECT country_code FROM public.requests
           WHERE id = (SELECT val FROM sc WHERE name = 'ke')::uuid), 'KE'::char(2),
  'the request carries the country it was made in');

-- ---------------------------------------------------------------------------
-- The whole finding, in three rows.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('96666666-6666-4666-8666-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 2,
  'an unscoped support agent reads both, which is what every agent used to do');
RESET ROLE;

SELECT pg_temp.act('94444444-4444-4444-8444-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 1,
  'an agent scoped to Nigeria reads one');
SELECT is((SELECT country_code FROM public.requests), 'NG'::char(2), 'and it is the Nigerian one');
RESET ROLE;

SELECT pg_temp.act('95555555-5555-4555-8555-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT country_code FROM public.requests), 'KE'::char(2),
  'an agent scoped to Kenya reads the other, and only the other');
RESET ROLE;

SELECT pg_temp.act('98888888-8888-4888-8888-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 2,
  'a super admin is never country-scoped, even carrying a scope: the matrix gives it plain R, '
  'and it is the escape hatch for everything this closes');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The scope reaches through a join, not just where the row names a country.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('94444444-4444-4444-8444-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.user_devices), 0,
  'devices, scoped through their owner''s profile');
SELECT is((SELECT count(*)::int FROM public.provider_profiles), 1,
  'provider profiles, the same way — the Nigerian provider and nobody else');
RESET ROLE;

INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash) VALUES
  ('91111111-1111-4111-8111-777777777777', 'android', sha256('ng-device'::bytea)),
  ('93333333-3333-4333-8333-777777777777', 'android', sha256('ke-device'::bytea));
SELECT pg_temp.act('94444444-4444-4444-8444-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.user_devices), 1,
  'one device now, and it belongs to the Nigerian customer');
RESET ROLE;
SELECT pg_temp.act('95555555-5555-4555-8555-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.user_devices), 1,
  'and the Kenyan agent sees the other one');
RESET ROLE;

-- A row whose country cannot be determined is not shown to a scoped officer: an access control
-- that fails open is a suggestion.
UPDATE public.profiles SET country_code = NULL
WHERE user_id = '93333333-3333-4333-8333-777777777777';
SELECT pg_temp.act('95555555-5555-4555-8555-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.user_devices), 0,
  'it fails closed, and super admin is the way to reach what falls through');
RESET ROLE;
UPDATE public.profiles SET country_code = 'KE'
WHERE user_id = '93333333-3333-4333-8333-777777777777';

-- ---------------------------------------------------------------------------
-- Money is scoped too, which is where it matters most.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('92222222-2222-4222-8222-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO sc VALUES ('offer', public.create_offer('key-sc-off-ng-000001',
  (SELECT val FROM sc WHERE name = 'ng')::uuid, 10000, NULL)::text);
RESET ROLE;
SELECT pg_temp.act('91111111-1111-4111-8111-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.accept_offer('key-sc-acc-ng-000001',
  (SELECT val FROM sc WHERE name = 'offer')::uuid) IS NOT NULL, 'the Nigerian job is agreed');
SELECT ok((SELECT payment_id FROM public.start_payment('key-sc-pay-ng-000001',
             (SELECT val FROM sc WHERE name = 'ng')::uuid)) IS NOT NULL, 'and paid for');
RESET ROLE;

SELECT pg_temp.act('97777777-7777-4777-8777-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments), 1,
  'a finance officer scoped to Nigeria reads the Nigerian payment');
RESET ROLE;
SELECT pg_temp.act('95555555-5555-4555-8555-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.payments), 0,
  'and somebody scoped elsewhere reads no payment at all');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- U.3 — the provider card the matrix names and nothing had built.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('91111111-1111-4111-8111-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.profiles), 1,
  'a customer still reads only their own profile, which is why the card has to exist');
SELECT is((SELECT display_name FROM public.get_provider_card(
             '92222222-2222-4222-8222-777777777777')), 'Emeka Deliveries',
  'and now they can see who made them an offer');
SELECT is((SELECT verified FROM public.get_provider_card(
             '92222222-2222-4222-8222-777777777777')), true,
  'with the one badge a decision actually turns on');
SELECT is((SELECT rating_count FROM public.get_provider_card(
             '92222222-2222-4222-8222-777777777777')), 0,
  'and the count beside the rating, because a 5.0 from nobody is not a 5.0');
RESET ROLE;

SELECT pg_temp.act('93333333-3333-4333-8333-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT * FROM public.get_provider_card('92222222-2222-4222-8222-777777777777')$$,
  '42501', NULL,
  'a customer with no dealings with that provider gets nothing: a card is not a directory');
RESET ROLE;

SELECT pg_temp.act('94444444-4444-4444-8444-777777777777');
SET LOCAL ROLE authenticated;
SELECT is((SELECT display_name FROM public.get_provider_card(
             '92222222-2222-4222-8222-777777777777')), 'Emeka Deliveries',
  'a support agent in the right country can read the card');
RESET ROLE;
SELECT pg_temp.act('95555555-5555-4555-8555-777777777777');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT * FROM public.get_provider_card('92222222-2222-4222-8222-777777777777')$$,
  '42501', NULL, 'and one in the wrong country cannot');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- U.2 — a business could rename itself after it was verified.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('92222222-2222-4222-8222-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO sc VALUES ('org', public.register_organization('key-sc-org-000000001',
  'Emeka Logistics Ltd', '\xdeadbeef'::bytea, sha256('RC999999'::bytea))::text);
SELECT lives_ok(
  format($$UPDATE public.organizations SET legal_name = 'Emeka Holdings Ltd' WHERE id = %L$$,
         (SELECT val FROM sc WHERE name = 'org')),
  'an unverified business can still correct its own name');
RESET ROLE;

UPDATE public.organizations SET verification_status = 'verified'
WHERE id = (SELECT val FROM sc WHERE name = 'org')::uuid;
SELECT pg_temp.act('92222222-2222-4222-8222-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
UPDATE public.organizations SET legal_name = 'Renamed After Verification'
WHERE id = (SELECT val FROM sc WHERE name = 'org')::uuid;
RESET ROLE;
SELECT is((SELECT legal_name FROM public.organizations
           WHERE id = (SELECT val FROM sc WHERE name = 'org')::uuid), 'Emeka Holdings Ltd',
  'and after verification the rename writes nothing: the matrix says before verification only, '
  'and a business verified as one company must not quietly become another');

-- ---------------------------------------------------------------------------
-- N.1 — the four creates that now take a key.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('91111111-1111-4111-8111-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
INSERT INTO sc VALUES ('tc', public.add_trusted_contact('key-sc-contact-000001',
  'Chidi', '\x1111'::bytea, sha256('2348030009001'::bytea), 'brother')::text);
SELECT is(public.add_trusted_contact('key-sc-contact-000001',
            'Chidi', '\x1111'::bytea, sha256('2348030009001'::bytea), 'brother')::text,
  (SELECT val FROM sc WHERE name = 'tc'),
  'the same key replays the contact rather than raising a unique violation at a retrying client');
SELECT is((SELECT count(*)::int FROM public.trusted_contacts), 1, 'and there is still one of them');
RESET ROLE;

SELECT pg_temp.act('92222222-2222-4222-8222-777777777777', 'aal1');
SET LOCAL ROLE authenticated;
SELECT public.record_consent('criminal_record_check', true, 'key-sc-consent-crim-01');
INSERT INTO sc VALUES ('sess', public.start_verification_session('key-sc-sess-000000001',
  'police_clearance')::text);
SELECT is(public.start_verification_session('key-sc-sess-000000001', 'police_clearance')::text,
  (SELECT val FROM sc WHERE name = 'sess'),
  'and a retried verification session is the same session, not a second vendor bill');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
