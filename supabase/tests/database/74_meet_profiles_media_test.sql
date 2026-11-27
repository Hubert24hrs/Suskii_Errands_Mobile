-- Meet v5 M1-PR3 (20261126120200): profiles, preferences, prompts, photos and the media buckets
-- (design §2.7, §3.2.1, §4.2, §8.2 profile surfaces, §8.5, §8.6, §8.7; D5, D15).
--
-- What has to hold: no client role reaches a Meet table; every profile function refuses
-- somebody Meet is off for or who has not passed the 18+ gate; first name, bio and prompts are
-- screened before anything is written; the area is a cell and never the point; "show me" is
-- consented, applied one way and read by nobody but its owner; a photo goes inbox → worker →
-- review, with a limit, and is fetched only through the policy (owner, an eligible viewer in the
-- same country who may see the profile, a moderator in scope, and nobody else); and no auth uid
-- appears in any path somebody else's app can read.
--
-- Review of PR #121: visibility follows access (a barred phone or outdated guidelines hides the
-- person and stops them fetching), the ways out stay open to somebody shut out, invisible
-- characters and any punctuation inside a digit run are caught, prompt answers are screened by a
-- trigger, only staff can sign a meet-media URL, the inbox is capped and swept, an
-- underage-appearance rejection keeps its files, account erasure reaches Meet, and a Yoruba name
-- with its tones is a name.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(214);

INSERT INTO auth.users (id, phone) VALUES
  ('b7411111-1111-4111-8111-747474747474', '2348000007401'),   -- A: the owner, NG
  ('b7422222-2222-4222-8222-747474747474', '2348000007402'),   -- B: a viewer, NG
  ('b7433333-3333-4333-8333-747474747474', '2348000007403'),   -- C: blocked by A, NG
  ('b7444444-4444-4444-8444-747474747474', '2337000007404'),   -- D: Ghana
  ('b7455555-5555-4555-8555-747474747474', '2348000007405'),   -- M: refused as a minor
  ('b7466666-6666-4666-8666-747474747474', '2348000007406'),   -- E: never checked in
  ('b7477777-7777-4777-8777-747474747474', '2348000007407'),   -- F: did an errand with A
  ('b7481111-1111-4111-8111-747474747474', '2348000007481'),   -- meet moderator, NG
  ('b7482222-2222-4222-8222-747474747474', '2348000007482'),   -- meet moderator, KE
  ('b7483333-3333-4333-8333-747474747474', '2348000007483'),   -- super admin
  ('b7484444-4444-4444-8444-747474747474', '2348000007484');   -- support agent, NG
UPDATE public.profiles SET country_code = 'NG' WHERE user_id::text LIKE 'b74%-747474747474';
UPDATE public.profiles SET country_code = 'GH'
WHERE user_id = 'b7444444-4444-4444-8444-747474747474';
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('b7481111-1111-4111-8111-747474747474', ARRAY['meet_moderator']::public.admin_role[], ARRAY['NG']::char(2)[]),
  ('b7482222-2222-4222-8222-747474747474', ARRAY['meet_moderator']::public.admin_role[], ARRAY['KE']::char(2)[]),
  ('b7483333-3333-4333-8333-747474747474', ARRAY['super_admin']::public.admin_role[], NULL),
  ('b7484444-4444-4444-8444-747474747474', ARRAY['support_agent']::public.admin_role[], ARRAY['NG']::char(2)[]);

UPDATE public.feature_flags SET enabled = true WHERE key = 'meet.v5' AND country_code IS NULL;
INSERT INTO private.meet_testers (user_id)
SELECT id FROM auth.users WHERE id::text LIKE 'b74%-747474747474';
INSERT INTO public.meet_eligibility (user_id, status, birth_date, guidelines_version) VALUES
  ('b7411111-1111-4111-8111-747474747474', 'eligible', '1996-04-02', 1),
  ('b7455555-5555-4555-8555-747474747474', 'refused_minor', NULL, 1);
UPDATE public.profiles SET customer_verification = 'verified'
WHERE user_id = 'b7411111-1111-4111-8111-747474747474';
UPDATE public.profiles SET provider_verification = 'verified'
WHERE user_id = 'b7477777-7777-4777-8777-747474747474';
INSERT INTO public.provider_profiles (user_id) VALUES ('b7477777-7777-4777-8777-747474747474');

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1')
RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- An eligible member with an active, discoverable profile and one approved photo, as the review
-- in M1-PR4 will leave one, at a point given as lat/lng.
CREATE FUNCTION pg_temp.member(p_user uuid, p_name text, p_lat double precision,
                               p_lng double precision, p_birth date, p_gender text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_profile uuid;
  v_photo   uuid := gen_random_uuid();
  v_cell    text := extensions.ST_GeoHash(extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326), 5);
BEGIN
  INSERT INTO public.meet_eligibility (user_id, status, birth_date, guidelines_version)
  VALUES (p_user, 'eligible', p_birth, 1);
  INSERT INTO public.meet_profiles (user_id, country_code, first_name, gender, area_geohash,
                                    area_point, area_set_at)
  SELECT p_user, p.country_code, p_name, p_gender, v_cell,
         extensions.ST_SetSRID(extensions.ST_PointFromGeoHash(v_cell), 4326)::extensions.geography,
         now() - interval '1 day'
  FROM public.profiles p WHERE p.user_id = p_user
  RETURNING id INTO v_profile;
  INSERT INTO public.meet_photos (id, profile_id, position, media_path, thumb_path, sha256, width,
                                  height, mime, status)
  VALUES (v_photo, v_profile, 0, v_profile || '/p/' || v_photo || '.jpg',
          v_profile || '/pt/' || v_photo || '.jpg', sha256(convert_to(p_name, 'UTF8')), 1080, 1350,
          'image/jpeg', 'approved');
  INSERT INTO storage.objects (bucket_id, name) VALUES
    ('meet-media', v_profile || '/p/' || v_photo || '.jpg'),
    ('meet-media', v_profile || '/pt/' || v_photo || '.jpg');
  PERFORM private.meet_refresh_profile(v_profile);
  UPDATE public.meet_profiles SET discoverable = true WHERE id = v_profile;
  RETURN v_profile;
END $fn$;

-- Calls each of this PR's functions with NULL arguments as the current role and records how each
-- one ended. meet_get_state and meet_check_in have their own tests.
CREATE FUNCTION pg_temp.outcomes()
RETURNS TABLE (fn text, outcome text)
LANGUAGE plpgsql AS $fn$
DECLARE
  r       record;
  v_state text;
  v_msg   text;
BEGIN
  FOR r IN
    SELECT p.proname::text AS name,
           (SELECT string_agg(format('NULL::%s', format_type(a.t, NULL)), ', ' ORDER BY a.i)
            FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a (t, i)) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'meet_accept_guidelines', 'meet_save_profile', 'meet_set_area', 'meet_set_discovery_prefs',
      'meet_get_my_profile', 'meet_submit_photo', 'meet_remove_photo', 'meet_reorder_photos',
      'meet_save_prompt', 'meet_remove_prompt', 'meet_set_discoverable', 'meet_pause',
      'meet_set_privacy', 'meet_delete_profile')
    ORDER BY 1
  LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM public.%I(%s)', r.name, coalesce(r.args, ''));
      fn := r.name; outcome := 'returned';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      fn := r.name; outcome := v_state || ' ' || v_msg;
    END;
    RETURN NEXT;
  END LOOP;
END $fn$;

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE outcomes (who text, fn text, outcome text);
CREATE TEMP TABLE results (name text PRIMARY KEY, r jsonb);
GRANT ALL ON ids, outcomes, results TO authenticated, service_role;

INSERT INTO ids VALUES
  ('b', pg_temp.member('b7422222-2222-4222-8222-747474747474', 'Bola', 6.4281, 3.4219, '1994-01-15', 'woman')),
  ('c', pg_temp.member('b7433333-3333-4333-8333-747474747474', 'Chidi', 6.4549, 3.4246, '1993-07-07', 'man')),
  ('d', pg_temp.member('b7444444-4444-4444-8444-747474747474', 'Dede', 5.6037, -0.1870, '1995-03-03', 'woman')),
  ('f', pg_temp.member('b7477777-7777-4777-8777-747474747474', 'Funmi', 6.5095, 3.3711, '1992-11-11', 'woman'));
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('b7411111-1111-4111-8111-747474747474', 'b7433333-3333-4333-8333-747474747474');

-- A and F did an errand together: A asked, F was the provider.
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('errand', public.create_request(
  'key-74-errand-req-000001', 'personal_assistance', 'Queue at the bank for me',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM ids WHERE name = 'errand'), 'key-74-errand-pub-000001');
RESET ROLE;
SELECT pg_temp.act('b7477777-7777-4777-8777-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('errand_offer', public.create_offer(
  'key-74-errand-offer-0001', (SELECT id FROM ids WHERE name = 'errand'), 500000, NULL));
