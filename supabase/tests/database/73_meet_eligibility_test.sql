-- Meet v5 M1-PR3 (20261126120200): the 18+ gate (design §4.2 meet_check_in, §8.1, D24).
--
-- What has to hold: the date is taken once and the age computed where the person is, a
-- 29 February birthday falling on 1 March in other years; somebody under 18 is refused with no
-- birth date stored anywhere, every device they used is barred for a year, and the refusal is
-- returned rather than raised, so it survives; another account on a barred phone, or a phone
-- that failed integrity, gets "unavailable"; the guidelines version is enforced and can be
-- brought up to date; the record outlives the Meet profile; and with the flag off nothing works.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(69);

INSERT INTO auth.users (id, phone) VALUES
  ('b7311111-1111-4111-8111-737373737373', '2348000007301'),   -- A: adult, tester
  ('b7322222-2222-4222-8222-737373737373', '2348000007302'),   -- M: 16, tester, two phones
  ('b7333333-3333-4333-8333-737373737373', '2348000007303'),   -- S: adult on M's first phone
  ('b7344444-4444-4444-8444-737373737373', '2348000007304'),   -- I: a phone that failed integrity
  ('b7355555-5555-4555-8555-737373737373', '2348000007305'),   -- K: lives at UTC+14
  ('b7366666-6666-4666-8666-737373737373', '2348000007306'),   -- P: lives at UTC-11
  ('b7377777-7777-4777-8777-737373737373', '2348000007307'),   -- N: not a tester
  ('b7399999-9999-4999-8999-737373737373', '2348000007309');   -- O: the oldest
UPDATE public.profiles SET country_code = 'NG' WHERE user_id::text LIKE 'b73%-737373737373';
INSERT INTO auth.users (id, email)
VALUES ('b7388888-8888-4888-8888-737373737373', 'meet.c@suskii.test');   -- C: no country yet
UPDATE public.profiles SET timezone = 'Pacific/Kiritimati'
WHERE user_id = 'b7355555-5555-4555-8555-737373737373';
UPDATE public.profiles SET timezone = 'Pacific/Pago_Pago'
WHERE user_id = 'b7366666-6666-4666-8666-737373737373';

INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash, integrity_verdict) VALUES
  ('b7311111-1111-4111-8111-737373737373', 'android', sha256('phone-a'), NULL),
  ('b7322222-2222-4222-8222-737373737373', 'android', sha256('phone-m1'), NULL),
  ('b7322222-2222-4222-8222-737373737373', 'android', sha256('phone-m2'), NULL),
  ('b7333333-3333-4333-8333-737373737373', 'android', sha256('phone-m1'), NULL),
  ('b7344444-4444-4444-8444-737373737373', 'android', sha256('phone-i'),
   '{"status": "fail", "platform": "android", "reasons": ["device_not_recognised"]}');

UPDATE public.feature_flags SET enabled = true WHERE key = 'meet.v5' AND country_code IS NULL;
INSERT INTO private.meet_testers (user_id)
SELECT id FROM auth.users WHERE id::text LIKE 'b73%-737373737373'
  AND id <> 'b7377777-7777-4777-8777-737373737373';

CREATE FUNCTION pg_temp.act(p_user text)
RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

CREATE TEMP TABLE dates (name text PRIMARY KEY, d date);
CREATE TEMP TABLE results (name text PRIMARY KEY, r jsonb);
GRANT ALL ON dates, results TO authenticated;
INSERT INTO dates VALUES
  ('lagos_today', (now() AT TIME ZONE 'Africa/Lagos')::date),
  ('adult', ((now() AT TIME ZONE 'Africa/Lagos')::date - interval '30 years')::date),
  ('minor', ((now() AT TIME ZONE 'Africa/Lagos')::date - interval '16 years' - interval '41 days')::date),
  ('k_18', ((now() AT TIME ZONE 'Pacific/Kiritimati')::date - interval '18 years')::date),
  ('age_99', ((now() AT TIME ZONE 'Africa/Lagos')::date - interval '99 years')::date),
  ('age_100', ((now() AT TIME ZONE 'Africa/Lagos')::date - interval '100 years')::date);

