-- The outbox's second reader, database half (audit `AUDIT-2026-09-22.md` N.3).
--
-- `private.notify` has been emitting `notification.created` since Phase 3 with nothing reading
-- it. What is asserted here is the half that lives in SQL: the event carries the decision, the
-- delivery is recorded rather than assumed, and nobody reads somebody else's delivery log.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(20);

INSERT INTO auth.users (id, phone) VALUES
  ('a0111111-1111-4111-8111-999999999999', '2348000000901'),   -- the recipient
  ('a0222222-2222-4222-8222-999999999999', '2348000000902'),   -- support, scoped to NG
  ('a0333333-3333-4333-8333-999999999999', '2547000000903');   -- support, scoped to KE
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('a0111111-1111-4111-8111-999999999999',
                  'a0222222-2222-4222-8222-999999999999');
UPDATE public.profiles SET country_code = 'KE'
WHERE user_id = 'a0333333-3333-4333-8333-999999999999';
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('a0222222-2222-4222-8222-999999999999', ARRAY['support_agent']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('a0333333-3333-4333-8333-999999999999', ARRAY['support_agent']::public.admin_role[],
   ARRAY['KE']::char(2)[]);

CREATE TEMP TABLE nd (name text PRIMARY KEY, val text);
GRANT ALL ON nd TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The event carries the decision, so no sender re-derives it.
-- ---------------------------------------------------------------------------
INSERT INTO nd VALUES ('n1', private.notify('a0111111-1111-4111-8111-999999999999', 'job_status',
  'notification.job.assigned.title', 'notification.job.assigned.body',
  jsonb_build_object('request_id', '11111111-1111-4111-8111-111111111111',
                     'amount_minor', 10000, 'currency', 'NGN'),
  '/jobs/11111111-1111-4111-8111-111111111111')::text);

SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE event_type = 'notification.created'), 1,
  'notifying somebody emits an event, which is what has been happening since Phase 3');
SELECT is((SELECT jsonb_array_length(payload -> 'channels') FROM private.outbox
           WHERE event_type = 'notification.created'), 1,
  'and the channel decision travels on it: push, by default, and only push');
SELECT is((SELECT payload ->> 'urgent' FROM private.outbox
           WHERE event_type = 'notification.created'), 'true',
  'along with whether the kind is job-critical, which quiet hours may not suppress (SH-16)');
SELECT is((SELECT count(*)::int FROM private.claim_outbox(ARRAY['user'], 50)
           WHERE event_type = 'notification.created'), 1,
  'and the worker can claim it — until now nothing read the `user` aggregate at all');

-- ---------------------------------------------------------------------------
-- A delivery is recorded, not assumed.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 0,
  '"did they get the push?" had no answer before this table');
SELECT ok(private.record_notification_delivery(
  (SELECT val FROM nd WHERE name = 'n1')::bigint,
  'a0111111-1111-4111-8111-999999999999', 'push', 'console', 'sent') IS NOT NULL,
  'the worker writes one');
SELECT ok(private.record_notification_delivery(
  (SELECT val FROM nd WHERE name = 'n1')::bigint,
  'a0111111-1111-4111-8111-999999999999', 'push', 'fcm', 'failed', 'token_expired') IS NOT NULL,
  'and a retry overwrites it');
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 1,
  'one outcome per notification per channel: the question is "did it arrive", and the outbox''s '
  'own attempts counter answers "how many times did we try"');
SELECT is((SELECT reason_key FROM public.notification_deliveries), 'token_expired',
  'with the reason the sender gave');
SELECT ok(private.record_notification_delivery(
  (SELECT val FROM nd WHERE name = 'n1')::bigint,
  'a0111111-1111-4111-8111-999999999999', 'sms', 'console', 'skipped',
  'no_sender_configured') IS NOT NULL, 'a second channel is a second row');
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 2, 'so there are two');
SELECT throws_ok(
  format($$SELECT private.record_notification_delivery(%L, %L, 'carrier_pigeon', 'x', 'sent')$$,
         (SELECT val FROM nd WHERE name = 'n1'), 'a0111111-1111-4111-8111-999999999999'),
  '22023', NULL, 'and a channel nobody defined is refused');

-- ---------------------------------------------------------------------------
-- Who reads a delivery log.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  jsonb_build_object('sub', 'a0111111-1111-4111-8111-999999999999',
                     'role', 'authenticated', 'aal', 'aal1')::text, true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 0,
  'not the recipient: whether a push reached a handset is telemetry about a device, and showing '
  'somebody their own log is one query from showing them another''s');
SELECT ok((SELECT count(*)::int FROM public.notifications) > 0,
  'they read the inbox row instead, which is the record either way');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  jsonb_build_object('sub', 'a0222222-2222-4222-8222-999999999999',
                     'role', 'authenticated', 'aal', 'aal2')::text, true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 2,
  'a support agent in the right country answers the question');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  jsonb_build_object('sub', 'a0333333-3333-4333-8333-999999999999',
                     'role', 'authenticated', 'aal', 'aal2')::text, true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.notification_deliveries), 0,
  'and one in the wrong country does not — the same scope as everything else');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Push targets, and the device that does not get one.
-- ---------------------------------------------------------------------------
INSERT INTO public.user_devices (user_id, platform, device_fingerprint_hash, push_token) VALUES
  ('a0111111-1111-4111-8111-999999999999', 'android', sha256('good-device'::bytea), 'tok-good'),
  ('a0111111-1111-4111-8111-999999999999', 'ios', sha256('no-token'::bytea), NULL);
SELECT is((SELECT count(*)::int FROM public.dispatch_push_targets(
             'a0111111-1111-4111-8111-999999999999')), 1,
  'a device with no token is not a target');

UPDATE public.user_devices SET integrity_verdict = jsonb_build_object('verdict', 'fail')
WHERE push_token = 'tok-good';
SELECT is((SELECT count(*)::int FROM public.dispatch_push_targets(
             'a0111111-1111-4111-8111-999999999999')), 0,
  'and neither is one that failed device integrity: a notification carries a deep link, and the '
  'spec puts integrity in front of anything sensitive');

-- ---------------------------------------------------------------------------
-- Ops.
-- ---------------------------------------------------------------------------
SELECT is(private.record_notification_health(), 'warn',
  'a failed delivery in the last hour is a warning');
SELECT is((SELECT detail ->> 'failed_last_hour' FROM private.health_checks
           WHERE check_key = 'notifications' ORDER BY id DESC LIMIT 1), '1',
  'and the check says how many');

SELECT * FROM finish();
ROLLBACK;