RESET ROLE;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-74-errand-accept-01', (SELECT id FROM ids WHERE name = 'errand_offer'));
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Structure: functions are the only door.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT coalesce(array_agg(t || ':' || r || ':' || p ORDER BY 1), '{}')
   FROM unnest(ARRAY['meet_interest_keys', 'meet_prompt_keys', 'meet_eligibility',
                     'meet_age_refusal_devices', 'meet_profiles', 'meet_discovery_prefs',
                     'meet_photos', 'meet_prompts']) t,
        unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
        unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   WHERE has_table_privilege(r, 'public.' || t, p)),
  '{}'::text[], 'no client role, and not the service role, holds any privilege on a Meet table');
SELECT is(
  (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname LIKE 'meet\_%' AND c.relkind = 'r'
     AND c.relrowsecurity AND c.relforcerowsecurity), 8,
  'all eight force row level security');
SELECT set_eq(
  $$SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'private') AND p.prosrc ~ 'meet_discovery_prefs'$$,
  ARRAY['meet_set_discovery_prefs', 'meet_get_my_profile', 'meet_erase_profile',
        'meet_discoverable_to'],
  '"show me" is read by the owner''s own functions and the discovery predicate, and no staff function');
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.gateway_meet_media_ingested(text, uuid, text, text, text, integer, integer, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.gateway_meet_media_failed(text, uuid, text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.gateway_meet_media_ingested(text, uuid, text, text, text, integer, integer, text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.gateway_meet_media_failed(text, uuid, text)', 'EXECUTE'),
  'the media worker''s two reports are the service role''s alone');
SELECT is(
  (SELECT array_agg(id || ':' || public::text || ':' || (file_size_limit / 1048576)::text || ':'
                    || array_to_string(allowed_mime_types, ',') ORDER BY id)
   FROM storage.buckets WHERE id LIKE 'meet-%'),
  ARRAY['meet-inbox:false:8:image/jpeg,image/png,image/webp',
        'meet-media:false:5:image/jpeg,image/png,image/webp',
        'meet-verify:false:5:image/jpeg'],
  'three private buckets with their limits');
SELECT is(
  (SELECT array_agg(policyname::text || ':' || cmd ORDER BY policyname) FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'meet\_%'),
  ARRAY['meet_inbox_own_insert:INSERT', 'meet_media_read:SELECT', 'meet_verify_own_insert:INSERT'],
  'uploads into the inbox and the selfies, reads from meet-media, and nothing else');
SELECT is(
  (SELECT count(*)::int FROM pg_constraint
   WHERE conrelid = 'public.legal_documents'::regclass AND conname = 'legal_documents_type_check'
     AND pg_get_constraintdef(oid) ~ 'meet_guidelines' AND pg_get_constraintdef(oid) ~ 'child_safety'
     AND pg_get_constraintdef(oid) ~ 'meet_reward_rules' AND pg_get_constraintdef(oid) ~ '''meet_terms'''
     AND pg_get_constraintdef(oid) ~ 'provider_agreement'), 1,
  'legal documents gain the four Meet types and keep the old ones');
SELECT ok(
  (SELECT count(*) = 30 FROM public.meet_interest_keys WHERE active)
  AND (SELECT count(*) = 20 FROM public.meet_prompt_keys WHERE active),
  'thirty interests and twenty prompts ship as reference data');

-- ---------------------------------------------------------------------------
-- Deny: the flag, then eligibility.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7466666-6666-4666-8666-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'not_eligible', * FROM pg_temp.outcomes();
RESET ROLE;
SELECT pg_temp.act('b7455555-5555-4555-8555-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'minor', * FROM pg_temp.outcomes();
RESET ROLE;
UPDATE public.feature_flags SET enabled = false WHERE key = 'meet.v5' AND country_code IS NULL;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO outcomes SELECT 'flag_off', * FROM pg_temp.outcomes();
RESET ROLE;
UPDATE public.feature_flags SET enabled = true WHERE key = 'meet.v5' AND country_code IS NULL;

SELECT is((SELECT count(*)::int FROM outcomes WHERE who = 'flag_off'), 14, 'fourteen functions');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'flag_off' AND outcome <> 'P0001 ERR_FEATURE_UNAVAILABLE'),
  '{}'::text[], 'with meet.v5 off, every one refuses an eligible tester before looking at anything');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'not_eligible' AND outcome <> 'P0001 ERR_MEET_ELIGIBILITY_REQUIRED'),
  '{}'::text[], 'somebody who never checked in is sent to check in by all fourteen');
SELECT is(
  (SELECT coalesce(array_agg(fn || ': ' || outcome ORDER BY fn), '{}') FROM outcomes
   WHERE who = 'minor' AND outcome <> 'P0001 ERR_MEET_UNAVAILABLE'
     AND fn NOT IN ('meet_delete_profile', 'meet_remove_photo', 'meet_remove_prompt',
                    'meet_set_privacy')),
  '{}'::text[], 'somebody refused as under 18 gets unavailable from every function that lets anybody in');
SELECT is(
  (SELECT array_agg(fn || ': ' || outcome ORDER BY fn) FROM outcomes
   WHERE who = 'minor' AND fn IN ('meet_delete_profile', 'meet_remove_photo', 'meet_remove_prompt',
                                  'meet_set_privacy')),
  ARRAY['meet_delete_profile: 22023 ERR_IDEMPOTENCY_KEY_INVALID',
        'meet_remove_photo: 22023 ERR_IDEMPOTENCY_KEY_INVALID',
        'meet_remove_prompt: 22023 ERR_IDEMPOTENCY_KEY_INVALID',
        'meet_set_privacy: 22023 ERR_INVALID_ARGUMENT'],
  'while the ways out let them through to the argument checks (pause and hide, called with NULL, are not leaving)');
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-anon-000001', 'Ada', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, '42501', NULL, 'signed out, the grant refuses');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The profile.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000001', NULL, 'Hi', NULL, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'a profile cannot be created without a first name');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000002', 'ada_x', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'a first name with an underscore is a handle, and is refused');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000003', 'Ada2', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'so is one with a digit');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000004', 'ada.obi', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'or a dot');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000005', 'Ada', repeat('x', 301), NULL,
                     NULL, NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'a bio over 300 characters');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000006', 'Ada', NULL, 'casual', NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'an intent that is not one of the four');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000007', 'Ada', NULL, NULL, 'other',
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'a gender other than woman or man: nothing else is stored (OD-38)');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000008', 'Ada', NULL, NULL, NULL,
                     NULL, ARRAY['afrobeats', 'sugar'], NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'an interest that is not a key');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000009', 'Ada', NULL, NULL, NULL,
                     NULL, ARRAY['music','travel','beach','art','tech','faith','pets','coffee','comedy'],
                     NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'more than eight interests');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000010', 'Ada', NULL, NULL, 'woman',
                     NULL, NULL, NULL)$$, 'P0001', 'ERR_CONSENT_REQUIRED',
  'setting a gender the first time needs the sensitive-data consent (D5)');
SELECT is(public.meet_save_profile('key-74-a-000000011', '  Ada  ', 'Lagos girl, loves jollof',
            'friendship', 'woman', false, ARRAY['afrobeats', 'travel'], true)
          - 'id' - 'completeness',
  '{"first_name": "Ada", "bio": "Lagos girl, loves jollof", "intent": "friendship",
    "gender": "woman", "show_gender": false, "interests": ["afrobeats", "travel"], "area": null,
    "status": "draft", "discoverable": false, "paused": false, "verified": false, "held": false,
    "text_moderation": "clean", "version": 1}'::jsonb,
  'with it, the profile is created as a draft and returned to its owner');
RESET ROLE;
INSERT INTO ids SELECT 'a', id FROM public.meet_profiles
WHERE user_id = 'b7411111-1111-4111-8111-747474747474';
SELECT is((SELECT count(*)::int FROM public.consents
           WHERE user_id = 'b7411111-1111-4111-8111-747474747474' AND kind = 'meet_sensitive_data'),
  1, 'and meet_sensitive_data is recorded');
SELECT is((SELECT country_code FROM public.meet_profiles WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'NG', 'the Meet profile takes the account''s country');

SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_save_profile('key-74-a-000000012', NULL, NULL, 'open', 'man', NULL, NULL, NULL)
            -> 'gender', '"man"'::jsonb, 'changing the gender later needs no second consent');
SELECT is(public.meet_save_profile('key-74-a-000000013', NULL, 'I''m 25 and love jollof', NULL, '',
                                   NULL, NULL, NULL)
            - 'id' - 'completeness' - 'interests' - 'area' - 'status' - 'discoverable' - 'paused'
            - 'verified' - 'held' - 'show_gender',
  '{"first_name": "Ada", "bio": "I''m 25 and love jollof", "intent": "open", "gender": null,
    "text_moderation": "clean", "version": 3}'::jsonb,
  'NULL leaves a field alone, an empty gender clears it, and the version counts edits');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000014', NULL, 'call 0803 123 4567',
                     NULL, NULL, NULL, NULL, NULL)$$, 'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED',
  'a phone number in a bio is refused');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000015', NULL, 'ada.obi@gmail.com',
                     NULL, NULL, NULL, NULL, NULL)$$, 'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED',
  'so is an email address');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000016', NULL, 'see my page www.ada.ng',
                     NULL, NULL, NULL, NULL, NULL)$$, 'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED',
  'and a link');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000017', NULL,
                     'sugar baby looking for daddy', NULL, NULL, NULL, NULL, NULL)$$,
  'P0001', 'ERR_MEET_SOLICITATION_NOT_ALLOWED', 'solicitation in a bio is refused');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000018', 'Escort', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, 'P0001', 'ERR_MEET_SOLICITATION_NOT_ALLOWED',
  'and as a first name');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000019', NULL, 'cocaine plug',
                     NULL, NULL, NULL, NULL, NULL)$$, 'P0001', 'ERR_CONTENT_NOT_ALLOWED',
  'what passes the Meet screen still goes through the errands screen, which blocks this');
