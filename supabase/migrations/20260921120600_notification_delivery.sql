-- Phase 6, part 2: which channels a notification actually goes out on (spec phase 6,
-- "Notification service (push, SMS, email, in-app inbox) with preferences and quiet hours";
-- PRD SH-16, SH-17; DF rule 1).
--
-- The inbox row is written unconditionally — it is the record, not a channel you can miss. What
-- this migration decides is the *sending*: push, SMS, email, WhatsApp, and whether quiet hours
-- hold one back. The decision is made here, in the same transaction as the event, so the sender
-- never has to re-derive it and two senders cannot disagree.
--
-- **Quiet hours need a time zone**, and until now a profile had none. `language` and
-- `country_code` do not answer it: a Nigerian in London should not be woken at 3 a.m. Lagos time.
-- The column is client-writable because the device knows the answer and nothing else does.
--
-- **Job-critical events are never suppressed** (SH-16). SOS and payment failure belong in that
-- set and are not in it yet: SOS reaches operations through the outbox rather than
-- `notifications`, and payment does not exist until Phase 5. Both are named in the function so
-- the omission is visible rather than forgotten.

ALTER TABLE public.profiles
  ADD COLUMN timezone text CHECK (timezone IS NULL OR timezone ~ '^[A-Za-z][A-Za-z0-9+_/-]{2,63}$');
GRANT UPDATE (timezone) ON public.profiles TO authenticated;

-- A name that passed the CHECK can still be one PostgreSQL does not know, and an unknown zone
-- makes `AT TIME ZONE` raise — inside a trigger, that would lose the notification and the event
-- that caused it. So the zone is looked up, and falls back through the country's first city to
-- UTC.
CREATE FUNCTION private.user_timezone(p_user uuid)
RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(
    (SELECT p.timezone FROM public.profiles p
     WHERE p.user_id = p_user
       AND EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names z WHERE z.name = p.timezone)),
    (SELECT c.timezone FROM public.profiles p
     JOIN public.cities c ON c.country_code = p.country_code
     WHERE p.user_id = p_user
     ORDER BY c.code
     LIMIT 1),
    'UTC');
$$;

-- SH-16's "job-critical events are never suppressed", as a list rather than a judgement call.
CREATE FUNCTION private.notification_is_urgent(p_kind public.notification_kind)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_kind IN ('offer_accepted', 'job_assigned', 'job_status', 'call_incoming');
$$;

-- The channels a notification is *sent* on. The inbox row is always written, so `in_app` is not
-- in the answer: it is not a decision.
--
-- With no preference row, push is on and the paid channels are off. A default that sent SMS
-- would spend the client's money on everyone who never opened the settings screen.
CREATE FUNCTION private.notification_channels(p_user uuid, p_kind public.notification_kind)
RETURNS text[]
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_zone   text := private.user_timezone(p_user);
  v_now    time := (now() AT TIME ZONE v_zone)::time;
  v_urgent boolean := private.notification_is_urgent(p_kind);
  v_out    text[] := '{}'::text[];
  v_ch     text;
  v_pref   public.notification_preferences%ROWTYPE;
  v_quiet  boolean;
BEGIN
  FOREACH v_ch IN ARRAY ARRAY['push', 'sms', 'email', 'whatsapp'] LOOP
    SELECT * INTO v_pref FROM public.notification_preferences np
    WHERE np.user_id = p_user AND np.channel = v_ch AND np.category = 'transactional';

    IF NOT FOUND THEN
      IF v_ch = 'push' THEN v_out := v_out || v_ch; END IF;
      CONTINUE;
    END IF;
    IF NOT v_pref.enabled THEN
      CONTINUE;
    END IF;

    -- A window that wraps midnight (22:00–07:00) is the normal case, so both orderings count.
    v_quiet := v_pref.quiet_start IS NOT NULL AND (
      CASE WHEN v_pref.quiet_start <= v_pref.quiet_end
           THEN v_now >= v_pref.quiet_start AND v_now < v_pref.quiet_end
           ELSE v_now >= v_pref.quiet_start OR v_now < v_pref.quiet_end END);

    IF v_quiet AND NOT v_urgent THEN
      CONTINUE;
    END IF;
    v_out := v_out || v_ch;
  END LOOP;
  RETURN v_out;
END $$;

-- ---------------------------------------------------------------------------
-- notify, replaced whole because a function body cannot be patched. The row it writes is
-- unchanged; what is added is the delivery decision on the outbox event.
--
-- **The payload here is internal.** `params` carries request ids, amounts and names, and a push
-- notification must carry none of it: DF rule 1 and SH-17 say the push contains a notification id
-- and a generic title, and the app fetches the rest after unlock. That is the sender's
-- obligation, and `notification_id` is in the payload precisely so it can meet it.
-- ---------------------------------------------------------------------------
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
  v_id       bigint;
  v_channels text[];
BEGIN
  IF p_user IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.notifications (user_id, kind, title_key, body_key, params, deep_link)
  VALUES (p_user, p_kind, p_title_key, p_body_key, coalesce(p_params, '{}'::jsonb), p_deep_link)
  RETURNING id INTO v_id;

  v_channels := private.notification_channels(p_user, p_kind);

  PERFORM private.emit_event('user', p_user::text, 'notification.created',
    jsonb_build_object('notification_id', v_id, 'kind', p_kind, 'title_key', p_title_key,
                       'body_key', p_body_key, 'params', coalesce(p_params, '{}'::jsonb),
                       'deep_link', p_deep_link,
                       'channels', to_jsonb(v_channels),
                       'urgent', private.notification_is_urgent(p_kind)));
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION
  private.user_timezone(uuid),
  private.notification_is_urgent(public.notification_kind),
  private.notification_channels(uuid, public.notification_kind)
  FROM PUBLIC, anon, authenticated;
