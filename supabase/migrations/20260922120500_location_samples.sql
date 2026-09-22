-- Phase 9, part 2: `location_samples` — the trip trail (RLS matrix §9; ERD; DPIA).
--
-- The matrix has had a row for this since Phase 1 and nothing behind it. `provider_live_location`
-- is one row per provider, overwritten on every heartbeat: it answers "where are they now" and
-- destroys the answer to "where did they go". The trail is what a customer replays after a
-- delivery, what a dispute officer reads as evidence, and what the spec lists under the dispute
-- centre's evidence ("chat, photos, **GPS trail**, PIN logs, call metadata").
--
-- **It is the most sensitive table in the schema, so it has the narrowest rules.**
--
--   * Samples are written **only while the provider is on an active job**, and only that job's
--     id is recorded. A provider driving home is not tracked; the table cannot answer where
--     somebody lives, because nothing writes to it then.
--   * The participant read is **post-completion**, exactly as the matrix says. A customer
--     watching a live job gets the provider's position from the realtime channel, which is one
--     point; the trail is history, and history is for afterwards.
--   * A provider reads their own trail whenever they like — it is their movement.
--   * Support gets nothing at all. The matrix gives `location_samples` to disputes and to super
--     admin and to nobody else, and a support agent has no business reconstructing a route.
--   * It expires. `location_retention_days` (default 90) is remote config, and a daily job drops
--     whole partitions rather than deleting rows, so the retention promise costs nothing to keep.
--
-- Monthly partitions, like every other high-volume append-only table here, with the cron job
-- that audit finding T.1 established this schema needs.

CREATE TABLE public.location_samples (
  id                bigint GENERATED ALWAYS AS IDENTITY,
  request_id        uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  provider_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  pos               extensions.geography(Point, 4326) NOT NULL,
  heading           smallint CHECK (heading IS NULL OR heading BETWEEN 0 AND 359),
  speed_cm_s        integer CHECK (speed_cm_s IS NULL OR speed_cm_s >= 0),
  accuracy_m        integer CHECK (accuracy_m IS NULL OR accuracy_m >= 0),
  -- The device said its location was mocked. Kept rather than refused: a sample that is known to
  -- be false is evidence, and dropping it would hide the thing worth seeing (risk engine).
  is_mock           boolean NOT NULL DEFAULT false,
  recorded_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);
CREATE INDEX location_samples_trail ON public.location_samples (request_id, recorded_at);

ALTER TABLE public.location_samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.location_samples FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.location_samples FROM anon, authenticated;
GRANT SELECT ON public.location_samples TO authenticated;
GRANT ALL ON public.location_samples TO service_role;

-- The provider's own trail; the customer's after the job is done; a dispute officer's when a case
-- names the job; super admin's. **Not support's** — the matrix gives them no cell here.
CREATE POLICY location_samples_read ON public.location_samples FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = location_samples.request_id
                      AND r.customer_id = (SELECT auth.uid())
                      AND r.status IN ('confirmed', 'settlement_pending', 'settled', 'closed',
                                       'disputed', 'refunded'))
         OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
         OR (SELECT private.dispute_scope(location_samples.request_id)));

CREATE TRIGGER location_samples_no_update_delete
  BEFORE UPDATE OR DELETE ON public.location_samples
  FOR EACH ROW EXECUTE FUNCTION private.audit_forbid_mutation();

SELECT private.ensure_monthly_partitions('public.location_samples'::regclass, 3);

-- ---------------------------------------------------------------------------
-- Retention. Dropping a partition is how a promise about deletion is kept cheaply; deleting rows
-- from a table this size is how it stops being kept.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.drop_expired_location_partitions()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_days   integer := coalesce(private.remote_config_int('location_retention_days'), 90);
  v_cutoff date;
  v_part   record;
  v_count  integer := 0;
BEGIN
  -- A partition is dropped only when its whole month is older than the cutoff, so the retention
  -- is "at least `v_days`", never less.
  v_cutoff := date_trunc('month', now() - make_interval(days => greatest(v_days, 1)))::date;
  FOR v_part IN
    SELECT c.relname
    FROM pg_catalog.pg_inherits i
    JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = 'public.location_samples'::regclass
      AND c.relname < format('location_samples_y%sm%s',
                             to_char(v_cutoff, 'YYYY'), to_char(v_cutoff, 'MM'))
  LOOP
    EXECUTE format('DROP TABLE public.%I', v_part.relname);
    v_count := v_count + 1;
  END LOOP;
  IF v_count > 0 THEN
    PERFORM private.audit_write('location.retention', 'public.location_samples', NULL, NULL,
      jsonb_build_object('partitions_dropped', v_count, 'retention_days', v_days), NULL);
  END IF;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- heartbeat, replaced whole: the same live position, plus a sample on the trail when the
