-- Support tickets, the ticket scope the DPIA relies on, and suspension (ERD §10; RLS matrix §8
-- and §9; spec phase 8). The property this file exists for: a support agent reads a job's
-- conversation because a ticket points at it, not because they are a support agent.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(38);

INSERT INTO auth.users (id, phone) VALUES
  ('b0111111-1111-4111-8111-999999999999', '2348000000201'),   -- customer
  ('b0222222-2222-4222-8222-999999999999', '2348000000202'),   -- provider
  ('b0333333-3333-4333-8333-999999999999', '2348000000203'),   -- support agent
  ('b0444444-4444-4444-8444-999999999999', '2348000000204'),   -- super admin
  ('b0555555-5555-4555-8555-999999999999', '2348000000205');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'b0111111-1111-4111-8111-999999999999';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'b0222222-2222-4222-8222-999999999999';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('b0333333-3333-4333-8333-999999999999',
                  'b0444444-4444-4444-8444-999999999999',
                  'b0555555-5555-4555-8555-999999999999');
INSERT INTO public.provider_profiles (user_id) VALUES ('b0222222-2222-4222-8222-999999999999');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('b0333333-3333-4333-8333-999999999999', ARRAY['support_agent']::public.admin_role[]),
  ('b0444444-4444-4444-8444-999999999999', ARRAY['super_admin']::public.admin_role[]);

CREATE TEMP TABLE sp (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE spn (name text PRIMARY KEY, id bigint);
GRANT ALL ON sp, spn TO authenticated, service_role;

-- A job with a chat on it, which is what the scoping is about.
SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sp VALUES ('r', public.create_request(
  'key-sp-create-req-000000001', 'personal_assistance', 'Take my documents to the ministry',
  'Ministry, Ikoyi', 'standard', false, NULL, NULL, 6.4541, 3.4348));
SELECT public.publish_request((SELECT id FROM sp WHERE name = 'r'), 'key-sp-publish-000000001');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "b0222222-2222-4222-8222-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO sp VALUES ('o', public.create_offer(
  'key-sp-offer-p-0000000001', (SELECT id FROM sp WHERE name = 'r'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-sp-accept-c-000000001', (SELECT id FROM sp WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM sp WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is assigned');
SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.send_message('key-sp-msg-c-00000000001', (SELECT id FROM sp WHERE name = 'r'),
            'I am at the gate') IS NOT NULL, 'and the two of them are talking');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The control: no ticket, no reach.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b0333333-3333-4333-8333-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.conversations), 0,
  'a support agent browsing conversations finds none');
SELECT is((SELECT count(*)::int FROM public.messages), 0,
  'and reads nobody''s messages: being support is not a reason (RLS matrix §8)');
SELECT is((SELECT count(*)::int FROM public.ticket_queue()), 0,
  'the queue is theirs to work, and there is nothing in it yet');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Opening a ticket.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b0555555-5555-4555-8555-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.open_ticket('key-sp-ticket-x-000001', 'job', 'Tell me about this job', %L)$$,
    (SELECT id FROM sp WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_FOUND',
  'a stranger cannot name somebody else''s job: the request id is what widens support''s reach');
SELECT ok(public.open_ticket('key-sp-ticket-x-000002', 'account', 'I cannot sign in') IS NOT NULL,
  'but anyone may open a ticket about themselves');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.open_ticket('key-sp-ticket-c-000000', 'job', '   ')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a ticket with nothing in it is not a ticket');
INSERT INTO sp VALUES ('t', public.open_ticket('key-sp-ticket-c-000001', 'job',
  'The provider took my documents and stopped answering.',
  (SELECT id FROM sp WHERE name = 'r')));
SELECT ok((SELECT id FROM sp WHERE name = 't') IS NOT NULL, 'the customer opens a ticket');
SELECT is((SELECT count(*)::int FROM public.ticket_messages), 1,
  'the first message is the ticket body, so nothing is lost between the two tables');
SELECT is((SELECT count(*)::int FROM public.support_tickets), 1,
  'and they see their own ticket, not the stranger''s');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Now the scope opens — and only for that job.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b0333333-3333-4333-8333-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.conversations), 1,
  'the ticket names a job, so that job''s conversation is readable');
SELECT is((SELECT count(*)::int FROM public.messages), 1, 'and its messages with it');
SELECT is((SELECT count(*)::int FROM public.ticket_queue()), 2,
  'both tickets are in the queue, worst first');
SELECT is((SELECT count(*)::int FROM public.support_tickets), 2, 'support reads every ticket');
INSERT INTO spn VALUES ('note', public.reply_to_ticket('key-sp-reply-s-000001',
  (SELECT id FROM sp WHERE name = 't'), 'Checked the job events; provider went offline.', true));
SELECT ok((SELECT id FROM spn WHERE name = 'note') IS NOT NULL, 'support writes a staff note');
SELECT is((SELECT status FROM public.support_tickets WHERE id = (SELECT id FROM sp WHERE name = 't')),
  'open'::public.support_ticket_status,
  'a note to a colleague is not an answer, so the ticket does not move');
