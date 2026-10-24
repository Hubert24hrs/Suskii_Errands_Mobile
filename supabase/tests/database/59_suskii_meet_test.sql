-- Suskii Meet: social meet-ups. Visible in the host's own country to signed-in people who have
-- not blocked each other; the attendee list only to the host and the people going; capacity held
-- under concurrency by a row lock; moderation as for a request; export and erasure cover it.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(39);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-595959595959', '2348000005901'),   -- host
  ('b2222222-2222-4222-8222-595959595959', '2348000005902'),   -- joins
  ('b3333333-3333-4333-8333-595959595959', '2348000005903'),   -- joins, fills it
  ('b4444444-4444-4444-8444-595959595959', '2348000005904'),   -- too late
  ('b5555555-5555-4555-8555-595959595959', '2348000005905'),   -- blocked by the host
  ('b6666666-6666-4666-8666-595959595959', '254700005906');    -- another country
UPDATE public.profiles SET country_code = 'NG', display_name = 'Ada Okafor'
WHERE user_id = 'b1111111-1111-4111-8111-595959595959';
UPDATE public.profiles SET country_code = 'NG', display_name = 'Bisi Ade'
WHERE user_id = 'b2222222-2222-4222-8222-595959595959';
UPDATE public.profiles SET country_code = 'NG', display_name = 'Chidi Eze'
WHERE user_id = 'b3333333-3333-4333-8333-595959595959';
UPDATE public.profiles SET country_code = 'NG', display_name = 'Dayo'
WHERE user_id IN ('b4444444-4444-4444-8444-595959595959', 'b5555555-5555-4555-8555-595959595959');
UPDATE public.profiles SET country_code = 'KE', language = 'en', display_name = 'Wanjiru'
WHERE user_id = 'b6666666-6666-4666-8666-595959595959';
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('b1111111-1111-4111-8111-595959595959', 'b5555555-5555-4555-8555-595959595959');

CREATE TEMP TABLE mv (name text PRIMARY KEY, val text);
GRANT ALL ON mv TO authenticated, service_role;
CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;
CREATE FUNCTION pg_temp.v(p_name text) RETURNS uuid LANGUAGE sql AS $fn$
  SELECT val::uuid FROM mv WHERE name = p_name;
$fn$;

-- Structure.
SELECT ok(NOT has_table_privilege('authenticated', 'public.meetups', 'SELECT'),
  'no client reads the meet-ups table directly');
SELECT ok(NOT has_table_privilege('authenticated', 'public.meetup_attendees', 'SELECT'),
  'nor the attendee table');
SELECT ok(NOT has_function_privilege('anon', 'public.list_meetups(double precision, double precision, integer, public.meetup_topic, integer)', 'EXECUTE'),
  'nobody signed out can list meet-ups');

-- Creating.
SELECT pg_temp.act('b1111111-1111-4111-8111-595959595959');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.create_meetup('key-meet-past-0000000001', 'Morning run', '',
  'sports_fitness', 'Freedom Park', 6.4498, 3.3920, now() + interval '5 minutes',
  now() + interval '2 hours', 10)$$, 'P0001', 'ERR_MEETUP_TIME_INVALID',
  'a meet-up starts at least 30 minutes ahead');
SELECT throws_ok($$SELECT public.create_meetup('key-meet-long-0000000001', 'Marathon', '',
  'sports_fitness', 'Freedom Park', 6.4498, 3.3920, now() + interval '1 day',
  now() + interval '3 days', 10)$$, 'P0001', 'ERR_MEETUP_TIME_INVALID',
  'and lasts at most 24 hours');
SELECT throws_ok($$SELECT public.create_meetup('key-meet-cap-00000000001', 'Tiny', '',
  'social', 'Freedom Park', 6.4498, 3.3920, now() + interval '1 day',
  now() + interval '1 day 2 hours', 1)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'capacity is at least two');
INSERT INTO mv VALUES ('m', public.create_meetup('key-meet-create-00000001', 'Saturday book club',
  'We read and talk about one novel a month.', 'learning', 'Terra Kulture, Victoria Island',
  6.4300, 3.4200, now() + interval '2 days', now() + interval '2 days 2 hours', 2)::text);
