-- Saved places and the access note (RLS matrix §2; AUDIT-2026-09-22c).
--
-- The address book is the easy half: own rows, every verb, three updatable columns, and nobody
-- else -- support and super admin included. The access note is the half that matters. The claim
-- under test is that **the provider working the job reads the note while they are on the way or
-- at the door, and at no other time; nobody else reads it at all; and it is gone once the job
-- is over.**
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(41);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-111111111111', '2348000004001'),   -- customer
  ('f2222222-2222-4222-8222-222222222222', '2348000004002'),   -- provider, assigned
  ('f3333333-3333-4333-8333-333333333333', '2348000004003'),   -- provider, bid only
  ('f4444444-4444-4444-8444-444444444444', '2348000004004'),   -- a stranger
  ('f5555555-5555-4555-8555-555555555555', '2348000004005');   -- super admin

UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'f1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('f2222222-2222-4222-8222-222222222222', 'f3333333-3333-4333-8333-333333333333');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('f4444444-4444-4444-8444-444444444444', 'f5555555-5555-4555-8555-555555555555');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('f2222222-2222-4222-8222-222222222222'),
  ('f3333333-3333-4333-8333-333333333333');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('f5555555-5555-4555-8555-555555555555', ARRAY['super_admin']::public.admin_role[],
   ARRAY['NG']::char(2)[]);

CREATE TEMP TABLE sids (name text PRIMARY KEY, id uuid);
GRANT ALL ON sids TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- ---------------------------------------------------------------------------
-- Structure: the ciphertext is never granted, and the note's own table is out of reach.
-- ---------------------------------------------------------------------------
SELECT ok(NOT has_column_privilege('authenticated', 'public.saved_places',
            'access_note_ciphertext', 'SELECT'),
  'a client cannot select a saved place''s access note');
SELECT ok(NOT has_column_privilege('authenticated', 'public.saved_places',
            'access_note_ciphertext', 'UPDATE')
          AND NOT has_column_privilege('authenticated', 'public.saved_places',
            'access_note_ciphertext', 'INSERT'),
  'nor write it except through the function');
SELECT ok(NOT has_column_privilege('authenticated', 'public.saved_places', 'user_id', 'UPDATE'),
  'and a place cannot be moved to somebody else''s book');
SELECT ok(NOT has_table_privilege('authenticated', 'private.request_access_notes', 'SELECT'),
  'no client role reads the notes attached to requests');

-- ---------------------------------------------------------------------------
-- The address book: own rows, every verb.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO public.saved_places (label, point, landmark_note)
VALUES ('Home', extensions.st_setsrid(extensions.st_makepoint(3.4750, 6.4459), 4326)::extensions.geography,
        'Blue gate');
