-- The risk engine and fraud cases (spec "Rule-based risk engine"; ERD §7; threat model rows 37,
-- 38 and 159). The property under test throughout: a rule raises a flag for a person to look at,
-- and nothing in this file suspends, bans or refuses anybody.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(36);

INSERT INTO auth.users (id, phone) VALUES
  ('8d111111-1111-4111-8111-cccccccccccc', '2348000000171'),   -- customer
  ('8d222222-2222-4222-8222-cccccccccccc', '2348000000172'),   -- provider, same handset
  ('8d333333-3333-4333-8333-cccccccccccc', '2348000000173'),   -- support agent
  ('8d444444-4444-4444-8444-cccccccccccc', '2348000000174'),   -- four accounts sharing one phone
  ('8d555555-5555-4555-8555-cccccccccccc', '2348000000175'),
  ('8d666666-6666-4666-8666-cccccccccccc', '2348000000176'),
  ('8d777777-7777-4777-8777-cccccccccccc', '2348000000177');
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = '8d111111-1111-4111-8111-cccccccccccc';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = '8d222222-2222-4222-8222-cccccccccccc';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('8d333333-3333-4333-8333-cccccccccccc',
                  '8d444444-4444-4444-8444-cccccccccccc',
                  '8d555555-5555-4555-8555-cccccccccccc',
                  '8d666666-6666-4666-8666-cccccccccccc',
                  '8d777777-7777-4777-8777-cccccccccccc');
INSERT INTO public.provider_profiles (user_id) VALUES ('8d222222-2222-4222-8222-cccccccccccc');
INSERT INTO public.admin_users (user_id, roles)
VALUES ('8d333333-3333-4333-8333-cccccccccccc',
        ARRAY['support_agent']::public.admin_role[]);

CREATE TEMP TABLE rk (name text PRIMARY KEY, id uuid);
GRANT ALL ON rk TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The door in. One open flag per subject per rule, which is what lets a sweep run hourly.
-- ---------------------------------------------------------------------------
INSERT INTO rk VALUES ('first', private.raise_fraud_flag(
  'user', '8d444444-4444-4444-8444-cccccccccccc', 'request_velocity', 50::smallint));
SELECT ok((SELECT id FROM rk WHERE name = 'first') IS NOT NULL, 'a rule raises a flag');
SELECT is(private.raise_fraud_flag(
    'user', '8d444444-4444-4444-8444-cccccccccccc', 'request_velocity', 50::smallint),
  NULL, 'and raising the same one again changes nothing: an hourly sweep is not a queue of 24');
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 1, 'so there is one flag');
SELECT is((SELECT count(*)::int FROM private.outbox WHERE event_type = 'risk.flag_raised'), 1,
  'announced once');

-- ---------------------------------------------------------------------------
-- Immediate signals.
-- ---------------------------------------------------------------------------
-- GPS spoofing: the client says the position was mocked, and we believe it *against* them.
INSERT INTO public.provider_live_location (provider_id, pos, is_mock)
VALUES ('8d222222-2222-4222-8222-cccccccccccc',
        extensions.ST_GeogFromText('POINT(3.3792 6.5244)'), true);
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE rule_key = 'mock_location'
             AND subject_id = '8d222222-2222-4222-8222-cccccccccccc'), 1,
  'a mocked position flags the provider');
SELECT ok((SELECT suspended_until IS NULL FROM public.provider_profiles
           WHERE user_id = '8d222222-2222-4222-8222-cccccccccccc'),
  'and does not suspend them: the PIN and the photo at the door are the real control');

