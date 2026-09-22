-- Phase 9, part 6: the outbox's second reader (audit `AUDIT-2026-09-22.md` N.3).
--
-- `private.outbox` has been written to since Phase 2 and read by one worker since Phase 5 part 8.
-- That worker claims `payment` and `payout`. Everything else — `request`, `job`, `user`,
-- `referral`, `config`, `dispute`, `admin`, `organization`, `kyc` — has accumulated since the
-- schema's first migration with nothing on the other end, which is why `health_snapshot` reports
-- the outbox as `skipped` rather than as a backlog.
--
-- The most valuable of those is `user` / `notification.created`. `private.notify` already does
-- the hard part: it writes the inbox row, decides the channels from preferences and quiet hours,
-- and **carries the decision on the event** so no sender re-derives it and two senders cannot
-- disagree. What has been missing is anything that reads the event.
--
-- **This is the database half.** The sending itself needs credentials nobody has: APNs and FCM
-- keys and a device lab (timeline action 6), and an SMS vendor that spike S-09 has not chosen.
-- So the worker ships with the console sender the SMS hook already uses, the same posture as the
-- payment adapters: the whole path is exercisable today and a country still routing to `console`
-- in production fails loudly.
--
-- **A delivery is recorded, not assumed.** "Did they get the push?" is the first question support
-- asks about a missed job, and until now the only possible answer was "an event was emitted".

CREATE TABLE public.notification_deliveries (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- No foreign key: `notifications` is partitioned monthly and its primary key carries the
  -- partition key, so a reference to `id` alone cannot exist. The id is still the join.
  notification_id bigint NOT NULL,
  -- Denormalised so the country scope can reach this row without joining a partitioned table.
  user_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  channel         text NOT NULL CHECK (channel IN ('push', 'sms', 'email', 'whatsapp')),
  provider        text CHECK (provider IS NULL OR length(provider) <= 40),
  status          text NOT NULL CHECK (status IN ('sent', 'failed', 'skipped')),
  reason_key      text CHECK (reason_key IS NULL OR reason_key ~ '^[a-z0-9_]{3,60}$'),
  attempted_at    timestamptz NOT NULL DEFAULT now(),
  -- One outcome per notification per channel. A retry overwrites it, because the question is
  -- "did it arrive", not "how many times did we try" — the outbox's `attempts` answers that.
  UNIQUE (notification_id, channel)
);
CREATE INDEX notification_deliveries_failed ON public.notification_deliveries (attempted_at)
  WHERE status = 'failed';

ALTER TABLE public.notification_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_deliveries FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_deliveries FROM anon, authenticated;
GRANT SELECT ON public.notification_deliveries TO authenticated;
GRANT ALL ON public.notification_deliveries TO service_role;
-- **Not the recipient's.** Whether a push reached a handset is operational telemetry about a
-- device, and showing somebody their own delivery log is one query away from showing them
-- somebody else's. Support answers the question; the person asks it.
CREATE POLICY notification_deliveries_read ON public.notification_deliveries
  FOR SELECT TO authenticated
  USING ((SELECT private.admin_may_read_user(notification_deliveries.user_id,
            ARRAY['support_agent']::public.admin_role[])));

CREATE FUNCTION private.record_notification_delivery(
  p_notification_id bigint, p_user_id uuid, p_channel text, p_provider text,
  p_status text, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_notification_id IS NULL OR p_user_id IS NULL
     OR p_channel NOT IN ('push', 'sms', 'email', 'whatsapp')
     OR p_status NOT IN ('sent', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.notification_deliveries
    (notification_id, user_id, channel, provider, status, reason_key)
  VALUES (p_notification_id, p_user_id, p_channel, p_provider, p_status, p_reason_key)
  ON CONFLICT (notification_id, channel) DO UPDATE
  SET provider = excluded.provider, status = excluded.status,
      reason_key = excluded.reason_key, attempted_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- The worker's door, granted to `service_role` alone. The outbox verbs it also needs —
-- `gateway_claim_outbox`, `gateway_complete_outbox`, `gateway_fail_outbox` — are already generic
-- over the aggregate and are shared with the payments worker; only the record-back is per-worker.
CREATE FUNCTION public.dispatch_record_notification(
  p_notification_id bigint, p_user_id uuid, p_channel text, p_provider text,
  p_status text, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_notification_delivery(p_notification_id, p_user_id, p_channel,
                                                  p_provider, p_status, p_reason_key); $$;

-- The push tokens a sender needs, for one user, with the rows that cannot receive one left out.
-- Definer and `service_role`-only: `user_devices` grants no client role a sight of a push token,
-- and this does not change that.
CREATE FUNCTION public.dispatch_push_targets(p_user_id uuid)
RETURNS TABLE (device_id uuid, platform public.device_platform, push_token text,
               voip_token text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, d.platform, d.push_token, d.voip_token
  FROM public.user_devices d
  WHERE d.user_id = p_user_id
    AND (d.push_token IS NOT NULL OR d.voip_token IS NOT NULL)
    -- A device that failed integrity does not get a push: the spec puts device integrity in
    -- front of sensitive actions, and a notification carrying a deep link is one.
    AND coalesce(d.integrity_verdict ->> 'verdict', 'unevaluated') <> 'fail'
  ORDER BY d.last_seen_at DESC
  LIMIT 20;
$$;

REVOKE ALL ON FUNCTION
  private.record_notification_delivery(bigint, uuid, text, text, text, text),
  public.dispatch_record_notification(bigint, uuid, text, text, text, text),
  public.dispatch_push_targets(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.dispatch_record_notification(bigint, uuid, text, text, text, text),
  public.dispatch_push_targets(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Ops. A sender that has stopped working is invisible until somebody misses a job, so it is a
-- health check like the others — and the outbox's own `skipped` status can now be lifted for the
-- one aggregate that has a reader, which is what `ops.outbox_max_age_seconds` is for.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.record_notification_health()
RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_failed  integer;
  v_pending integer;
  v_status  text;
BEGIN
  SELECT count(*)::integer INTO v_failed
  FROM public.notification_deliveries d
  WHERE d.status = 'failed' AND d.attempted_at > now() - interval '1 hour';

  SELECT count(*)::integer INTO v_pending
  FROM private.outbox o
  WHERE o.dispatched_at IS NULL AND o.aggregate = 'user'
    AND o.created_at < now() - interval '15 minutes';

  v_status := CASE WHEN v_pending > 0 THEN 'fail'
                   WHEN v_failed > 0 THEN 'warn'
                   ELSE 'ok' END;
  PERFORM private.record_health_check('notifications', v_status,
    jsonb_build_object('failed_last_hour', v_failed, 'undispatched_over_15m', v_pending));
  RETURN v_status;
END $$;

REVOKE ALL ON FUNCTION private.record_notification_health() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('notification-health', '*/10 * * * *',
      $cron$SELECT private.record_notification_health()$cron$);
  END IF;
END $$;