INSERT INTO sids SELECT 'home', id FROM public.saved_places WHERE label = 'Home';
SELECT is((SELECT user_id FROM public.saved_places WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  'f1111111-1111-4111-8111-111111111111'::uuid, 'the owner defaults to the caller');
SELECT throws_ok(
  $$INSERT INTO public.saved_places (user_id, label, point)
    VALUES ('f4444444-4444-4444-8444-444444444444', 'Theirs',
            extensions.st_setsrid(extensions.st_makepoint(3.47, 6.44), 4326)::extensions.geography)$$,
  '42501', NULL, 'and a place cannot be written into somebody else''s book');
UPDATE public.saved_places SET label = 'Home (Lekki)' WHERE id = (SELECT id FROM sids WHERE name = 'home');
SELECT is((SELECT label FROM public.saved_places WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  'Home (Lekki)', 'the owner renames it');
SELECT is((SELECT has_access_note FROM public.saved_places
           WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  false, 'and it has no access note yet');
SELECT throws_ok($$SELECT access_note_ciphertext FROM public.saved_places$$,
  '42501', NULL, 'selecting the ciphertext column is refused outright');

SELECT is(public.set_saved_place_access_note((SELECT id FROM sids WHERE name = 'home'),
            '\x0102030405'::bytea),
  true, 'the owner sets an access note through the function');
SELECT is((SELECT has_access_note FROM public.saved_places
           WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  true, 'and the book now says one is saved, without showing it');
SELECT throws_ok(
  format($$SELECT public.set_saved_place_access_note(%L, '\x'::bytea)$$,
    (SELECT id FROM sids WHERE name = 'home')),
  '22023', 'ERR_INVALID_ARGUMENT', 'an empty ciphertext is not a note');
RESET ROLE;

SELECT pg_temp.act('f4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.saved_places), 0,
  'a stranger sees nobody''s places');
SELECT throws_ok(
  format($$SELECT public.set_saved_place_access_note(%L, '\x09'::bytea)$$,
    (SELECT id FROM sids WHERE name = 'home')),
  'P0001', 'ERR_SAVED_PLACE_NOT_FOUND', 'and cannot overwrite a note on one');
UPDATE public.saved_places SET label = 'Mine now' WHERE id = (SELECT id FROM sids WHERE name = 'home');
DELETE FROM public.saved_places WHERE id = (SELECT id FROM sids WHERE name = 'home');
RESET ROLE;
SELECT is((SELECT label FROM public.saved_places WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  'Home (Lekki)', 'nor rename or delete it');

SELECT pg_temp.act('f5555555-5555-4555-8555-555555555555', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.saved_places), 0,
  'super admin reads no saved places: the matrix gives nobody an operator''s view');
RESET ROLE;

-- The cap, from configuration.
UPDATE public.remote_config SET value = '2' WHERE key = 'saved_places_max' AND country_code IS NULL;
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO public.saved_places (label, point)
VALUES ('Office', extensions.st_setsrid(extensions.st_makepoint(3.42, 6.43), 4326)::extensions.geography);
SELECT throws_ok(
  $$INSERT INTO public.saved_places (label, point)
    VALUES ('Gym', extensions.st_setsrid(extensions.st_makepoint(3.41, 6.42), 4326)::extensions.geography)$$,
  'P0001', 'ERR_SAVED_PLACE_LIMIT', 'a third place past a cap of two is refused');
DELETE FROM public.saved_places WHERE label = 'Office';
SELECT is((SELECT count(*)::int FROM public.saved_places), 1, 'the owner deletes their own place');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A request, a note copied from the book, and a job that goes all the way.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
INSERT INTO sids VALUES ('r1', public.create_request(
  'key-sp-create-r1-00000000001', 'errands_delivery', 'Take a parcel to Ikoyi',
  '12 Admiralty Way', 'standard', false, NULL, 'Blue gate', 6.4459, 3.4750,
  '4 Awolowo Road, Flat 3B', 'Ring twice', 6.4531, 3.4356));
SELECT is(public.request_has_access_note((SELECT id FROM sids WHERE name = 'r1')), false,
  'a new request carries no note');
SELECT throws_ok(
  format($$SELECT public.set_request_access_note(%L, '\x01'::bytea, %L)$$,
    (SELECT id FROM sids WHERE name = 'r1'), (SELECT id FROM sids WHERE name = 'home')),
  '22023', 'ERR_INVALID_ARGUMENT', 'fresh ciphertext and a saved place at once is ambiguous');
SELECT is(public.set_request_access_note((SELECT id FROM sids WHERE name = 'r1'),
            p_saved_place_id := (SELECT id FROM sids WHERE name = 'home')),
  true, 'the customer attaches the note from their saved place');
SELECT is(public.request_has_access_note((SELECT id FROM sids WHERE name = 'r1')), true,
  'and the request now says it carries one');
SELECT public.publish_request((SELECT id FROM sids WHERE name = 'r1'), 'key-sp-publish-r1-0000000001');
RESET ROLE;

SELECT pg_temp.act('f4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.set_request_access_note(%L, '\x09'::bytea)$$,
    (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'a stranger cannot attach a note to somebody''s request');
SELECT throws_ok(
  format($$SELECT public.request_has_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'or learn whether it has one');
SELECT throws_ok($$SELECT * FROM private.request_access_notes$$,
  '42501', NULL, 'or read the table behind it');
RESET ROLE;

SELECT pg_temp.act('f2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
INSERT INTO sids VALUES ('o1', public.create_offer(
  'key-sp-offer-f2-0000000000001', (SELECT id FROM sids WHERE name = 'r1'), 800000, NULL));
RESET ROLE;
SELECT pg_temp.act('f3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT public.create_offer('key-sp-offer-f3-0000000000001', (SELECT id FROM sids WHERE name = 'r1'),
  850000, NULL);
RESET ROLE;

SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-sp-accept-o1-000000001', (SELECT id FROM sids WHERE name = 'o1'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM sids WHERE name = 'r1')),
  'assigned'::public.job_status, 'the job is funded and assigned');

-- Assigned is not yet the window.
SELECT pg_temp.act('f2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reveal_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_ACCESS_NOTE_WINDOW_CLOSED',
  'the assigned provider does not get the note before setting off');
SELECT is(public.set_job_status('key-sp-enroute-f2-000001', (SELECT id FROM sids WHERE name = 'r1'),
            'en_route'),
  'en_route'::public.job_status, 'the provider sets off');
SELECT is(public.reveal_access_note((SELECT id FROM sids WHERE name = 'r1')),
  '\x0102030405'::bytea, 'and now reads exactly the note the customer saved');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'access_note.revealed'
             AND target_id = (SELECT id FROM sids WHERE name = 'r1')::text
             AND actor_id = 'f2222222-2222-4222-8222-222222222222'),
  1, 'and the reveal is audited with who read it');

SELECT pg_temp.act('f3333333-3333-4333-8333-333333333333');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reveal_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'a provider who only bid gets nothing, and learns nothing');
RESET ROLE;
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reveal_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'the customer is not a provider on their own job');
-- The gate code changed while the provider was on the way.
SELECT is(public.set_request_access_note((SELECT id FROM sids WHERE name = 'r1'), '\x0a0b'::bytea),
  true, 'the customer replaces the note mid-job');
RESET ROLE;
SELECT pg_temp.act('f5555555-5555-4555-8555-555555555555', 'aal2');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reveal_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'super admin does not read access notes either');
RESET ROLE;

SELECT pg_temp.act('f2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT is(public.reveal_access_note((SELECT id FROM sids WHERE name = 'r1')),
  '\x0a0b'::bytea, 'and the provider reads the new one');
RESET ROLE;

-- Editing the saved place afterwards does not reach into the job: the copy was taken.
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT public.set_saved_place_access_note((SELECT id FROM sids WHERE name = 'home'), NULL);
SELECT is((SELECT has_access_note FROM public.saved_places
           WHERE id = (SELECT id FROM sids WHERE name = 'home')),
  false, 'clearing the saved place''s note clears it from the book');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.request_access_notes
           WHERE request_id = (SELECT id FROM sids WHERE name = 'r1')),
  1, 'and leaves the job''s copy alone');

