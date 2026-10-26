-- Ask Suskii: the text concierge's database half (go-live item 5; ai-design §§2–6; ADR-0024).
--
-- The concierge is an Edge Function (`concierge`) that talks to Vertex AI and to this database
-- **as the user**, with the user's own JWT (ADR-0012): a hijacked conversation can do only what
-- the person could already do by hand. What it may call is `services/ai/tools/allowlist.json`.
--
-- Three verbs, and nothing here moves money, publishes or decides anything:
--   concierge_start        opens a conversation; refuses when `concierge.text` is off for the
--                          user's country (the kill switch, enforced here because no app reads
--                          flags yet: HANDOFF part 19, X.1)
--   concierge_begin_turn   what the function needs before calling the model: the slots so far,
--                          the last four turns, the categories, the currency, and whether this
--                          person has hit a limit. A replay of a recorded turn returns it.
--   concierge_record_turn  writes the redacted user line and the reply, once per idempotency key
--
-- Only the redacted text is stored (ai-design §6.1, data-flow rule 4): a phone number someone typed
-- is `<PHONE_1>` here and in the history they see. Messages are kept 90 days, conversations a year.

CREATE TABLE public.ai_conversations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  feature      text NOT NULL DEFAULT 'concierge.text'
               CHECK (feature IN ('concierge.text', 'concierge.voice')),
  country_code char(2) NOT NULL REFERENCES public.countries (code),
  language     text CHECK (language IS NULL OR language IN ('en', 'pcm')),
  -- The slots filled so far. Never money: preferred price, float and declared value come from the
  -- form's own controls, so a model cannot put a number on anything (ai-design §5.3).
  state        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(state) = 'object'),
  turn_count   integer NOT NULL DEFAULT 0 CHECK (turn_count >= 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_turn_at timestamptz
);
CREATE INDEX ai_conversations_user ON public.ai_conversations (user_id, created_at DESC);
CREATE INDEX ai_conversations_created ON public.ai_conversations (created_at);

CREATE TABLE public.ai_messages (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id  uuid NOT NULL REFERENCES public.ai_conversations (id) ON DELETE CASCADE,
  -- Denormalised so the read policy and the rate limits need no join.
  user_id          uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role             text NOT NULL CHECK (role IN ('user', 'assistant')),
  body             text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  structured_draft jsonb CHECK (structured_draft IS NULL OR jsonb_typeof(structured_draft) = 'object'),
  proposed_action  text NOT NULL DEFAULT 'none'
                   CHECK (proposed_action IN ('none', 'show_publish_card', 'show_offer_comparison',
                                              'show_sos_card', 'handoff_to_form')),
  safety_flags     text[] NOT NULL DEFAULT '{}',
  language         text CHECK (language IS NULL OR language IN ('en', 'pcm')),
  model_id         text CHECK (model_id IS NULL OR length(model_id) <= 80),
  prompt_version   text CHECK (prompt_version IS NULL OR length(prompt_version) <= 40),
  tokens_in        integer CHECK (tokens_in IS NULL OR tokens_in >= 0),
  tokens_out       integer CHECK (tokens_out IS NULL OR tokens_out >= 0),
  tokens_thought   integer CHECK (tokens_thought IS NULL OR tokens_thought >= 0),
  latency_ms       integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
  tool_calls       jsonb CHECK (tool_calls IS NULL OR jsonb_typeof(tool_calls) = 'array'),
  idempotency_key  text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ai_messages_conversation ON public.ai_messages (conversation_id, id);
CREATE INDEX ai_messages_user_recent ON public.ai_messages (user_id, created_at) WHERE role = 'user';
CREATE INDEX ai_messages_created ON public.ai_messages (created_at);
CREATE UNIQUE INDEX ai_messages_reply_key ON public.ai_messages (user_id, idempotency_key)
  WHERE role = 'assistant' AND idempotency_key IS NOT NULL;

ALTER TABLE public.ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_conversations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_messages FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ai_conversations, public.ai_messages FROM anon, authenticated;
GRANT ALL ON public.ai_conversations, public.ai_messages TO service_role;
-- A person reads their own conversations and nothing about what they cost.
GRANT SELECT (id, created_at, language, last_turn_at) ON public.ai_conversations TO authenticated;
GRANT SELECT (id, conversation_id, role, body, structured_draft, proposed_action, created_at)
  ON public.ai_messages TO authenticated;
CREATE POLICY ai_conversations_read_own ON public.ai_conversations FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));
CREATE POLICY ai_messages_read_own ON public.ai_messages FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- The route the concierge calls, in order (ADR-0006, RB-11). Verified 2026-10-26 against Vertex in
-- suskii-staging: gemini-3.5-flash answers in europe-west2, next to the database (ADR-0008), and
-- on the global endpoint; thinking off, because a turn is a short structured answer and thinking
-- tokens cost and add latency without changing it.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('ai.routes.concierge.text', NULL,
   '[{"model": "gemini-3.5-flash", "location": "europe-west2", "thinking_budget": 0},
     {"model": "gemini-3.5-flash", "location": "global", "thinking_budget": 0}]', false)