-- A device that fails integrity. The verdict shape is the one the Edge Function writes.
SELECT set_config('request.jwt.claims',
  '{"sub": "8d222222-2222-4222-8222-cccccccccccc", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rk VALUES ('dev_p', public.register_device('android', 'shared-handset-fingerprint-1'));
RESET ROLE;
UPDATE public.user_devices
SET integrity_verdict = '{"status": "fail", "platform": "android", "reasons": ["MEETS_DEVICE_INTEGRITY missing"]}'::jsonb
WHERE id = (SELECT id FROM rk WHERE name = 'dev_p');
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE rule_key = 'device_integrity_failed'), 1, 'a failed integrity verdict flags it');
UPDATE public.user_devices
SET integrity_verdict = '{"status": "unevaluated", "platform": "android", "reasons": []}'::jsonb
WHERE id = (SELECT id FROM rk WHERE name = 'dev_p');
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE rule_key = 'device_integrity_failed'), 1,
  'and `unevaluated` does not: it means we had no credentials, not that the device lied');

-- ---------------------------------------------------------------------------
-- Self-dealing across two accounts on one handset. The customer registers the same phone the
-- provider uses, then hires them.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "8d111111-1111-4111-8111-cccccccccccc", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.register_device('android', 'shared-handset-fingerprint-1') IS NOT NULL,
  'the customer registers the same handset');
INSERT INTO rk VALUES ('r', public.create_request(
  'key-rk-create-req-000000001', 'personal_assistance', 'Collect a parcel from the depot',
  'Depot, Apapa', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM rk WHERE name = 'r'), 'key-rk-publish-000000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "8d222222-2222-4222-8222-cccccccccccc", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rk VALUES ('o', public.create_offer(
  'key-rk-offer-p-0000000001', (SELECT id FROM rk WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "8d111111-1111-4111-8111-cccccccccccc", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-rk-accept-c-000000001', (SELECT id FROM rk WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM rk WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned — nothing refused it');
SELECT is((SELECT count(*)::int FROM public.fraud_flags
           WHERE rule_key = 'self_dealing_device'
             AND subject_id = (SELECT id::text FROM rk WHERE name = 'r')), 1,
  'and the shared handset is flagged afterwards, which is the only time it can be seen');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM rk WHERE name = 'r')),
  'assigned'::public.job_status, 'the job carries on: a flag is not a refusal');

-- ---------------------------------------------------------------------------
-- The sweep.
-- ---------------------------------------------------------------------------
-- Device reuse. Two accounts on one phone is ordinary here; four is the configured line.
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash)
SELECT u, 'android', sha256('family-phone'::bytea)
FROM unnest(ARRAY['8d444444-4444-4444-8444-cccccccccccc',
                  '8d555555-5555-4555-8555-cccccccccccc',
                  '8d666666-6666-4666-8666-cccccccccccc']::uuid[]) u;
SELECT is(private.risk_device_reuse(), 0, 'three accounts on one handset is not a finding');
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash)
VALUES ('8d777777-7777-4777-8777-cccccccccccc', 'android', sha256('family-phone'::bytea));
SELECT is(private.risk_device_reuse(), 1, 'a fourth is');
SELECT is(private.risk_device_reuse(), 0, 'and it is raised once, not on every sweep');
SELECT is((SELECT subject_kind FROM public.fraud_flags WHERE rule_key = 'device_reuse'), 'device',
  'the subject is the handset, not any one of the people on it');

-- Velocity.
SELECT is(private.risk_velocity(), 0, 'an ordinary customer trips nothing');
INSERT INTO public.requests
  (customer_id, country_code, category_id, description, pickup_label, currency)
SELECT '8d111111-1111-4111-8111-cccccccccccc', 'NG',
       (SELECT id FROM public.service_categories WHERE key = 'personal_assistance'),
       'Bulk request ' || g, 'Somewhere in Lagos', 'NGN'
FROM generate_series(1, 12) g;
SELECT is(private.risk_velocity(), 1, 'twelve requests in an hour is not running errands');
SELECT is((SELECT (details ->> 'requests_1h')::int FROM public.fraud_flags
           WHERE rule_key = 'request_velocity' AND status = 'open'
           ORDER BY created_at DESC LIMIT 1), 13,
  'and the flag carries the number, so a reviewer does not have to go and count');

