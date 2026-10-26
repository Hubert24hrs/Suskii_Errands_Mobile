-- The nearest-provider query and matching, as set operations.
--
-- Load-tested on staging (2026-10-26) at the launch profile, 10,000 online providers around Lagos:
-- `nearby_providers` took p50 66 ms and p95 70 ms against a target of 50 ms, with p99 over 500 ms.
-- Both functions called `private.is_blocked_pair` (and `nearby_providers` `is_active_provider`, and
-- `match_providers` `vehicle_allowed_at`) once per candidate, because a function with a SET clause
-- is never inlined. The same query with the checks as joins measured p95 17 ms on the same data,
-- with identical answers at all 200 points.
--
-- `match_providers` also learns the organisation suspension `is_active_provider` gained in Phase 8:
-- it wrote its own provider checks and never had it, so a suspended business's workers were still
-- matched and notified about requests they could not bid on.

CREATE OR REPLACE FUNCTION public.nearby_providers(
  p_lat double precision, p_lng double precision, p_category_key text DEFAULT NULL,
  p_radius_m integer DEFAULT 5000)
RETURNS TABLE (total integer, radius_m integer, areas jsonb)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_country  char(2);
  v_point    extensions.geography(Point, 4326);
  v_radius   integer := least(greatest(coalesce(p_radius_m, 5000), 500), 30000);
  v_cell     numeric;
  v_k        integer;
  v_category uuid;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL
     OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_country := private.require_profile_country(v_uid);
  IF p_category_key IS NOT NULL THEN
    SELECT c.id INTO v_category FROM public.service_categories c
    WHERE c.key = p_category_key AND c.active;
    IF v_category IS NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT (rc.value #>> '{}')::numeric INTO v_cell FROM public.remote_config rc
  WHERE rc.key = 'nearby_providers_cell_deg' AND rc.country_code IS NULL
    AND jsonb_typeof(rc.value) = 'number';
  v_cell := least(greatest(coalesce(v_cell, 0.01), 0.005), 0.1);
  v_k := greatest(coalesce(private.remote_config_int('nearby_providers_min_per_cell'), 3), 2);
  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;

  RETURN QUERY
  WITH near AS (
    SELECT l.pos
    FROM public.provider_profiles pp
    JOIN public.profiles pr ON pr.user_id = pp.user_id
    JOIN public.provider_live_location l ON l.provider_id = pp.user_id
    WHERE pp.online
      AND pp.user_id <> v_uid
      AND pr.country_code = v_country
      -- private.is_active_provider, written as joins: a function with a SET clause is never
      -- inlined, so calling it here ran it once per candidate. Keep the two in step;
      -- 66_matching_set_based_test holds them together.
      AND pr.provider_verification = 'verified'
      AND (pp.suspended_until IS NULL OR pp.suspended_until <= now())
      AND NOT EXISTS (
            SELECT 1 FROM public.organization_members m
            JOIN public.organizations o ON o.id = m.organization_id
            WHERE m.user_id = pp.user_id AND m.status = 'active'
              AND o.suspended_until IS NOT NULL AND o.suspended_until > now())
      AND l.updated_at > now() - interval '2 minutes'
      AND extensions.ST_DWithin(l.pos, v_point, v_radius)
      AND (v_category IS NULL OR EXISTS (
            SELECT 1 FROM public.provider_services ps
            WHERE ps.provider_id = pp.user_id AND ps.category_id = v_category))
      -- private.is_blocked_pair, both directions, as anti-joins.
      AND NOT EXISTS (SELECT 1 FROM public.blocks b WHERE b.blocker_id = v_uid AND b.blocked_id = pp.user_id)
      AND NOT EXISTS (SELECT 1 FROM public.blocks b WHERE b.blocker_id = pp.user_id AND b.blocked_id = v_uid)
  ), cells AS (
    SELECT floor(extensions.ST_Y(n.pos::extensions.geometry) / v_cell) AS cy,
           floor(extensions.ST_X(n.pos::extensions.geometry) / v_cell) AS cx,
           count(*)::integer AS c
    FROM near n GROUP BY 1, 2
    HAVING count(*) >= v_k
  )
  SELECT (SELECT count(*)::integer FROM near),
         v_radius,
         coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'lat', ((cl.cy + 0.5) * v_cell)::float8,
                     'lng', ((cl.cx + 0.5) * v_cell)::float8,
                     'providers', cl.c) ORDER BY cl.c DESC)
                   FROM cells cl), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION private.match_providers(
  p_request_id uuid, p_limit integer DEFAULT 20, p_radius_m integer DEFAULT 5000)