-- The job ends; the note goes.
UPDATE public.requests SET status = 'cancelled' WHERE id = (SELECT id FROM sids WHERE name = 'r1');
SELECT is((SELECT count(*)::int FROM private.request_access_notes
           WHERE request_id = (SELECT id FROM sids WHERE name = 'r1')),
  0, 'the note is deleted when the job stops being active');
SELECT pg_temp.act('f2222222-2222-4222-8222-222222222222');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reveal_access_note(%L)$$, (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_ACCESS_NOTE_WINDOW_CLOSED', 'and the provider is told the window has closed');
RESET ROLE;
SELECT pg_temp.act('f1111111-1111-4111-8111-111111111111');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.set_request_access_note(%L, '\x01'::bytea)$$,
    (SELECT id FROM sids WHERE name = 'r1')),
  'P0001', 'ERR_ACCESS_NOTE_WINDOW_CLOSED', 'nor can the customer put one back afterwards');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Erasure takes the address book with the account.
-- ---------------------------------------------------------------------------
SELECT private.erase_account('f1111111-1111-4111-8111-111111111111');
SELECT is((SELECT count(*)::int FROM public.saved_places
           WHERE user_id = 'f1111111-1111-4111-8111-111111111111'),
  0, 'an erased account keeps no saved places');

SELECT * FROM finish();
ROLLBACK;