-- Cancellation abuse: the rate, and the volume floor underneath it.
UPDATE public.provider_profiles SET cancellation_rate_bps = 4000
WHERE user_id = '8d222222-2222-4222-8222-cccccccccccc';
SELECT is(private.risk_cancellations(), 0,
  'a high rate over one job is arithmetic, not evidence');
UPDATE public.remote_config SET value = '1' WHERE key = 'risk_min_jobs_for_rate';
SELECT is(private.risk_cancellations(), 1, 'with enough history behind it, it is a finding');

-- Collusion: a pair that works only with each other.
UPDATE public.remote_config SET value = '1' WHERE key = 'risk_pair_jobs_30d';
SELECT is(private.risk_collusive_pairs(), 1, 'a pair with no other counterparties is flagged');
SELECT is((SELECT subject_id FROM public.fraud_flags WHERE rule_key = 'collusive_pair'),
  '8d111111-1111-4111-8111-cccccccccccc:8d222222-2222-4222-8222-cccccccccccc',
  'and both sides are named, because neither half of a pair is the culprit on its own');

-- ---------------------------------------------------------------------------
-- Who sees the flags. Not the people they are about.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "8d222222-2222-4222-8222-cccccccccccc", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.fraud_flags), 0,
  'a flagged provider cannot read their own flags: a visible score is a score you can tune');
SELECT throws_ok($$SELECT public.fraud_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and does not work the queue');
SELECT throws_ok(
  format($$SELECT public.review_fraud_flag('key-rk-x-00000000000001', %L, false, 'nothing here')$$,
    (SELECT id FROM rk WHERE name = 'first')),
  '42501', 'ERR_PERMISSION_DENIED', 'nor clear one by id');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The reviewer.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "8d333333-3333-4333-8333-cccccccccccc", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*) FROM public.fraud_queue()) >= 6, 'the reviewer sees the open flags');
SELECT is((SELECT rule_key FROM public.fraud_queue() LIMIT 1), 'self_dealing_device',
  'worst first: the queue is ordered by score, which is all a score is for');
SELECT throws_ok(
  $$SELECT public.review_fraud_flag('key-rk-rev-missing-001',
      '00000000-0000-4000-8000-000000000000'::uuid, false, 'no such flag')$$,
  'P0001', 'ERR_FRAUD_FLAG_NOT_FOUND', 'a flag that does not exist is said so plainly');
SELECT throws_ok(
  format($$SELECT public.review_fraud_flag('key-rk-rev-nonote-01', %L, true, '   ')$$,
    (SELECT id FROM rk WHERE name = 'first')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'and a decision with no reasoning is refused: nobody can defend it six months later');
SELECT is(public.review_fraud_flag('key-rk-rev-confirm-01',
            (SELECT id FROM rk WHERE name = 'first'), true, 'Bot posting; account referred.'),
  'confirmed'::public.fraud_flag_status, 'the reviewer confirms it');
SELECT is(public.review_fraud_flag('key-rk-rev-confirm-01',
            (SELECT id FROM rk WHERE name = 'first'), true, 'Bot posting; account referred.'),
  'confirmed'::public.fraud_flag_status, 'and a repeat with the same key decides nothing twice');
SELECT throws_ok(
  format($$SELECT public.review_fraud_flag('key-rk-rev-again-001', %L, false, 'changed my mind')$$,
    (SELECT id FROM rk WHERE name = 'first')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a decided flag is not re-decided');
RESET ROLE;

SELECT ok((SELECT suspended_until IS NULL FROM public.provider_profiles
           WHERE user_id = '8d222222-2222-4222-8222-cccccccccccc'),
  'confirming a flag suspends nobody — that is a separate decision, by a person, with a name on it');
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'risk.review_flag'), 1,
  'and the review is in the hash-chained log');
SELECT ok(private.raise_fraud_flag(
    'user', '8d444444-4444-4444-8444-cccccccccccc', 'request_velocity', 50::smallint) IS NOT NULL,
  'once a flag is decided the same rule can fire again: the lock is on open cases, not on people');

SELECT * FROM finish();
ROLLBACK;