SELECT is(public.create_meetup('key-meet-create-00000001', 'Saturday book club', '', 'learning',
  'Terra Kulture, Victoria Island', 6.43, 3.42, now() + interval '2 days',
  now() + interval '2 days 2 hours', 2), pg_temp.v('m'), 'a retry is the same meet-up');
SELECT is((SELECT is_host::text || attendee_count FROM public.get_meetup(pg_temp.v('m'))),
  'true0', 'the host sees it as theirs, with nobody going yet');
RESET ROLE;
SELECT is((SELECT moderation_status::text FROM public.meetups WHERE id = pg_temp.v('m')),
  'approved', 'clean text is approved at once');

-- Seeing it.
SELECT pg_temp.act('b2222222-2222-4222-8222-595959595959');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.list_meetups(6.45, 3.40) WHERE id = pg_temp.v('m')), 1,
  'another person in Nigeria finds it');
SELECT is((SELECT host_first_name FROM public.list_meetups() WHERE id = pg_temp.v('m')), 'Ada',
  'with the host''s first name only');
SELECT ok((SELECT distance_km BETWEEN 2 AND 5 FROM public.list_meetups(6.45, 3.40)
           WHERE id = pg_temp.v('m')), 'and how far away it is from where they are');
SELECT is((SELECT count(*)::int FROM public.list_meetups(9.07, 7.40, 50) WHERE id = pg_temp.v('m')),
  0, 'but not from Abuja with a 50 km radius');
SELECT is((SELECT count(*)::int FROM public.list_meetups(NULL, NULL, 50, 'sports_fitness')
           WHERE id = pg_temp.v('m')), 0, 'and not under another topic');
SELECT throws_ok(format($$SELECT * FROM public.meetup_attendees(%L)$$, pg_temp.v('m')),
  'P0001', 'ERR_MEETUP_NOT_FOUND', 'somebody not going cannot see who is');
RESET ROLE;

SELECT pg_temp.act('b6666666-6666-4666-8666-595959595959');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.list_meetups() WHERE id = pg_temp.v('m')), 0,
  'somebody in Kenya does not see a Lagos meet-up');
SELECT throws_ok(format($$SELECT public.join_meetup('key-meet-join-ke-0000001', %L)$$,
  pg_temp.v('m')), 'P0001', 'ERR_MEETUP_NOT_FOUND', 'nor join it');
RESET ROLE;

SELECT pg_temp.act('b5555555-5555-4555-8555-595959595959');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.list_meetups() WHERE id = pg_temp.v('m')), 0,
  'somebody the host blocked does not see it');
SELECT throws_ok(format($$SELECT public.join_meetup('key-meet-join-bl-0000001', %L)$$,
  pg_temp.v('m')), 'P0001', 'ERR_MEETUP_NOT_FOUND', 'nor join it');
RESET ROLE;

-- Joining.
SELECT pg_temp.act('b2222222-2222-4222-8222-595959595959');
SET LOCAL ROLE authenticated;
SELECT is(public.join_meetup('key-meet-join-b2-0000001', pg_temp.v('m')), 1, 'Bisi joins');
SELECT is(public.join_meetup('key-meet-join-b2-0000001', pg_temp.v('m')), 1, 'a retry is the same join');
SELECT is((SELECT string_agg(first_name || ':' || is_host::text, ',')
           FROM public.meetup_attendees(pg_temp.v('m'))), 'Ada:true,Bisi:false',
  'once going, Bisi sees who else is: first names only');
RESET ROLE;

SELECT pg_temp.act('b3333333-3333-4333-8333-595959595959');
SET LOCAL ROLE authenticated;
SELECT is(public.join_meetup('key-meet-join-b3-0000001', pg_temp.v('m')), 2, 'Chidi takes the last place');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-595959595959');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format($$SELECT public.join_meetup('key-meet-join-b4-0000001', %L)$$,
  pg_temp.v('m')), 'P0001', 'ERR_MEETUP_FULL', 'a full meet-up takes nobody else');
RESET ROLE;

SELECT pg_temp.act('b3333333-3333-4333-8333-595959595959');
SET LOCAL ROLE authenticated;
SELECT ok(public.leave_meetup(pg_temp.v('m')), 'Chidi leaves');
SELECT ok(NOT public.leave_meetup(pg_temp.v('m')), 'leaving twice changes nothing');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-595959595959');
SET LOCAL ROLE authenticated;
SELECT is(public.join_meetup('key-meet-join-b4-0000002', pg_temp.v('m')), 2,
  'and the place he freed is taken');
