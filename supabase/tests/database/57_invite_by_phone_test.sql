-- Audit Z.20: inviting by phone tells a business owner nothing about whether the number has an
-- account. A number with one and a number without one get the same answer, the same row in the
-- member list and the same count; the invitation waits for the number to sign up and is claimed
-- when its owner first looks at their invitations.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(20);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-575757575757', '2348000005701'),   -- the owner
  ('f2222222-2222-4222-8222-575757575757', '2348000005702');   -- has an account
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
       customer_verification = 'verified', display_name = 'Ade Account'
WHERE user_id IN ('f1111111-1111-4111-8111-575757575757', 'f2222222-2222-4222-8222-575757575757');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('f1111111-1111-4111-8111-575757575757'), ('f2222222-2222-4222-8222-575757575757');

CREATE TEMP TABLE iv (name text PRIMARY KEY, val text);
GRANT ALL ON iv TO authenticated, service_role;
INSERT INTO iv VALUES ('masked_has', private.mask_phone('+2348000005702')),
                      ('masked_none', private.mask_phone('+2348000005799'));

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;
CREATE FUNCTION pg_temp.v(p_name text) RETURNS text LANGUAGE sql AS $fn$
  SELECT val FROM iv WHERE name = p_name;
$fn$;

SELECT pg_temp.act('f1111111-1111-4111-8111-575757575757');
SET LOCAL ROLE authenticated;
INSERT INTO iv VALUES ('org', public.register_organization('key-iv-org-000000001',
  'Invite Test Ltd', 'RC575757')::text);
INSERT INTO iv VALUES ('id_has', public.invite_member_by_phone('key-iv-has-000000001',
  pg_temp.v('org')::uuid, '+234 800 000 5702', 'worker')::text);
INSERT INTO iv VALUES ('id_none', public.invite_member_by_phone('key-iv-none-00000001',
  pg_temp.v('org')::uuid, '+234 800 000 5799', 'worker')::text);

SELECT ok(pg_temp.v('id_has') IS NOT NULL AND pg_temp.v('id_none') IS NOT NULL,
  'both invitations are accepted: no error for the number without an account');
SELECT isnt(pg_temp.v('id_has'), 'f2222222-2222-4222-8222-575757575757',
  'the account''s user id is not handed back');
SELECT is(public.invite_member_by_phone('key-iv-none-00000001', pg_temp.v('org')::uuid,
  '+2348000005799', 'worker')::text, pg_temp.v('id_none'), 'a retry is the same invitation');

SELECT is(
  (SELECT role::text || '|' || status::text || '|' || verification_status::text || '|'
          || jobs_completed || '|' || earnings_minor
   FROM public.my_organization_members() WHERE user_id = pg_temp.v('id_has')::uuid),
  (SELECT role::text || '|' || status::text || '|' || verification_status::text || '|'
          || jobs_completed || '|' || earnings_minor
   FROM public.my_organization_members() WHERE user_id = pg_temp.v('id_none')::uuid),
  'the two rows are the same row: a verified provider shows as pending, like nobody at all');
SELECT is((SELECT display_name FROM public.my_organization_members()
           WHERE user_id = pg_temp.v('id_has')::uuid), pg_temp.v('masked_has'),
  'the number with an account shows masked');
SELECT is((SELECT display_name FROM public.my_organization_members()
           WHERE user_id = pg_temp.v('id_none')::uuid), pg_temp.v('masked_none'),
  'and so does the number without one');
SELECT is((SELECT count(*)::int FROM public.my_organization_members()
           WHERE user_id = 'f2222222-2222-4222-8222-575757575757'), 0,
  'the account''s id appears nowhere in the list');
SELECT is((SELECT member_count FROM public.my_organization()), 3,
  'the member count includes both invitations');

-- Withdrawing an invitation uses the id the list showed, for either kind.
SELECT ok(public.remove_member(pg_temp.v('org')::uuid, pg_temp.v('id_none')::uuid),
  'the owner withdraws the invitation to the number without an account');
SELECT is((SELECT member_count FROM public.my_organization()), 2, 'and it is gone');
INSERT INTO iv VALUES ('id_none2', public.invite_member_by_phone('key-iv-none-00000002',
  pg_temp.v('org')::uuid, '+2348000005799', 'dispatcher')::text);
SELECT is(pg_temp.v('id_none2'), pg_temp.v('id_none'),
  'invited again, it comes back under the same id');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM private.org_phone_invitations$$, '42501', NULL,
  'no client reads the pending invitations');
RESET ROLE;
SELECT ok(NOT has_function_privilege('authenticated',
  'private.org_invitation_id(uuid, text)', 'EXECUTE'),
  'nor computes an invitation id');

-- The number signs up; the first look at invitations claims it.
INSERT INTO auth.users (id, phone) VALUES ('f3333333-3333-4333-8333-575757575757', '2348000005799');
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
       display_name = 'Nkechi New'
WHERE user_id = 'f3333333-3333-4333-8333-575757575757';
SELECT pg_temp.act('f3333333-3333-4333-8333-575757575757');
SET LOCAL ROLE authenticated;
SELECT is((SELECT name || ':' || role::text FROM public.my_organization_invitations()),
  'Invite Test Ltd:dispatcher', 'the new account sees the invitation waiting for its number');
SELECT is(public.accept_organization_invite('key-iv-acc-000000001', pg_temp.v('org')::uuid),
  'dispatcher'::public.business_role, 'and accepts it');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.org_phone_invitations
           WHERE organization_id = pg_temp.v('org')::uuid), 0,
  'nothing is left pending once it is claimed');

SELECT pg_temp.act('f1111111-1111-4111-8111-575757575757');
SET LOCAL ROLE authenticated;
SELECT is((SELECT display_name FROM public.my_organization_members()
           WHERE user_id = 'f3333333-3333-4333-8333-575757575757'), 'Nkechi New',
  'a member who has accepted is listed by name and real id');
SELECT ok(public.remove_member(pg_temp.v('org')::uuid, pg_temp.v('id_has')::uuid),
  'the owner withdraws the other invitation by its id');
SELECT is((SELECT member_count FROM public.my_organization()), 2, 'owner and dispatcher remain');
RESET ROLE;

SELECT pg_temp.act('f2222222-2222-4222-8222-575757575757');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.my_organization_invitations()), 0,
  'the withdrawn invitation is gone for its recipient too');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
