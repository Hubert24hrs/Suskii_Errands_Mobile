-- Restricted items and moderation rules (ai-design §6 and §8; ERD §1 and §8; OD-21).
-- The shape being tested: the deterministic rules decide, `block` refuses a request outright,
-- everything else publishes and goes into a queue, and a reviewer's decision takes content down
-- without touching the account.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(47);

INSERT INTO auth.users (id, phone) VALUES
  ('7c111111-1111-4111-8111-dddddddddddd', '2348000000161'),   -- customer
  ('7c222222-2222-4222-8222-dddddddddddd', '2348000000162'),   -- provider
  ('7c333333-3333-4333-8333-dddddddddddd', '2348000000163'),   -- support agent
  ('7c444444-4444-4444-8444-dddddddddddd', '2348000000164');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = '7c111111-1111-4111-8111-dddddddddddd';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = '7c222222-2222-4222-8222-dddddddddddd';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('7c333333-3333-4333-8333-dddddddddddd',
                  '7c444444-4444-4444-8444-dddddddddddd');
INSERT INTO public.provider_profiles (user_id) VALUES ('7c222222-2222-4222-8222-dddddddddddd');
INSERT INTO public.admin_users (user_id, roles)
VALUES ('7c333333-3333-4333-8333-dddddddddddd',
        ARRAY['support_agent']::public.admin_role[]);

CREATE TEMP TABLE md (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE mdn (name text PRIMARY KEY, id bigint);
GRANT ALL ON md, mdn TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The rules, on their own. Nothing here touches a table a client can reach: this is the
-- decision function, and it is the part that has to be explainable.
-- ---------------------------------------------------------------------------
SELECT is(private.moderate_text('', 'NG') ->> 'action', 'allow',
  'an empty description decides nothing');
SELECT is(private.moderate_text('Please queue at the bank and collect my card', 'NG') ->> 'action',
  'allow', 'an ordinary errand passes');
SELECT is(private.moderate_text('Deliver a rifle to my friend in Ikeja', 'NG') ->> 'action',
  'block', 'a firearm is refused outright');
SELECT is(private.moderate_text('Deliver a rifle to my friend in Ikeja', 'NG')
            -> 'labels' -> 0 ->> 'rule_key', 'firearms_ammunition',
  'and the rule that refused it is named, so a screen can say which');
SELECT is(private.moderate_text('Buy ammonia for cleaning the kitchen', 'NG') ->> 'action',
  'allow', 'the match is on a word boundary: "ammo" does not fire on "ammonia"');
SELECT is(private.moderate_text('My phone was stolen, please report it at the station', 'NG')
            ->> 'action', 'hold',
  '"stolen" is held, not blocked — reporting a theft is an errand we want');
SELECT is(private.moderate_text('I have a pre-registered sim card for sale', 'NG') ->> 'action',
  'block', 'a country rule applies in its own country');
SELECT is(private.moderate_text('I have a pre-registered sim card for sale', 'GH') ->> 'action',
  'allow', 'and only there: Ghana has no such rule, and the baseline does not invent one');
SELECT is(private.moderate_text('Let us cancel the request and pay cash instead', 'NG')
            -> 'labels' -> 0 ->> 'rule_key', 'off_platform_payment',
  'taking the job off the platform is recognised');
SELECT is(private.moderate_text('Call me on 08031234567 when you arrive', 'NG') ->> 'action',
  'hold', 'a phone number in free text is held');
SELECT is(private.moderate_text('Call me on 08031234567 when you arrive', 'NG')
            -> 'labels' -> 0 ->> 'rule_key', 'contact_in_text', 'and labelled for what it is');

-- ---------------------------------------------------------------------------
-- Requests. `block` is the only refusal in the system; everything else publishes (OD-21).
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "7c111111-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO md VALUES ('blocked', public.create_request(
  'key-md-create-blocked-0001', 'personal_assistance', 'Deliver a rifle to my friend in Ikeja',
  'Ikeja City Mall', 'standard', false, NULL, NULL, 6.6018, 3.3515));
