-- In-app calls, missed calls and the PSTN seam (PRD SH-12, SH-14, SH-15; ERD §8; RLS matrix §8).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(38);

INSERT INTO auth.users (id, phone) VALUES
  ('9e111111-1111-4111-8111-bbbbbbbbbbbb', '2348000000181'),   -- customer
  ('9e222222-2222-4222-8222-bbbbbbbbbbbb', '2348000000182'),   -- provider
  ('9e333333-3333-4333-8333-bbbbbbbbbbbb', '2348000000183'),   -- a stranger
  ('9e444444-4444-4444-8444-bbbbbbbbbbbb', '2348000000184');   -- support agent
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = '9e111111-1111-4111-8111-bbbbbbbbbbbb';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('9e333333-3333-4333-8333-bbbbbbbbbbbb',
                  '9e444444-4444-4444-8444-bbbbbbbbbbbb');
INSERT INTO public.provider_profiles (user_id) VALUES ('9e222222-2222-4222-8222-bbbbbbbbbbbb');
INSERT INTO public.admin_users (user_id, roles)
VALUES ('9e444444-4444-4444-8444-bbbbbbbbbbbb',
        ARRAY['support_agent']::public.admin_role[]);

CREATE TEMP TABLE cl (name text PRIMARY KEY, id uuid);
GRANT ALL ON cl TO authenticated, service_role;

-- No recording column, and none may be added: the spec says metadata only and the DPIA was
-- written on that basis. Asserted structurally so a future migration cannot add one quietly.
SELECT is((SELECT count(*)::int FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'calls'
             AND (column_name ~ 'record' OR column_name ~ 'transcript')), 0,
  'calls stores no recording and no transcript');

-- ---------------------------------------------------------------------------
-- Before there is a job there is no call.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('r', public.create_request(
  'key-cl-create-req-000000001', 'personal_assistance', 'Collect my suit from the tailor',
  'Tailor, Surulere', 'standard', false, NULL, NULL, 6.4969, 3.3481));
SELECT public.publish_request((SELECT id FROM cl WHERE name = 'r'), 'key-cl-publish-000000001');
SELECT throws_ok(
  format($$SELECT public.start_call('key-cl-early-c-00000001', %L)$$,
    (SELECT id FROM cl WHERE name = 'r')),
  'P0001', 'ERR_CALL_WINDOW_CLOSED',
  'a published request is not a job: there is nobody to call yet');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "9e222222-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('o', public.create_offer(
  'key-cl-offer-p-0000000001', (SELECT id FROM cl WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-cl-accept-c-000000001', (SELECT id FROM cl WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM cl WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned, so the call window opens');

-- ---------------------------------------------------------------------------
-- Ringing.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('c1', (SELECT call_id FROM public.start_call(
  'key-cl-start-c1-00000001', (SELECT id FROM cl WHERE name = 'r'))));
SELECT ok((SELECT id FROM cl WHERE name = 'c1') IS NOT NULL, 'the customer starts a call');
SELECT is((SELECT counterparty_id FROM public.start_call(
             'key-cl-start-c1-00000001', (SELECT id FROM cl WHERE name = 'r'))),
  '9e222222-2222-4222-8222-bbbbbbbbbbbb'::uuid,
  'the server decides who is called, from the job — the caller never names them');
SELECT ok((SELECT is_caller FROM public.start_call(
             'key-cl-start-c1-00000001', (SELECT id FROM cl WHERE name = 'r'))),
  'and the replay of the same key answers the same, rather than ringing twice');
SELECT matches((SELECT room_name FROM public.calls WHERE id = (SELECT id FROM cl WHERE name = 'c1')),
  '-[0-9a-f]{12}$', 'the room name is salted, so it cannot be guessed from the request id');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb' AND kind = 'call_incoming'), 1,
  'the person being called is told once');

-- A second attempt, from either side, joins the one call.
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT call_id FROM public.start_call(
             'key-cl-start-c1-00000002', (SELECT id FROM cl WHERE name = 'r'))),
  (SELECT id FROM cl WHERE name = 'c1'),
  'a fresh key does not start a second call: one live call per job');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "9e222222-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT (SELECT is_caller FROM public.start_call(
                 'key-cl-start-p1-00000001', (SELECT id FROM cl WHERE name = 'r'))),
  'and the other party calling back is told they are the callee, so their screen says answer');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.calls), 1, 'still one call');

SELECT set_config('request.jwt.claims',
  '{"sub": "9e333333-3333-4333-8333-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.start_call('key-cl-start-x-00000001', %L)$$,
    (SELECT id FROM cl WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_FOUND', 'a stranger cannot ring either of them');
SELECT is((SELECT count(*)::int FROM public.calls), 0, 'and sees no call metadata at all');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Answering.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.answer_call('key-cl-ans-c-00000001', %L)$$,
    (SELECT id FROM cl WHERE name = 'c1')),
  '42501', 'ERR_PERMISSION_DENIED',
  'the caller cannot answer their own ring, which would stop it ever being missed');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "9e222222-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.answer_call('key-cl-ans-p-00000001', (SELECT id FROM cl WHERE name = 'c1')),
  'active'::public.call_status, 'the callee answers');
