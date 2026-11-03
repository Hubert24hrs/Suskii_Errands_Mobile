-- Ask Suskii usage and cost control (feature 3 of the 2026-11-03 brief).
--
-- What existed: per-person rate limits read from remote config (20 a minute, 200 a day, 30 turns a
-- conversation), the `concierge.text` kill switch, and token counts on each recorded reply. What
-- did not: a monthly allowance, any notion of cost, a ceiling on what the platform spends, a way
-- to give one person more or less, and a limit that holds when one person sends several messages
-- at once. The old check counted messages before the model was called and reserved nothing, so
-- ten simultaneous messages all saw the same count and all went through.
--
-- `ai_usage` is the ledger: one row per message that reached the point of calling the model,
-- keyed by the message's idempotency key so a retry is the same row. `concierge_begin_turn`
-- **reserves** that row under a lock on the person's `ai_usage_accounts` row, which serialises one
-- person's turns without touching anybody else's; `concierge_record_turn` settles it with the
-- tokens the provider reported. A message that never reached the model (the switch off, a limit
-- hit, the SOS rule, no route, or the model failing before it answered) is released and costs the
-- person nothing.
--
-- Cost is estimated, in integer micro-dollars, from list prices kept in `ai.pricing`. Those were
-- read from Google's Vertex AI pricing page on 2026-11-03 [V]; they are configuration, and a price
-- change is a config edit, not a migration. The global budget compares settled spend with
-- `ai.budget`; when either ceiling is reached the concierge answers with the form for everybody
-- until the day or month turns, and `admin_set_ai_enabled` switches it off outright.
--
-- Halving the limits for unverified customers (ai-design §6.5) is dropped: customer verification
-- was withdrawn on 2026-10-24, so every customer is unverified and the rule halved everyone.

