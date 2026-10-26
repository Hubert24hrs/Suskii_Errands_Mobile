-- Ask Suskii's database half: the kill switch, ownership, limits, replay, what a turn may store.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(24);

INSERT INTO auth.users (id, phone) VALUES
  ('c0c00000-0000-4000-8000-000000000001', '2348000006701'),   -- verified customer
  ('c0c00000-0000-4000-8000-000000000002', '2348000006702'),   -- somebody else
  ('c0c00000-0000-4000-8000-000000000003', '2348000006703');   -- unverified
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified', language = 'pcm'
WHERE user_id = 'c0c00000-0000-4000-8000-000000000001';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('c0c00000-0000-4000-8000-000000000002', 'c0c00000-0000-4000-8000-000000000003');

CREATE TEMP TABLE cv (name text PRIMARY KEY, id uuid);
GRANT ALL ON cv TO authenticated;
CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

-- The kill switch: off, then on.
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible)
VALUES ('concierge.text', NULL, false, 100, true)
ON CONFLICT (key, country_code) DO UPDATE SET enabled = false, rollout_pct = 100;
SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.concierge_start('key-cv-start-00000000001')$$,
  'P0001', 'ERR_FEATURE_UNAVAILABLE', 'with concierge.text off, no conversation opens');
RESET ROLE;
UPDATE public.feature_flags SET enabled = true WHERE key = 'concierge.text' AND country_code IS NULL;

SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO cv SELECT 'c', id FROM public.concierge_start('key-cv-start-00000000002');
SELECT ok((SELECT id FROM cv WHERE name = 'c') IS NOT NULL, 'with it on, one opens');
SELECT is((SELECT id FROM public.concierge_start('key-cv-start-00000000002')),
  (SELECT id FROM cv WHERE name = 'c'), 'and the same key opens the same one again');
SELECT is((SELECT language FROM public.ai_conversations WHERE id = (SELECT id FROM cv WHERE name = 'c')),
  'pcm', 'in the language the person uses');

CREATE TEMP TABLE bt AS SELECT public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'),
  'key-cv-turn-000000000001') AS b;
SELECT is((SELECT b ->> 'enabled' FROM bt), 'true', 'begin_turn reports the switch');
SELECT is((SELECT b -> 'limited' FROM bt), 'null'::jsonb, 'and no limit hit');
SELECT is((SELECT b -> 'currency' ->> 'code' FROM bt), 'NGN', 'with the currency');
SELECT is((SELECT (b -> 'currency' ->> 'exponent')::int FROM bt), 2, 'and its exponent');
SELECT ok((SELECT jsonb_array_length(b -> 'categories') > 0 FROM bt), 'and the categories to choose from');
SELECT is((SELECT b -> 'replay' FROM bt), 'null'::jsonb, 'and nothing to replay yet');

-- A turn: the money and an unknown key are dropped from the state, whatever was sent.
SELECT is((public.concierge_record_turn((SELECT id FROM cv WHERE name = 'c'), 'key-cv-turn-000000000001',
  'Abeg I wan send document go Ikeja, call me <PHONE_1>', 'Wetin be the pickup place?', 'pcm',
  '{"category_key": "document_delivery", "description": "Send a document", "preferred_price_minor": 100,
    "item_float_minor": 5, "secret": "x"}'::jsonb,
  '{"category_key": "document_delivery", "declared_value_minor": 900, "missing_slots": ["pickup_label"]}'::jsonb,
  'none', '{}', 'gemini-3.5-flash', 'concierge/v1', 120, 30, 0, 900, '[]'::jsonb) ->> 'body'),
  'Wetin be the pickup place?', 'a turn is recorded and returns the reply');
RESET ROLE;
SELECT is((SELECT state FROM public.ai_conversations WHERE id = (SELECT id FROM cv WHERE name = 'c')),
  '{"category_key": "document_delivery", "description": "Send a document"}'::jsonb,
  'the stored state keeps the slots and drops money and anything unknown');
SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((SELECT structured_draft FROM public.ai_messages
           WHERE conversation_id = (SELECT id FROM cv WHERE name = 'c') AND role = 'assistant'),
  '{"category_key": "document_delivery", "missing_slots": ["pickup_label"]}'::jsonb,
  'and so does the draft the app reads');
SELECT is((SELECT count(*)::int FROM public.ai_messages WHERE conversation_id = (SELECT id FROM cv WHERE name = 'c')),
  2, 'two messages, the person''s and the reply');
SELECT is((public.concierge_record_turn((SELECT id FROM cv WHERE name = 'c'), 'key-cv-turn-000000000001',
  'Abeg I wan send document go Ikeja, call me <PHONE_1>', 'A different reply', 'pcm',
  '{}'::jsonb, NULL, 'none') ->> 'body'),
  'Wetin be the pickup place?', 'recording the same key again returns the first reply');
SELECT is((SELECT count(*)::int FROM public.ai_messages WHERE conversation_id = (SELECT id FROM cv WHERE name = 'c')),
  2, 'and writes nothing');
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'), 'key-cv-turn-000000000001')
           -> 'replay' ->> 'body'), 'Wetin be the pickup place?',
  'begin_turn with a recorded key hands back the reply instead of a second model call');
SELECT is((SELECT jsonb_array_length(public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'c'),
            'key-cv-turn-000000000002') -> 'history')), 2, 'the history carries the turns so far');
SELECT throws_ok($$SELECT public.concierge_record_turn((SELECT id FROM cv WHERE name = 'c'),
    'key-cv-turn-000000000003', 'hi', 'ok', 'fr', '{}'::jsonb, NULL, 'none')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'a language it does not speak is refused');
SELECT is((SELECT count(*)::int FROM public.ai_messages WHERE body LIKE '%<PHONE_1>%'), 1,
  'the person reads their own history, redacted as stored');
RESET ROLE;

-- Somebody else's conversation does not exist for them.
SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT throws_ok(format($$SELECT public.concierge_begin_turn(%L, 'key-cv-turn-000000000009')$$,
                        (SELECT id FROM cv WHERE name = 'c')),
  'P0001', 'ERR_CONVERSATION_NOT_FOUND', 'another person cannot continue the conversation');
SELECT is((SELECT count(*)::int FROM public.ai_messages), 0, 'or read a line of it');
RESET ROLE;

-- Limits: half for the unverified. Ten user lines a minute is the default 20 halved.
SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
INSERT INTO cv SELECT 'u', id FROM public.concierge_start('key-cv-start-00000000003');
RESET ROLE;
INSERT INTO public.ai_messages (conversation_id, user_id, role, body)
SELECT (SELECT id FROM cv WHERE name = 'u'), 'c0c00000-0000-4000-8000-000000000003', 'user', 'hello'
FROM generate_series(1, 10);
SELECT pg_temp.act('c0c00000-0000-4000-8000-000000000003');
SET LOCAL ROLE authenticated;
SELECT is((public.concierge_begin_turn((SELECT id FROM cv WHERE name = 'u'), 'key-cv-turn-000000000010')
           ->> 'limited'), 'minute', 'an unverified person hits the per-minute limit at ten');
RESET ROLE;

SELECT ok(NOT has_column_privilege('authenticated', 'public.ai_messages', 'tokens_in', 'SELECT'),
  'nobody reads what their turns cost');

SELECT * FROM finish();
ROLLBACK;