SELECT ok((SELECT id FROM md WHERE name = 'blocked') IS NOT NULL,
  'a draft is written without being judged: nobody is refused while they are still typing');
SELECT throws_ok(
  format($$SELECT public.publish_request(%L, 'key-md-publish-blocked-001')$$,
    (SELECT id FROM md WHERE name = 'blocked')),
  'P0001', 'ERR_CONTENT_NOT_ALLOWED', 'publishing it is refused, by a rule and not by a model');

INSERT INTO md VALUES ('held', public.create_request(
  'key-md-create-held-000001', 'personal_assistance',
  'My phone was stolen, please report it at the station', 'Panti Police Station',
  'standard', false, NULL, NULL, 6.5244, 3.3792));
SELECT is(public.publish_request((SELECT id FROM md WHERE name = 'held'),
            'key-md-publish-held-00001'),
  'published'::public.job_status, 'a held request still publishes — fail open, per OD-21');

INSERT INTO md VALUES ('clean', public.create_request(
  'key-md-create-clean-00001', 'personal_assistance', 'Queue at the bank and collect my card',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750, 'Home — Lekki', NULL,
  6.4531, 3.4356));
SELECT is(public.publish_request((SELECT id FROM md WHERE name = 'clean'),
            'key-md-publish-clean-0001'),
  'published'::public.job_status, 'and so does an ordinary one');
RESET ROLE;

SELECT is((SELECT moderation_status FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'held')),
  'pending'::public.moderation_status, 'the held one is waiting on a person');
SELECT ok((SELECT 'stolen_goods' = ANY (moderation_flags) FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'held')),
  'with the rule that flagged it recorded on the row');
SELECT is((SELECT moderation_status FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'clean')),
  'approved'::public.moderation_status,
  'the ordinary one is approved outright, and never reaches a queue');
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 1,
  'so there is exactly one case: a rule that fires on everything is a rule nobody reads');
SELECT is((SELECT count(*)::int FROM private.outbox WHERE event_type = 'moderation.case_opened'),
  1, 'and the case was announced once');

-- ---------------------------------------------------------------------------
-- Who sees what.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "7c111111-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 1,
  'the author sees that their own content was held — being moderated in silence is worse');
SELECT ok((SELECT count(*) FROM public.prohibited_items) >= 20,
  'and can read what the platform will not carry, before they type it');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "7c444444-4444-4444-8444-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_cases), 0,
  'a stranger sees no cases at all');
SELECT throws_ok($$SELECT public.moderation_queue()$$,
  '42501', 'ERR_PERMISSION_DENIED', 'and does not work the queue');
SELECT throws_ok(
  format($$SELECT public.decide_moderation_case('key-md-x-00000000000001', %L, true)$$,
    (SELECT id FROM public.moderation_cases LIMIT 1)),
  '42501', 'ERR_PERMISSION_DENIED', 'nor decide a case by id');
SELECT throws_ok(
  $$INSERT INTO public.prohibited_items (key, match_terms) VALUES ('mine', ARRAY['anything'])$$,
  '42501', NULL, 'and cannot add a rule of their own');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The reviewer. Upholding takes the content down; nothing here touches the account.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "7c333333-3333-4333-8333-dddddddddddd", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.moderation_queue()), 1, 'the reviewer sees the queue');
INSERT INTO md VALUES ('case', (SELECT id FROM public.moderation_queue() LIMIT 1));
SELECT throws_ok(
  $$SELECT public.decide_moderation_case('key-md-dec-missing-0001',
      '00000000-0000-4000-8000-000000000000'::uuid, true)$$,
  'P0001', 'ERR_MODERATION_CASE_NOT_FOUND', 'a case that does not exist is said so plainly');
SELECT is(public.decide_moderation_case('key-md-dec-uphold-0001',
            (SELECT id FROM md WHERE name = 'case'), true),
  'upheld'::public.moderation_case_status, 'the reviewer upholds the hold');