-- ---------------------------------------------------------------------------
-- The age, and where "today" is.
-- ---------------------------------------------------------------------------
SELECT is(
  ARRAY[private.meet_age_on('2008-02-29', '2026-02-28'), private.meet_age_on('2008-02-29', '2026-03-01'),
        private.meet_age_on('2008-02-29', '2028-02-28'), private.meet_age_on('2008-02-29', '2028-02-29')],
  ARRAY[17, 18, 19, 20],
  '29 February: still 17 on 28 February of a common year, 18 on 1 March; in a leap year, on the day');
SELECT is(
  ARRAY[private.meet_age_on('2008-06-15', '2026-06-14'), private.meet_age_on('2008-06-15', '2026-06-15'),
        private.meet_age_on('2008-12-31', '2026-12-31'), private.meet_age_on('2009-01-01', '2026-12-31')],
  ARRAY[17, 18, 18, 17],
  'an 18th birthday counts from the day itself, and not the day before');
SELECT is(private.meet_local_today('b7311111-1111-4111-8111-737373737373'),
  (SELECT d FROM dates WHERE name = 'lagos_today'),
  'somebody with no time zone of their own gets their country''s (Lagos)');
SELECT ok(private.meet_local_today('b7355555-5555-4555-8555-737373737373')
          > private.meet_local_today('b7366666-6666-4666-8666-737373737373'),
  'and UTC+14 is always a day ahead of UTC-11, whatever the hour the test runs');

-- ---------------------------------------------------------------------------
-- The flag and the country come first.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7377777-7777-4777-8777-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_get_state() ->> 'v5', 'false',
  'somebody Meet is not on for gets v5 false from meet_get_state, not an error');
SELECT throws_ok($$SELECT public.meet_check_in('key-73-n-0000000001', '1990-01-01', 1)$$,
  'P0001', 'ERR_FEATURE_UNAVAILABLE', 'and cannot check in');
RESET ROLE;

SELECT pg_temp.act('b7388888-8888-4888-8888-737373737373');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_check_in('key-73-c-0000000001', '1990-01-01', 1)$$,
  'P0001', 'ERR_COUNTRY_NOT_SET', 'a tester with no country cannot check in');
SELECT throws_ok($$SELECT public.meet_get_state()$$, 'P0001', 'ERR_COUNTRY_NOT_SET',
  'nor read their Meet state');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- An adult.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_get_state() - 'features' - 'restrictions' - 'suspension' - 'unread',
  '{"v5": true, "eligibility": "none", "profile": null,
    "guidelines": {"required_version": 1, "accepted_version": null, "url": null}}'::jsonb,
  'before checking in: eligibility none, guidelines v1 required, no profile');
SELECT throws_ok($$SELECT public.meet_check_in('key-73-a-0000000001', NULL, 1)$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a missing date is refused');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'key-73-a-0000000002',
         (SELECT d + 1 FROM dates WHERE name = 'lagos_today')),
  '22023', 'ERR_INVALID_ARGUMENT', 'so is a date in the future');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 2)', 'key-73-a-0000000003',
         (SELECT d FROM dates WHERE name = 'adult')),
  'P0001', 'ERR_MEET_GUIDELINES_OUTDATED', 'and a guidelines version that is not the current one');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'short', (SELECT d FROM dates WHERE name = 'adult')),
  '22023', 'ERR_IDEMPOTENCY_KEY_INVALID', 'and a key that is not one');
INSERT INTO results VALUES ('a', public.meet_check_in('key-73-a-0000000010',
  (SELECT d FROM dates WHERE name = 'adult'), 1));
RESET ROLE;
SELECT is((SELECT r FROM results WHERE name = 'a'), '{"status": "eligible", "age": 30}'::jsonb,
  'an adult is eligible, and told the age the server computed');
