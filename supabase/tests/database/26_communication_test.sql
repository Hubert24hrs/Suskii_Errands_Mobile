-- Notification delivery and scheduled errands (PRD SH-16, SH-17, CU-08, CU-32).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(28);

INSERT INTO auth.users (id, phone) VALUES
  ('af111111-1111-4111-8111-aaaaaaaaaaaa', '2348000000191'),   -- customer
  ('af222222-2222-4222-8222-aaaaaaaaaaaa', '2348000000192');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'af222222-2222-4222-8222-aaaaaaaaaaaa';

CREATE TEMP TABLE cm (name text PRIMARY KEY, id uuid);
GRANT ALL ON cm TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The time zone quiet hours are measured in.
-- ---------------------------------------------------------------------------
SELECT is(private.user_timezone('af111111-1111-4111-8111-aaaaaaaaaaaa'), 'Africa/Lagos',
  'with no time zone set, the country''s own is used rather than the server''s');
UPDATE public.profiles SET timezone = 'Not/A/Zone'
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa';
SELECT is(private.user_timezone('af111111-1111-4111-8111-aaaaaaaaaaaa'), 'Africa/Lagos',
  'a name PostgreSQL does not know falls back instead of raising inside a trigger');
UPDATE public.profiles SET timezone = 'Europe/London'
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa';
SELECT is(private.user_timezone('af111111-1111-4111-8111-aaaaaaaaaaaa'), 'Europe/London',
  'and a Nigerian in London is not woken at 3 a.m. Lagos time');

-- ---------------------------------------------------------------------------
-- Which channels a notification is sent on.
-- ---------------------------------------------------------------------------
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received'),
  ARRAY['push'],
  'with no preferences at all, push only: a default that sent SMS would spend real money');
INSERT INTO public.notification_preferences (user_id, channel, category, enabled) VALUES
  ('af111111-1111-4111-8111-aaaaaaaaaaaa', 'sms', 'transactional', true);
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received'),
  ARRAY['push', 'sms'], 'a channel the user turned on is used');
INSERT INTO public.notification_preferences (user_id, channel, category, enabled) VALUES
  ('af111111-1111-4111-8111-aaaaaaaaaaaa', 'push', 'transactional', false);
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received'),
  ARRAY['sms'], 'and one they turned off is not');

-- Quiet hours, anchored on the user's own clock so the test does not depend on the server's.
UPDATE public.notification_preferences
SET quiet_start = ((now() AT TIME ZONE 'Europe/London')::time - interval '1 hour')::time,
    quiet_end   = ((now() AT TIME ZONE 'Europe/London')::time + interval '1 hour')::time
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa' AND channel = 'sms';
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received'),
  ARRAY[]::text[], 'inside quiet hours an ordinary notification waits');
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'call_incoming'),
  ARRAY['sms'],
  'but a ringing phone is never held back — that is SH-16''s job-critical rule');
SELECT ok(private.notification_is_urgent('offer_accepted')
          AND private.notification_is_urgent('job_status')
          AND NOT private.notification_is_urgent('chat_message'),
  'the urgent set is a list, not a judgement made per call site');

UPDATE public.notification_preferences
SET quiet_start = ((now() AT TIME ZONE 'Europe/London')::time + interval '1 hour')::time,
    quiet_end   = ((now() AT TIME ZONE 'Europe/London')::time + interval '2 hours')::time
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa' AND channel = 'sms';
SELECT is(private.notification_channels('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received'),
  ARRAY['sms'], 'outside them it goes, including when the window crosses midnight');

-- The decision travels with the event, so no sender has to make it again.
SELECT ok(private.notify('af111111-1111-4111-8111-aaaaaaaaaaaa', 'rating_received',
            'notification.test.title', 'notification.test.body') IS NOT NULL,
  'notify writes the inbox row');
SELECT is((SELECT payload -> 'channels' FROM private.outbox
           WHERE event_type = 'notification.created' ORDER BY id DESC LIMIT 1),
  '["sms"]'::jsonb, 'and hands the sender the channels it decided on');