SELECT is(public.decide_moderation_case('key-md-dec-uphold-0001',
            (SELECT id FROM md WHERE name = 'case'), true),
  'upheld'::public.moderation_case_status,
  'and a repeated call with the same key returns the same answer rather than deciding twice');
SELECT throws_ok(
  format($$SELECT public.decide_moderation_case('key-md-dec-again-00001', %L, false)$$,
    (SELECT id FROM md WHERE name = 'case')),
  'P0001', 'ERR_ILLEGAL_TRANSITION',
  'a decided case is not re-decided: that is an appeal, and it has its own record');
SELECT is((SELECT count(*)::int FROM public.moderation_queue()), 0, 'the queue is empty again');
RESET ROLE;

SELECT is((SELECT moderation_status FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'held')),
  'rejected'::public.moderation_status, 'the request is marked rejected');
SELECT is((SELECT status FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'held')),
  'cancelled'::public.job_status,
  'and actually leaves the market: the feed reads status, not a flag');
SELECT is((SELECT cancellation_reason_code FROM public.requests
           WHERE id = (SELECT id FROM md WHERE name = 'held')), 'moderation_upheld',
  'with the reason on the record');
SELECT is((SELECT customer_verification FROM public.profiles
           WHERE user_id = '7c111111-1111-4111-8111-dddddddddddd'),
  'verified'::public.verification_status,
  'and the account is untouched: moderation removes content, it never bans anybody');
SELECT ok((SELECT count(*) FROM public.notifications
           WHERE user_id = '7c111111-1111-4111-8111-dddddddddddd' AND kind = 'system') >= 1,
  'the author is told, which is the difference between a decision and a disappearance');
SELECT is((SELECT count(*)::int FROM audit.log WHERE action = 'moderation.decide'), 1,
  'and the decision is in the hash-chained log');

-- ---------------------------------------------------------------------------
-- Chat. A message always delivers; a reviewer may remove it afterwards (OD-21).
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "7c222222-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO md VALUES ('offer', public.create_offer(
  'key-md-offer-p-0000000001', (SELECT id FROM md WHERE name = 'clean'), 500000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "7c111111-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-md-accept-c-000000001', (SELECT id FROM md WHERE name = 'offer'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM md WHERE name = 'clean')),
  'assigned'::public.job_status, 'the job is assigned, so the chat is open');

SELECT set_config('request.jwt.claims',
  '{"sub": "7c222222-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO mdn VALUES ('msg', public.send_message('key-md-msg-p-00000000001',
  (SELECT id FROM md WHERE name = 'clean'), 'Call me on 08031234567 when you get there'));
SELECT ok((SELECT id FROM mdn WHERE name = 'msg') IS NOT NULL,
  'a flagged message is still delivered: two people mid-job have to keep talking');
RESET ROLE;
SELECT ok((SELECT 'contact_in_text' = ANY (moderation_flags) FROM public.messages
           WHERE id = (SELECT id FROM mdn WHERE name = 'msg')),
  'with the label on it');
SELECT is((SELECT count(*)::int FROM public.moderation_cases WHERE subject_kind = 'message'), 1,
  'and a case for somebody to look at');

SELECT set_config('request.jwt.claims',
  '{"sub": "7c111111-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.messages), 1,
  'the other party reads it in the meantime, because nothing has been decided yet');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "7c333333-3333-4333-8333-dddddddddddd", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.decide_moderation_case('key-md-dec-msg-0000001',
            (SELECT id FROM public.moderation_queue() LIMIT 1), true),
  'upheld'::public.moderation_case_status, 'the reviewer removes it');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "7c111111-1111-4111-8111-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.messages), 0, 'and then it is gone from the thread');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "7c222222-2222-4222-8222-dddddddddddd", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.messages), 1,
  'but the person who wrote it still sees their own words, and that they were removed');
RESET ROLE;

SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM md WHERE name = 'clean')),
  'assigned'::public.job_status,
  'and the job carries on: removing a message is not cancelling the work');

SELECT * FROM finish();
ROLLBACK;