SELECT ok(public.reply_to_ticket('key-sp-reply-s-000002',
            (SELECT id FROM sp WHERE name = 't'), 'We have contacted the provider.') > 0,
  'and then an actual reply');
SELECT is((SELECT status FROM public.support_tickets WHERE id = (SELECT id FROM sp WHERE name = 't')),
  'waiting_on_user'::public.support_ticket_status, 'which moves it to the customer');
RESET ROLE;

-- The customer sees the reply, and never the note.
SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.ticket_messages), 2,
  'the customer reads their own message and the reply');
SELECT is((SELECT count(*)::int FROM public.ticket_messages WHERE internal), 0,
  'and never the staff note, which is the only reason it can be written down at all');
SELECT is((SELECT count(*)::int FROM public.notifications WHERE kind = 'system'), 1,
  'they were told there was a reply');
SELECT throws_ok(
  $$SELECT public.reply_to_ticket('key-sp-reply-c-000001',
      (SELECT id FROM public.support_tickets LIMIT 1), 'Internal, honestly', true)$$,
  '42501', 'ERR_PERMISSION_DENIED',
  'a user cannot mark their own message internal, which would hide it from the only people who can help');
SELECT ok(public.reply_to_ticket('key-sp-reply-c-000002',
            (SELECT id FROM sp WHERE name = 't'), 'Still nothing from them.') > 0,
  'the customer replies');
RESET ROLE;
SELECT is((SELECT status FROM public.support_tickets WHERE id = (SELECT id FROM sp WHERE name = 't')),
  'waiting_on_support'::public.support_ticket_status, 'and it comes back to support');

SELECT set_config('request.jwt.claims',
  '{"sub": "b0555555-5555-4555-8555-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reply_to_ticket('key-sp-reply-x-000001', %L, 'Let me in')$$,
    (SELECT id FROM sp WHERE name = 't')),
  'P0001', 'ERR_TICKET_NOT_FOUND',
  'somebody else''s ticket is not admitted to exist, let alone replied to');
SELECT throws_ok($$SELECT public.ticket_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and the queue is not theirs');
RESET ROLE;

-- Closing it ends the thread.
SELECT set_config('request.jwt.claims',
  '{"sub": "b0333333-3333-4333-8333-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.update_ticket('key-sp-update-s-00001', (SELECT id FROM sp WHERE name = 't'),
            'closed', 'b0333333-3333-4333-8333-999999999999', 1::smallint),
  'closed'::public.support_ticket_status, 'support closes it, assigned and prioritised');
SELECT throws_ok(
  format($$SELECT public.update_ticket('key-sp-update-s-00002', %L, 'open',
      'b0555555-5555-4555-8555-999999999999')$$,
    (SELECT id FROM sp WHERE name = 't')),
  '22023', 'ERR_INVALID_ARGUMENT',
  'a ticket cannot be assigned to somebody who cannot work the queue: it would vanish');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "b0111111-1111-4111-8111-999999999999", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.reply_to_ticket('key-sp-reply-c-000003', %L, 'One more thing')$$,
    (SELECT id FROM sp WHERE name = 't')),
  'P0001', 'ERR_TICKET_CLOSED', 'and a closed ticket takes no more replies');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Suspension: the explicit decision the risk engine refuses to make (OD-25).
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "b0333333-3333-4333-8333-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.suspend_provider('key-sp-susp-s-000001',
      'b0222222-2222-4222-8222-999999999999', 'fraud_confirmed', now() + interval '30 days')$$,
  '42501', 'ERR_PERMISSION_DENIED',
  'a support agent cannot suspend anybody: this is not a support decision');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "b0444444-4444-4444-8444-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.suspend_provider('key-sp-susp-a-000001',
      'b0222222-2222-4222-8222-999999999999', 'fraud_confirmed', NULL)$$,
  '22023', 'ERR_INVALID_ARGUMENT',
  'and nobody is suspended forever by one function call: an end date is required');
SELECT ok(public.suspend_provider('key-sp-susp-a-000002',
            'b0222222-2222-4222-8222-999999999999', 'fraud_confirmed',
            now() + interval '30 days') IS NOT NULL,
  'a super admin suspends them, with a reason key and a date');
RESET ROLE;
SELECT ok(NOT (SELECT private.is_active_provider('b0222222-2222-4222-8222-999999999999')),
  'so offers and dispatch refuse them');
SELECT is((SELECT count(*)::int FROM public.notifications
           WHERE user_id = 'b0222222-2222-4222-8222-999999999999' AND kind = 'system'), 1,
  'and they are told, with the reason and the date');
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'admin.suspend_provider'), 1,
  'the decision is in the hash-chained log, with a name on it');

SELECT set_config('request.jwt.claims',
  '{"sub": "b0444444-4444-4444-8444-999999999999", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(public.reinstate_provider('key-sp-rein-a-000001',
            'b0222222-2222-4222-8222-999999999999', 'appeal_upheld'),
  'and it can be undone, which is what makes it safe to do at all');
RESET ROLE;
SELECT ok((SELECT private.is_active_provider('b0222222-2222-4222-8222-999999999999')),
  'the provider works again');

SELECT * FROM finish();
ROLLBACK;