ON CONFLICT DO NOTHING;

-- `concierge.text` for this person in this country: the country row over the global one, the
-- rollout bucketed the way get_bootstrap buckets it, and **off when there is no row at all**.
CREATE FUNCTION private.concierge_enabled(p_user uuid, p_country char(2))
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce((
    SELECT f.enabled AND private.flag_on_for(f.key, f.rollout_pct, p_user)
    FROM public.feature_flags f
    WHERE f.key = 'concierge.text' AND (f.country_code IS NULL OR f.country_code = p_country)
    ORDER BY f.country_code NULLS LAST
    LIMIT 1), false);
$$;

CREATE FUNCTION public.concierge_start(p_idempotency_key text)
RETURNS TABLE (id uuid, created_at timestamptz, language text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_country char(2);
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'concierge_start', '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN QUERY SELECT c.id, c.created_at, c.language FROM public.ai_conversations c
      WHERE c.id = (v_claim ->> 'conversation_id')::uuid AND c.user_id = v_uid;
    RETURN;
  END IF;

  v_country := private.require_profile_country(v_uid);
  IF NOT private.concierge_enabled(v_uid, v_country) THEN
    RAISE EXCEPTION 'ERR_FEATURE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.ai_conversations (user_id, country_code, language)
  VALUES (v_uid, v_country,
          (SELECT CASE WHEN p.language IN ('en', 'pcm') THEN p.language END
           FROM public.profiles p WHERE p.user_id = v_uid))
  RETURNING ai_conversations.id INTO v_id;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('conversation_id', v_id));
  RETURN QUERY SELECT c.id, c.created_at, c.language FROM public.ai_conversations c WHERE c.id = v_id;
END $$;

CREATE FUNCTION public.concierge_begin_turn(p_conversation_id uuid, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_conv      public.ai_conversations%ROWTYPE;
  v_profile   public.profiles%ROWTYPE;
  v_replay    jsonb;
  v_minute    integer;
  v_day       integer;
  v_per_min   integer;
  v_per_day   integer;
  v_max_turns integer;
  v_limited   text;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 16 AND 128 THEN
    RAISE EXCEPTION 'ERR_IDEMPOTENCY_KEY_INVALID' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_conv FROM public.ai_conversations c
  WHERE c.id = p_conversation_id AND c.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CONVERSATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_profile FROM public.profiles p WHERE p.user_id = v_uid;

  SELECT jsonb_build_object('body', m.body, 'structured_draft', m.structured_draft,
                            'proposed_action', m.proposed_action, 'language', m.language,
                            'created_at', m.created_at, 'id', m.id::text)
  INTO v_replay
  FROM public.ai_messages m
  WHERE m.user_id = v_uid AND m.role = 'assistant' AND m.idempotency_key = p_idempotency_key;

  -- ai-design §6.5: 20 a minute, 200 a day, 30 turns a conversation; half for the unverified,
  -- who may use the concierge (the spec says so) but whose throwaway accounts are the abuse case.
  v_per_min := coalesce(private.remote_config_int('concierge.messages_per_minute'), 20);
  v_per_day := coalesce(private.remote_config_int('concierge.messages_per_day'), 200);
  v_max_turns := coalesce(private.remote_config_int('concierge.turns_per_conversation'), 30);
  IF v_profile.customer_verification IS DISTINCT FROM 'verified' THEN
    v_per_min := greatest(v_per_min / 2, 1);
    v_per_day := greatest(v_per_day / 2, 1);
  END IF;
  SELECT count(*) FILTER (WHERE m.created_at > now() - interval '1 minute'), count(*)
  INTO v_minute, v_day
  FROM public.ai_messages m
  WHERE m.user_id = v_uid AND m.role = 'user' AND m.created_at > now() - interval '1 day';
  v_limited := CASE
    WHEN v_conv.turn_count >= v_max_turns THEN 'turns'
    WHEN v_day >= v_per_day THEN 'day'
    WHEN v_minute >= v_per_min THEN 'minute' END;

  RETURN jsonb_build_object(
    'conversation_id', v_conv.id,
    'enabled', private.concierge_enabled(v_uid, v_conv.country_code),
    'limited', v_limited,
    'replay', v_replay,
    'country_code', v_conv.country_code,
    'language', coalesce(v_conv.language,
                         CASE WHEN v_profile.language IN ('en', 'pcm') THEN v_profile.language END, 'en'),
    'currency', (SELECT jsonb_build_object('code', cu.code, 'exponent', cu.exponent)
                 FROM public.countries co JOIN public.currencies cu ON cu.code = co.currency_code
                 WHERE co.code = v_conv.country_code),
    'state', v_conv.state,
    'turn_count', v_conv.turn_count,
    -- ADR-0006: model ids are configuration. No row, no model: the function hands off to the form.
    'routes', coalesce(private.remote_config_json('ai.routes.concierge.text', v_conv.country_code),
                       '[]'::jsonb),
    'history', coalesce((
      SELECT jsonb_agg(jsonb_build_object('role', h.role, 'body', h.body) ORDER BY h.id)
      FROM (SELECT m.id, m.role, m.body FROM public.ai_messages m
            WHERE m.conversation_id = v_conv.id ORDER BY m.id DESC LIMIT 8) h), '[]'::jsonb),
    'categories', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'key', sc.key,
                                          'allows_custom', sc.allows_custom) ORDER BY sc.sort_order, sc.key)
      FROM public.service_categories sc WHERE sc.active), '[]'::jsonb));