SELECT is(
  (SELECT jsonb_build_object('status', status, 'birth_date', birth_date, 'method', method,
                             'guidelines_version', guidelines_version)
   FROM public.meet_eligibility WHERE user_id = 'b7311111-1111-4111-8111-737373737373'),
  jsonb_build_object('status', 'eligible', 'birth_date', (SELECT d FROM dates WHERE name = 'adult'),
                     'method', 'self_declared', 'guidelines_version', 1),
  'with the date, self-declared, against guidelines v1');
SELECT is(
  (SELECT count(*)::int FROM public.consents
   WHERE user_id = 'b7311111-1111-4111-8111-737373737373' AND kind = 'meet_terms' AND granted),
  1, 'and a meet_terms consent recorded server-side');

SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-a-0000000010', (SELECT d FROM dates WHERE name = 'adult'), 1),
  '{"status": "eligible", "age": 30}'::jsonb, 'a replay of the same key returns the stored answer');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'key-73-a-0000000010',
         (SELECT d FROM dates WHERE name = 'minor')),
  'P0001', 'ERR_IDEMPOTENCY_KEY_REUSED', 'the same key with an under-18 date is refused as reused');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'key-73-a-0000000011',
         (SELECT d - 400 FROM dates WHERE name = 'adult')),
  'P0001', 'ERR_MEET_AGE_ALREADY_SET', 'the date is set once: a second check-in is refused');
SELECT is(public.meet_get_state() ->> 'eligibility', 'eligible', 'meet_get_state says eligible');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.meet_eligibility
           WHERE user_id = 'b7311111-1111-4111-8111-737373737373'), 1, 'one record, still');
SELECT lives_ok(
  $$SELECT private.meet_require_access('b7311111-1111-4111-8111-737373737373', 'meet.v5', false)$$,
  'the access check now passes an eligible adult');
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7311111-1111-4111-8111-737373737373', 'meet.v5', true)$$,
  'P0001', 'ERR_MEET_PROFILE_INCOMPLETE', 'and asks for an active profile where the function needs one');

-- ---------------------------------------------------------------------------
-- Somebody under 18.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7322222-2222-4222-8222-737373737373');
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  format($$INSERT INTO results VALUES ('m', public.meet_check_in(%L, %L, 1))$$,
         'key-73-m-0000000001', (SELECT d FROM dates WHERE name = 'minor')),
  'an under-18 check-in returns: it is not raised, so what it records survives (D24)');
RESET ROLE;
SELECT is((SELECT r FROM results WHERE name = 'm'), '{"status": "refused", "age": null}'::jsonb,
  'the answer is refused, without the age');
SELECT is(
  (SELECT jsonb_build_object('status', status, 'birth_date', birth_date)
   FROM public.meet_eligibility WHERE user_id = 'b7322222-2222-4222-8222-737373737373'),
  '{"status": "refused_minor", "birth_date": null}'::jsonb,
  'the account is marked refused_minor, and the birth date is not stored');
SELECT is(
  (SELECT request_hash FROM private.idempotency_keys
   WHERE user_id = 'b7322222-2222-4222-8222-737373737373' AND key = 'key-73-m-0000000001'),
  sha256(convert_to(jsonb_build_object('adult', false, 'guidelines_version', 1)::text, 'UTF8')),
  'nor its hash: the idempotency claim hashes "not an adult", because a hash of a date is the date');
SELECT ok(
  NOT EXISTS (SELECT 1 FROM private.idempotency_keys k
              WHERE k.user_id = 'b7322222-2222-4222-8222-737373737373'
                AND (k.response::text LIKE '%' || (SELECT d FROM dates WHERE name = 'minor')::text || '%'
                     OR k.request_hash = sha256(convert_to(jsonb_build_object(
                          'birth_date', (SELECT d FROM dates WHERE name = 'minor'),
                          'guidelines_version', 1)::text, 'UTF8'))))
  AND NOT EXISTS (SELECT 1 FROM private.outbox o
                  WHERE o.payload::text LIKE '%' || (SELECT d FROM dates WHERE name = 'minor')::text || '%')
  AND NOT EXISTS (SELECT 1 FROM audit.log l
                  WHERE coalesce(l.before::text, '') || coalesce(l.after::text, '')
                        LIKE '%' || (SELECT d FROM dates WHERE name = 'minor')::text || '%'),
  'the date is nowhere: not in a stored answer, a request hash, the outbox or the audit log');