RESET ROLE;
SELECT is(
  (SELECT bio || ' v' || version FROM public.meet_profiles WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'I''m 25 and love jollof v3', 'none of the refusals wrote anything');

SELECT pg_temp.act('b7422222-2222-4222-8222-747474747474');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_save_profile('key-74-b-000000002', U&'F\1ECD\0301l\00E1k\1EB9\0301', NULL, NULL,
                                   NULL, NULL, NULL, NULL) ->> 'first_name',
  U&'F\1ECD\0301l\00E1k\1EB9\0301',
  'a Yoruba name with its tones is a name: NFC has no single character for a tone over o or e with a dot below');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-b-000000003', U&'Ada\0300\0301\0302\0303',
                     NULL, NULL, NULL, NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'three accents stacked on one letter are not');
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-b-000000004', U&'Ad\034Fa', NULL, NULL, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT',
  'nor is an invisible grapheme joiner inside one');
RESET ROLE;
SELECT throws_ok(
  format($$UPDATE public.meet_profiles SET bio = 'text me 08031234567' WHERE id = %L$$,
         (SELECT id FROM ids WHERE name = 'a')),
  'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED',
  'the screen is a trigger, so no write path gets around it');

-- The interim screen (review of PR #121; vectors in contact_filter_cases.json).
SELECT is(
  (SELECT array_agg(to_hex(c) || ':' || (private.meet_screen_text(
            '0803' || chr(c) || '123' || chr(c) || '4567', 'NG', 'bio') ->> 'action') ORDER BY c)
   FROM unnest(ARRAY[x'00AD', x'034F', x'061C', x'115F', x'17B4', x'180B', x'180E', x'200B', x'200E',
                     x'200F', x'202A', x'202E', x'2060', x'2061', x'2064', x'2066', x'2069', x'3164',
                     x'FE00', x'FE0F', x'FEFF', x'FFA0', x'E0001', x'E0041']::int[]) c),
  (SELECT array_agg(to_hex(c) || ':block' ORDER BY c)
   FROM unnest(ARRAY[x'00AD', x'034F', x'061C', x'115F', x'17B4', x'180B', x'180E', x'200B', x'200E',
                     x'200F', x'202A', x'202E', x'2060', x'2061', x'2064', x'2066', x'2069', x'3164',
                     x'FE00', x'FE0F', x'FEFF', x'FFA0', x'E0001', x'E0041']::int[]) c),
  'every invisible code point between the groups of a phone number is removed before matching: soft hyphen, joiners, direction marks and isolates, invisible operators, fillers, variation selectors, tags');
SELECT is(
  ARRAY[private.meet_screen_text('ada.obi@gmail' || chr(x'200E'::int) || '.com', 'NG', 'bio') ->> 'category',
        private.meet_screen_text('ada.obi' || chr(x'00AD'::int) || '@' || chr(x'2063'::int) || 'yahoo.com',
                                 'NG', 'bio') ->> 'category',
        private.meet_screen_text('www' || chr(x'200F'::int) || '.adaobi.ng', 'NG', 'bio') ->> 'category'],
  ARRAY['contact', 'contact', 'contact'], 'and so is one inside an email address or a link');
SELECT is(
  ARRAY(SELECT private.meet_screen_text(t, 'NG', 'bio') ->> 'action'
        FROM unnest(ARRAY['0803,123,4567', '0803 *** 123 *** 4567', '0803_123_4567',
                          '0803' || chr(x'1F525'::int) || '123' || chr(x'2764'::int) || '4567',
                          '0803' || chr(x'043E'::int) || '123' || chr(x'043E'::int) || '4567'])
             WITH ORDINALITY u (t, n) ORDER BY n),
  ARRAY['block', 'block', 'block', 'block', 'block'],
  'inside a run anything that is not a letter or a digit separates digits: commas, stars, underscores, emoji, a look-alike letter');
SELECT is(
  ARRAY(SELECT private.meet_screen_text(t, 'NG', 'bio') ->> 'action'
        FROM unnest(ARRAY['I''m 25, love 2 dogs', 'see you at 7:30', U&'\20A65,000 dinner?', 'flat 12',
                          'I''m 5''9', 'call me at 9pm',
                          'Lagos' || chr(x'00AD'::int) || ' girl, flat 12'])
             WITH ORDINALITY u (t, n) ORDER BY n),
  ARRAY['allow', 'allow', 'allow', 'allow', 'allow', 'allow', 'allow'],
  'while the design''s own innocent sentences still pass');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_save_profile('key-74-a-000000020', NULL, 'Class of 2012. 5''7, big smile',
                    NULL, NULL, NULL, NULL, NULL)$$,
  'a year and a height are not phone numbers');
SELECT is(public.meet_save_profile('key-74-a-000000021', NULL, 'tramadol fan', NULL, NULL, NULL, NULL,
                                   NULL) ->> 'text_moderation', 'held',
  'a hold is written and marked held, for a person to review');
SELECT is(public.meet_get_state() #>> '{profile,held}', 'true', 'meet_get_state says the profile is held');
SELECT is(public.meet_save_profile('key-74-a-000000022', NULL, 'Proud aunty of 2', NULL, NULL, NULL,
                                   NULL, NULL) ->> 'text_moderation', 'clean',
  'and rewriting the held field clears it');
SELECT is(public.meet_save_profile('key-74-a-000000022', NULL, 'Proud aunty of 2', NULL, NULL, NULL,
                                   NULL, NULL) ->> 'version', '6', 'a replay returns the stored profile');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Prompts.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO ids VALUES ('prompt0', public.meet_save_prompt('key-74-a-000000030', 'sunday',
  'Suya, a long walk and an old Nollywood film', 0));
SELECT is(public.meet_save_prompt('key-74-a-000000031', 'green_flag', 'Replies within 10 minutes', 0),
  (SELECT id FROM ids WHERE name = 'prompt0'), 'saving to a taken position replaces it and keeps its id');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000032', 'not_a_prompt', 'x', 1)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a prompt key that does not exist');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000033', 'red_flag', repeat('y', 151), 1)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'an answer over 150 characters');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000034', 'red_flag', 'Lateness', 3)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a fourth position');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000035', 'green_flag', 'Kindness', 1)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'the same prompt twice');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000037', 'red_flag',
                     'call me 0803 123 4567', 1)$$, 'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED',
  'an answer is screened like a bio');
SELECT throws_ok($$SELECT public.meet_save_prompt('key-74-a-000000038', 'red_flag',
                     'My ideal date: you pay me', 1)$$, 'P0001', 'ERR_MEET_SOLICITATION_NOT_ALLOWED',
  'solicitation in an answer is refused');
INSERT INTO ids VALUES ('prompt1', public.meet_save_prompt('key-74-a-000000039', 'red_flag',
  'Anyone selling tramadol', 1));
RESET ROLE;
SELECT is(
  (SELECT array_agg(prompt_key || ':' || moderation ORDER BY position) FROM public.meet_prompts
   WHERE profile_id = (SELECT id FROM ids WHERE name = 'a')),
  ARRAY['green_flag:clean', 'red_flag:held'], 'two prompts, the second held for review');
SELECT pg_temp.act('b7422222-2222-4222-8222-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format('SELECT public.meet_remove_prompt(%L, %L)', 'key-74-b-000000001',
                        (SELECT id FROM ids WHERE name = 'prompt1')),
  '22023', 'ERR_INVALID_ARGUMENT', 'somebody else''s prompt cannot be removed');
RESET ROLE;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(format('SELECT public.meet_remove_prompt(%L, %L)', 'key-74-a-000000040',
                       (SELECT id FROM ids WHERE name = 'prompt1')), 'the owner removes their own');
RESET ROLE;

-- Answers are screened by the table's trigger, on every write path.
SELECT throws_ok(
  format($$UPDATE public.meet_prompts SET answer = 'text me 08031234567' WHERE id = %L$$,
         (SELECT id FROM ids WHERE name = 'prompt0')),
  'P0001', 'ERR_MEET_CONTACT_NOT_ALLOWED', 'a prompt answer written directly is screened too');
SELECT throws_ok(
  format($$INSERT INTO public.meet_prompts (profile_id, prompt_key, answer, position)
           VALUES (%L, 'red_flag', 'Sugar daddy wanted', 2)$$, (SELECT id FROM ids WHERE name = 'a')),
  'P0001', 'ERR_MEET_SOLICITATION_NOT_ALLOWED', 'and so is one inserted directly');
UPDATE public.meet_prompts SET moderation = 'removed' WHERE id = (SELECT id FROM ids WHERE name = 'prompt0');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_save_prompt('key-74-a-000000041', 'green_flag',
                    'Replies within 10 minutes', 0)$$, 'the owner saves the same words again');