SELECT throws_ok(
  format($$SELECT public.answer_call('key-cl-ans-p-00000002', %L)$$,
    (SELECT id FROM cl WHERE name = 'c1')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'and cannot answer it twice');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- SH-14: the phone fallback, which has no vendor behind it yet.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.request_pstn_fallback('key-cl-pstn-c-00000001', %L)$$,
    (SELECT id FROM cl WHERE name = 'c1')),
  'P0001', 'ERR_PSTN_UNAVAILABLE',
  'with no telephony provider contracted, the fallback says so plainly');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.outbox WHERE event_type = 'call.pstn_requested'), 1,
  'and the demand is recorded, so it can be measured before anybody buys numbers');

SELECT ok(private.record_masked_number((SELECT id FROM cl WHERE name = 'r'),
            '+2348000099999', 'infobip', 'vendor-ref-1') IS NOT NULL,
  'the telephony worker writes an allocation back through the seam');
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.request_pstn_fallback('key-cl-pstn-c-00000002',
            (SELECT id FROM cl WHERE name = 'c1')), '+2348000099999',
  'and then a participant gets the proxy number');
SELECT is((SELECT count(*)::int FROM public.masked_numbers), 0,
  'but never the row: it names the vendor and the window, which is not theirs to read');
RESET ROLE;
SELECT ok((SELECT pstn_fallback FROM public.calls WHERE id = (SELECT id FROM cl WHERE name = 'c1')),
  'the call records that it fell back');

-- ---------------------------------------------------------------------------
-- Ending, and the three ways a call can end badly.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.end_call('key-cl-end-c1-00000001', (SELECT id FROM cl WHERE name = 'c1'),
            '{"jitter_ms": 12, "loss_pct": 1}'::jsonb),
  'ended'::public.call_status, 'an answered call ends');
RESET ROLE;
SELECT ok((SELECT duration_s IS NOT NULL AND ended_at IS NOT NULL FROM public.calls
           WHERE id = (SELECT id FROM cl WHERE name = 'c1')),
  'with a duration and a time, and nothing else');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb' AND kind = 'call_missed'), 0,
  'a call that was answered is not a missed call');

-- The caller hangs up on a ring: that is a missed call for the other side (SH-15).
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('c2', (SELECT call_id FROM public.start_call(
  'key-cl-start-c2-00000001', (SELECT id FROM cl WHERE name = 'r'))));
SELECT is(public.end_call('key-cl-end-c2-00000001', (SELECT id FROM cl WHERE name = 'c2')),
  'missed'::public.call_status,
  'the outcome is derived from who hung up, not declared by the client');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb' AND kind = 'call_missed'), 1,
  'and the person who missed it is told');
SELECT is((SELECT count(*)::int FROM public.messages WHERE type = 'system'), 1,
  'with a system message in the job chat, so it is there when they open it');

-- The callee hangs up on a ring: that is a decline, and nobody missed anything.
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('c3', (SELECT call_id FROM public.start_call(
  'key-cl-start-c3-00000001', (SELECT id FROM cl WHERE name = 'r'))));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "9e222222-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.end_call('key-cl-end-c3-p-0000001', (SELECT id FROM cl WHERE name = 'c3')),
  'declined'::public.call_status, 'the callee hanging up is a decline');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb' AND kind = 'call_missed'), 1,
  'which is not a missed call: they were there, and said no');

-- A ring nobody answers at all.
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO cl VALUES ('c4', (SELECT call_id FROM public.start_call(
  'key-cl-start-c4-00000001', (SELECT id FROM cl WHERE name = 'r'))));
RESET ROLE;
SELECT is(private.expire_calls(), 0, 'a call that has just started is still ringing');
UPDATE public.calls SET started_at = now() - interval '5 minutes'
WHERE id = (SELECT id FROM cl WHERE name = 'c4');
SELECT is(private.expire_calls(), 1, 'one that rang out is missed');
SELECT is(private.expire_calls(), 0, 'and is missed once, not every minute');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = '9e222222-2222-4222-8222-bbbbbbbbbbbb' AND kind = 'call_missed'), 2,
  'the second missed call is recorded too');

-- ---------------------------------------------------------------------------
-- Who reads the metadata.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "9e222222-2222-4222-8222-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.calls), 4, 'a participant sees their own call history');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "9e444444-4444-4444-8444-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.calls), 4, 'support sees it, for the ticket');
SELECT is((SELECT count(*)::int FROM public.masked_numbers), 0,
  'but support has no business with the proxy numbers');
RESET ROLE;

-- The window closes with the job.
UPDATE public.requests SET status = 'closed' WHERE id = (SELECT id FROM cl WHERE name = 'r');
SELECT set_config('request.jwt.claims',
  '{"sub": "9e111111-1111-4111-8111-bbbbbbbbbbbb", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.start_call('key-cl-start-late-000001', %L)$$,
    (SELECT id FROM cl WHERE name = 'r')),
  'P0001', 'ERR_CALL_WINDOW_CLOSED',
  'once the job is over the line is closed, and so is the phone fallback');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