SELECT is((SELECT count(*)::int FROM public.consents
           WHERE user_id = 'b7322222-2222-4222-8222-737373737373'), 0,
  'and no consent is recorded for somebody refused');
SELECT is(
  (SELECT count(*)::int FROM public.meet_age_refusal_devices
   WHERE device_fingerprint_hash IN (sha256('phone-m1'), sha256('phone-m2'))
     AND expires_at BETWEEN now() + interval '364 days' AND now() + interval '366 days'),
  2, 'both of their phones are barred for 365 days (meet.retention.age_refusal_device_days)');
SELECT set_eq(
  $$SELECT column_name::text FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'meet_age_refusal_devices'$$,
  ARRAY['device_fingerprint_hash', 'refused_at', 'expires_at'],
  'a barred phone is kept without a user id or a birth date');

SELECT pg_temp.act('b7322222-2222-4222-8222-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-m-0000000002', (SELECT d FROM dates WHERE name = 'adult'), 1),
  '{"status": "unavailable", "age": null}'::jsonb,
  'a retry with an adult''s date gets unavailable');
SELECT is(public.meet_check_in('key-73-m-0000000001', (SELECT d FROM dates WHERE name = 'minor'), 1),
  '{"status": "refused", "age": null}'::jsonb, 'a replay of the first key still says refused');
SELECT is(public.meet_get_state() ->> 'eligibility', 'refused', 'meet_get_state says refused');
SELECT throws_ok($$SELECT public.meet_get_my_profile()$$, 'P0001', 'ERR_MEET_UNAVAILABLE',
  'and every other Meet function says unavailable, never why');
RESET ROLE;
SELECT is(
  (SELECT status || coalesce(birth_date::text, '') FROM public.meet_eligibility
   WHERE user_id = 'b7322222-2222-4222-8222-737373737373'),
  'refused_minor', 'the refusal stands, still with no date');

-- Another account on the same phone.
SELECT pg_temp.act('b7333333-3333-4333-8333-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_get_state() ->> 'eligibility', 'unavailable',
  'an account on a barred phone sees unavailable before it starts');
SELECT is(public.meet_check_in('key-73-s-0000000001', (SELECT d FROM dates WHERE name = 'adult'), 1),
  '{"status": "unavailable", "age": null}'::jsonb, 'and gets unavailable when it tries');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.meet_eligibility
           WHERE user_id = 'b7333333-3333-4333-8333-737373737373'), 0,
  'with no record written for it: nothing is known about that person');
UPDATE public.meet_age_refusal_devices SET expires_at = now() - interval '1 minute'
WHERE device_fingerprint_hash = sha256('phone-m1');
SELECT pg_temp.act('b7333333-3333-4333-8333-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-s-0000000002', (SELECT d FROM dates WHERE name = 'adult'), 1)
            ->> 'status', 'eligible', 'once the bar expires, the same phone can check in');
RESET ROLE;

-- An eligible adult whose phone is barred later is shut out too.
UPDATE public.meet_age_refusal_devices SET expires_at = now() + interval '365 days'
WHERE device_fingerprint_hash = sha256('phone-m1');
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7333333-3333-4333-8333-737373737373', 'meet.v5', false)$$,
  'P0001', 'ERR_MEET_UNAVAILABLE', 'a barred device shuts out an eligible account on it');

-- Device integrity (L3).
SELECT pg_temp.act('b7344444-4444-4444-8444-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-i-0000000001', (SELECT d FROM dates WHERE name = 'adult'), 1),
  '{"status": "unavailable", "age": null}'::jsonb,
  'a phone that failed device integrity gets unavailable');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.meet_eligibility
           WHERE user_id = 'b7344444-4444-4444-8444-737373737373'), 0, 'and no record');
