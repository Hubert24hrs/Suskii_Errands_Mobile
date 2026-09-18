-- Marketplace, part 7: job-scoped chat, and the private realtime channels (ERD §8; RLS matrix §8
-- and "Realtime channel authorisation"; job lifecycle transition 11, which opens chat).
--
-- Chat is scoped to a job and to a window: it opens when a provider is assigned and closes a day
-- after the work is confirmed. Two people who have never been matched cannot message each other
-- at all, which is the point — an open messaging system inside a marketplace is a fraud channel
-- ("pay me directly and cancel the job") and a harassment one.
--
-- **Moderation.** There is no moderation service yet, so messages are delivered and marked
-- `pending`. That is OD-21's stated default — fail open, queue for review — rather than silently
-- doing nothing: `moderation_status` and `moderation_flags` are the columns the reviewer writes,
-- and `rejected` is what hides a message.
--
-- **Realtime authorisation is [A], not [V].** S-13 covered table RLS but explicitly not Realtime;
-- that needs S-02 against a real project. The policies below are written to the documented shape
-- and guarded so that a stack without `realtime.messages` still migrates. Nothing depends on them
-- for correctness: every channel carries data the tables already protect.

CREATE TABLE public.conversations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE REFERENCES public.requests (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.conversations FROM anon, authenticated;
GRANT SELECT ON public.conversations TO authenticated;
GRANT ALL ON public.conversations TO service_role;
CREATE POLICY conversations_read_participant ON public.conversations FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(conversations.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

CREATE TABLE public.messages (
  id                bigint GENERATED ALWAYS AS IDENTITY,
  conversation_id   uuid NOT NULL REFERENCES public.conversations (id) ON DELETE CASCADE,
  sender_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  type              public.chat_message_type NOT NULL DEFAULT 'text',
  body              text CHECK (body IS NULL OR length(body) BETWEEN 1 AND 4000),
  media_path        text CHECK (media_path IS NULL OR length(media_path) <= 512),
  offer_id          uuid REFERENCES public.offers (id),
  location          extensions.geography(Point, 4326),
  moderation_status public.moderation_status NOT NULL DEFAULT 'pending',
  moderation_flags  text[] NOT NULL DEFAULT '{}'::text[],
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE INDEX messages_conversation ON public.messages (conversation_id, id DESC);

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.messages FROM anon, authenticated;
GRANT SELECT ON public.messages TO authenticated;
GRANT ALL ON public.messages TO service_role;
-- Your own message is always yours to see, including one a moderator later rejects — being told
-- nothing about your own words is worse than being told they were removed.
CREATE POLICY messages_read_participant ON public.messages FOR SELECT TO authenticated
  USING ((sender_id = (SELECT auth.uid())
          OR (moderation_status <> 'rejected'
              AND EXISTS (SELECT 1 FROM public.conversations c
                          WHERE c.id = messages.conversation_id
                            AND (SELECT private.is_job_participant(c.request_id)))))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

SELECT private.ensure_monthly_partitions('public.messages'::regclass, 3);

CREATE TABLE public.message_reads (
  conversation_id      uuid NOT NULL REFERENCES public.conversations (id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  last_read_message_id bigint NOT NULL DEFAULT 0,
  read_at              timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

ALTER TABLE public.message_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reads FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_reads FROM anon, authenticated;
GRANT SELECT ON public.message_reads TO authenticated;
GRANT ALL ON public.message_reads TO service_role;
CREATE POLICY message_reads_read_own ON public.message_reads FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- The chat window. Transition 11 opens it; it closes a day after confirmation so a customer can
-- still ask a question about work that has just finished, and not a month later.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.chat_is_open(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.requests r
    LEFT JOIN public.jobs j ON j.request_id = r.id
    WHERE r.id = p_request_id
      AND r.status IN ('assigned', 'en_route', 'arrived', 'in_progress',
                       'completed_by_provider', 'confirmed', 'settlement_pending', 'settled',
                       'disputed')
      AND (j.confirmed_at IS NULL
           OR j.confirmed_at > now() - make_interval(
                hours => coalesce(private.remote_config_int('chat_window_hours_after_confirm'), 24))
           OR r.status = 'disputed'));
$$;

-- ---------------------------------------------------------------------------
-- send_message — the only way a message is written, so moderation has somewhere to stand even
-- before there is a moderator (RLS matrix §8: "moderation first, then insert").
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.send_message(
  p_idempotency_key text,
  p_request_id uuid,
  p_body text DEFAULT NULL,
  p_type public.chat_message_type DEFAULT 'text',
  p_media_path text DEFAULT NULL,
  p_offer_id uuid DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_conv   uuid;
  v_id     bigint;
  v_body   text := nullif(btrim(coalesce(p_body, '')), '');
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'send_message',
    jsonb_build_object('request_id', p_request_id, 'type', p_type, 'body', p_body,
                       'media_path', p_media_path));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'message_id')::bigint;
  END IF;

  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.chat_is_open(p_request_id) THEN
    RAISE EXCEPTION 'ERR_CHAT_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  -- Every kind of message has to carry the thing that makes it that kind.
  IF (p_type = 'text' AND v_body IS NULL)
     OR (p_type IN ('image', 'voice_note') AND p_media_path IS NULL)
     OR (p_type = 'location' AND (p_lat IS NULL OR p_lng IS NULL))
     OR (p_type = 'offer_card' AND p_offer_id IS NULL)
     OR (p_type = 'system') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  -- The conversation appears with the first message rather than at assignment: one row, written
  -- when there is something to put in it.
  SELECT c.id INTO v_conv FROM public.conversations c WHERE c.request_id = p_request_id;
  IF NOT FOUND THEN
    INSERT INTO public.conversations (request_id) VALUES (p_request_id)
    ON CONFLICT (request_id) DO UPDATE SET request_id = excluded.request_id
    RETURNING id INTO v_conv;
  END IF;

  INSERT INTO public.messages (conversation_id, sender_id, type, body, media_path, offer_id,
                               location)
  VALUES (v_conv, v_uid, p_type, v_body, p_media_path, p_offer_id,
          CASE WHEN p_lat IS NULL OR p_lng IS NULL THEN NULL
               ELSE extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography END)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('request', p_request_id::text, 'chat.message',
    jsonb_build_object('message_id', v_id, 'conversation_id', v_conv, 'sender_id', v_uid,
                       'type', p_type));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('message_id', v_id, 'conversation_id', v_conv));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- mark_read — a function rather than the column grant the matrix sketches, because the row has
-- to exist before a column can be updated and no client may insert one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.mark_read(p_request_id uuid, p_last_message_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_conv uuid;
  v_last bigint;
BEGIN
  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_conv FROM public.conversations c WHERE c.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.message_reads (conversation_id, user_id, last_read_message_id, read_at)
  VALUES (v_conv, v_uid, coalesce(p_last_message_id, 0), now())
  ON CONFLICT (conversation_id, user_id) DO UPDATE
  -- Never move the marker backwards: two devices reading the same conversation would otherwise
  -- fight, and the unread badge would flicker.
  SET last_read_message_id = greatest(public.message_reads.last_read_message_id,
                                      excluded.last_read_message_id),
      read_at = now()
  RETURNING last_read_message_id INTO v_last;
  RETURN v_last;
END $$;

-- ---------------------------------------------------------------------------
-- chat-media: one folder per request, participants only, no delete. Same shape as job-proofs.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public) VALUES ('chat-media', 'chat-media', false)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'file_size_limit') THEN
    UPDATE storage.buckets SET file_size_limit = 10 * 1024 * 1024 WHERE id = 'chat-media';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'allowed_mime_types') THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'audio/mp4',
                                   'audio/aac', 'audio/ogg']
    WHERE id = 'chat-media';
  END IF;
END $$;

CREATE POLICY chat_media_participant_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'chat-media'
         AND (SELECT private.is_job_participant(private.path_request_id(name))));