SELECT is((SELECT payload ->> 'urgent' FROM private.outbox
           WHERE event_type = 'notification.created' ORDER BY id DESC LIMIT 1),
  'false', 'with whether it may be held back');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa'), 1,
  'the inbox row is written whatever the channels say: it is the record, not a channel');

-- ---------------------------------------------------------------------------
-- CU-08 and CU-32: a scheduled errand publishes itself.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "af111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cm VALUES ('soon', public.create_request(
  'key-cm-create-soon-00001', 'personal_assistance', 'Collect the dry cleaning on Saturday',
  'Dry cleaner, Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711, NULL, NULL, NULL, NULL,
  now() + interval '30 minutes'));
INSERT INTO cm VALUES ('later', public.create_request(
  'key-cm-create-later-0001', 'personal_assistance', 'Collect a parcel next week',
  'Depot, Apapa', 'standard', false, NULL, NULL, 6.4459, 3.3600, NULL, NULL, NULL, NULL,
  now() + interval '3 days'));
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cm WHERE name = 'soon')),
  'draft'::public.job_status,
  'a scheduled errand stays a draft, so it can still be edited and cancelled (CU-32)');
RESET ROLE;

SELECT is(private.publish_scheduled_requests(), 1, 'the sweep publishes the one that is due');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cm WHERE name = 'soon')),
  'published'::public.job_status, 'it is on the board an hour before the customer needs it');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cm WHERE name = 'later')),
  'draft'::public.job_status, 'and next week''s errand is not');
SELECT is(private.publish_scheduled_requests(), 0, 'a second sweep finds nothing to do');
SELECT is((SELECT count(*)::int FROM private.outbox
           WHERE event_type = 'request.published'), 1,
  'publishing announces itself exactly as a customer pressing the button would');

-- One that cannot publish must not take the batch with it, and the customer has to be told.
UPDATE public.profiles SET customer_verification = 'unverified'
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa';
UPDATE public.requests SET scheduled_at = now() + interval '20 minutes'
WHERE id = (SELECT id FROM cm WHERE name = 'later');
SELECT is(private.publish_scheduled_requests(), 0, 'an unverified customer publishes nothing');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM cm WHERE name = 'later')),
  'draft'::public.job_status, 'the draft is still theirs to fix');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa' AND kind = 'system'), 1,
  'and they are told, rather than watching a draft that never went anywhere');
SELECT is((SELECT params ->> 'reason_key' FROM public.notifications
           WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa' AND kind = 'system'
           ORDER BY id DESC LIMIT 1), 'ERR_VERIFICATION_REQUIRED',
  'with a reason key the screen can act on, and never a raw database message');

-- ---------------------------------------------------------------------------
-- The hand-published path is the same code, with the caller's name on it.
-- ---------------------------------------------------------------------------
UPDATE public.profiles SET customer_verification = 'verified'
WHERE user_id = 'af111111-1111-4111-8111-aaaaaaaaaaaa';
SELECT set_config('request.jwt.claims',
  '{"sub": "af222222-2222-4222-8222-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.publish_request(%L, 'key-cm-publish-x-000001')$$,
    (SELECT id FROM cm WHERE name = 'later')),
  'P0001', 'ERR_REQUEST_NOT_FOUND',
  'somebody else''s draft is not publishable, and is not admitted to exist');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "af111111-1111-4111-8111-aaaaaaaaaaaa", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.publish_request((SELECT id FROM cm WHERE name = 'later'),
            'key-cm-publish-c-000001'),
  'published'::public.job_status, 'the owner publishes it by hand');
SELECT is(public.publish_request((SELECT id FROM cm WHERE name = 'later'),
            'key-cm-publish-c-000001'),
  'published'::public.job_status, 'and a replayed key answers rather than transitioning again');
SELECT throws_ok(
  format($$SELECT public.publish_request(%L, 'key-cm-publish-c-000002')$$,
    (SELECT id FROM cm WHERE name = 'later')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a published request does not publish twice');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