UPDATE public.remote_config SET value = 'false'
WHERE key = 'meet.require_device_integrity' AND country_code IS NULL;
SELECT pg_temp.act('b7344444-4444-4444-8444-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-i-0000000002', (SELECT d FROM dates WHERE name = 'adult'), 1)
            ->> 'status', 'eligible', 'with meet.require_device_integrity off, the same phone passes');
RESET ROLE;
UPDATE public.remote_config SET value = 'true'
WHERE key = 'meet.require_device_integrity' AND country_code IS NULL;

-- ---------------------------------------------------------------------------
-- Time zones and the edges of the range.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7355555-5555-4555-8555-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-k-0000000001', (SELECT d FROM dates WHERE name = 'k_18'), 1),
  '{"status": "eligible", "age": 18}'::jsonb,
  'an 18th birthday that is today where the person lives (UTC+14) is eligible');
RESET ROLE;
SELECT pg_temp.act('b7366666-6666-4666-8666-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_check_in('key-73-p-0000000001', (SELECT d FROM dates WHERE name = 'k_18'), 1),
  '{"status": "refused", "age": null}'::jsonb,
  'the same date for somebody at UTC-11, where it is still the day before, is refused');
RESET ROLE;
SELECT pg_temp.act('b7399999-9999-4999-8999-737373737373');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'key-73-o-0000000001',
         (SELECT d FROM dates WHERE name = 'age_100')),
  '22023', 'ERR_INVALID_ARGUMENT', 'an age of 100 is not a date anybody means');
SELECT is(public.meet_check_in('key-73-o-0000000002', (SELECT d FROM dates WHERE name = 'age_99'), 1),
  '{"status": "eligible", "age": 99}'::jsonb, 'and 99, the oldest a preference can name, is fine');
RESET ROLE;
UPDATE public.remote_config SET value = '16' WHERE key = 'meet.min_age' AND country_code IS NULL;
SELECT is(private.meet_min_age(), 18, 'meet.min_age can never take the bar below 18');
UPDATE public.remote_config SET value = '18' WHERE key = 'meet.min_age' AND country_code IS NULL;

-- ---------------------------------------------------------------------------
-- The guidelines version.
-- ---------------------------------------------------------------------------
INSERT INTO public.legal_documents (country_code, type, version, locale, url, published_at)
VALUES ('NG', 'meet_guidelines', 2, 'en', 'https://suskiierrand.com/en/legal/meet-guidelines',
        now() - interval '1 minute');
UPDATE public.remote_config SET value = '2' WHERE key = 'meet.guidelines_version' AND country_code IS NULL;
SELECT throws_ok(
  $$SELECT private.meet_require_access('b7311111-1111-4111-8111-737373737373', 'meet.v5', false)$$,
  'P0001', 'ERR_MEET_GUIDELINES_OUTDATED', 'a new guidelines version stops an eligible adult');
SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_get_state() -> 'guidelines',
  '{"required_version": 2, "accepted_version": 1,
    "url": "https://suskiierrand.com/en/legal/meet-guidelines"}'::jsonb,
  'meet_get_state says which version is required, which was accepted, and where to read it');
SELECT throws_ok($$SELECT public.meet_get_my_profile()$$, 'P0001', 'ERR_MEET_GUIDELINES_OUTDATED',
  'every other function refuses until they accept');
SELECT throws_ok($$SELECT public.meet_accept_guidelines('key-73-a-0000000020', 1)$$,
  'P0001', 'ERR_MEET_GUIDELINES_OUTDATED', 'accepting the old version again does not count');
SELECT lives_ok($$SELECT public.meet_accept_guidelines('key-73-a-0000000021', 2)$$,
  'accepting the current version does');
SELECT lives_ok($$SELECT public.meet_accept_guidelines('key-73-a-0000000021', 2)$$,
  'and a replay of it is harmless');