RETURNS TABLE (provider_id uuid, distance_m integer, score_milli integer)
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_w       jsonb;
  v_radius  integer := least(greatest(coalesce(p_radius_m, 5000), 100), 50000);
  v_limit   integer := least(greatest(coalesce(p_limit, 20), 1), 200);
  w_dist    double precision;
  w_rating  double precision;
  w_compl   double precision;
  w_cancel  double precision;
  w_resp    double precision;
  w_load    double precision;
  w_total   double precision;
  v_vehicles public.vehicle_type[];
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.pickup_point IS NULL THEN
    RETURN;
  END IF;

  v_w := coalesce(private.remote_config_json('matching_weights', v_request.country_code),
                  '{}'::jsonb);
  w_dist   := coalesce((v_w ->> 'distance')::double precision, 40);
  w_rating := coalesce((v_w ->> 'rating')::double precision, 20);
  w_compl  := coalesce((v_w ->> 'completion')::double precision, 15);
  w_resp   := coalesce((v_w ->> 'response')::double precision, 10);
  w_cancel := coalesce((v_w ->> 'cancellation')::double precision, 15);
  w_load   := coalesce((v_w ->> 'workload')::double precision, 10);
  w_total  := greatest(w_dist + w_rating + w_compl + w_resp, 1);
  -- Which vehicles the pickup's zones allow, once, rather than once per candidate.
  v_vehicles := ARRAY(SELECT vt FROM unnest(enum_range(NULL::public.vehicle_type)) vt
                      WHERE private.vehicle_allowed_at(v_request.pickup_point, vt));

  RETURN QUERY
  WITH candidate AS (
    SELECT pp.user_id,
           extensions.ST_Distance(l.pos, v_request.pickup_point) AS d,
           pp.rating_avg_milli,
           pp.rating_count,
           pp.completion_rate_bps,
           pp.cancellation_rate_bps,
           pp.response_time_p50_s,
           (SELECT count(*) FROM public.offers o
            JOIN public.requests r2 ON r2.id = o.request_id
            WHERE o.provider_id = pp.user_id AND o.status = 'accepted'
              AND r2.status = 'agreed') AS active_jobs,
           EXISTS (SELECT 1 FROM public.favorites f
                   WHERE f.customer_id = v_request.customer_id
                     AND f.provider_id = pp.user_id) AS favoured
    FROM public.provider_profiles pp
    JOIN public.profiles p ON p.user_id = pp.user_id
    JOIN public.provider_services ps
      ON ps.provider_id = pp.user_id AND ps.category_id = v_request.category_id
    JOIN public.provider_live_location l
      ON l.provider_id = pp.user_id AND l.updated_at > now() - interval '2 minutes'
    WHERE pp.online
      AND (pp.suspended_until IS NULL OR pp.suspended_until <= now())
      AND p.provider_verification = 'verified'
      AND p.country_code = v_request.country_code
      AND pp.user_id <> v_request.customer_id
      AND extensions.ST_DWithin(l.pos, v_request.pickup_point, v_radius)
      -- A worker whose business is suspended is not active (private.is_active_provider). This
      -- check was missing here, so such a worker was still matched and notified, and could not bid.
      AND NOT EXISTS (
            SELECT 1 FROM public.organization_members m
            JOIN public.organizations o ON o.id = m.organization_id
            WHERE m.user_id = pp.user_id AND m.status = 'active'
              AND o.suspended_until IS NOT NULL AND o.suspended_until > now())
      AND NOT EXISTS (SELECT 1 FROM public.blocks b
                      WHERE b.blocker_id = v_request.customer_id AND b.blocked_id = pp.user_id)
      AND NOT EXISTS (SELECT 1 FROM public.blocks b
                      WHERE b.blocker_id = pp.user_id AND b.blocked_id = v_request.customer_id)
      -- BU-09: the zone decides which vehicle may work there. No vehicle is not a vehicle.
      AND (pp.vehicle_type IS NULL OR pp.vehicle_type = ANY (v_vehicles))
      AND NOT EXISTS (SELECT 1 FROM public.offer_threads t
                      WHERE t.request_id = v_request.id AND t.provider_id = pp.user_id)
  )
  SELECT c.user_id,
         c.d::integer,
         (1000 * (
             w_dist   * (1 - least(c.d, v_radius::double precision) / v_radius)
           + w_rating * (CASE WHEN c.rating_count = 0 THEN 0.6::double precision
                              ELSE c.rating_avg_milli::double precision / 5000 END)
           + w_compl  * (c.completion_rate_bps::double precision / 10000)
           + w_resp   * (1 - least(coalesce(c.response_time_p50_s, 300), 900)::double precision / 900)
           - w_cancel * (c.cancellation_rate_bps::double precision / 10000)
           - w_load   * (least(c.active_jobs, 3)::double precision / 3)
           + CASE WHEN c.favoured THEN 0.1 * w_total ELSE 0 END
         ) / w_total)::integer
  FROM candidate c
  -- Nearest first: 500 m bands, then the score within a band, then the exact distance.
  ORDER BY floor(c.d / 500), 3 DESC, 2 ASC
  LIMIT v_limit;
END $$;