CREATE POLICY chat_media_participant_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'chat-media'
              AND (SELECT private.is_job_participant(private.path_request_id(name)))
              AND (SELECT private.chat_is_open(private.path_request_id(name))));

-- ---------------------------------------------------------------------------
-- Realtime channel authorisation. The topics are the ones in the RLS matrix; the competitive
-- invariant is the reason the provider topic carries the provider id — a rival's amount must not
-- be on a channel a rival can join.
--
-- Guarded on both the table and `realtime.topic()`: a stack without Realtime still migrates, and
-- the whole block is [A] until S-02 verifies it against a real project.
-- ---------------------------------------------------------------------------
-- A uuid, or NULL when the text is not one. Topics come from a client, so nothing here may
-- raise on a malformed one.
CREATE FUNCTION private.try_uuid(p_value text)
RETURNS uuid
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p_value ~
    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    THEN p_value::uuid END;
$$;

CREATE FUNCTION private.may_join_topic(p_topic text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_parts   text[];
  v_request uuid;
BEGIN
  IF v_uid IS NULL OR p_topic IS NULL THEN
    RETURN false;
  END IF;
  v_parts := string_to_array(p_topic, ':');
  v_request := private.try_uuid(v_parts[2]);

  -- user:{user_id}
  IF v_parts[1] = 'user' THEN
    RETURN v_parts[2] = v_uid::text;
  END IF;

  -- request:{request_id}:customer  and  request:{request_id}:provider:{provider_id}
  IF v_parts[1] = 'request' AND v_request IS NOT NULL THEN
    IF v_parts[3] = 'customer' THEN
      RETURN EXISTS (SELECT 1 FROM public.requests r
                     WHERE r.id = v_request AND r.customer_id = v_uid);
    END IF;
    IF v_parts[3] = 'provider' THEN
      -- The provider named in the topic, and only on a request they have a thread on.
      RETURN v_parts[4] = v_uid::text
             AND EXISTS (SELECT 1 FROM public.offer_threads t
                         WHERE t.request_id = v_request AND t.provider_id = v_uid);
    END IF;
    RETURN false;
  END IF;

  -- job:{request_id} — participants, once there is a job
  IF v_parts[1] = 'job' AND v_request IS NOT NULL THEN
    RETURN private.is_job_participant(v_request);
  END IF;

  -- ops:sos
  IF p_topic = 'ops:sos' THEN
    RETURN private.has_admin_role(ARRAY['super_admin']::public.admin_role[]);
  END IF;

  RETURN false;
END $$;

DO $$
BEGIN
  IF to_regclass('realtime.messages') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'realtime' AND p.proname = 'topic') THEN
    EXECUTE $pol$
      CREATE POLICY realtime_join_own_topics ON realtime.messages
      FOR SELECT TO authenticated
      USING (private.may_join_topic(realtime.topic()))
    $pol$;
    EXECUTE $pol$
      CREATE POLICY realtime_send_own_topics ON realtime.messages
      FOR INSERT TO authenticated
      WITH CHECK (private.may_join_topic(realtime.topic()))
    $pol$;
  ELSE
    RAISE NOTICE 'realtime.messages not present: channel policies skipped';
  END IF;
EXCEPTION
  WHEN insufficient_privilege OR duplicate_object THEN
    RAISE NOTICE 'realtime channel policies not applied here: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION
  public.send_message(text, uuid, text, public.chat_message_type, text, uuid,
                      double precision, double precision),
  public.mark_read(uuid, bigint),
  private.chat_is_open(uuid),
  private.try_uuid(text),
  private.may_join_topic(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.send_message(text, uuid, text, public.chat_message_type, text, uuid,
                      double precision, double precision),
  public.mark_read(uuid, bigint)
  TO authenticated;
-- The storage policy and the realtime policies are evaluated as the calling role.
GRANT EXECUTE ON FUNCTION
  private.chat_is_open(uuid),
  private.try_uuid(text),
  private.may_join_topic(text)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('messages-partitions', '23 3 * * *',
      $cron$SELECT private.ensure_monthly_partitions('public.messages'::regclass)$cron$);
  END IF;
END $$;