SELECT lives_ok($$SELECT public.meet_get_my_profile()$$, 'after which Meet opens again');
RESET ROLE;
SELECT is((SELECT guidelines_version FROM public.meet_eligibility
           WHERE user_id = 'b7311111-1111-4111-8111-737373737373'), 2, 'the record says version 2');
SELECT is(
  (SELECT array_agg(d.version ORDER BY c.id) FROM public.consents c
   LEFT JOIN public.legal_documents d ON d.id = c.legal_document_id
   WHERE c.user_id = 'b7311111-1111-4111-8111-737373737373' AND c.kind = 'meet_terms'),
  ARRAY[NULL, 2]::integer[],
  'a second meet_terms consent, linked to the v2 page; the replay recorded nothing');
SELECT pg_temp.act('b7355555-5555-4555-8555-737373737373');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.meet_accept_guidelines(NULL, 2)$$,
  '22023', 'ERR_IDEMPOTENCY_KEY_INVALID', 'accepting needs a key like every other change');
RESET ROLE;
UPDATE public.remote_config SET value = '1' WHERE key = 'meet.guidelines_version' AND country_code IS NULL;

-- ---------------------------------------------------------------------------
-- The record outlives the Meet profile.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.meet_save_profile('key-73-a-0000000030', 'Ada', NULL, NULL, NULL,
                    NULL, NULL, NULL)$$, 'an eligible adult makes a profile');
SELECT lives_ok($$SELECT public.meet_delete_profile('key-73-a-0000000031')$$, 'and deletes it');
SELECT throws_ok(
  format('SELECT public.meet_check_in(%L, %L, 1)', 'key-73-a-0000000032',
         (SELECT d - 3650 FROM dates WHERE name = 'adult')),
  'P0001', 'ERR_MEET_AGE_ALREADY_SET', 'deleting the profile does not reopen the date');
RESET ROLE;
SELECT ok(
  (SELECT birth_date = (SELECT d FROM dates WHERE name = 'adult') AND status = 'eligible'
   FROM public.meet_eligibility WHERE user_id = 'b7311111-1111-4111-8111-737373737373')
  AND NOT EXISTS (SELECT 1 FROM public.meet_profiles
                  WHERE user_id = 'b7311111-1111-4111-8111-737373737373'),
  'the profile is gone and the eligibility record is untouched');
SELECT is(
  (SELECT count(*)::int FROM pg_constraint
   WHERE conrelid = 'public.meet_eligibility'::regclass AND contype = 'f'
     AND confrelid <> 'auth.users'::regclass), 0,
  'structurally: eligibility hangs off the account, never off the Meet profile');

-- ---------------------------------------------------------------------------
-- Nobody reaches the tables, and the kill switch works.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int FROM unnest(ARRAY['public.meet_eligibility', 'public.meet_age_refusal_devices']) t,
          unnest(ARRAY['anon', 'authenticated']) r,
          unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   WHERE has_table_privilege(r, t, p)), 0,
  'no client role holds any privilege on either table');
SELECT is(
  (SELECT count(*)::int FROM pg_class
   WHERE oid IN ('public.meet_eligibility'::regclass, 'public.meet_age_refusal_devices'::regclass)
     AND relrowsecurity AND relforcerowsecurity), 2, 'and both force row level security');
SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT birth_date FROM public.meet_eligibility$$, '42501', NULL,
  'not even the owner reads their own row directly');
RESET ROLE;

UPDATE public.feature_flags SET enabled = false WHERE key = 'meet.v5' AND country_code IS NULL;
SELECT pg_temp.act('b7311111-1111-4111-8111-737373737373');
SET LOCAL ROLE authenticated;
SELECT is(public.meet_get_state(), '{"v5": false, "features": [], "eligibility": null,
  "guidelines": null, "profile": null, "restrictions": [], "suspension": null, "unread": null}'::jsonb,
  'with meet.v5 off, meet_get_state says so and nothing more');
SELECT throws_ok($$SELECT public.meet_accept_guidelines('key-73-a-0000000040', 1)$$,
  'P0001', 'ERR_FEATURE_UNAVAILABLE', 'and nothing else works');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