END $$;

CREATE FUNCTION public.concierge_record_turn(
  p_conversation_id uuid,
  p_idempotency_key text,
  p_user_body text,
  p_reply text,
  p_language text,
  p_state jsonb,
  p_draft jsonb,
  p_proposed_action text,
  p_safety_flags text[] DEFAULT '{}',
  p_model_id text DEFAULT NULL,
  p_prompt_version text DEFAULT NULL,
  p_tokens_in integer DEFAULT NULL,
  p_tokens_out integer DEFAULT NULL,
  p_tokens_thought integer DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL,
  p_tool_calls jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_conv  public.ai_conversations%ROWTYPE;
  -- What a slot may be. Anything else in the state or the draft is dropped, money above all:
  -- the validator in the function refuses it too, and this is the half nothing can route around.
  v_slots constant text[] := ARRAY['category_key', 'category_id', 'is_custom_category',
    'custom_category_label', 'description', 'pickup_label', 'pickup_landmark_note',
    'destination_label', 'destination_landmark_note', 'urgency', 'scheduled_at', 'missing_slots'];
  v_state jsonb;
  v_draft jsonb;
  v_reply public.ai_messages%ROWTYPE;
  v_out   jsonb;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'concierge_record_turn',
    jsonb_build_object('conversation_id', p_conversation_id, 'user_body', p_user_body));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_conv FROM public.ai_conversations c
  WHERE c.id = p_conversation_id AND c.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CONVERSATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF p_user_body IS NULL OR length(p_user_body) NOT BETWEEN 1 AND 2000
     OR p_reply IS NULL OR length(p_reply) NOT BETWEEN 1 AND 2000
     OR (p_language IS NOT NULL AND p_language NOT IN ('en', 'pcm'))
     OR p_proposed_action IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) INTO v_state
  FROM jsonb_each(CASE WHEN jsonb_typeof(p_state) = 'object' THEN p_state ELSE '{}'::jsonb END) e
  WHERE e.key = ANY (v_slots);
  IF jsonb_typeof(p_draft) = 'object' THEN
    SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) INTO v_draft
    FROM jsonb_each(p_draft) e WHERE e.key = ANY (v_slots);
  END IF;

  INSERT INTO public.ai_messages (conversation_id, user_id, role, body, language)
  VALUES (v_conv.id, v_uid, 'user', p_user_body, p_language);
  INSERT INTO public.ai_messages (conversation_id, user_id, role, body, structured_draft,
                                  proposed_action, safety_flags, language, model_id, prompt_version,
                                  tokens_in, tokens_out, tokens_thought, latency_ms, tool_calls,
                                  idempotency_key)
  VALUES (v_conv.id, v_uid, 'assistant', p_reply, v_draft, p_proposed_action,
          coalesce(p_safety_flags, '{}'), p_language, p_model_id, p_prompt_version,
          p_tokens_in, p_tokens_out, p_tokens_thought, p_latency_ms, p_tool_calls, p_idempotency_key)
  RETURNING * INTO v_reply;

  UPDATE public.ai_conversations c
  SET state = v_state, turn_count = c.turn_count + 1, last_turn_at = now(),
      language = coalesce(p_language, c.language)
  WHERE c.id = v_conv.id;

  v_out := jsonb_build_object('id', v_reply.id::text, 'conversation_id', v_reply.conversation_id,
    'body', v_reply.body, 'structured_draft', v_reply.structured_draft,
    'proposed_action', v_reply.proposed_action, 'language', v_reply.language,
    'created_at', v_reply.created_at);
  -- "Look again" for the app's message stream; the payload names nothing a stranger could use.
  PERFORM private.broadcast('user:' || v_uid::text, 'concierge.turn',
    jsonb_build_object('conversation_id', v_conv.id));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_out);
  RETURN v_out;
