-- Job-scoped chat and the private channel rules (ERD §8; RLS matrix §8 and realtime
-- authorisation; job lifecycle transition 11).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(33);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-111111111111', '2348000000101'),   -- customer
  ('f2222222-2222-4222-8222-222222222222', '2348000000102'),   -- provider
  ('f3333333-3333-4333-8333-333333333333', '2348000000103');   -- a rival provider
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'f1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('f2222222-2222-4222-8222-222222222222',
                  'f3333333-3333-4333-8333-333333333333');
INSERT INTO public.provider_profiles (user_id) VALUES
  ('f2222222-2222-4222-8222-222222222222'),
  ('f3333333-3333-4333-8333-333333333333');

CREATE TEMP TABLE ch (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE chm (name text PRIMARY KEY, id bigint);
GRANT ALL ON ch, chm TO authenticated, service_role;

SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ch VALUES ('r', public.create_request(
  'key-ch-create-req-0000000001', 'personal_assistance', 'Queue at the bank for me',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM ch WHERE name = 'r'), 'key-ch-publish-0000000001');
RESET ROLE;

-- Two providers bid, which is what makes the channel rules matter.
SELECT set_config('request.jwt.claims',
  '{"sub": "f2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO ch VALUES ('o', public.create_offer(
  'key-ch-offer-p-000000000001', (SELECT id FROM ch WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "f3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.create_offer('key-ch-offer-q-000000000001', (SELECT id FROM ch WHERE name = 'r'),
  600000, NULL);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Chat is closed until somebody is actually doing the job.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-early-0000001', %L, 'Hello?')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  'P0001', 'ERR_CHAT_CLOSED', 'there is no chat before a provider is assigned');
SELECT public.accept_offer('key-ch-accept-c-00000001', (SELECT id FROM ch WHERE name = 'o'));
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-agreed-000001', %L, 'Hello?')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  'P0001', 'ERR_CHAT_CLOSED', 'nor while the job is only agreed');
RESET ROLE;

SELECT is(private.mark_paid_held((SELECT id FROM ch WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned, which opens the chat');
SELECT ok((SELECT private.chat_is_open((SELECT id FROM ch WHERE name = 'r'))),
  'and the window says so');

-- ---------------------------------------------------------------------------
-- Sending.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO chm VALUES ('m1', public.send_message('key-ch-msg-c-00000000001',
  (SELECT id FROM ch WHERE name = 'r'), 'I am at the gate in a blue shirt.'));
SELECT ok((SELECT id FROM chm WHERE name = 'm1') > 0, 'the customer sends a message');
SELECT is(public.send_message('key-ch-msg-c-00000000001', (SELECT id FROM ch WHERE name = 'r'),
            'I am at the gate in a blue shirt.'),
  (SELECT id FROM chm WHERE name = 'm1'), 'a repeated key replays rather than sending twice');
SELECT is((SELECT count(*)::int FROM public.messages), 1, 'so there is one message, not two');
SELECT is((SELECT count(*)::int FROM public.conversations), 1,
  'and one conversation, created with the first message');
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-empty-000001', %L, '   ')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'an empty message is not a message');
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-image-000001', %L, NULL, 'image')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'an image message with no image is refused');
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-system-00001', %L, 'I am the system', 'system')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'and nobody sends a system message by hand');
SELECT is((SELECT moderation_status FROM public.messages
           WHERE id = (SELECT id FROM chm WHERE name = 'm1')),
  'pending'::public.moderation_status,
  'messages deliver and queue for review: OD-21 fail-open, not a silent no-op');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Who can read it.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "f2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.messages), 1, 'the assigned provider reads the thread');
INSERT INTO chm VALUES ('m2', public.send_message('key-ch-msg-p-00000000001',
  (SELECT id FROM ch WHERE name = 'r'), 'On my way, five minutes.'));
SELECT is(public.mark_read((SELECT id FROM ch WHERE name = 'r'),
            (SELECT id FROM chm WHERE name = 'm1')),
  (SELECT id FROM chm WHERE name = 'm1'), 'and marks what they have read');
SELECT is(public.mark_read((SELECT id FROM ch WHERE name = 'r'), 0::bigint),
  (SELECT id FROM chm WHERE name = 'm1'),
  'a later call with an older id does not move the marker backwards');
RESET ROLE;

-- The provider who lost the job is not in the conversation.
SELECT set_config('request.jwt.claims',
  '{"sub": "f3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.messages), 0, 'the rival provider reads nothing');
SELECT is((SELECT count(*)::int FROM public.conversations), 0, 'and cannot see the conversation');
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-rival-000001', %L, 'Use me instead')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'nor message the customer behind the winner''s back');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM public.messages$$,
  '42501', NULL, 'anon has no access to messages at all');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Channel authorisation: the same rules, one topic at a time.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "f2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok((SELECT private.may_join_topic('user:f2222222-2222-4222-8222-222222222222')),
  'a user joins their own channel');
SELECT ok(NOT (SELECT private.may_join_topic('user:f1111111-1111-4111-8111-111111111111')),
  'and not somebody else''s');
SELECT ok((SELECT private.may_join_topic(
            'request:' || (SELECT id FROM ch WHERE name = 'r') ||
            ':provider:f2222222-2222-4222-8222-222222222222')),
  'a provider joins their own offer channel');
SELECT ok(NOT (SELECT private.may_join_topic(
            'request:' || (SELECT id FROM ch WHERE name = 'r') ||
            ':provider:f3333333-3333-4333-8333-333333333333')),
  'and cannot join a rival''s, which is where the rival''s amount would be');
SELECT ok(NOT (SELECT private.may_join_topic(
            'request:' || (SELECT id FROM ch WHERE name = 'r') || ':customer')),
  'nor the customer channel, which carries every offer on the request');
SELECT ok((SELECT private.may_join_topic('job:' || (SELECT id FROM ch WHERE name = 'r'))),
  'but the job channel is theirs: they are on the job');
SELECT ok(NOT (SELECT private.may_join_topic('ops:sos')), 'ops channels are not theirs');
SELECT ok(NOT (SELECT private.may_join_topic('job:not-a-uuid')),
  'a malformed topic is refused rather than raising');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "f3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT (SELECT private.may_join_topic('job:' || (SELECT id FROM ch WHERE name = 'r'))),
  'the rival is not on the job channel either');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The window closes a day after confirmation.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.send_message('key-ch-msg-c-00000000002', (SELECT id FROM ch WHERE name = 'r'),
  'Thank you, see you shortly.');
RESET ROLE;

UPDATE public.jobs SET confirmed_at = now() - interval '2 days', completed_at = now() - interval '2 days'
WHERE request_id = (SELECT id FROM ch WHERE name = 'r');
UPDATE public.requests SET status = 'confirmed' WHERE id = (SELECT id FROM ch WHERE name = 'r');
SELECT ok(NOT (SELECT private.chat_is_open((SELECT id FROM ch WHERE name = 'r'))),
  'two days after confirmation the conversation is closed');

SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.send_message('key-ch-msg-late-00000001', %L, 'One more thing')$$,
    (SELECT id FROM ch WHERE name = 'r')),
  'P0001', 'ERR_CHAT_CLOSED', 'and nothing more can be sent');
SELECT is((SELECT count(*)::int FROM public.messages), 3,
  'though the history stays readable to the people who were in it');
RESET ROLE;

-- A dispute reopens it, because that is when people most need to talk.
UPDATE public.requests SET status = 'disputed' WHERE id = (SELECT id FROM ch WHERE name = 'r');
SELECT ok((SELECT private.chat_is_open((SELECT id FROM ch WHERE name = 'r'))),
  'an open dispute keeps the conversation open, whatever the window says');

-- Whether the channel policies actually bound to `realtime.messages` is a fact about the stack,
-- not an assumption: where the table exists, the policies must be on it. If Realtime is ever
-- absent, this records that too rather than quietly passing.
SELECT is(
  (SELECT CASE WHEN to_regclass('realtime.messages') IS NULL THEN -1
               ELSE (SELECT count(*)::int FROM pg_policies
                     WHERE schemaname = 'realtime' AND tablename = 'messages'
                       AND policyname IN ('realtime_join_own_topics', 'realtime_send_own_topics'))
          END),
  2, 'the channel policies are bound to realtime.messages');

SELECT * FROM finish();
ROLLBACK;