RESET ROLE;
SELECT is((SELECT moderation FROM public.meet_prompts WHERE id = (SELECT id FROM ids WHERE name = 'prompt0')),
  'removed', 'which does not undo a moderator''s removal of them');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_save_prompt('key-74-a-000000042', 'green_flag', 'Replies within the hour', 0),
  (SELECT id FROM ids WHERE name = 'prompt0'), 'new words at the same position keep the prompt''s id');
RESET ROLE;
SELECT is((SELECT moderation FROM public.meet_prompts WHERE id = (SELECT id FROM ids WHERE name = 'prompt0')),
  'clean', 'and are screened afresh');

-- ---------------------------------------------------------------------------
-- The area (§8.6).
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_set_area('key-74-a-000000050', 6.447412, 3.470631)$$,
  'P0001', 'ERR_CONSENT_REQUIRED', 'the area needs the location consent');
SELECT lives_ok($$SELECT public.record_consent('location', true, 'key-74-a-location01')$$,
  'which the person gives');
SELECT throws_ok($$SELECT public.meet_set_area('key-74-a-000000051', 91, 3.47)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a latitude past the pole');
SELECT is(public.meet_set_area('key-74-a-000000052', 6.447412, 3.470631),
  '{"area_label": "Lagos", "city_code": "lagos"}'::jsonb,
  'Lekki is answered as Lagos, the nearest service area');
RESET ROLE;
SELECT ok(
  (SELECT area_geohash = extensions.ST_GeoHash(extensions.ST_SetSRID(
            extensions.ST_MakePoint(3.470631, 6.447412), 4326), 5)
          AND length(area_geohash) = 5
          AND extensions.ST_Equals(area_point::extensions.geometry,
                extensions.ST_SetSRID(extensions.ST_PointFromGeoHash(area_geohash), 4326))
          AND NOT extensions.ST_DWithin(area_point,
                extensions.ST_SetSRID(extensions.ST_MakePoint(3.470631, 6.447412), 4326)::extensions.geography, 10)
   FROM public.meet_profiles WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'what is stored is the five-character cell and its centroid, never the point');
SELECT is(
  (SELECT request_hash FROM private.idempotency_keys
   WHERE user_id = 'b7411111-1111-4111-8111-747474747474' AND key = 'key-74-a-000000052'),
  sha256(convert_to(jsonb_build_object('cell', (SELECT area_geohash FROM public.meet_profiles
                                                WHERE id = (SELECT id FROM ids WHERE name = 'a')))::text,
                    'UTF8')),
  'the idempotency hash is over the cell too, so not even a hash of the coordinates is kept');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_set_area('key-74-a-000000052', 6.4475, 3.4706) ->> 'city_code', 'lagos',
  'a replay from the same cell returns the stored answer');
SELECT throws_ok($$SELECT public.meet_set_area('key-74-a-000000053', 6.5095, 3.3711)$$,
  'P0001', 'ERR_MEET_RATE_LIMITED', 'moving again within six hours is refused');
RESET ROLE;
UPDATE public.meet_profiles SET area_set_at = now() - interval '7 hours'
WHERE id = (SELECT id FROM ids WHERE name = 'a');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_set_area('key-74-a-000000054', -1.2921, 36.8219)$$,
  'P0001', 'ERR_LOCATION_UNAVAILABLE', 'Nairobi is not in Nigeria');
SELECT lives_ok($$SELECT public.meet_set_area('key-74-a-000000055', 6.447412, 3.470631)$$,
  'after six hours the area can move again');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- "Show me" (D5, §8.7).
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7422222-2222-4222-8222-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000010', 'men', NULL, NULL,
                     NULL, NULL, NULL)$$, 'P0001', 'ERR_CONSENT_REQUIRED',
  'the first "show me" that is not everyone needs the sensitive-data consent');
SELECT throws_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000011', NULL, 17, NULL,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'nobody under 18 can be asked for');
SELECT throws_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000012', NULL, 40, 30,
                     NULL, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'a range upside down');
SELECT throws_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000013', NULL, NULL, NULL,
                     7, NULL, NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'a distance that is not a band');
SELECT throws_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000014', NULL, NULL, NULL,
                     NULL, ARRAY['hookup'], NULL)$$, '22023', 'ERR_INVALID_ARGUMENT', 'an intent that is not one');
SELECT lives_ok($$SELECT public.meet_set_discovery_prefs('key-74-b-000000015', 'everyone', 21, 45,
                    25, ARRAY['friendship'], NULL)$$, 'everyone needs no consent');
RESET ROLE;
SELECT is(
  (SELECT seeking || ' ' || age_min || '-' || age_max || ' ' || max_band_km || ' '
          || array_to_string(intents, ',')
   FROM public.meet_discovery_prefs WHERE user_id = 'b7422222-2222-4222-8222-747474747474'),
  'everyone 21-45 25 friendship', 'stored apart from the profile');
SELECT is((SELECT count(*)::int FROM public.consents
           WHERE user_id = 'b7422222-2222-4222-8222-747474747474' AND kind = 'meet_sensitive_data'),
  0, 'and no consent was recorded for it');

-- ---------------------------------------------------------------------------
-- Photos: the inbox, the worker's report, the review.
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES
  ('a0', 'a0000000-0000-4000-8000-747474747400'), ('a0t', 'a0000000-0000-4000-8000-747474747401'),
  ('a1', 'a1000000-0000-4000-8000-747474747400'), ('a1t', 'a1000000-0000-4000-8000-747474747401'),
  ('a2', 'a2000000-0000-4000-8000-747474747400'), ('a2t', 'a2000000-0000-4000-8000-747474747401'),
  ('a2b', 'a2b00000-0000-4000-8000-747474747400'), ('a2bt', 'a2b00000-0000-4000-8000-747474747401'),
  ('a3', 'a3000000-0000-4000-8000-747474747400'), ('a3t', 'a3000000-0000-4000-8000-747474747401'),
  ('a4', 'a4000000-0000-4000-8000-747474747400'), ('a4t', 'a4000000-0000-4000-8000-747474747401'),
  ('a5', 'a5000000-0000-4000-8000-747474747400'), ('a5t', 'a5000000-0000-4000-8000-747474747401'),
  ('a6', 'a6000000-0000-4000-8000-747474747400'), ('a6t', 'a6000000-0000-4000-8000-747474747401');
CREATE FUNCTION pg_temp.inbox(p_name text) RETURNS text LANGUAGE sql AS $fn$
  SELECT 'b7411111-1111-4111-8111-747474747474/' || (SELECT id FROM ids WHERE name = p_name) || '.jpg';
$fn$;

SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    SELECT 'meet-inbox', pg_temp.inbox(n)
    FROM unnest(ARRAY['a0', 'a0t', 'a1', 'a1t', 'a2', 'a2t', 'a2b', 'a2bt', 'a3', 'a3t', 'a4',
                      'a4t', 'a5', 'a5t', 'a6', 'a6t']) n$$,
  'an eligible member uploads into their own inbox folder');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7422222-2222-4222-8222-747474747474/a0000000-0000-4000-8000-747474747499.jpg')$$,
  '42501', NULL, 'and into nobody else''s');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7411111-1111-4111-8111-747474747474/sub/a0000000-0000-4000-8000-747474747499.jpg')$$,
  '42501', NULL, 'not into a subfolder');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7411111-1111-4111-8111-747474747474/me.gif')$$,
  '42501', NULL, 'not a name the worker would not take');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-media', (SELECT id FROM ids WHERE name = 'a') || '/p/a0000000-0000-4000-8000-747474747400.jpg')$$,
  '42501', NULL, 'and never straight into meet-media, which only the worker writes');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'meet-inbox'), 0,
  'nobody reads the inbox back, the uploader included');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-verify', 'b7411111-1111-4111-8111-747474747474/a0000000-0000-4000-8000-747474747498.jpg')$$,
  '42501', NULL, 'a selfie needs meet.photo_verification');
RESET ROLE;
UPDATE public.feature_flags SET enabled = true WHERE key = 'meet.photo_verification' AND country_code IS NULL;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-verify', 'b7411111-1111-4111-8111-747474747474/a0000000-0000-4000-8000-747474747498.jpg')$$,
  'with it on, the selfie goes into the person''s own folder');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'meet-verify'), 0,
  'and is not readable back either');
RESET ROLE;
SELECT pg_temp.act('b7455555-5555-4555-8555-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7455555-5555-4555-8555-747474747474/a0000000-0000-4000-8000-747474747497.jpg')$$,
  '42501', NULL, 'somebody refused as under 18 cannot upload at all');
RESET ROLE;
SELECT pg_temp.act('b7466666-6666-4666-8666-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7466666-6666-4666-8666-747474747474/a0000000-0000-4000-8000-747474747496.jpg')$$,
  '42501', NULL, 'nor can somebody who never checked in');
RESET ROLE;

