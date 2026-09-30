-- Saved places and access notes (RLS matrix §2; ADR-0018; audit 2026-09-22c).
--
-- The claim under test is the matrix's: a customer's own places are theirs alone, super admin
-- included; the access note leaves the database only through a function; and the provider reads
-- it **only while working the job**. Before en_route it is refused, after the work it is gone,
-- and anybody else is told the request does not exist.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(39);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-111111111111', '2348000005001'),   -- customer
  ('e2222222-2222-4222-8222-222222222222', '2348000005002'),   -- provider, assigned
  ('e3333333-3333-4333-8333-333333333333', '2348000005003'),   -- provider, bid only
  ('e5555555-5555-4555-8555-555555555555', '2348000005005'),   -- a stranger
  ('e6666666-6666-4666-8666-666666666666', '2348000005006'),   -- support, scoped NG
  ('e8888888-8888-4888-8888-888888888888', '2348000005008');   -- super admin

UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('e2222222-2222-4222-8222-222222222222', 'e3333333-3333-4333-8333-333333333333');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('e5555555-5555-4555-8555-555555555555', 'e6666666-6666-4666-8666-666666666666',
                  'e8888888-8888-4888-8888-888888888888');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('e2222222-2222-4222-8222-222222222222'), ('e3333333-3333-4333-8333-333333333333');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('e6666666-6666-4666-8666-666666666666', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('e8888888-8888-4888-8888-888888888888', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
GRANT ALL ON ids TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- Saved places
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('home', public.add_saved_place('key-sp-home-000000000001',
  '12 Admiralty Way, Lekki', 6.4459, 3.4750, 'Blue gate', 'Gate code 4471, ring twice'));
SELECT is(public.add_saved_place('key-sp-home-000000000001', '12 Admiralty Way, Lekki',
            6.4459, 3.4750, 'Blue gate', 'A different note entirely'),
  (SELECT id FROM ids WHERE name = 'home'),
  'a replay returns the same place, and the note is not in the fingerprint: a hash of a gate code is the gate code');
SELECT is((SELECT label || '|' || landmark_note || '|' || has_access_note::text
           FROM public.saved_places WHERE id = (SELECT id FROM ids WHERE name = 'home')),
  '12 Admiralty Way, Lekki|Blue gate|true', 'the owner reads their place, and that it has a note');
SELECT is(public.get_saved_place_access_note((SELECT id FROM ids WHERE name = 'home')),
  'Gate code 4471, ring twice', 'and reads the note through the function');
SELECT throws_ok(
  $$SELECT access_note_ciphertext FROM public.saved_places$$,
  '42501', NULL, 'but cannot select the ciphertext, even their own');
SELECT lives_ok(
  $$UPDATE public.saved_places SET label = 'Home, 12 Admiralty Way'
    WHERE id = (SELECT id FROM ids WHERE name = 'home')$$,
  'the owner renames it in place (U:own label, point, landmark_note)');
SELECT throws_ok(
  $$UPDATE public.saved_places SET access_note_ciphertext = '\x00'
    WHERE id = (SELECT id FROM ids WHERE name = 'home')$$,
  '42501', NULL, 'and cannot write the ciphertext directly');
SELECT throws_ok(
  $$SELECT public.add_saved_place('key-sp-bad-000000000001', 'Nowhere', 91, 3.47)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a latitude off the planet is refused');
INSERT INTO ids VALUES ('office', public.add_saved_place('key-sp-office-00000000001',
  '4 Awolowo Road, Ikoyi', 6.4531, 3.4356));
SELECT is((SELECT has_access_note FROM public.saved_places WHERE id = (SELECT id FROM ids WHERE name = 'office')),
  false, 'a place without a note says so');
RESET ROLE;

UPDATE public.remote_config SET value = '2' WHERE key = 'saved_places_max' AND country_code IS NULL;
SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.add_saved_place('key-sp-third-00000000001', '9 Glover Road', 6.4460, 3.4751)$$,
  'P0001', 'ERR_SAVED_PLACE_LIMIT', 'the limit is enforced in the database, not in a screen');
RESET ROLE;

-- Nobody else, including the two roles that read most things.
SELECT pg_temp.act('e5555555-5555-4555-8555-555555555555');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.saved_places), 0, 'a stranger reads no saved places');
SELECT throws_ok(
  format('SELECT public.get_saved_place_access_note(%L)', (SELECT id FROM ids WHERE name = 'home')),
  'P0001', 'ERR_SAVED_PLACE_NOT_FOUND', 'nor anybody''s note');
SELECT is(public.remove_saved_place((SELECT id FROM ids WHERE name = 'home')), false,
  'nor removes anybody''s place');
RESET ROLE;

SELECT pg_temp.act('e6666666-6666-4666-8666-666666666666');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.saved_places), 0,
  'support reads no saved places: nobody operates on them');
RESET ROLE;

SELECT pg_temp.act('e8888888-8888-4888-8888-888888888888');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.saved_places), 0,
  'and neither does super admin, which the matrix withholds on purpose');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A request, funded and assigned to e2
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('r1', public.create_request(
  'key-sp-create-r1-0000000001', 'errands_delivery', 'Take a parcel to Ikoyi',
  '12 Admiralty Way', 'standard', false, NULL, 'Blue gate', 6.4459, 3.4750,
  '4 Awolowo Road, Flat 3B', NULL, 6.4531, 3.4356));
SELECT is(public.set_request_access_note((SELECT id FROM ids WHERE name = 'r1'),
            'Side door; the dog is friendly'), true,
  'the customer puts a note on their draft');
