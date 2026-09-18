-- Marketplace, part 11: database broadcasts (spec phase 3, "Realtime private channels and
-- database broadcasts"; RLS matrix, realtime channel authorisation).
--
-- The channels and their authorisation already exist. This is the other half: the database
-- putting messages on them, in the same transaction as the change they describe, so a client
-- cannot be told about something that then rolled back.
--
-- Every broadcast is addressed to a topic `private.may_join_topic` already governs, and the
-- competitive invariant decides the addressing: an offer goes to the customer's topic and to
-- **that provider's own** topic, never to a shared request topic a rival could join. What is on
-- the wire is a notice that something changed, with ids — never the amounts of other people's
-- offers, and never a chat body.
--
-- A broadcast is a courtesy, not a guarantee: the tables are the truth, and the apps refetch.
-- So a failure here must never take down the transaction that produced it.

CREATE FUNCTION private.broadcast(p_topic text, p_event text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF p_topic IS NULL THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
             JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'realtime' AND p.proname = 'send') THEN
    -- Dynamic, so a stack without Realtime does not fail to create this function.
    EXECUTE 'SELECT realtime.send($1, $2, $3, true)'
      USING coalesce(p_payload, '{}'::jsonb), p_event, p_topic;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    -- The tables are the truth and the apps refetch; a channel that is down must not roll back
    -- an accepted offer.
    RAISE NOTICE 'broadcast to % failed: %', p_topic, SQLERRM;
END $$;

-- A notification is already addressed to one person, so it rides their own channel.
CREATE OR REPLACE FUNCTION private.notify(
  p_user uuid,
  p_kind public.notification_kind,
  p_title_key text,
  p_body_key text,
  p_params jsonb DEFAULT '{}'::jsonb,
  p_deep_link text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_user IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.notifications (user_id, kind, title_key, body_key, params, deep_link)
  VALUES (p_user, p_kind, p_title_key, p_body_key, coalesce(p_params, '{}'::jsonb), p_deep_link)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('user', p_user::text, 'notification.created',
    jsonb_build_object('notification_id', v_id, 'kind', p_kind, 'title_key', p_title_key,
                       'body_key', p_body_key, 'params', coalesce(p_params, '{}'::jsonb),
                       'deep_link', p_deep_link));
  PERFORM private.broadcast('user:' || p_user::text, 'notification',
    jsonb_build_object('notification_id', v_id, 'kind', p_kind, 'title_key', p_title_key,
                       'body_key', p_body_key, 'params', coalesce(p_params, '{}'::jsonb),
                       'deep_link', p_deep_link));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Offers: the customer's board updates, and the provider's own thread updates. Two topics, and
-- the amounts only ever go where they belong.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.offers_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_event text;
BEGIN
  v_event := CASE
    WHEN TG_OP = 'INSERT' AND NEW.round = 1 THEN 'offer.created'
    WHEN TG_OP = 'INSERT' THEN 'offer.countered'
    ELSE 'offer.' || NEW.status::text END;

  -- The customer's channel carries every thread on their own request, which is theirs to see.
  PERFORM private.broadcast('request:' || NEW.request_id::text || ':customer', v_event,
    jsonb_build_object('offer_id', NEW.id, 'thread_id', NEW.thread_id,
                       'provider_id', NEW.provider_id, 'status', NEW.status,
                       'amount_minor', NEW.amount_minor, 'currency', NEW.currency,
                       'round', NEW.round, 'expires_at', NEW.expires_at));

  -- The provider's channel carries their thread and nothing else.
  PERFORM private.broadcast(
    'request:' || NEW.request_id::text || ':provider:' || NEW.provider_id::text, v_event,
    jsonb_build_object('offer_id', NEW.id, 'thread_id', NEW.thread_id, 'status', NEW.status,
                       'amount_minor', NEW.amount_minor, 'currency', NEW.currency,
                       'round', NEW.round, 'expires_at', NEW.expires_at));
  RETURN NULL;
END $$;

CREATE TRIGGER offers_broadcast_insert AFTER INSERT ON public.offers
  FOR EACH ROW EXECUTE FUNCTION private.offers_broadcast();
CREATE TRIGGER offers_broadcast_status AFTER UPDATE OF status ON public.offers
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.offers_broadcast();

-- ---------------------------------------------------------------------------
-- The job channel: participants, from assignment onwards. Status changes and new messages, by
-- id — a chat body on a channel is a chat body in whatever logs the channel passes through.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.requests_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  PERFORM private.broadcast('job:' || NEW.id::text, 'job.status',
    jsonb_build_object('request_id', NEW.id, 'from_status', OLD.status,
                       'to_status', NEW.status, 'version', NEW.version));
  RETURN NULL;
END $$;

CREATE TRIGGER requests_broadcast_status AFTER UPDATE OF status ON public.requests
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.requests_broadcast();

CREATE FUNCTION private.messages_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request uuid;
BEGIN
  SELECT c.request_id INTO v_request FROM public.conversations c WHERE c.id = NEW.conversation_id;
  PERFORM private.broadcast('job:' || v_request::text, 'chat.message',
    jsonb_build_object('conversation_id', NEW.conversation_id, 'message_id', NEW.id,
                       'sender_id', NEW.sender_id, 'type', NEW.type,
                       'created_at', NEW.created_at));
  RETURN NULL;
END $$;

CREATE TRIGGER messages_broadcast AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_broadcast();

REVOKE ALL ON FUNCTION
  private.broadcast(text, text, jsonb),
  private.offers_broadcast(),
  private.requests_broadcast(),
  private.messages_broadcast()
  FROM PUBLIC, anon, authenticated;
