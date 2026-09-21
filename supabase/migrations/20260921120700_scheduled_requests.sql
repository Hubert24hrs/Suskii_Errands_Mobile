-- Phase 6, part 3: scheduled errands publish themselves (spec phase 6, "Scheduled errands
-- publishing via queues/cron"; PRD CU-08 and CU-32).
--
-- A customer booking a cleaner for Saturday does not want the request on the board on Tuesday:
-- it would collect offers from providers who cannot remember why they bid, and it would expire
-- before the day arrived. So a scheduled request stays a draft — editable and cancellable, which
-- is what CU-32 promises — and publishes at a configured lead time before the chosen hour.
--
-- Publishing is the same code path either way. `publish_request` and the scheduler both call
-- `private.do_publish_request`, so a guard added to one is a guard in both; the alternative is
-- two copies of "is this customer still verified?" that drift apart on a Friday afternoon.

CREATE FUNCTION private.do_publish_request(p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_country public.country_status;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status <> 'draft' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.user_id = v_request.customer_id
                   AND p.customer_verification = 'verified') THEN
    RAISE EXCEPTION 'ERR_VERIFICATION_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.status INTO v_country FROM public.countries c WHERE c.code = v_request.country_code;
  IF v_country NOT IN ('live', 'beta') THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.requests r
  SET status = 'published',
      published_at = now(),
      expires_at = now() + interval '24 hours',
      version = r.version + 1
  WHERE r.id = p_request_id;

  PERFORM private.emit_event('request', p_request_id::text, 'request.published',
    jsonb_build_object('category_id', v_request.category_id, 'city_id', v_request.city_id,
                       'country_code', v_request.country_code, 'urgency', v_request.urgency,
                       'scheduled_at', v_request.scheduled_at));
  RETURN 'published'::public.job_status;
END $$;

-- Replaced whole, since a function body cannot be patched. The behaviour a client sees is
-- unchanged: the ownership check and the idempotency key stay here, where the caller is known.
CREATE OR REPLACE FUNCTION public.publish_request(p_request_id uuid, p_idempotency_key text)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_status public.job_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'publish_request',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = p_request_id AND r.customer_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_status := private.do_publish_request(p_request_id);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- The scheduler. Every minute, which is finer than any lead time anybody will configure.
--
-- Each request is published in its own subtransaction. One that cannot publish — an unverified
-- customer, a country that closed, a description a moderation rule refuses — must not take the
-- rest of the batch down with it, and the customer has to be told rather than left watching a
-- draft that never went anywhere.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.publish_scheduled_requests()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_lead  integer := coalesce(private.remote_config_int('scheduled_publish_lead_minutes'), 60);
  v_count integer := 0;
  v_row   record;
  v_err   text;
BEGIN
  FOR v_row IN
    SELECT r.id, r.customer_id, r.scheduled_at
    FROM public.requests r
    WHERE r.status = 'draft'
      AND r.scheduled_at IS NOT NULL
      AND r.scheduled_at - make_interval(mins => v_lead) <= now()
    ORDER BY r.scheduled_at
    LIMIT 500
  LOOP
    BEGIN
      PERFORM private.do_publish_request(v_row.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Only our own error codes are handed back. A raw PostgreSQL message would describe the
      -- schema to whoever booked the errand.
      v_err := CASE WHEN SQLERRM ~ '^ERR_[A-Z_]+$' THEN SQLERRM ELSE 'ERR_INTERNAL' END;
      PERFORM private.notify(v_row.customer_id, 'system',
        'notification.request.scheduled_failed.title',
        'notification.request.scheduled_failed.body',
        jsonb_build_object('request_id', v_row.id, 'reason_key', v_err,
                           'scheduled_at', v_row.scheduled_at),
        '/requests/' || v_row.id::text);
      PERFORM private.emit_event('request', v_row.id::text, 'request.scheduled_publish_failed',
        jsonb_build_object('request_id', v_row.id, 'reason_key', v_err));
    END;
  END LOOP;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  private.do_publish_request(uuid),
  private.publish_scheduled_requests()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_request(uuid, text) TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('scheduled_publish_lead_minutes', NULL, '60', true)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('publish-scheduled-requests', '* * * * *',
      $cron$SELECT private.publish_scheduled_requests()$cron$);
  END IF;
END $$;