SELECT public.publish_request((SELECT id FROM ids WHERE name = 'r1'), 'key-sp-publish-r1-000000001');
RESET ROLE;

SELECT pg_temp.act('e2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('o1', public.create_offer(
  'key-sp-offer-e2-000000000001', (SELECT id FROM ids WHERE name = 'r1'), 800000, NULL));
RESET ROLE;

SELECT pg_temp.act('e3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT public.create_offer('key-sp-offer-e3-000000000001', (SELECT id FROM ids WHERE name = 'r1'),
  850000, NULL);
RESET ROLE;

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-sp-accept-o1-00000000001', (SELECT id FROM ids WHERE name = 'o1'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM ids WHERE name = 'r1')),
  'assigned'::public.job_status, 'r1 is funded and assigned to e2');

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.set_request_access_note(%L, %L, %L)', (SELECT id FROM ids WHERE name = 'r1'),
         'both', (SELECT id FROM ids WHERE name = 'home')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a note and a place at once is ambiguous and refused');
SELECT is(public.set_request_access_note((SELECT id FROM ids WHERE name = 'r1'),
            p_saved_place_id := (SELECT id FROM ids WHERE name = 'home')), true,
  'the customer uses their saved place''s note instead');
SELECT is(public.reveal_access_note((SELECT id FROM ids WHERE name = 'r1')),
  'Gate code 4471, ring twice', 'and reads back what the provider will see');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('e2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.reveal_access_note(%L)', (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION',
  'assigned is not yet working: a provider who accepts and walks away leaves without the code');
SELECT is(public.set_job_status('key-sp-enroute-r1-000000001', (SELECT id FROM ids WHERE name = 'r1'),
            'en_route'), 'en_route'::public.job_status, 'the provider starts the journey');
SELECT is(public.reveal_access_note((SELECT id FROM ids WHERE name = 'r1')),
  'Gate code 4471, ring twice', 'and now reads the note');
SELECT throws_ok(
  format('SELECT public.set_request_access_note(%L, %L)', (SELECT id FROM ids WHERE name = 'r1'), 'mine'),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'but cannot change it: it is the customer''s');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM ids WHERE name = 'r1')
             AND reason_code = 'access_note_revealed'
             AND actor_id = 'e2222222-2222-4222-8222-222222222222'
             AND actor_kind = 'provider'), 1,
  'the read is on the job''s record, once, as the provider');

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM ids WHERE name = 'r1')
             AND reason_code = 'access_note_revealed'), 1,
  'where the customer can see it');
SELECT is(public.set_request_access_note((SELECT id FROM ids WHERE name = 'r1'), 'Code changed: 9902'),
  true, 'the customer changes the code while the provider travels');
RESET ROLE;

SELECT pg_temp.act('e2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT is(public.reveal_access_note((SELECT id FROM ids WHERE name = 'r1')), 'Code changed: 9902',
  'and the provider reads the new one');
RESET ROLE;

-- Everybody else is told there is no such request.
SELECT pg_temp.act('e3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.reveal_access_note(%L)', (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'a provider who only bid reads nothing');
RESET ROLE;
SELECT pg_temp.act('e6666666-6666-4666-8666-666666666666');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.reveal_access_note(%L)', (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'support reads nothing');
RESET ROLE;
SELECT pg_temp.act('e8888888-8888-4888-8888-888888888888');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.reveal_access_note(%L)', (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'super admin reads nothing');
RESET ROLE;

SELECT is(
  (SELECT array_agg(r ORDER BY r) FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r
   WHERE has_table_privilege(r, 'private.request_access_notes', 'SELECT')),
  NULL, 'no client role can read the note table');

-- ---------------------------------------------------------------------------
-- After the work, it is gone
-- ---------------------------------------------------------------------------
UPDATE public.requests SET status = 'cancelled' WHERE id = (SELECT id FROM ids WHERE name = 'r1');
SELECT is((SELECT count(*)::int FROM private.request_access_notes
           WHERE request_id = (SELECT id FROM ids WHERE name = 'r1')), 0,
  'leaving the window deletes the note (data flow 8)');

SELECT pg_temp.act('e2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.reveal_access_note(%L)', (SELECT id FROM ids WHERE name = 'r1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'the provider cannot read it after the job');
RESET ROLE;

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is(public.reveal_access_note((SELECT id FROM ids WHERE name = 'r1')), NULL::text,
  'and the customer finds nothing there either');
SELECT throws_ok(
  format('SELECT public.set_request_access_note(%L, %L)', (SELECT id FROM ids WHERE name = 'r1'), 'late'),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'nor can one be added to a finished job');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Export and erasure
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT e -> 'access_note' #>> '{}'
   FROM jsonb_array_elements(private.collect_personal_data('e1111111-1111-4111-8111-111111111111')
                             -> 'saved_places') e
   WHERE e ->> 'label' = 'Home, 12 Admiralty Way'),
  'Gate code 4471, ring twice', 'the export carries the user''s own notes, readable');

SELECT pg_temp.act('e1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT is(public.set_saved_place_access_note((SELECT id FROM ids WHERE name = 'home'), '  '), false,
  'a blank note clears it');
SELECT is(public.remove_saved_place((SELECT id FROM ids WHERE name = 'office')), true,
  'the owner removes a place');
RESET ROLE;

SELECT private.erase_account('e1111111-1111-4111-8111-111111111111');
SELECT is((SELECT count(*)::int FROM public.saved_places
           WHERE user_id = 'e1111111-1111-4111-8111-111111111111'), 0,
  'erasure removes every saved place');

SELECT * FROM finish();
ROLLBACK;
