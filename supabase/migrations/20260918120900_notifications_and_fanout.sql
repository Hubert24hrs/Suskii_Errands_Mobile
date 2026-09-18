-- Marketplace, part 10: notifications and the matching fan-out (ERD §8; RLS matrix §2; spec
-- phase 3, "PostGIS matching and provider notification fan-out" and "Realtime private channels
-- and database broadcasts").
--
-- Matching answered *who*; nothing yet told them. This closes that loop inside the database:
-- publishing a request fans out to the matched providers, each one gets a row addressed to them,
-- and the outbox carries the push job to whatever sends push.
--
-- **Notification bodies are keys, not sentences.** `title_key`, `body_key` and a `params` object
-- — never assembled text. The app renders them in the reader's language, and a server that wrote
-- English here would have decided that for everyone.
--
-- Quiet hours and channel preferences live in `notification_preferences`, which already exists.
-- They are honoured by the sender, not here: a row that was never written cannot be read later,
-- and a provider who was asleep should still find the job in their list in the morning.

CREATE TYPE public.notification_kind AS ENUM (
  'request_matched', 'offer_received', 'offer_countered', 'offer_accepted', 'offer_expired',
  'job_assigned', 'job_status', 'chat_message', 'rating_received', 'system');

CREATE TABLE public.notifications (
  id         bigint GENERATED ALWAYS AS IDENTITY,
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  kind       public.notification_kind NOT NULL,
  title_key  text NOT NULL CHECK (length(title_key) BETWEEN 2 AND 80),
  body_key   text NOT NULL CHECK (length(body_key) BETWEEN 2 AND 80),
  params     jsonb NOT NULL DEFAULT '{}'::jsonb,
  deep_link  text CHECK (deep_link IS NULL OR length(deep_link) <= 300),
  read_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE INDEX notifications_user ON public.notifications (user_id, id DESC);
CREATE INDEX notifications_unread ON public.notifications (user_id) WHERE read_at IS NULL;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.notifications FROM anon, authenticated;
GRANT SELECT ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;
CREATE POLICY notifications_read_own ON public.notifications FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

SELECT private.ensure_monthly_partitions('public.notifications'::regclass, 3);

-- Marking one read is the only write a client makes, and it is one-way: a notification cannot be
-- marked unread, which keeps the badge honest across devices.
CREATE FUNCTION public.mark_notifications_read(p_up_to_id bigint DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_count integer;
BEGIN
  WITH marked AS (
    UPDATE public.notifications n SET read_at = now()
    WHERE n.user_id = v_uid AND n.read_at IS NULL
      AND (p_up_to_id IS NULL OR n.id <= p_up_to_id)
    RETURNING n.id
  )
  SELECT count(*)::int INTO v_count FROM marked;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- notify — one row, plus the outbox record that whatever sends push will pick up. Both in the
-- same transaction as the thing being announced, so a notification cannot exist for an event
-- that rolled back.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.notify(
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
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- fan_out_request — the other half of matching. Called when a request is published, and again by
-- the scheduler for anything that has been waiting: a provider who comes online two minutes later
-- is a better match than nobody at all.
-- ---------------------------------------------------------------------------
-- Who has already been told about which request. Its own table rather than a borrowed
-- idempotency key: those expire after a day by design, and an expired key would quietly turn
-- into a second notification for the same work.
CREATE TABLE private.request_fanouts (
  request_id  uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  notified_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, provider_id)
);
REVOKE ALL ON private.request_fanouts FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.fan_out_request(p_request_id uuid, p_limit integer DEFAULT 20,
                                        p_radius_m integer DEFAULT 5000)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_row     record;
  v_count   integer := 0;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND OR v_request.status NOT IN ('published', 'offers_received', 'negotiating') THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT m.provider_id, m.distance_m FROM private.match_providers(p_request_id, p_limit, p_radius_m) m
  LOOP
    -- Once per provider per request. Someone who saw it and did not bid is not told twice.
    INSERT INTO private.request_fanouts (request_id, provider_id)
    VALUES (p_request_id, v_row.provider_id)
    ON CONFLICT (request_id, provider_id) DO NOTHING;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    PERFORM private.notify(v_row.provider_id, 'request_matched',
      'notifRequestMatchedTitle', 'notifRequestMatchedBody',
      jsonb_build_object('request_id', p_request_id, 'distance_m', v_row.distance_m,
                         'category_id', v_request.category_id, 'urgency', v_request.urgency),
      '/provider/requests/' || p_request_id::text);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- Publishing fans out immediately. A trigger rather than a line in `publish_request`, so a
-- request that reaches `published` by any route is announced the same way.
CREATE FUNCTION private.requests_fan_out()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  PERFORM private.fan_out_request(NEW.id);
  RETURN NULL;
END $$;

CREATE TRIGGER requests_fan_out AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status = 'published' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.requests_fan_out();

-- A sweep for requests nobody was near when they were published.
CREATE FUNCTION private.fan_out_open_requests(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id    uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT r.id FROM public.requests r
    WHERE r.status IN ('published', 'offers_received', 'negotiating')
      AND (r.expires_at IS NULL OR r.expires_at > now())
    ORDER BY r.published_at DESC NULLS LAST
    LIMIT p_limit
  LOOP
    v_count := v_count + private.fan_out_request(v_id);
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- The notifications the other side of the marketplace gets. Offers and job transitions already
-- write events; these turn the ones a person should hear about into something addressed to them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.offers_notify()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
  v_target   uuid;
BEGIN
  SELECT r.customer_id INTO v_customer FROM public.requests r WHERE r.id = NEW.request_id;

  IF TG_OP = 'INSERT' THEN
    -- A new offer goes to the counterparty: the side that did not write it.
    v_target := CASE WHEN NEW.author_side = 'provider' THEN v_customer ELSE NEW.provider_id END;
    PERFORM private.notify(v_target,
      CASE WHEN NEW.round = 1 THEN 'offer_received'::public.notification_kind
           ELSE 'offer_countered'::public.notification_kind END,
      CASE WHEN NEW.round = 1 THEN 'notifOfferReceivedTitle' ELSE 'notifOfferCounteredTitle' END,
      CASE WHEN NEW.round = 1 THEN 'notifOfferReceivedBody' ELSE 'notifOfferCounteredBody' END,
      jsonb_build_object('request_id', NEW.request_id, 'offer_id', NEW.id,
                         'amount_minor', NEW.amount_minor, 'currency', NEW.currency,
                         'round', NEW.round),
      '/requests/' || NEW.request_id::text || '/offers');
    RETURN NEW;
  END IF;

  IF NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM private.notify(NEW.provider_id, 'offer_accepted',
      'notifOfferAcceptedTitle', 'notifOfferAcceptedBody',
      jsonb_build_object('request_id', NEW.request_id, 'offer_id', NEW.id,
                         'amount_minor', NEW.amount_minor, 'currency', NEW.currency),
      '/provider/jobs/' || NEW.request_id::text);
  ELSIF NEW.status = 'expired' AND OLD.status = 'pending'
        AND NEW.status_reason = 'sibling_accepted' THEN
    -- The losing provider is told plainly, and told nothing about who won or for how much.
    PERFORM private.notify(NEW.provider_id, 'offer_expired',
      'notifOfferLostTitle', 'notifOfferLostBody',
      jsonb_build_object('request_id', NEW.request_id, 'offer_id', NEW.id), NULL);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER offers_notify_insert AFTER INSERT ON public.offers
  FOR EACH ROW EXECUTE FUNCTION private.offers_notify();
CREATE TRIGGER offers_notify_status AFTER UPDATE OF status ON public.offers
  FOR EACH ROW EXECUTE FUNCTION private.offers_notify();

CREATE FUNCTION private.jobs_notify()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
  v_worker   uuid;
BEGIN
  SELECT r.customer_id, j.worker_id INTO v_customer, v_worker
  FROM public.requests r LEFT JOIN public.jobs j ON j.request_id = r.id
  WHERE r.id = NEW.id;

  IF NEW.status = 'assigned' THEN
    PERFORM private.notify(v_customer, 'job_assigned', 'notifJobAssignedTitle',
      'notifJobAssignedBody', jsonb_build_object('request_id', NEW.id),
      '/requests/' || NEW.id::text);
    PERFORM private.notify(v_worker, 'job_assigned', 'notifJobAssignedProviderTitle',
      'notifJobAssignedProviderBody', jsonb_build_object('request_id', NEW.id),
      '/provider/jobs/' || NEW.id::text);
    RETURN NULL;
  END IF;

  -- The customer hears about the steps that mean something to them.
  IF NEW.status IN ('en_route', 'arrived', 'in_progress', 'completed_by_provider') THEN
    -- One key pair with the status in `params`, rather than a key name assembled from the
    -- enum: a generated key is a contract the other side never agreed to, and it breaks
    -- silently the day a state is renamed.
    PERFORM private.notify(v_customer, 'job_status', 'notifJobStatusTitle', 'notifJobStatusBody',
      jsonb_build_object('request_id', NEW.id, 'status', NEW.status),
      '/requests/' || NEW.id::text);
  ELSIF NEW.status = 'confirmed' THEN
    PERFORM private.notify(v_worker, 'job_status', 'notifJobConfirmedTitle',
      'notifJobConfirmedBody', jsonb_build_object('request_id', NEW.id),
      '/provider/jobs/' || NEW.id::text);
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER requests_notify_status AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.jobs_notify();

CREATE FUNCTION private.messages_notify()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
  v_provider uuid;
  v_target   uuid;
BEGIN
  SELECT r.customer_id, coalesce(j.worker_id, j.provider_id) INTO v_customer, v_provider
  FROM public.conversations c
  JOIN public.requests r ON r.id = c.request_id
  LEFT JOIN public.jobs j ON j.request_id = c.request_id
  WHERE c.id = NEW.conversation_id;

  v_target := CASE WHEN NEW.sender_id = v_customer THEN v_provider ELSE v_customer END;
  -- The body is not in the notification: a message preview on a lock screen is a message read by
  -- whoever is holding the phone.
  PERFORM private.notify(v_target, 'chat_message', 'notifChatMessageTitle', 'notifChatMessageBody',
    jsonb_build_object('conversation_id', NEW.conversation_id, 'message_id', NEW.id,
                       'type', NEW.type),
    '/chat/' || NEW.conversation_id::text);
  RETURN NULL;
END $$;

CREATE TRIGGER messages_notify AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_notify();

REVOKE ALL ON FUNCTION
  public.mark_notifications_read(bigint),
  private.notify(uuid, public.notification_kind, text, text, jsonb, text),
  private.fan_out_request(uuid, integer, integer),
  private.fan_out_open_requests(integer),
  private.requests_fan_out(),
  private.offers_notify(),
  private.jobs_notify(),
  private.messages_notify()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_notifications_read(bigint) TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('requests-fan-out', '*/2 * * * *',
      $cron$SELECT private.fan_out_open_requests()$cron$);
    PERFORM cron.schedule('notifications-partitions', '29 3 * * *',
      $cron$SELECT private.ensure_monthly_partitions('public.notifications'::regclass)$cron$);
  END IF;
END $$;
