-- SOS, trusted contacts and trip sharing (PRD SH-24, SH-25, SH-26; RLS matrix §2 and §9).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(40);

INSERT INTO auth.users (id, phone) VALUES
  ('5a111111-1111-4111-8111-eeeeeeeeeeee', '2348000000141'),   -- customer
  ('5a222222-2222-4222-8222-eeeeeeeeeeee', '2348000000142'),   -- provider
  ('5a333333-3333-4333-8333-eeeeeeeeeeee', '2348000000143'),   -- a stranger
  ('5a444444-4444-4444-8444-eeeeeeeeeeee', '2348000000144');   -- support agent
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = '5a111111-1111-4111-8111-eeeeeeeeeeee';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = '5a222222-2222-4222-8222-eeeeeeeeeeee';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('5a333333-3333-4333-8333-eeeeeeeeeeee',
                  '5a444444-4444-4444-8444-eeeeeeeeeeee');
INSERT INTO public.provider_profiles (user_id) VALUES ('5a222222-2222-4222-8222-eeeeeeeeeeee');
INSERT INTO public.admin_users (user_id, roles)
VALUES ('5a444444-4444-4444-8444-eeeeeeeeeeee',
        ARRAY['support_agent']::public.admin_role[]);

CREATE TEMP TABLE sf (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE sft (name text PRIMARY KEY, token text);
-- `anon` reads the token too: following a shared trip without an account is the point of
-- SH-26, so the anonymous half of this file needs the scratch table as well.
GRANT ALL ON sf, sft TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- SH-25: trusted contacts, capped at five.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sf VALUES ('tc1', public.add_trusted_contact(
  'Chidi', '\x1111'::bytea, sha256('2348030000001'::bytea), 'brother'));
SELECT ok((SELECT id FROM sf WHERE name = 'tc1') IS NOT NULL, 'a user adds a trusted contact');
SELECT is((SELECT count(*)::int FROM public.trusted_contacts), 1, 'and sees their own list');
SELECT throws_ok(
  $$SELECT public.add_trusted_contact('Chidi again', '\x2222'::bytea,
      sha256('2348030000001'::bytea))$$,
  '23505', NULL, 'the same number twice is a mistake, not a second contact');
SELECT ok(public.add_trusted_contact('Ada', '\x33'::bytea, sha256('2348030000002'::bytea))
          IS NOT NULL, 'a second contact is fine');
SELECT ok(public.add_trusted_contact('Musa', '\x44'::bytea, sha256('2348030000003'::bytea))
          IS NOT NULL, 'and a third');
SELECT ok(public.add_trusted_contact('Ngozi', '\x55'::bytea, sha256('2348030000004'::bytea))
          IS NOT NULL, 'and a fourth');
SELECT ok(public.add_trusted_contact('Tunde', '\x66'::bytea, sha256('2348030000005'::bytea))
          IS NOT NULL, 'and a fifth');
SELECT throws_ok(
  $$SELECT public.add_trusted_contact('One too many', '\x77'::bytea,
      sha256('2348030000006'::bytea))$$,
  'P0001', 'ERR_TRUSTED_CONTACT_LIMIT', 'the sixth is refused by the database, not by a screen');
SELECT ok(public.remove_trusted_contact((SELECT id FROM sf WHERE name = 'tc1')),
  'a contact can be removed');
SELECT is((SELECT count(*)::int FROM public.trusted_contacts), 4, 'leaving four');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "5a333333-3333-4333-8333-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.trusted_contacts), 0,
  'nobody else reads them — not another user, and not support either');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "5a444444-4444-4444-8444-eeeeeeeeeeee", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.trusted_contacts), 0,
  'support has no read on trusted contacts: nobody operates on them, so nobody sees them');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A job under way, which is where SOS and trip sharing apply.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sf VALUES ('r', public.create_request(
  'key-sf-create-req-000000001', 'personal_assistance', 'Queue at the bank for me',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750, 'Home — Lekki', NULL,
  6.4531, 3.4356));
SELECT public.publish_request((SELECT id FROM sf WHERE name = 'r'), 'key-sf-publish-000000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "5a222222-2222-4222-8222-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sf VALUES ('o', public.create_offer(
  'key-sf-offer-p-0000000001', (SELECT id FROM sf WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-sf-accept-c-000000001', (SELECT id FROM sf WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM sf WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned');

-- ---------------------------------------------------------------------------
-- SH-24: raising SOS.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sf VALUES ('sos', public.raise_sos('key-sf-sos-c-00000000001',
  (SELECT id FROM sf WHERE name = 'r'), 6.4459, 3.4750));
SELECT ok((SELECT id FROM sf WHERE name = 'sos') IS NOT NULL, 'a customer raises SOS');
SELECT is((SELECT status FROM public.sos_incidents WHERE id = (SELECT id FROM sf WHERE name = 'sos')),
  'open'::public.sos_status, 'and it opens');
SELECT is((SELECT trusted_contacts_notified FROM public.sos_incidents
           WHERE id = (SELECT id FROM sf WHERE name = 'sos')), 4,
  'with the number of trusted contacts the senders will reach');
SELECT is(
  public.raise_sos('key-sf-sos-c-00000000002', (SELECT id FROM sf WHERE name = 'r'), 6.44, 3.47),
  (SELECT id FROM sf WHERE name = 'sos'),
  'pressing again joins the open incident: a frightened person does not open two cases');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.sos_incidents), 1, 'so there is one incident');
SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE aggregate = 'sos' AND event_type = 'sos.raised'), 1,
  'and operations was told once');

-- The provider on the same job can see that something is wrong.
SELECT set_config('request.jwt.claims',
  '{"sub": "5a222222-2222-4222-8222-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.sos_incidents), 1,
  'the other party on the job sees it: they may be the nearest help');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "5a333333-3333-4333-8333-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.sos_incidents), 0, 'a stranger sees nothing');
SELECT throws_ok(
  format($$SELECT public.update_sos_incident('key-sf-sos-x-00000000001', %L, 'acknowledged')$$,
    (SELECT id FROM sf WHERE name = 'sos')),
  '42501', 'ERR_PERMISSION_DENIED', 'and cannot work the ops queue');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The ops console.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "5a444444-4444-4444-8444-eeeeeeeeeeee", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.sos_incidents), 1, 'support sees the queue');
SELECT is(public.update_sos_incident('key-sf-ops-ack-000000001',
            (SELECT id FROM sf WHERE name = 'sos'), 'acknowledged'),
  'acknowledged'::public.sos_status, 'and acknowledges it');
SELECT is(public.update_sos_incident('key-sf-ops-res-000000001',
            (SELECT id FROM sf WHERE name = 'sos'), 'resolved', 'Customer safe, false alarm.'),
  'resolved'::public.sos_status, 'then resolves it');
SELECT throws_ok(
  format($$SELECT public.update_sos_incident('key-sf-ops-re-0000000001', %L, 'open')$$,
    (SELECT id FROM sf WHERE name = 'sos')),
  'P0001', 'ERR_ILLEGAL_TRANSITION',
  'a closed incident stays closed: reopening would hide how long the first one took');
RESET ROLE;
SELECT ok((SELECT ops_assignee_id IS NOT NULL AND resolved_at IS NOT NULL
           FROM public.sos_incidents WHERE id = (SELECT id FROM sf WHERE name = 'sos')),
  'the incident records who handled it and when it closed');

-- Escalation: an incident nobody acknowledges does not sit in the queue (AD-21).
SELECT set_config('request.jwt.claims',
  '{"sub": "5a222222-2222-4222-8222-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sf VALUES ('sos2', public.raise_sos('key-sf-sos-p-00000000001',
  (SELECT id FROM sf WHERE name = 'r'), 6.4460, 3.4751));
RESET ROLE;
SELECT is(private.escalate_unacked_sos(), 0, 'a fresh incident is not escalated');
UPDATE public.sos_incidents SET created_at = now() - interval '10 minutes'
WHERE id = (SELECT id FROM sf WHERE name = 'sos2');
SELECT is(private.escalate_unacked_sos(), 1, 'one nobody answered in three minutes is');
SELECT is(private.escalate_unacked_sos(), 0, 'and it is escalated once, not every minute');

-- ---------------------------------------------------------------------------
-- SH-26: trip sharing.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sft VALUES ('t', public.create_trip_share('key-sf-share-c-000000001',
  (SELECT id FROM sf WHERE name = 'r')));
SELECT matches((SELECT token FROM sft WHERE name = 't'), '^[0-9a-f]{64}$',
  'the token is 32 bytes of hex, handed back once');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.trip_share_links
           WHERE token_hash = sha256(convert_to((SELECT token FROM sft WHERE name = 't'), 'UTF8'))),
  1, 'and only its hash is stored');

-- The point of the link: it works for somebody with no account.
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM public.get_shared_trip((SELECT token FROM sft WHERE name = 't'))),
  1, 'anon can follow a shared trip — the one intentional anonymous read');
SELECT is((SELECT status FROM public.get_shared_trip((SELECT token FROM sft WHERE name = 't'))),
  'assigned'::public.job_status, 'and sees the job status');
SELECT is((SELECT count(*)::int FROM public.get_shared_trip('not-a-real-token-but-long-enough-xx')),
  0, 'a wrong token returns nothing at all: no row, no error, nothing to guess against');
SELECT throws_ok($$SELECT count(*) FROM public.trip_share_links$$,
  '42501', NULL, 'and the table itself stays shut');
RESET ROLE;

-- Revoking ends access immediately.
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.revoke_trip_share((SELECT id FROM public.trip_share_links LIMIT 1)),
  'the person who shared it can revoke it');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM public.get_shared_trip((SELECT token FROM sft WHERE name = 't'))),
  0, 'and the link stops working at once');
RESET ROLE;

-- Ending the job ends the sharing, whether or not anyone revoked it.
SELECT set_config('request.jwt.claims',
  '{"sub": "5a111111-1111-4111-8111-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sft VALUES ('t2', public.create_trip_share('key-sf-share-c-000000002',
  (SELECT id FROM sf WHERE name = 'r')));
RESET ROLE;
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM public.get_shared_trip((SELECT token FROM sft WHERE name = 't2'))),
  1, 'a fresh link works');
RESET ROLE;
UPDATE public.requests SET status = 'closed' WHERE id = (SELECT id FROM sf WHERE name = 'r');
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM public.get_shared_trip((SELECT token FROM sft WHERE name = 't2'))),
  0, 'and stops the moment the job is over, without anyone revoking anything');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