-- The inbox cap: two files per allowed photo, plus one pair (14 with meet.photos.max at 6).
SELECT pg_temp.act('b7422222-2222-4222-8222-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$DO $do$
    BEGIN
      FOR i IN 1..14 LOOP
        INSERT INTO storage.objects (bucket_id, name)
        VALUES ('meet-inbox', 'b7422222-2222-4222-8222-747474747474/' || gen_random_uuid() || '.jpg');
      END LOOP;
    END $do$ $$,
  'fourteen uploads one after another fill the inbox');
SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('meet-inbox', 'b7422222-2222-4222-8222-747474747474/' || gen_random_uuid() || '.jpg')$$,
  '42501', NULL, 'and a fifteenth is refused, so a script cannot fill the bucket');
RESET ROLE;

SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 0)', 'key-74-a-000000060',
                        'b7411111-1111-4111-8111-747474747474/a9000000-0000-4000-8000-747474747400.jpg',
                        pg_temp.inbox('a0t')),
  'P0001', 'ERR_UPLOAD_NOT_FOUND', 'a photo that was never uploaded');
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 0)', 'key-74-a-000000061',
                        replace(pg_temp.inbox('a0'), 'b7411111-1111-4111-8111', 'b7422222-2222-4222-8222'),
                        pg_temp.inbox('a0t')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a path outside the caller''s own inbox folder');
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 6)', 'key-74-a-000000062',
                        pg_temp.inbox('a0'), pg_temp.inbox('a0t')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a seventh position');
INSERT INTO results VALUES ('p0', public.meet_submit_photo('key-74-a-000000063', pg_temp.inbox('a0'),
  pg_temp.inbox('a0t'), 0));
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 1)', 'key-74-a-000000064',
                        pg_temp.inbox('a0'), pg_temp.inbox('a0t')),
  '22023', 'ERR_INVALID_ARGUMENT', 'the same upload cannot be submitted twice');
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 0)', 'key-74-a-000000065',
                        pg_temp.inbox('a1'), pg_temp.inbox('a1t')),
  'P0001', 'ERR_MEET_PHOTO_LIMIT', 'nor go to a position that is taken');
INSERT INTO results VALUES ('p1', public.meet_submit_photo('key-74-a-000000066', pg_temp.inbox('a1'),
  pg_temp.inbox('a1t'), 1));
INSERT INTO results VALUES ('p2', public.meet_submit_photo('key-74-a-000000067', pg_temp.inbox('a2'),
  pg_temp.inbox('a2t'), 2));
RESET ROLE;
INSERT INTO ids SELECT name, (r ->> 'photo_id')::uuid FROM results WHERE name IN ('p0', 'p1', 'p2');
SELECT is((SELECT r ->> 'status' FROM results WHERE name = 'p0'), 'processing',
  'a submitted photo is processing');
SELECT is(
  (SELECT payload FROM private.outbox
   WHERE aggregate = 'meet_media' AND event_type = 'meet.media.ingest'
     AND payload ->> 'id' = (SELECT id FROM ids WHERE name = 'p0')::text),
  jsonb_build_object('kind', 'photo', 'id', (SELECT id FROM ids WHERE name = 'p0'),
                     'profile_id', (SELECT id FROM ids WHERE name = 'a'),
                     'inbox_path', pg_temp.inbox('a0'), 'thumb_inbox_path', pg_temp.inbox('a0t')),
  'and queued for the media worker under the profile''s aggregate');
SELECT is((SELECT aggregate_id FROM private.outbox
           WHERE aggregate = 'meet_media' AND payload ->> 'id' = (SELECT id FROM ids WHERE name = 'p0')::text),
  (SELECT id FROM ids WHERE name = 'a')::text, 'the aggregate is the profile id');
SELECT is((SELECT status FROM public.meet_profiles WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'pending_review', 'a profile with photos waiting is pending review');

-- The worker reports (service role).
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format('SELECT public.gateway_meet_media_ingested(%L, %L, %L, %L, %L, 1080, 1350, %L)',
                        'photo', (SELECT id FROM ids WHERE name = 'p0'), 'x', 'y', repeat('a', 64), 'image/jpeg'),
  '42501', NULL, 'an app cannot report its own photo as processed');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT throws_ok(format('SELECT public.gateway_meet_media_ingested(%L, %L, %L, %L, %L, 1080, 1350, %L)',
    'photo', (SELECT id FROM ids WHERE name = 'p0'),
    'b7411111-1111-4111-8111-747474747474/p/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    'b7411111-1111-4111-8111-747474747474/pt/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    repeat('a', 64), 'image/jpeg'),
  '22023', 'ERR_INVALID_ARGUMENT', 'a stored path under the auth uid is refused: meet-media is foldered by profile');
SELECT is(public.gateway_meet_media_ingested('photo', (SELECT id FROM ids WHERE name = 'p0'),
    (SELECT id FROM ids WHERE name = 'a') || '/p/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    (SELECT id FROM ids WHERE name = 'a') || '/pt/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    repeat('a', 64), 1080, 1350, 'image/jpeg'),
  '{"accepted": true}'::jsonb, 'the worker reports the stored files');
SELECT is(public.gateway_meet_media_ingested('photo', (SELECT id FROM ids WHERE name = 'p0'),
    (SELECT id FROM ids WHERE name = 'a') || '/p/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    (SELECT id FROM ids WHERE name = 'a') || '/pt/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
    repeat('a', 64), 1080, 1350, 'image/jpeg'),
  '{"accepted": true}'::jsonb, 'and the same report again, after a partial run, is harmless');
SELECT is(public.gateway_meet_media_ingested('photo', (SELECT id FROM ids WHERE name = 'p1'),
    (SELECT id FROM ids WHERE name = 'a') || '/p/' || (SELECT id FROM ids WHERE name = 'p1') || '.webp',
    (SELECT id FROM ids WHERE name = 'a') || '/pt/' || (SELECT id FROM ids WHERE name = 'p1') || '.webp',
    encode(sha256(convert_to('Bola', 'UTF8')), 'hex'), 1080, 1080, 'image/webp'),
  '{"accepted": true}'::jsonb, 'a second photo, byte for byte one of somebody else''s');
SELECT is(public.gateway_meet_media_failed('photo', (SELECT id FROM ids WHERE name = 'p2'), 'bad_dimensions'),
  '{"recorded": true}'::jsonb, 'and a third the worker could not use');
SELECT throws_ok(format('SELECT public.gateway_meet_media_failed(%L, %L, %L)', 'photo',
                        (SELECT id FROM ids WHERE name = 'p2'), 'because'),
  '22023', 'ERR_INVALID_ARGUMENT', 'a failure reason must be one the app can explain');
RESET ROLE;
SELECT is(
  (SELECT array_agg(status || ':' || coalesce(failure_reason, '-') || ':'
                    || (inbox_path IS NULL)::text ORDER BY position)
   FROM public.meet_photos WHERE profile_id = (SELECT id FROM ids WHERE name = 'a')),
  ARRAY['pending_review:-:true', 'pending_review:-:true', 'failed:bad_dimensions:true'],
  'two wait for a person and one failed; none still points at the inbox');
SELECT ok(
  (SELECT sha256 = decode(repeat('a', 64), 'hex') AND width = 1080 AND mime = 'image/jpeg'
   FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p0')),
  'the hash and the dimensions are kept');
SELECT is(
  (SELECT count(*)::int FROM public.fraud_flags
   WHERE subject_kind = 'user' AND subject_id = 'b7411111-1111-4111-8111-747474747474'
     AND rule_key = 'meet_photo_reuse'
     AND details = jsonb_build_object('source', 'meet', 'photo_id', (SELECT id FROM ids WHERE name = 'p1'))),
  1, 'the copied photo raises meet_photo_reuse on the uploader, with opaque ids only');

-- A person approves photo 0 (M1-PR4 builds the console decision; here it is written directly).
UPDATE public.meet_photos SET status = 'approved', reviewed_at = now()
WHERE id = (SELECT id FROM ids WHERE name = 'p0');
SELECT is(private.meet_refresh_profile((SELECT id FROM ids WHERE name = 'a')), 'active',
  'one approved photo, a clean name and an area make the profile active');
SELECT ok((SELECT newcomer_until BETWEEN now() + interval '23 hours' AND now() + interval '25 hours'
           FROM public.meet_profiles WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'and start the 24-hour newcomer spotlight');
INSERT INTO storage.objects (bucket_id, name)
SELECT 'meet-media', p FROM public.meet_photos ph, unnest(ARRAY[ph.media_path, ph.thumb_path]) p
WHERE ph.id IN ((SELECT id FROM ids WHERE name = 'p0'), (SELECT id FROM ids WHERE name = 'p1'));

SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_set_discoverable('key-74-a-000000070', true)$$,
  'an active profile can be made discoverable');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Who can fetch A's photos: photo 0 approved, photo 1 waiting (four objects).
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.sees(p_user text, p_aal text DEFAULT 'aal1') RETURNS integer
LANGUAGE plpgsql AS $fn$
DECLARE
  v_n integer;
BEGIN
  PERFORM pg_temp.act(p_user, p_aal);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM storage.objects o
  WHERE o.bucket_id = 'meet-media' AND o.name LIKE (SELECT id FROM ids WHERE name = 'a') || '/%';
  RESET ROLE;
  RETURN v_n;
END $fn$;

SELECT is(pg_temp.sees('b7411111-1111-4111-8111-747474747474'), 4,
  'the owner sees every photo of theirs, waiting ones included');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2,
  'a viewer A is discoverable to sees the approved photo and its thumbnail, nothing waiting');