-- provider is actually working. The movement gate is unchanged and does both — S-06 measured
-- write rate as the limit, and a trail written on every tick would be the same mistake twice.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.heartbeat(
  p_lat double precision,
  p_lng double precision,
  p_heading smallint DEFAULT NULL,
  p_speed_cm_s integer DEFAULT NULL,
  p_accuracy_m integer DEFAULT NULL,
  p_is_mock boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_point    extensions.geography(Point, 4326);
  v_existing public.provider_live_location%ROWTYPE;
  v_min_move integer := coalesce(private.remote_config_int('location_min_move_m'), 25);
  v_max_gap  integer := coalesce(private.remote_config_int('location_max_interval_s'), 60);
  v_request  uuid;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL
     OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  PERFORM private.require_active_provider(v_uid);

  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;

  SELECT * INTO v_existing FROM public.provider_live_location l
  WHERE l.provider_id = v_uid FOR UPDATE;
  IF FOUND
     AND v_existing.updated_at > now() - make_interval(secs => v_max_gap)
     AND extensions.ST_DWithin(v_existing.pos, v_point, v_min_move) THEN
    RETURN false;
  END IF;

  INSERT INTO public.provider_live_location AS l
    (provider_id, pos, heading, speed_cm_s, accuracy_m, is_mock, updated_at)
  VALUES (v_uid, v_point, p_heading, p_speed_cm_s, p_accuracy_m, coalesce(p_is_mock, false), now())
  ON CONFLICT (provider_id) DO UPDATE
  SET pos = excluded.pos, heading = excluded.heading, speed_cm_s = excluded.speed_cm_s,
      accuracy_m = excluded.accuracy_m, is_mock = excluded.is_mock, updated_at = now();

  -- **Only while on a job.** One active job at a time is the state machine's own rule, so this
  -- picks the one they are on and records nothing when there is none. A provider between jobs is
  -- not tracked, which is the whole difference between a trip trail and surveillance.
  SELECT j.request_id INTO v_request
  FROM public.jobs j
  JOIN public.requests r ON r.id = j.request_id
  WHERE (j.provider_id = v_uid OR j.worker_id = v_uid)
    AND r.status IN ('assigned', 'en_route', 'arrived', 'in_progress')
  ORDER BY j.assigned_at DESC
  LIMIT 1;

  IF v_request IS NOT NULL THEN
    INSERT INTO public.location_samples
      (request_id, provider_id, pos, heading, speed_cm_s, accuracy_m, is_mock)
    VALUES (v_request, v_uid, v_point, p_heading, p_speed_cm_s, p_accuracy_m,
            coalesce(p_is_mock, false));
  END IF;
  RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- The trail itself. A function rather than a bare select, so that a dispute officer reading
-- somebody's movements leaves a record of having done so — the same rule `audit.kyc_access`
-- applies to documents, for the same reason.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.job_trail(p_request_id uuid)
RETURNS TABLE (recorded_at timestamptz, lat double precision, lng double precision,
               heading smallint, speed_cm_s integer, accuracy_m integer, is_mock boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.jobs j
                  WHERE j.request_id = p_request_id
                    AND (j.provider_id = v_uid OR j.worker_id = v_uid))
          OR EXISTS (SELECT 1 FROM public.requests r
                     WHERE r.id = p_request_id AND r.customer_id = v_uid
                       AND r.status IN ('confirmed', 'settlement_pending', 'settled', 'closed',
                                        'disputed', 'refunded'))
          OR private.has_admin_role(ARRAY['super_admin']::public.admin_role[])
          OR private.dispute_scope(p_request_id)) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  -- Staff reads are logged; the two people who were on the job reading their own trip are not,
  -- because an audit row per replay would bury the reads that matter.
  IF v_uid IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.jobs j
                     WHERE j.request_id = p_request_id
                       AND (j.provider_id = v_uid OR j.worker_id = v_uid))
     AND NOT EXISTS (SELECT 1 FROM public.requests r
                     WHERE r.id = p_request_id AND r.customer_id = v_uid) THEN
    PERFORM private.audit_write('location.trail_read', 'public.location_samples',
      p_request_id::text, NULL, jsonb_build_object('request_id', p_request_id), NULL);
  END IF;

  RETURN QUERY
  SELECT s.recorded_at,
         extensions.ST_Y(s.pos::extensions.geometry),
         extensions.ST_X(s.pos::extensions.geometry),
         s.heading, s.speed_cm_s, s.accuracy_m, s.is_mock
  FROM public.location_samples s
  WHERE s.request_id = p_request_id
  ORDER BY s.recorded_at;
END $$;

REVOKE ALL ON FUNCTION
  private.drop_expired_location_partitions(),
  public.job_trail(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.job_trail(uuid) TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('location_retention_days', NULL, '90', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('location-sample-partitions', '21 3 * * *',
      $cron$SELECT private.ensure_monthly_partitions('public.location_samples'::regclass)$cron$);
    PERFORM cron.schedule('location-retention', '23 3 * * *',
      $cron$SELECT private.drop_expired_location_partitions()$cron$);
  END IF;
END $$;
