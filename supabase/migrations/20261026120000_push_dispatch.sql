-- Push delivery, the database half: running the workers, expiring stale pushes, dropping dead
-- tokens.
--
-- **Nothing called the Edge Function workers.** `notifications-worker`, `storage-worker` and
-- `payments-worker` have existed since Phase 5 and 9, each authenticated by a named secret API key,
-- and no schedule anywhere invoked them, so the outbox filled and nothing drained it. pg_cron runs
-- every database job already; here it also posts to the workers through pg_net.
--
-- **The URL and the key live in Vault**, as `edge_functions_url` and `worker_api_key`, and are
-- written per environment by `supabase/tools/set_worker_key.py`. Until both exist the invoker
-- returns NULL and does nothing, so CI, a local stack and an environment nobody has configured are
-- all quiet rather than failing every minute.
--
-- **A push about something two hours old is noise.** The sandbox's outbox had been filling for two
-- weeks before anything read it, and the first run would otherwise have woken every tester with a
-- fortnight of alerts. Events older than `notifications.push_max_age_minutes` (default 120) are
-- marked dispatched with `ERR_NOTIFICATION_STALE` before each run. The in-app inbox keeps them:
-- only the push is dropped.

-- ---------------------------------------------------------------------------
-- A token FCM says is dead is cleared, not retried.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.dispatch_clear_push_token(p_device_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.user_devices d SET push_token = NULL
  WHERE d.id = p_device_id AND d.push_token IS NOT NULL
  RETURNING true;
$$;

REVOKE ALL ON FUNCTION public.dispatch_clear_push_token(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_clear_push_token(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Stale pushes are dropped before they are sent.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.expire_stale_notification_events()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_minutes integer := greatest(coalesce(private.remote_config_int('notifications.push_max_age_minutes'), 120), 1);
  v_count   integer;
BEGIN
  UPDATE private.outbox o
  SET dispatched_at = now(), last_error = 'ERR_NOTIFICATION_STALE'
  WHERE o.dispatched_at IS NULL
    AND o.aggregate = 'user'
    AND o.event_type = 'notification.created'
    AND o.created_at < now() - make_interval(mins => v_minutes);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION private.expire_stale_notification_events() FROM PUBLIC, anon, authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('notifications.push_max_age_minutes', NULL, '120', false)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Calling a worker.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.invoke_edge_worker(p_function text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_url text;
  v_key text;
BEGIN
  -- A fixed list: this posts a secret key, and it posts it only to our own workers.
  IF p_function IS NULL OR p_function NOT IN ('notifications-worker', 'storage-worker', 'payments-worker') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT s.decrypted_secret INTO v_url FROM vault.decrypted_secrets s WHERE s.name = 'edge_functions_url';
  SELECT s.decrypted_secret INTO v_key FROM vault.decrypted_secrets s WHERE s.name = 'worker_api_key';
  IF v_url IS NULL OR v_key IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_net') THEN
    RETURN NULL;
  END IF;
  RETURN net.http_post(
    url := rtrim(v_url, '/') || '/' || p_function,
    body := '{}'::jsonb,
    headers := jsonb_build_object('apikey', v_key, 'content-type', 'application/json'),
    timeout_milliseconds := 30000
  );
END $$;

REVOKE ALL ON FUNCTION private.invoke_edge_worker(text) FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net') THEN
    CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('notifications-dispatch', '* * * * *',
      $cron$SELECT private.expire_stale_notification_events(); SELECT private.invoke_edge_worker('notifications-worker')$cron$);
    PERFORM cron.schedule('storage-dispatch', '*/5 * * * *',
      $cron$SELECT private.invoke_edge_worker('storage-worker')$cron$);
  END IF;
END $$;