SELECT is(pg_temp.sees('b7433333-3333-4333-8333-747474747474'), 0, 'somebody A blocked sees nothing');
SELECT is(pg_temp.sees('b7444444-4444-4444-8444-747474747474'), 0,
  'somebody in another country sees nothing');
SELECT is(pg_temp.sees('b7455555-5555-4555-8555-747474747474'), 0,
  'somebody refused as under 18 sees nothing');
SELECT is(pg_temp.sees('b7466666-6666-4666-8666-747474747474'), 0,
  'somebody who never checked in sees nothing');
SELECT is(pg_temp.sees('b7477777-7777-4777-8777-747474747474'), 0,
  'somebody A did an errand with sees nothing: "hide me from errand contacts" is on by default');
SELECT is(pg_temp.sees('b7481111-1111-4111-8111-747474747474', 'aal2'), 4,
  'a meet moderator for Nigeria sees every photo, to review the waiting one');
SELECT is(pg_temp.sees('b7481111-1111-4111-8111-747474747474', 'aal1'), 0,
  'but not without MFA');
SELECT is(pg_temp.sees('b7482222-2222-4222-8222-747474747474', 'aal2'), 0,
  'a meet moderator for Kenya sees nothing of Nigeria');
SELECT is(pg_temp.sees('b7483333-3333-4333-8333-747474747474', 'aal2'), 4, 'a super admin sees them');
SELECT is(pg_temp.sees('b7484444-4444-4444-8444-747474747474', 'aal2'), 0,
  'a support agent sees nothing of Meet (D25)');
SELECT set_config('request.jwt.claims', '', true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'meet-media'), 0,
  'and nobody signed out sees anything');
RESET ROLE;

-- The viewer's side of the same rules.
UPDATE public.meet_profiles SET hide_from_errand_contacts = false
WHERE user_id IN ('b7411111-1111-4111-8111-747474747474', 'b7477777-7777-4777-8777-747474747474');
SELECT ok(private.meet_errand_contacts('b7477777-7777-4777-8777-747474747474',
                                       'b7411111-1111-4111-8111-747474747474'),
  'A and F are errand contacts, in either order');
SELECT is(pg_temp.sees('b7477777-7777-4777-8777-747474747474'), 2,
  'with both switches off, an errand contact can see them');
UPDATE public.meet_profiles SET paused_at = now() WHERE id = (SELECT id FROM ids WHERE name = 'a');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0, 'a paused profile is seen by nobody');
UPDATE public.meet_profiles SET paused_at = NULL, hold_reason = 'underage_report', hold_at = now()
WHERE id = (SELECT id FROM ids WHERE name = 'a');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'nor a profile on a discovery hold (D16)');
UPDATE public.meet_profiles SET hold_reason = NULL, hold_at = NULL
WHERE id = (SELECT id FROM ids WHERE name = 'a');
UPDATE public.meet_profiles SET gender = 'woman' WHERE id = (SELECT id FROM ids WHERE name = 'a');
INSERT INTO public.meet_discovery_prefs (user_id, seeking)
VALUES ('b7411111-1111-4111-8111-747474747474', 'men');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2,
  'A''s "show me: men" does not hide A from a woman: it narrows what A sees, never who sees A');
UPDATE public.meet_discovery_prefs SET seeking = 'men'
WHERE user_id = 'b7422222-2222-4222-8222-747474747474';
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'while B''s "show me: men" hides A from B');
UPDATE public.meet_discovery_prefs SET seeking = 'everyone', age_min = 18, age_max = 25
WHERE user_id = 'b7411111-1111-4111-8111-747474747474';
UPDATE public.meet_discovery_prefs SET seeking = 'everyone'
WHERE user_id = 'b7422222-2222-4222-8222-747474747474';
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'ages are two-way: B is outside A''s range, so B does not see A');
UPDATE public.meet_discovery_prefs SET age_max = 60 WHERE user_id = 'b7411111-1111-4111-8111-747474747474';
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2, 'back inside it, B does');
UPDATE public.feature_flags SET payload = '{"testers_only": true}', enabled = true
WHERE key = 'meet.v5' AND country_code IS NULL;
DELETE FROM private.meet_testers WHERE user_id = 'b7422222-2222-4222-8222-747474747474';
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'with Meet off for the viewer, nothing is fetched (the kill switch reaches media too)');
INSERT INTO private.meet_testers (user_id) VALUES ('b7422222-2222-4222-8222-747474747474');

-- Visibility follows access, and somebody shut out can still leave (review of PR #121).
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash) VALUES
  ('b7411111-1111-4111-8111-747474747474', 'android', sha256('phone-a-74')),
  ('b7422222-2222-4222-8222-747474747474', 'android', sha256('phone-b-74'));
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2, 'B, a tester again, sees A');
INSERT INTO public.meet_age_refusal_devices (device_fingerprint_hash, expires_at)
VALUES (sha256('phone-a-74'), now() + interval '1 day');
SELECT ok(NOT private.meet_discoverable_to((SELECT id FROM ids WHERE name = 'b'),
                                           (SELECT id FROM ids WHERE name = 'a')),
  'once A''s phone is barred (a sibling refused on it), A is discoverable to nobody');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0, 'and nobody fetches A''s photos');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_save_profile('key-74-a-000000071', NULL, 'Back soon', NULL, NULL,
                     NULL, NULL, NULL)$$, 'P0001', 'ERR_MEET_UNAVAILABLE', 'A, shut out, cannot edit');
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000072', true)$$, 'but can pause');
SELECT throws_ok($$SELECT public.meet_pause('key-74-a-000000073', false)$$, 'P0001', 'ERR_MEET_UNAVAILABLE',
  'not unpause');
SELECT lives_ok($$SELECT public.meet_set_discoverable('key-74-a-000000074', false)$$, 'can hide');
SELECT throws_ok($$SELECT public.meet_set_discoverable('key-74-a-000000075', true)$$,
  'P0001', 'ERR_MEET_UNAVAILABLE', 'not show again');
SELECT lives_ok($$SELECT public.meet_set_privacy('key-74-a-000000076', '{"show_gender": false}')$$,
  'and can change a privacy switch');
RESET ROLE;
DELETE FROM public.meet_age_refusal_devices WHERE device_fingerprint_hash = sha256('phone-a-74');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000077', false)$$, 'with the bar gone, A comes back');
SELECT lives_ok($$SELECT public.meet_set_discoverable('key-74-a-000000078', true)$$, 'and shows again');
RESET ROLE;
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2, 'so B sees A again');
INSERT INTO public.meet_age_refusal_devices (device_fingerprint_hash, expires_at)
VALUES (sha256('phone-b-74'), now() + interval '1 day');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'a viewer whose own phone is barred fetches nothing, even of somebody discoverable');
DELETE FROM public.meet_age_refusal_devices WHERE device_fingerprint_hash = sha256('phone-b-74');
UPDATE public.remote_config SET value = '2' WHERE key = 'meet.guidelines_version' AND country_code IS NULL;
UPDATE public.meet_eligibility SET guidelines_version = 2 WHERE user_id = 'b7422222-2222-4222-8222-747474747474';
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'somebody who has not accepted the current guidelines is hidden, even from a viewer who has');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_pause('key-74-a-000000079', false)$$,
  'P0001', 'ERR_MEET_GUIDELINES_OUTDATED', 'A cannot come back in without accepting them');
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000085', true)$$, 'but can still pause');
RESET ROLE;
UPDATE public.remote_config SET value = '1' WHERE key = 'meet.guidelines_version' AND country_code IS NULL;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000086', false)$$, 'and unpauses once they are current');
RESET ROLE;
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2, 'after which B sees A again');

-- Only staff may sign a URL: a signed link works without a session and outlives a block.
SELECT set_config('storage.operation', 'storage.object.sign', true);
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0,
  'while Storage is signing a URL, a viewer the policy otherwise admits gets nothing');
SELECT is(pg_temp.sees('b7411111-1111-4111-8111-747474747474'), 0, 'nor does the owner');
SELECT is(pg_temp.sees('b7481111-1111-4111-8111-747474747474', 'aal2'), 4,
  'a moderator in scope still can, for the console''s short-lived links');
SELECT set_config('storage.operation', 'storage.object.sign_many', true);
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0, 'signing several at once is refused the same way');
SELECT set_config('storage.operation', 'storage.object.get_authenticated', true);
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 2, 'and the authenticated fetch the app uses is unaffected');
SELECT set_config('storage.operation', '', true);