SELECT is((SELECT count(*)::int FROM public.my_meetups() WHERE id = pg_temp.v('m')), 1,
  'it is in the attendee''s own list');
SELECT throws_ok(format($$SELECT public.cancel_meetup('key-meet-cancel-b4-00001', %L)$$,
  pg_temp.v('m')), 'P0001', 'ERR_MEETUP_NOT_FOUND', 'only the host can cancel it');
RESET ROLE;

-- Cancelling tells everyone going, without the title on a lock screen.
SELECT pg_temp.act('b1111111-1111-4111-8111-595959595959');
SET LOCAL ROLE authenticated;
SELECT is(public.cancel_meetup('key-meet-cancel-0000001', pg_temp.v('m')),
  'cancelled'::public.meetup_status, 'the host cancels');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE body_key = 'notification.meetup.cancelled.body'
             AND params ->> 'meetup_id' = pg_temp.v('m')::text), 2,
  'both people going are told');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE body_key = 'notification.meetup.cancelled.body'
             AND params::text LIKE '%book club%'), 0, 'and the notification carries no title');

SELECT pg_temp.act('b2222222-2222-4222-8222-595959595959');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.list_meetups() WHERE id = pg_temp.v('m')), 0,
  'a cancelled meet-up leaves the list');
SELECT is((SELECT status FROM public.my_meetups() WHERE id = pg_temp.v('m')),
  'cancelled'::public.meetup_status, 'but stays in the attendee''s own, marked cancelled');
RESET ROLE;

-- The host limit.
SELECT pg_temp.act('b1111111-1111-4111-8111-595959595959');
SET LOCAL ROLE authenticated;
SELECT public.create_meetup('key-meet-lim-' || g || '-0000000', 'Five-a-side ' || g, '',
  'sports_fitness', 'Teslim Balogun Stadium', 6.50, 3.36, now() + (g || ' days')::interval,
  now() + (g || ' days')::interval + interval '1 hour', 12)
FROM generate_series(3, 5) g;
SELECT throws_ok($$SELECT public.create_meetup('key-meet-lim-6-0000000', 'One too many', '',
  'social', 'Somewhere public', 6.50, 3.36, now() + interval '6 days',
  now() + interval '6 days 1 hour', 12)$$, 'P0001', 'ERR_MEETUP_LIMIT_REACHED',
  'a host has at most three upcoming meet-ups');
RESET ROLE;

-- Moderation: a held meet-up publishes and opens a case; upholding the case cancels it.
INSERT INTO public.prohibited_items (key, action, match_terms)
VALUES ('test_meet_hold', 'hold', ARRAY['zzheldterm']);
SELECT pg_temp.act('b2222222-2222-4222-8222-595959595959');
SET LOCAL ROLE authenticated;
INSERT INTO mv VALUES ('held', public.create_meetup('key-meet-held-000000001', 'Zzheldterm swap',
  '', 'other', 'Ikeja City Mall', 6.61, 3.36, now() + interval '1 day',
  now() + interval '1 day 1 hour', 10)::text);
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.moderation_cases
           WHERE subject_kind = 'meetup' AND subject_id = pg_temp.v('held')::text), 1,
  'a held meet-up opens a moderation case');
UPDATE public.moderation_cases SET status = 'upheld'
WHERE subject_kind = 'meetup' AND subject_id = pg_temp.v('held')::text;
SELECT is((SELECT status::text || ':' || moderation_status::text FROM public.meetups
           WHERE id = pg_temp.v('held')), 'cancelled:rejected', 'upholding it takes the meet-up down');

-- Export and erasure.
SELECT is(jsonb_array_length(private.collect_personal_data('b1111111-1111-4111-8111-595959595959')
          -> 'meetups_hosted'), 4, 'the host''s export lists the meet-ups they hosted');
SELECT private.erase_account('b1111111-1111-4111-8111-595959595959');
SELECT is((SELECT count(*)::int FROM public.meetups
           WHERE host_id = 'b1111111-1111-4111-8111-595959595959'), 0,
  'erasure removes the meet-ups they hosted');

SELECT * FROM finish();
ROLLBACK;