END $$;

REVOKE ALL ON FUNCTION private.concierge_enabled(uuid, char) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.concierge_start(text),
  public.concierge_begin_turn(uuid, text),
  public.concierge_record_turn(uuid, text, text, text, text, jsonb, jsonb, text, text[], text, text,
                               integer, integer, integer, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.concierge_start(text),
  public.concierge_begin_turn(uuid, text),
  public.concierge_record_turn(uuid, text, text, text, text, jsonb, jsonb, text, text[], text, text,
                               integer, integer, integer, integer, jsonb)
  TO authenticated;

-- Retention (ai-design §10): turns 90 days, conversations a year.
CREATE FUNCTION private.expire_concierge_history()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  DELETE FROM public.ai_messages m WHERE m.created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM public.ai_conversations c WHERE c.created_at < now() - interval '365 days';
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION private.expire_concierge_history() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('concierge-retention', '23 4 * * *',
      $cron$SELECT private.expire_concierge_history()$cron$);
  END IF;
END $$;

-- Erasing an account (RB-07, the deletion grace period) removes the concierge history too. The
-- function is restated whole; the one new line is marked.
CREATE OR REPLACE FUNCTION private.erase_account(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = '', avatar_path = NULL, timezone = NULL
  WHERE user_id = p_user;

  DELETE FROM public.trusted_contacts WHERE user_id = p_user;
  DELETE FROM public.saved_places WHERE user_id = p_user;
  -- Concierge history goes with the account; its turns were redacted, and nothing needs them.
  DELETE FROM public.ai_conversations WHERE user_id = p_user;
  -- Meet-ups the person hosted are their words and their chosen place; attendance is who they
  -- met. Both go, and anybody still going to an upcoming one is told it is off.
  PERFORM private.notify(a.user_id, 'system', 'notification.meetup.cancelled.title',
    'notification.meetup.cancelled.body', jsonb_build_object('meetup_id', m.id))
  FROM public.meetups m JOIN public.meetup_attendees a ON a.meetup_id = m.id
  WHERE m.host_id = p_user AND m.status = 'published' AND m.ends_at > now();
  DELETE FROM public.meetups WHERE host_id = p_user;
  DELETE FROM public.meetup_attendees WHERE user_id = p_user;
  DELETE FROM private.request_access_notes n
  USING public.requests r
  WHERE r.id = n.request_id AND r.customer_id = p_user;
  DELETE FROM public.favorites WHERE customer_id = p_user OR provider_id = p_user;
  -- Device rows are referenced by consents, which are the record of what was agreed; the
  -- addresses a push could still reach are what identify the handset, so those go.
  UPDATE public.user_devices SET push_token = NULL, voip_token = NULL WHERE user_id = p_user;
  UPDATE public.provider_profiles SET online = false WHERE user_id = p_user;

  DELETE FROM auth.sessions WHERE user_id = p_user;
  DELETE FROM auth.identities WHERE user_id = p_user;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user;
  UPDATE auth.users
  SET phone = NULL, email = NULL, encrypted_password = NULL,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = 'infinity', deleted_at = now()
  WHERE id = p_user;

  -- The user's folder in `avatars` (one folder per user, named by id).
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'avatars', 'prefix', p_user::text || '/'));

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;