INSERT INTO results SELECT 'p0_path', to_jsonb(media_path) FROM public.meet_photos
WHERE id = (SELECT id FROM ids WHERE name = 'p0');
SELECT pg_temp.act('b7422222-2222-4222-8222-747474747474');
SET LOCAL ROLE authenticated;
SELECT ok(
  NOT private.meet_media_visible_to(
        (SELECT id FROM ids WHERE name = 'a') || '/p/../p/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
        'b7422222-2222-4222-8222-747474747474')
  AND NOT private.meet_media_visible_to(
        (SELECT id FROM ids WHERE name = 'a') || '/e/' || (SELECT id FROM ids WHERE name = 'p0') || '.jpg',
        'b7422222-2222-4222-8222-747474747474')
  AND NOT private.meet_media_visible_to((SELECT r #>> '{}' FROM results WHERE name = 'p0_path'),
                                        'b7411111-1111-4111-8111-747474747474')
  AND private.meet_media_visible_to((SELECT r #>> '{}' FROM results WHERE name = 'p0_path'),
                                    'b7422222-2222-4222-8222-747474747474'),
  'a traversal or an unknown folder is refused, and the policy never answers on somebody else''s behalf');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- No auth uid in any path a viewer reads (D15).
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int FROM storage.objects o, auth.users u
   WHERE o.bucket_id = 'meet-media' AND position(u.id::text IN o.name) > 0), 0,
  'no meet-media object name contains any account''s id');
SELECT is(
  (SELECT count(*)::int FROM storage.objects o
   WHERE o.bucket_id = 'meet-media'
     AND NOT EXISTS (SELECT 1 FROM public.meet_profiles mp
                     WHERE (string_to_array(o.name, '/'))[1] = mp.id::text)), 0,
  'every one sits in a Meet profile''s folder');
SELECT is(
  (SELECT count(*)::int FROM pg_constraint
   WHERE conrelid = 'public.meet_photos'::regclass
     AND conname IN ('meet_photos_media_path_own', 'meet_photos_thumb_path_own')), 2,
  'and the table holds every stored path to its own profile and photo id');

-- ---------------------------------------------------------------------------
-- What the owner reads back.
-- ---------------------------------------------------------------------------
UPDATE public.meet_photos SET status = 'rejected', reason_code = 'underage_appearance'
WHERE id = (SELECT id FROM ids WHERE name = 'p1');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO results VALUES ('mine', public.meet_get_my_profile());
RESET ROLE;
SELECT is((SELECT array_agg(k ORDER BY k) FROM results, jsonb_object_keys(r) k WHERE name = 'mine'),
  ARRAY['catalogue', 'photos', 'prefs', 'privacy', 'profile', 'prompts'],
  'meet_get_my_profile: profile, photos, prompts, prefs, privacy, and the key catalogue');
SELECT is(
  (SELECT jsonb_agg(p - 'id' - 'media_path' - 'thumb_path' ORDER BY (p ->> 'position')::int)
   FROM results, jsonb_array_elements(r -> 'photos') p WHERE name = 'mine'),
  '[{"position": 0, "status": "approved", "reason_code": null, "failure_reason": null},
    {"position": 1, "status": "rejected", "reason_code": "other", "failure_reason": null},
    {"position": 2, "status": "failed", "reason_code": null, "failure_reason": "bad_dimensions"}]'::jsonb,
  'every photo in every state but removed; an underage-appearance rejection reads as other');
SELECT is((SELECT r -> 'prefs' FROM results WHERE name = 'mine'),
  '{"seeking": "everyone", "age_min": 18, "age_max": 60, "max_band_km": 50, "intents": []}'::jsonb,
  'the owner reads their own "show me"');
SELECT ok(
  (SELECT jsonb_array_length(r #> '{catalogue,interests}') = 30
          AND jsonb_array_length(r #> '{catalogue,prompts}') = 20
          AND r #> '{catalogue,interests,0}' = '"afrobeats"'
   FROM results WHERE name = 'mine'),
  'and the catalogue the onboarding offers');
SELECT is(
  (SELECT count(*)::int FROM results, auth.users u
   WHERE name = 'mine' AND position(u.id::text IN r::text) > 0), 0,
  'no account id anywhere in it');

-- ---------------------------------------------------------------------------
-- Privacy, pause, discoverable.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_set_privacy('key-74-a-000000080', '{"incognito": true}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a privacy key M1 does not have is refused, not ignored');
SELECT throws_ok($$SELECT public.meet_set_privacy('key-74-a-000000081', '{"read_receipts": "no"}')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'so is a value that is not a boolean');
SELECT is(public.meet_set_privacy('key-74-a-000000082', '{"read_receipts": false, "show_gender": true}'),
  '{"hide_from_errand_contacts": false, "show_gender": true, "read_receipts": false}'::jsonb,
  'the switches named change, and the answer is all three');
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000083', true)$$, 'a pause');
SELECT is(public.meet_get_state() #>> '{profile,paused}', 'true', 'shows in meet_get_state');
SELECT lives_ok($$SELECT public.meet_pause('key-74-a-000000084', false)$$, 'and ends');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Replacing, the limit, removing and reordering.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
INSERT INTO results VALUES ('p2b', public.meet_submit_photo('key-74-a-000000090', pg_temp.inbox('a2b'),
  pg_temp.inbox('a2bt'), 2));
INSERT INTO results VALUES ('p3', public.meet_submit_photo('key-74-a-000000091', pg_temp.inbox('a3'),
  pg_temp.inbox('a3t'), 3));
INSERT INTO results VALUES ('p4', public.meet_submit_photo('key-74-a-000000092', pg_temp.inbox('a4'),
  pg_temp.inbox('a4t'), 4));
RESET ROLE;
INSERT INTO ids SELECT name, (r ->> 'photo_id')::uuid FROM results WHERE name IN ('p2b', 'p3', 'p4');
SELECT is((SELECT status FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p2')),
  'removed', 'a new photo at the failed one''s position replaces it');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 1)', 'key-74-a-000000093',
                       pg_temp.inbox('a5'), pg_temp.inbox('a5t')),
  'and the rejected one''s position takes a new photo too');
RESET ROLE;
SELECT ok(
  (SELECT status = 'removed' FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p1'))
  AND NOT EXISTS (SELECT 1 FROM private.outbox
                  WHERE aggregate = 'storage' AND event_type = 'storage.erase_object'
                    AND payload ->> 'path' LIKE '%' || (SELECT id FROM ids WHERE name = 'p1') || '%'),
  'the photo it replaced was rejected as appearing under 18: it is marked removed and its files stay, as child-safety evidence (RB-17)');
UPDATE public.remote_config SET value = '5' WHERE key = 'meet.photos.max' AND country_code IS NULL;
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format('SELECT public.meet_submit_photo(%L, %L, %L, 3)', 'key-74-a-000000094',
                        pg_temp.inbox('a6'), pg_temp.inbox('a6t')),
  'P0001', 'ERR_MEET_PHOTO_LIMIT', 'at meet.photos.max live photos, another is refused');
SELECT throws_ok(format('SELECT public.meet_remove_photo(%L, %L)', 'key-74-a-000000095',
                        (SELECT id FROM ids WHERE name = 'b')),
  'P0001', 'ERR_MEET_PHOTO_NOT_FOUND', 'an id that is not one of the caller''s photos');
SELECT lives_ok(format('SELECT public.meet_remove_photo(%L, %L)', 'key-74-a-000000096',
                       (SELECT id FROM ids WHERE name = 'p4')), 'a photo still processing is removed');
RESET ROLE;
UPDATE public.remote_config SET value = '6' WHERE key = 'meet.photos.max' AND country_code IS NULL;
SELECT set_eq(
  $$SELECT payload ->> 'bucket' || ' ' || aggregate_id || ' ' || (payload ->> 'path')
    FROM private.outbox WHERE aggregate = 'storage' AND event_type = 'storage.erase_object'
      AND payload ->> 'path' LIKE '%' || (SELECT id FROM ids WHERE name = 'a4') || '%'$$,
  ARRAY['meet-inbox b7411111-1111-4111-8111-747474747474 ' || pg_temp.inbox('a4')],
  'its inbox copy is queued for erasure, in the uploader''s own folder');
SET LOCAL ROLE service_role;
SELECT is(public.gateway_meet_media_ingested('photo', (SELECT id FROM ids WHERE name = 'p4'),
    (SELECT id FROM ids WHERE name = 'a') || '/p/' || (SELECT id FROM ids WHERE name = 'p4') || '.jpg',
    (SELECT id FROM ids WHERE name = 'a') || '/pt/' || (SELECT id FROM ids WHERE name = 'p4') || '.jpg',
    repeat('b', 64), 1080, 1350, 'image/jpeg'),
  '{"accepted": false}'::jsonb, 'and when the worker reports it anyway, it is told to discard the files');
RESET ROLE;

INSERT INTO results SELECT 'order', to_jsonb(array_agg(id ORDER BY CASE WHEN position = 0 THEN 99 ELSE position END))
FROM public.meet_photos WHERE profile_id = (SELECT id FROM ids WHERE name = 'a')
  AND status IN ('processing', 'pending_review', 'approved');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format('SELECT public.meet_reorder_photos(%L, %L::uuid[])', 'key-74-a-000000100',
                        ARRAY[(SELECT id FROM ids WHERE name = 'p0')]),
  '22023', 'ERR_INVALID_ARGUMENT', 'a reorder names every live photo');