-- ---------------------------------------------------------------------------
-- Configuration. Server-only; the apps learn their allowance from my_ai_usage().
-- ---------------------------------------------------------------------------
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('ai.quota.tiers', NULL, '{"free": {"daily": 10, "monthly": 150}}', false),
  ('ai.limits.concierge', NULL,
   '{"max_input_tokens_per_call": 4000, "max_input_tokens_per_turn": 12000,
     "max_output_tokens_per_turn": 800, "cooldown_seconds": 3}', false),
  -- Vertex AI list prices per million tokens, prompts up to 200K tokens, read 2026-11-03 from
  -- https://cloud.google.com/vertex-ai/generative-ai/pricing. Reasoning tokens bill as output.
  ('ai.pricing', NULL,
   '{"default_model": "gemini-3.5-flash",
     "models": {"gemini-3.5-flash": {
       "global":   {"input_micros_per_mtok": 1500000, "output_micros_per_mtok": 9000000},
       "regional": {"input_micros_per_mtok": 1650000, "output_micros_per_mtok": 9900000}}},
     "verified_at": "2026-11-03"}', false),
  ('ai.budget', NULL, '{"daily_micros": 2000000, "monthly_micros": 25000000}', false)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE public.ai_usage_accounts (
  user_id                uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  tier                   text NOT NULL DEFAULT 'free' CHECK (tier ~ '^[a-z_]{2,30}$'),
  daily_limit_override   integer CHECK (daily_limit_override IS NULL OR daily_limit_override BETWEEN 0 AND 10000),
  monthly_limit_override integer CHECK (monthly_limit_override IS NULL OR monthly_limit_override BETWEEN 0 AND 100000),
  override_expires_at    timestamptz,
  override_reason        text CHECK (override_reason IS NULL OR length(override_reason) <= 300),
  -- Extra messages beyond the allowance. Spent only once the allowance is used up.
  bonus_credits          integer NOT NULL DEFAULT 0 CHECK (bonus_credits BETWEEN 0 AND 100000),
  suspended_until        timestamptz,
  suspension_reason      text CHECK (suspension_reason IS NULL OR length(suspension_reason) <= 300),
  updated_by             uuid REFERENCES auth.users (id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER ai_usage_accounts_touch BEFORE UPDATE ON public.ai_usage_accounts
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

CREATE TABLE public.ai_usage (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  conversation_id uuid REFERENCES public.ai_conversations (id) ON DELETE SET NULL,
  feature         text NOT NULL DEFAULT 'concierge.text'
                  CHECK (feature IN ('concierge.text', 'concierge.voice')),
  country_code    char(2) REFERENCES public.countries (code),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 16 AND 128),
  -- reserved: counted, model call in flight. completed / failed: the model ran, tokens counted.
  -- released: never reached the model, not counted. abandoned: reserved and never settled (the
  -- function died); counted, cost unknown.
  status          text NOT NULL DEFAULT 'reserved'
                  CHECK (status IN ('reserved', 'completed', 'failed', 'released', 'abandoned')),
  funded_by       text NOT NULL DEFAULT 'allowance' CHECK (funded_by IN ('allowance', 'credit')),
  model_id        text CHECK (model_id IS NULL OR length(model_id) <= 80),
  location        text CHECK (location IS NULL OR location ~ '^[a-z0-9-]{2,40}$'),
  tokens_in       integer NOT NULL DEFAULT 0 CHECK (tokens_in >= 0),
  tokens_out      integer NOT NULL DEFAULT 0 CHECK (tokens_out >= 0),
  tokens_thought  integer NOT NULL DEFAULT 0 CHECK (tokens_thought >= 0),
  -- Estimated cost in millionths of a US dollar: integers, like every amount in public.
  cost_micros     bigint NOT NULL DEFAULT 0 CHECK (cost_micros >= 0),
  created_at      timestamptz NOT NULL DEFAULT now(),
  settled_at      timestamptz,
  UNIQUE (user_id, idempotency_key)
);
CREATE INDEX ai_usage_user_recent ON public.ai_usage (user_id, created_at);
CREATE INDEX ai_usage_created ON public.ai_usage (created_at);
CREATE INDEX ai_usage_reserved ON public.ai_usage (created_at) WHERE status = 'reserved';

ALTER TABLE public.ai_usage_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_usage_accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_usage FORCE ROW LEVEL SECURITY;
-- No client role reads or writes either table. A person sees their allowance through
-- my_ai_usage(), staff through the admin functions below, and neither ever writes a counter.
REVOKE ALL ON public.ai_usage_accounts, public.ai_usage FROM anon, authenticated;
GRANT ALL ON public.ai_usage_accounts, public.ai_usage TO service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.ai_cost_micros(p_model text, p_location text, p_in integer, p_out integer)
RETURNS bigint
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  -- A model with no price of its own is priced as the default one, so an unpriced model can
  -- never make spend look smaller than it is. Rounded up to the next micro-dollar.
  WITH cfg AS (SELECT private.remote_config_json('ai.pricing') AS v),
  m AS (
    SELECT coalesce(cfg.v -> 'models' -> p_model, cfg.v -> 'models' -> (cfg.v ->> 'default_model')) AS prices
    FROM cfg),
  p AS (
    SELECT coalesce(m.prices -> (CASE WHEN p_location = 'global' THEN 'global' ELSE 'regional' END),
                    m.prices -> 'regional') AS rate
    FROM m)
  SELECT CASE WHEN p.rate IS NULL THEN 0::bigint ELSE
    (greatest(coalesce(p_in, 0), 0)::bigint * coalesce((p.rate ->> 'input_micros_per_mtok')::bigint, 0)
     + greatest(coalesce(p_out, 0), 0)::bigint * coalesce((p.rate ->> 'output_micros_per_mtok')::bigint, 0)
     + 999999) / 1000000 END
  FROM p;
$$;

-- A person's allowance and how much of it is used, in their own day and month. Pass p_for_update
-- to take the lock that serialises their turns; reading for display takes none.
CREATE FUNCTION private.ai_quota(p_user uuid, p_for_update boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_acct        public.ai_usage_accounts%ROWTYPE;
  v_tz          text := private.user_timezone(p_user);
  v_local       timestamp := now() AT TIME ZONE v_tz;
  v_day_start   timestamptz := date_trunc('day', v_local) AT TIME ZONE v_tz;
  v_month_start timestamptz := date_trunc('month', v_local) AT TIME ZONE v_tz;
  v_tiers       jsonb := private.remote_config_json('ai.quota.tiers');
  v_daily       integer;
  v_monthly     integer;
  v_used_day    integer;
  v_used_month  integer;
BEGIN
  IF p_for_update THEN
    INSERT INTO public.ai_usage_accounts (user_id) VALUES (p_user) ON CONFLICT DO NOTHING;
    SELECT * INTO v_acct FROM public.ai_usage_accounts a WHERE a.user_id = p_user FOR UPDATE;
  ELSE
    SELECT * INTO v_acct FROM public.ai_usage_accounts a WHERE a.user_id = p_user;
  END IF;

  v_daily := coalesce((v_tiers -> coalesce(v_acct.tier, 'free') ->> 'daily')::integer,
                      (v_tiers -> 'free' ->> 'daily')::integer, 10);
  v_monthly := coalesce((v_tiers -> coalesce(v_acct.tier, 'free') ->> 'monthly')::integer,
                        (v_tiers -> 'free' ->> 'monthly')::integer, 150);
  IF v_acct.override_expires_at IS NULL OR v_acct.override_expires_at > now() THEN
    v_daily := coalesce(v_acct.daily_limit_override, v_daily);
    v_monthly := coalesce(v_acct.monthly_limit_override, v_monthly);
  END IF;

  SELECT count(*) FILTER (WHERE u.created_at >= v_day_start), count(*)
  INTO v_used_day, v_used_month
  FROM public.ai_usage u
  WHERE u.user_id = p_user AND u.created_at >= v_month_start
    AND u.funded_by = 'allowance' AND u.status <> 'released';

  RETURN jsonb_build_object(
    'tier', coalesce(v_acct.tier, 'free'),
    'daily_limit', v_daily,
    'monthly_limit', v_monthly,
    'used_today', v_used_day,
    'used_this_month', v_used_month,
    'remaining_today', greatest(least(v_daily - v_used_day, v_monthly - v_used_month), 0),
    'remaining_this_month', greatest(v_monthly - v_used_month, 0),
    'credits', coalesce(v_acct.bonus_credits, 0),
    'suspended_until', CASE WHEN v_acct.suspended_until > now() THEN v_acct.suspended_until END,
    'day_resets_at', v_day_start + interval '1 day',
    'month_resets_at', v_month_start + interval '1 month');
END $$;

-- Platform-wide spend against the budget, in UTC days and months.
CREATE FUNCTION private.ai_budget_state()
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH b AS (SELECT private.remote_config_json('ai.budget') AS v),
  s AS (
    SELECT coalesce(sum(u.cost_micros) FILTER (
             WHERE u.created_at >= date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'), 0) AS today,
           coalesce(sum(u.cost_micros), 0) AS month
    FROM public.ai_usage u
    WHERE u.created_at >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
  SELECT jsonb_build_object(
    'daily_micros', (b.v ->> 'daily_micros')::bigint,
    'monthly_micros', (b.v ->> 'monthly_micros')::bigint,
    'spent_today_micros', s.today,
    'spent_this_month_micros', s.month,
    'day_exceeded', (b.v ->> 'daily_micros') IS NOT NULL AND s.today >= (b.v ->> 'daily_micros')::bigint,
    'month_exceeded', (b.v ->> 'monthly_micros') IS NOT NULL AND s.month >= (b.v ->> 'monthly_micros')::bigint,
    'day_resets_at', (date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day') AT TIME ZONE 'UTC',
    'month_resets_at', (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC')
  FROM b, s;
$$;

CREATE FUNCTION private.ai_limits()
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'max_input_tokens_per_call', coalesce((c.v ->> 'max_input_tokens_per_call')::integer, 4000),
    'max_input_tokens_per_turn', coalesce((c.v ->> 'max_input_tokens_per_turn')::integer, 12000),
    'max_output_tokens_per_turn', coalesce((c.v ->> 'max_output_tokens_per_turn')::integer, 800),
    'cooldown_seconds', coalesce((c.v ->> 'cooldown_seconds')::integer, 3))
  FROM (SELECT private.remote_config_json('ai.limits.concierge') AS v) c;
$$;

-- Settle one reservation. Tokens and cost add up across attempts, so a retry of a message whose
-- first attempt ran the model never erases what that attempt cost. A message whose attempts never
-- reached the model is released: not counted, and a credit that funded it goes back.
CREATE FUNCTION private.ai_settle(p_user uuid, p_key text, p_model text, p_location text,
                                  p_in integer, p_out integer, p_thought integer, p_failed boolean)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_row    public.ai_usage%ROWTYPE;
  v_ran    boolean := coalesce(p_in, 0) + coalesce(p_out, 0) + coalesce(p_thought, 0) > 0;
  v_status text;
BEGIN
  SELECT * INTO v_row FROM public.ai_usage u
  WHERE u.user_id = p_user AND u.idempotency_key = p_key FOR UPDATE;
  IF NOT FOUND OR v_row.status NOT IN ('reserved', 'abandoned') THEN
    RETURN;
  END IF;
  v_status := CASE
    WHEN v_ran AND NOT p_failed THEN 'completed'
    WHEN v_ran OR v_row.tokens_in + v_row.tokens_out + v_row.tokens_thought > 0 THEN 'failed'
    ELSE 'released' END;
  UPDATE public.ai_usage u
  SET status = v_status,
      model_id = CASE WHEN v_ran THEN left(p_model, 80) ELSE u.model_id END,
      location = CASE WHEN v_ran AND p_location ~ '^[a-z0-9-]{2,40}$' THEN p_location ELSE u.location END,
      tokens_in = u.tokens_in + greatest(coalesce(p_in, 0), 0),
      tokens_out = u.tokens_out + greatest(coalesce(p_out, 0), 0),
      tokens_thought = u.tokens_thought + greatest(coalesce(p_thought, 0), 0),
      cost_micros = u.cost_micros + CASE WHEN v_ran THEN private.ai_cost_micros(
                      p_model, p_location, p_in, coalesce(p_out, 0) + coalesce(p_thought, 0)) ELSE 0 END,
      settled_at = now()
  WHERE u.id = v_row.id;
  IF v_status = 'released' AND v_row.funded_by = 'credit' THEN
    UPDATE public.ai_usage_accounts a SET bonus_credits = a.bonus_credits + 1 WHERE a.user_id = p_user;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- The concierge's verbs, restated from 20261026190000_concierge.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.concierge_begin_turn(uuid, text);
CREATE FUNCTION public.concierge_begin_turn(p_conversation_id uuid, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_conv      public.ai_conversations%ROWTYPE;
  v_profile   public.profiles%ROWTYPE;
  v_replay    jsonb;
  v_enabled   boolean;
  v_quota     jsonb;
  v_budget    jsonb;
  v_limits    jsonb;
  v_existing  public.ai_usage%ROWTYPE;
  v_minute    integer;
  v_last      timestamptz;
  v_per_min   integer;
  v_max_turns integer;
  v_limited   text;
  v_reset_at  timestamptz;
  v_funded    text;
  v_reserved  boolean := false;
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

  v_enabled := private.concierge_enabled(v_uid, v_conv.country_code);
  v_limits := private.ai_limits();

  IF v_replay IS NULL AND v_enabled THEN
    -- The lock that makes the limit hold: everything from here to the reservation runs one turn
    -- at a time per person, so a second message waits for the first and then counts it.
    v_quota := private.ai_quota(v_uid, true);
    v_budget := private.ai_budget_state();

    SELECT * INTO v_existing FROM public.ai_usage u
    WHERE u.user_id = v_uid AND u.idempotency_key = p_idempotency_key;

    v_per_min := coalesce(private.remote_config_int('concierge.messages_per_minute'), 20);
    v_max_turns := coalesce(private.remote_config_int('concierge.turns_per_conversation'), 30);
    SELECT count(*) FILTER (WHERE u.created_at > now() - interval '1 minute'), max(u.created_at)
    INTO v_minute, v_last
    FROM public.ai_usage u
    WHERE u.user_id = v_uid AND u.status <> 'released' AND u.created_at > now() - interval '1 minute'
      AND u.idempotency_key <> p_idempotency_key;

    IF v_existing.id IS NOT NULL AND v_existing.status = 'reserved'
       AND v_existing.created_at > now() - interval '2 minutes' THEN
      -- The same message is already being answered: a double tap, or a retry racing the first.
      v_limited := 'in_progress';
    ELSIF (v_quota ->> 'suspended_until') IS NOT NULL THEN
      v_limited := 'suspended';
      v_reset_at := (v_quota ->> 'suspended_until')::timestamptz;
    ELSIF (v_budget ->> 'month_exceeded')::boolean THEN
      v_limited := 'budget';
      v_reset_at := (v_budget ->> 'month_resets_at')::timestamptz;
    ELSIF (v_budget ->> 'day_exceeded')::boolean THEN
      v_limited := 'budget';
      v_reset_at := (v_budget ->> 'day_resets_at')::timestamptz;
    ELSIF v_conv.turn_count >= v_max_turns THEN
      v_limited := 'turns';
    -- Only when a cooldown is set: a turn that waited on the lock started before the one it waited
    -- for was stamped, so with no cooldown the comparison below would still refuse it.
    ELSIF (v_limits ->> 'cooldown_seconds')::integer > 0 AND v_last IS NOT NULL
          AND v_last > now() - make_interval(secs => (v_limits ->> 'cooldown_seconds')::integer) THEN
      v_limited := 'cooldown';
      v_reset_at := v_last + make_interval(secs => (v_limits ->> 'cooldown_seconds')::integer);
    ELSIF v_minute >= v_per_min THEN
      v_limited := 'minute';
      v_reset_at := now() + interval '1 minute';
    ELSIF v_existing.id IS NOT NULL AND v_existing.status <> 'released' THEN
      -- A retry of a message already counted (it failed, or the function died): same row, same
      -- funding, not counted twice.
      v_funded := v_existing.funded_by;
    ELSIF (v_quota ->> 'remaining_today')::integer > 0 THEN
      v_funded := 'allowance';
    ELSIF (v_quota ->> 'credits')::integer > 0 THEN
      v_funded := 'credit';
    ELSIF (v_quota ->> 'remaining_this_month')::integer <= 0 THEN
      v_limited := 'month';
      v_reset_at := (v_quota ->> 'month_resets_at')::timestamptz;
    ELSE
      v_limited := 'day';
      v_reset_at := (v_quota ->> 'day_resets_at')::timestamptz;
    END IF;

    IF v_limited IS NULL THEN
      IF v_existing.id IS NOT NULL THEN
        UPDATE public.ai_usage u
        SET status = 'reserved', funded_by = v_funded, created_at = now(), settled_at = NULL
        WHERE u.id = v_existing.id;
      ELSE
        INSERT INTO public.ai_usage (user_id, conversation_id, feature, country_code,
                                     idempotency_key, funded_by)
        VALUES (v_uid, v_conv.id, v_conv.feature, v_conv.country_code, p_idempotency_key, v_funded);
      END IF;
      -- A credit is spent when it newly pays for a message, and only then.
      IF v_funded = 'credit' AND (v_existing.id IS NULL OR v_existing.status = 'released') THEN
        UPDATE public.ai_usage_accounts a SET bonus_credits = a.bonus_credits - 1
        WHERE a.user_id = v_uid AND a.bonus_credits > 0;
      END IF;
      v_reserved := true;
      v_quota := private.ai_quota(v_uid, false);
    END IF;
  ELSIF v_replay IS NULL THEN
    v_quota := private.ai_quota(v_uid, false);
  END IF;

  RETURN jsonb_build_object(
    'conversation_id', v_conv.id,
    'enabled', v_enabled,
    'limited', v_limited,
    'reset_at', v_reset_at,
    'reserved', v_reserved,
    'usage', CASE WHEN v_quota IS NULL THEN NULL ELSE v_quota - 'tier' END,
    'limits', v_limits - 'cooldown_seconds',
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

-- Restated with the reservation settled in the same transaction as the reply, and the endpoint
-- that answered (`p_location`) so the estimate uses the right price. Everything else is unchanged.
DROP FUNCTION public.concierge_record_turn(uuid, text, text, text, text, jsonb, jsonb, text, text[],
                                           text, text, integer, integer, integer, integer, jsonb);
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
  p_tool_calls jsonb DEFAULT NULL,
  p_location text DEFAULT NULL)
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

  -- New (20261103120200): the reservation this turn made, settled from what the model reported.
  PERFORM private.ai_settle(v_uid, p_idempotency_key, p_model_id, p_location,
                            p_tokens_in, p_tokens_out, p_tokens_thought, false);

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

-- The function calls this when a turn fails after begin_turn reserved it and before a reply could
-- be recorded. Tokens reported means the model ran and the message counts; none means it did not.
CREATE FUNCTION public.concierge_release_turn(
  p_conversation_id uuid,
  p_idempotency_key text,
  p_model_id text DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_tokens_in integer DEFAULT 0,
  p_tokens_out integer DEFAULT 0,
  p_tokens_thought integer DEFAULT 0)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.ai_conversations c
                 WHERE c.id = p_conversation_id AND c.user_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_CONVERSATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.ai_settle(v_uid, p_idempotency_key, p_model_id, p_location,
                            p_tokens_in, p_tokens_out, p_tokens_thought, true);
END $$;

-- What the concierge screen shows: the allowance, what is left and when it comes back.
CREATE FUNCTION public.my_ai_usage()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_budget  jsonb := private.ai_budget_state();
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  RETURN (private.ai_quota(v_uid, false) - 'tier') || jsonb_build_object(
    -- Off for this person, or the platform's budget is spent: the screen says so plainly.
    'available', v_country IS NOT NULL AND private.concierge_enabled(v_uid, v_country)
                 AND NOT (v_budget ->> 'day_exceeded')::boolean
                 AND NOT (v_budget ->> 'month_exceeded')::boolean);
END $$;

REVOKE ALL ON FUNCTION
  private.ai_cost_micros(text, text, integer, integer), private.ai_quota(uuid, boolean),
  private.ai_budget_state(), private.ai_limits(),
  private.ai_settle(uuid, text, text, text, integer, integer, integer, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.concierge_begin_turn(uuid, text),
  public.concierge_record_turn(uuid, text, text, text, text, jsonb, jsonb, text, text[], text, text,
                               integer, integer, integer, integer, jsonb, text),
  public.concierge_release_turn(uuid, text, text, text, integer, integer, integer),
  public.my_ai_usage()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.concierge_begin_turn(uuid, text),
  public.concierge_record_turn(uuid, text, text, text, text, jsonb, jsonb, text, text[], text, text,
                               integer, integer, integer, integer, jsonb, text),
  public.concierge_release_turn(uuid, text, text, text, integer, integer, integer),
  public.my_ai_usage()
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Staff: what it costs, who uses it, and the controls.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_ai_usage_summary(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_roles constant public.admin_role[] := ARRAY['super_admin', 'finance_officer']::public.admin_role[];
  v_from  timestamptz;
  v_to    timestamptz;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(v_roles) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_from := p_from::timestamp AT TIME ZONE 'UTC';
  v_to := (p_to + 1)::timestamp AT TIME ZONE 'UTC';

  RETURN jsonb_build_object(
    'from', p_from, 'to', p_to,
    'totals', (
      SELECT jsonb_build_object(
        'requests', count(*) FILTER (WHERE u.status <> 'released'),
        'completed', count(*) FILTER (WHERE u.status = 'completed'),
        'failed', count(*) FILTER (WHERE u.status IN ('failed', 'abandoned')),
        'released', count(*) FILTER (WHERE u.status = 'released'),
        'tokens_in', coalesce(sum(u.tokens_in), 0),
        'tokens_out', coalesce(sum(u.tokens_out), 0),
        'tokens_thought', coalesce(sum(u.tokens_thought), 0),
        'cost_micros', coalesce(sum(u.cost_micros), 0),
        'users', count(DISTINCT u.user_id) FILTER (WHERE u.status <> 'released'),
        'avg_cost_per_user_micros', CASE WHEN count(DISTINCT u.user_id) FILTER (WHERE u.status <> 'released') = 0
          THEN 0 ELSE coalesce(sum(u.cost_micros), 0)
                      / count(DISTINCT u.user_id) FILTER (WHERE u.status <> 'released') END)
      FROM public.ai_usage u
      WHERE u.created_at >= v_from AND u.created_at < v_to
        AND private.admin_may_read_country(u.country_code, v_roles)),
    'by_day', coalesce((
      SELECT jsonb_agg(d ORDER BY d ->> 'day') FROM (
        SELECT jsonb_build_object(
          'day', (u.created_at AT TIME ZONE 'UTC')::date,
          'requests', count(*) FILTER (WHERE u.status <> 'released'),
          'failed', count(*) FILTER (WHERE u.status IN ('failed', 'abandoned')),
          'tokens_in', sum(u.tokens_in), 'tokens_out', sum(u.tokens_out) + sum(u.tokens_thought),
          'cost_micros', sum(u.cost_micros), 'users', count(DISTINCT u.user_id)) AS d
        FROM public.ai_usage u
        WHERE u.created_at >= v_from AND u.created_at < v_to
          AND private.admin_may_read_country(u.country_code, v_roles)
        GROUP BY (u.created_at AT TIME ZONE 'UTC')::date) x), '[]'::jsonb),
    'by_model', coalesce((
      SELECT jsonb_agg(m ORDER BY (m ->> 'cost_micros')::bigint DESC) FROM (
        SELECT jsonb_build_object(
          'model_id', u.model_id, 'location', u.location, 'requests', count(*),
          'tokens_in', sum(u.tokens_in), 'tokens_out', sum(u.tokens_out) + sum(u.tokens_thought),
          'cost_micros', sum(u.cost_micros)) AS m
        FROM public.ai_usage u
        WHERE u.created_at >= v_from AND u.created_at < v_to AND u.model_id IS NOT NULL
          AND private.admin_may_read_country(u.country_code, v_roles)
        GROUP BY u.model_id, u.location) y), '[]'::jsonb),
    -- Platform-wide by definition: the budget is one number for everybody.
    'budget', private.ai_budget_state(),
    'enabled', coalesce((SELECT f.enabled FROM public.feature_flags f
                         WHERE f.key = 'concierge.text' AND f.country_code IS NULL), false),
    'tiers', private.remote_config_json('ai.quota.tiers'),
    'limits', private.ai_limits(),
    'pricing_verified_at', private.remote_config_json('ai.pricing') ->> 'verified_at');
END $$;

-- One row per person who used it, most expensive first or closest to a limit first. A person-level
-- read, so it is audited before it returns, like admin_user_search.
CREATE FUNCTION public.admin_ai_users(p_from date, p_to date, p_sort text DEFAULT 'cost',
                                      p_limit integer DEFAULT 50)
RETURNS TABLE (user_id uuid, display_name text, country_code char(2), requests bigint,
               failed bigint, tokens bigint, cost_micros bigint, used_today integer,
               daily_limit integer, used_this_month integer, monthly_limit integer, credits integer,
               suspended_until timestamptz, override_expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_roles constant public.admin_role[] :=
    ARRAY['super_admin', 'finance_officer', 'support_agent']::public.admin_role[];
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(v_roles) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366
     OR coalesce(p_sort, 'cost') NOT IN ('cost', 'near_limit') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  PERFORM private.audit_write('admin.ai_users', 'public.ai_usage', NULL, NULL,
    jsonb_build_object('from', p_from, 'to', p_to, 'sort', coalesce(p_sort, 'cost')), NULL);

  RETURN QUERY
  WITH used AS (
    SELECT u.user_id AS uid,
           count(*) FILTER (WHERE u.status <> 'released') AS requests,
           count(*) FILTER (WHERE u.status IN ('failed', 'abandoned')) AS failed,
           sum(u.tokens_in + u.tokens_out + u.tokens_thought)::bigint AS tokens,
           sum(u.cost_micros)::bigint AS cost
    FROM public.ai_usage u
    WHERE u.created_at >= p_from::timestamp AT TIME ZONE 'UTC'
      AND u.created_at < (p_to + 1)::timestamp AT TIME ZONE 'UTC'
    GROUP BY u.user_id),
  q AS (
    SELECT used.*, private.ai_quota(used.uid, false) AS quota FROM used
    WHERE private.admin_may_read_user(used.uid, v_roles))
  SELECT q.uid, p.display_name, p.country_code, q.requests, q.failed, q.tokens, q.cost,
         (q.quota ->> 'used_today')::integer, (q.quota ->> 'daily_limit')::integer,
         (q.quota ->> 'used_this_month')::integer, (q.quota ->> 'monthly_limit')::integer,
         (q.quota ->> 'credits')::integer, (q.quota ->> 'suspended_until')::timestamptz,
         a.override_expires_at
  FROM q
  JOIN public.profiles p ON p.user_id = q.uid
  LEFT JOIN public.ai_usage_accounts a ON a.user_id = q.uid
  ORDER BY CASE WHEN coalesce(p_sort, 'cost') = 'cost' THEN q.cost::numeric
                ELSE greatest((q.quota ->> 'used_today')::numeric
                                / nullif((q.quota ->> 'daily_limit')::numeric, 0),
                              (q.quota ->> 'used_this_month')::numeric
                                / nullif((q.quota ->> 'monthly_limit')::numeric, 0)) END DESC NULLS LAST,
           q.uid
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE FUNCTION private.ai_require_staff_for(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT private.admin_may_read_user(p_user,
       ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = p_user) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.ai_usage_accounts (user_id) VALUES (p_user) ON CONFLICT DO NOTHING;
END $$;

-- A person's own limits, for a while or until changed. NULLs clear the override.
CREATE FUNCTION public.admin_set_ai_quota(p_user uuid, p_daily integer, p_monthly integer,
                                          p_expires_at timestamptz, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_before public.ai_usage_accounts%ROWTYPE;
BEGIN
  PERFORM private.ai_require_staff_for(p_user);
  IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300
     OR (p_daily IS NOT NULL AND p_daily NOT BETWEEN 0 AND 10000)
     OR (p_monthly IS NOT NULL AND p_monthly NOT BETWEEN 0 AND 100000)
     OR (p_expires_at IS NOT NULL AND p_expires_at <= now()) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_before FROM public.ai_usage_accounts a WHERE a.user_id = p_user FOR UPDATE;
  UPDATE public.ai_usage_accounts a
  SET daily_limit_override = p_daily, monthly_limit_override = p_monthly,
      override_expires_at = CASE WHEN p_daily IS NULL AND p_monthly IS NULL THEN NULL ELSE p_expires_at END,
      override_reason = left(btrim(p_reason), 300), updated_by = v_uid
  WHERE a.user_id = p_user;
  PERFORM private.audit_write('ai.quota_set', 'public.ai_usage_accounts', p_user::text,
    jsonb_build_object('daily', v_before.daily_limit_override, 'monthly', v_before.monthly_limit_override,
                       'expires_at', v_before.override_expires_at),
    jsonb_build_object('daily', p_daily, 'monthly', p_monthly, 'expires_at', p_expires_at),
    left(btrim(p_reason), 300));
  RETURN private.ai_quota(p_user, false) - 'tier';
END $$;

CREATE FUNCTION public.admin_grant_ai_credits(p_idempotency_key text, p_user uuid, p_credits integer,
                                              p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_out   jsonb;
BEGIN
  PERFORM private.ai_require_staff_for(p_user);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'admin_grant_ai_credits',
    jsonb_build_object('user', p_user, 'credits', p_credits));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;
  IF p_credits IS NULL OR p_credits NOT BETWEEN 1 AND 1000
     OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_usage_accounts a
  SET bonus_credits = least(a.bonus_credits + p_credits, 100000), updated_by = v_uid
  WHERE a.user_id = p_user;
  PERFORM private.audit_write('ai.credits_granted', 'public.ai_usage_accounts', p_user::text, NULL,
    jsonb_build_object('credits', p_credits), left(btrim(p_reason), 300));
  v_out := private.ai_quota(p_user, false) - 'tier';
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_out);
  RETURN v_out;
END $$;

-- Stop one person using the assistant until a time, or lift it with NULL. Nothing else about the
-- account changes: the request form works as before.
CREATE FUNCTION public.admin_set_ai_suspension(p_user uuid, p_until timestamptz, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_before timestamptz;
BEGIN
  PERFORM private.ai_require_staff_for(p_user);
  IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300
     OR (p_until IS NOT NULL AND p_until <= now()) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT a.suspended_until INTO v_before FROM public.ai_usage_accounts a WHERE a.user_id = p_user FOR UPDATE;
  UPDATE public.ai_usage_accounts a
  SET suspended_until = p_until,
      suspension_reason = CASE WHEN p_until IS NULL THEN NULL ELSE left(btrim(p_reason), 300) END,
      updated_by = v_uid
  WHERE a.user_id = p_user;
  PERFORM private.audit_write(CASE WHEN p_until IS NULL THEN 'ai.suspension_lifted' ELSE 'ai.suspended' END,
    'public.ai_usage_accounts', p_user::text, jsonb_build_object('suspended_until', v_before),
    jsonb_build_object('suspended_until', p_until), left(btrim(p_reason), 300));
  RETURN private.ai_quota(p_user, false) - 'tier';
END $$;

-- The platform's spend ceilings, in micro-dollars. One super admin with a fresh second factor can
-- change them: the ceiling is a brake, and a brake that needs a second signature to apply is late.
CREATE FUNCTION public.admin_set_ai_budget(p_daily_micros bigint, p_monthly_micros bigint, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_before jsonb := private.remote_config_json('ai.budget');
  v_after  jsonb;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_daily_micros IS NULL OR p_monthly_micros IS NULL
     OR p_daily_micros NOT BETWEEN 0 AND 1000000000 OR p_monthly_micros NOT BETWEEN 0 AND 10000000000
     OR p_daily_micros > p_monthly_micros
     OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_after := jsonb_build_object('daily_micros', p_daily_micros, 'monthly_micros', p_monthly_micros);
  INSERT INTO public.remote_config (key, country_code, value, client_visible)
  VALUES ('ai.budget', NULL, v_after, false)
  ON CONFLICT (key, country_code) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM private.audit_write('ai.budget_set', 'public.remote_config', 'ai.budget', v_before, v_after,
    left(btrim(p_reason), 300));
  RETURN private.ai_budget_state();
END $$;

-- An allowance for a tier: 'free' is everybody without an override.
CREATE FUNCTION public.admin_set_ai_tier(p_tier text, p_daily integer, p_monthly integer, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_before jsonb := coalesce(private.remote_config_json('ai.quota.tiers'), '{}'::jsonb);
  v_after  jsonb;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_tier IS NULL OR p_tier !~ '^[a-z_]{2,30}$'
     OR p_daily IS NULL OR p_daily NOT BETWEEN 0 AND 10000
     OR p_monthly IS NULL OR p_monthly NOT BETWEEN 0 AND 100000 OR p_daily > p_monthly
     OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_after := v_before || jsonb_build_object(p_tier, jsonb_build_object('daily', p_daily, 'monthly', p_monthly));
  INSERT INTO public.remote_config (key, country_code, value, client_visible)
  VALUES ('ai.quota.tiers', NULL, v_after, false)
  ON CONFLICT (key, country_code) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM private.audit_write('ai.tier_set', 'public.remote_config', 'ai.quota.tiers', v_before, v_after,
    left(btrim(p_reason), 300));
  RETURN v_after;
END $$;

-- The emergency switch: Ask Suskii on or off for everybody, in every country, at once.
CREATE FUNCTION public.admin_set_ai_enabled(p_enabled boolean, p_reason text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_before boolean;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT f.enabled INTO v_before FROM public.feature_flags f
  WHERE f.key = 'concierge.text' AND f.country_code IS NULL;
  INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible)
  VALUES ('concierge.text', NULL, p_enabled, 100, true)
  ON CONFLICT (key, country_code) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now();
  -- A country row overrides the global one, so switching off has to reach those too; switching on
  -- leaves them, because a country that was off on purpose stays off.
  IF NOT p_enabled THEN
    UPDATE public.feature_flags f SET enabled = false, updated_at = now()
    WHERE f.key = 'concierge.text' AND f.country_code IS NOT NULL AND f.enabled;
  END IF;
  PERFORM private.audit_write(CASE WHEN p_enabled THEN 'ai.enabled' ELSE 'ai.disabled' END,
    'public.feature_flags', 'concierge.text', jsonb_build_object('enabled', v_before),
    jsonb_build_object('enabled', p_enabled), left(btrim(p_reason), 300));
  RETURN p_enabled;
END $$;

REVOKE ALL ON FUNCTION private.ai_require_staff_for(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.admin_ai_usage_summary(date, date),
  public.admin_ai_users(date, date, text, integer),
  public.admin_set_ai_quota(uuid, integer, integer, timestamptz, text),
  public.admin_grant_ai_credits(text, uuid, integer, text),
  public.admin_set_ai_suspension(uuid, timestamptz, text),
  public.admin_set_ai_budget(bigint, bigint, text),
  public.admin_set_ai_tier(text, integer, integer, text),
  public.admin_set_ai_enabled(boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.admin_ai_usage_summary(date, date),
  public.admin_ai_users(date, date, text, integer),
  public.admin_set_ai_quota(uuid, integer, integer, timestamptz, text),
  public.admin_grant_ai_credits(text, uuid, integer, text),
  public.admin_set_ai_suspension(uuid, timestamptz, text),
  public.admin_set_ai_budget(bigint, bigint, text),
  public.admin_set_ai_tier(text, integer, integer, text),
  public.admin_set_ai_enabled(boolean, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Housekeeping: a reservation nobody settled is abandoned after ten minutes (it still counts, so
-- crashing the function is not a way round the limit), and the ledger is kept 13 months.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.ai_usage_housekeeping()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.ai_usage u SET status = 'abandoned', settled_at = now()
  WHERE u.status = 'reserved' AND u.created_at < now() - interval '10 minutes';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM public.ai_usage u WHERE u.created_at < now() - interval '400 days';
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION private.ai_usage_housekeeping() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('ai-usage-housekeeping', '*/10 * * * *',
      $cron$SELECT private.ai_usage_housekeeping()$cron$);
  END IF;
END $$;