SELECT throws_ok(format('SELECT public.meet_reorder_photos(%L, %L::uuid[])', 'key-74-a-000000101',
                        ARRAY[(SELECT id FROM ids WHERE name = 'p0'), (SELECT id FROM ids WHERE name = 'b')]),
  'P0001', 'ERR_MEET_PHOTO_NOT_FOUND', 'and only the caller''s own');
SELECT lives_ok(format('SELECT public.meet_reorder_photos(%L, %L::uuid[])', 'key-74-a-000000102',
  (SELECT array_agg(e::uuid ORDER BY n) FROM results, jsonb_array_elements_text(r) WITH ORDINALITY x (e, n)
   WHERE name = 'order')),
  'moving the first photo to the end shifts every other one in a single statement');
RESET ROLE;
SELECT is(
  (SELECT position FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p0')),
  3::smallint, 'photo 0 is now last');

SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok(format('SELECT public.meet_remove_photo(%L, %L)', 'key-74-a-000000103',
                       (SELECT id FROM ids WHERE name = 'p0')), 'the only approved photo is removed');
RESET ROLE;
SELECT is(
  (SELECT status || ' ' || discoverable::text FROM public.meet_profiles
   WHERE id = (SELECT id FROM ids WHERE name = 'a')),
  'pending_review false', 'and the profile leaves discovery');
SELECT set_eq(
  $$SELECT payload ->> 'bucket' || ' ' || aggregate_id || ' ' || (payload ->> 'path')
    FROM private.outbox WHERE aggregate = 'storage' AND event_type = 'storage.erase_object'
      AND payload ->> 'path' LIKE '%' || (SELECT id FROM ids WHERE name = 'p0') || '%'$$,
  ARRAY['meet-media ' || (SELECT id FROM ids WHERE name = 'a') || ' '
          || (SELECT media_path FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p0')),
        'meet-media ' || (SELECT id FROM ids WHERE name = 'a') || ' '
          || (SELECT thumb_path FROM public.meet_photos WHERE id = (SELECT id FROM ids WHERE name = 'p0'))],
  'both of its files are queued for erasure, in the profile''s folder');
SELECT is(pg_temp.sees('b7422222-2222-4222-8222-747474747474'), 0, 'and nobody else can fetch them now');
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_set_discoverable('key-74-a-000000104', true)$$,
  'P0001', 'ERR_MEET_PROFILE_INCOMPLETE', 'turning discovery back on needs an approved photo');
SELECT is(public.meet_get_state() #> '{profile,completeness}', '["photo"]'::jsonb,
  'which is the one step meet_get_state says is missing');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The inbox sweep and the media dispatch.
-- ---------------------------------------------------------------------------
UPDATE storage.objects SET created_at = now() - interval '2 days'
WHERE bucket_id = 'meet-inbox' AND name LIKE 'b7411111-1111-4111-8111-747474747474/%';
INSERT INTO results SELECT 'outbox_mark', to_jsonb(coalesce(max(id), 0)) FROM private.outbox;
SELECT is(private.meet_sweep_inbox(), 10,
  'the daily sweep queues the ten old inbox files no waiting photo needs');
SELECT set_eq(
  $$SELECT payload ->> 'path' FROM private.outbox
    WHERE id > (SELECT (r #>> '{}')::bigint FROM results WHERE name = 'outbox_mark')
      AND aggregate = 'storage' AND event_type = 'storage.erase_object'
      AND payload ->> 'bucket' = 'meet-inbox'
      AND aggregate_id = 'b7411111-1111-4111-8111-747474747474'$$,
  ARRAY[pg_temp.inbox('a0'), pg_temp.inbox('a0t'), pg_temp.inbox('a1'), pg_temp.inbox('a1t'),
        pg_temp.inbox('a2'), pg_temp.inbox('a2t'), pg_temp.inbox('a4'), pg_temp.inbox('a4t'),
        pg_temp.inbox('a6'), pg_temp.inbox('a6t')],
  'each in the uploader''s own folder: the ingested, failed, removed and never-submitted ones; the three photos still processing keep theirs');
SELECT CASE WHEN to_regclass('cron.job') IS NULL THEN skip('pg_cron is not installed here', 1)
  ELSE results_eq(
    $$SELECT schedule, command FROM cron.job WHERE jobname = 'meet-inbox-sweep'$$,
    $$VALUES ('25 2 * * *'::text, 'SELECT private.meet_sweep_inbox()'::text)$$,
    'meet-inbox-sweep runs the sweep daily at 02:25')
  END;
SELECT CASE WHEN to_regclass('cron.job') IS NULL THEN skip('pg_cron is not installed here', 1)
  ELSE results_eq(
    $$SELECT command ~ 'o\.attempts < 8' AND command ~ 'o\.claimed_at IS NULL' FROM cron.job
      WHERE jobname = 'meet-media-dispatch'$$,
    $$VALUES (true)$$,
    'meet-media-dispatch calls the worker only for an event it could claim')
  END;

-- ---------------------------------------------------------------------------
-- Deleting the profile.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7411111-1111-4111-8111-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_delete_profile('key-74-a-000000110')$$, 'the owner deletes their Meet profile');
SELECT lives_ok($$SELECT public.meet_delete_profile('key-74-a-000000110')$$, 'a replay is harmless');
SELECT is(public.meet_get_my_profile() -> 'profile', 'null'::jsonb, 'there is no profile any more');
RESET ROLE;
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.meet_photos WHERE profile_id = (SELECT id FROM ids WHERE name = 'a'))
  AND NOT EXISTS (SELECT 1 FROM public.meet_prompts WHERE profile_id = (SELECT id FROM ids WHERE name = 'a'))
  AND NOT EXISTS (SELECT 1 FROM public.meet_discovery_prefs
                  WHERE user_id = 'b7411111-1111-4111-8111-747474747474'),
  'its photos, prompts and "show me" went with it');
SELECT set_eq(
  $$SELECT payload ->> 'bucket' || ' ' || (payload ->> 'prefix') FROM private.outbox
    WHERE aggregate = 'storage' AND event_type = 'storage.erase_prefix'
      AND aggregate_id IN ((SELECT id FROM ids WHERE name = 'a')::text,
                           'b7411111-1111-4111-8111-747474747474')$$,
  ARRAY['meet-media ' || (SELECT id FROM ids WHERE name = 'a') || '/',
        'meet-inbox b7411111-1111-4111-8111-747474747474/'],
  'and both folders are queued for the storage worker to empty, each under its own aggregate');
SELECT is((SELECT status FROM public.meet_eligibility WHERE user_id = 'b7411111-1111-4111-8111-747474747474'),
  'eligible', 'the eligibility record stays');

-- Somebody Meet has shut out can still delete their profile.
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash)
VALUES ('b7477777-7777-4777-8777-747474747474', 'android', sha256('phone-f-74'));
INSERT INTO public.meet_age_refusal_devices (device_fingerprint_hash, expires_at)
VALUES (sha256('phone-f-74'), now() + interval '1 day');
SELECT pg_temp.act('b7477777-7777-4777-8777-747474747474');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_delete_profile('key-74-f-000000001')$$,
  'somebody whose phone was barred deletes their Meet profile');
RESET ROLE;
SELECT ok(NOT EXISTS (SELECT 1 FROM public.meet_profiles WHERE user_id = 'b7477777-7777-4777-8777-747474747474'),
  'and it is gone');

-- Account erasure reaches Meet now, not at M1-PR8.
SELECT lives_ok($$SELECT private.erase_account('b7444444-4444-4444-8444-747474747474')$$, 'D''s account is erased');
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.meet_profiles WHERE user_id = 'b7444444-4444-4444-8444-747474747474')
  AND NOT EXISTS (SELECT 1 FROM public.meet_photos WHERE profile_id = (SELECT id FROM ids WHERE name = 'd'))
  AND NOT EXISTS (SELECT 1 FROM public.meet_discovery_prefs WHERE user_id = 'b7444444-4444-4444-8444-747474747474'),
  'which removes the Meet profile, its photos and "show me"');
SELECT is((SELECT count(*)::int FROM public.meet_eligibility WHERE user_id = 'b7444444-4444-4444-8444-747474747474'), 0,
  'and the eligibility row with the birth date');
SELECT set_eq(
  $$SELECT payload ->> 'bucket' || ' ' || (payload ->> 'prefix') FROM private.outbox
    WHERE aggregate = 'storage' AND event_type = 'storage.erase_prefix'
      AND aggregate_id IN ((SELECT id FROM ids WHERE name = 'd')::text, 'b7444444-4444-4444-8444-747474747474')$$,
  ARRAY['meet-media ' || (SELECT id FROM ids WHERE name = 'd') || '/',
        'meet-inbox b7444444-4444-4444-8444-747474747474/', 'avatars b7444444-4444-4444-8444-747474747474/'],
  'and queues both Meet folders for the storage worker, beside the avatar folder');
SELECT lives_ok($$SELECT private.erase_account('b7455555-5555-4555-8555-747474747474')$$, 'erasing the account refused as a minor');
SELECT is((SELECT status || coalesce(birth_date::text, '') FROM public.meet_eligibility
           WHERE user_id = 'b7455555-5555-4555-8555-747474747474'), 'refused_minor',
  'keeps the refusal, which holds no date and is what bars the phones that account used');

SELECT * FROM finish();
ROLLBACK;
