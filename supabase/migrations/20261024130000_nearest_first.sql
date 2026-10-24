-- The customer is served by the providers closest to them (owner decision 2026-10-24, ADR-0022).
-- Offers and negotiation stay; what changes is who hears first and what the customer sees:
--
--   * Matching puts the nearest providers first. Candidates are grouped in 500 m bands and the
--     score orders a band; before this the score ordered everybody, so a well-rated provider
--     4 km away was told before an ordinary one round the corner.
--   * When nobody is within 5 km the search widens, 5 -> 15 -> 30 km
--     (`matching_radius_ladder_m`), instead of announcing to nobody and waiting for the sweep.
--   * Every offer carries how far its provider is from the pickup, rounded to 0.5 km.
--   * Before booking the customer sees how many providers are near and roughly where: counts on a
--     ~1 km grid, a cell shown only with at least `nearby_providers_min_per_cell` (3) providers in
--     it. Never a provider's position; that stays behind payment, as live tracking always was.

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('matching_radius_ladder_m', NULL, '[5000, 15000, 30000]', false),
  ('nearby_providers_min_per_cell', NULL, '3', false),
  ('nearby_providers_cell_deg', NULL, '0.01', false);

-- Replaced from its latest version (20260918120800) with one change: the ORDER BY.
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
      AND NOT private.is_blocked_pair(v_request.customer_id, pp.user_id)
      -- BU-09: the zone decides which vehicle may work there.
      AND private.vehicle_allowed_at(v_request.pickup_point, pp.vehicle_type)
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

-- Replaced from 20260918120900 so that nobody nearby means looking further, not giving up.
CREATE OR REPLACE FUNCTION private.fan_out_request(p_request_id uuid, p_limit integer DEFAULT 20,
                                                   p_radius_m integer DEFAULT 5000)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_row     record;
  v_count   integer := 0;
  v_found   boolean := false;
  v_ladder  jsonb;
  v_radius  integer;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND OR v_request.status NOT IN ('published', 'offers_received', 'negotiating') THEN
    RETURN 0;
  END IF;

  v_ladder := private.remote_config_json('matching_radius_ladder_m', v_request.country_code);
  IF v_ladder IS NULL OR jsonb_typeof(v_ladder) <> 'array' THEN
    v_ladder := '[]'::jsonb;
  END IF;

  -- The caller's radius first, then each wider rung; stop at the first radius with anybody in it.
  FOR v_radius IN
    SELECT r FROM (
      SELECT coalesce(p_radius_m, 5000) AS r, 0 AS o
      UNION
      SELECT (e #>> '{}')::integer, 1 FROM jsonb_array_elements(v_ladder) AS e
      WHERE jsonb_typeof(e) = 'number' AND (e #>> '{}')::integer > coalesce(p_radius_m, 5000)
    ) rungs ORDER BY r
  LOOP
    FOR v_row IN
      SELECT m.provider_id, m.distance_m
      FROM private.match_providers(p_request_id, p_limit, v_radius) m
    LOOP
      v_found := true;
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
    EXIT WHEN v_found;
  END LOOP;
  RETURN v_count;
END $$;

-- The return type gains `distance_km`, so the function is dropped and recreated (ADR-0013's rule
-- for a changed signature); the body is 20260922121100's with the distance added.
DROP FUNCTION public.rank_offers(uuid);

CREATE FUNCTION public.rank_offers(p_request_id uuid)
RETURNS TABLE (offer_id uuid, provider_id uuid, display_name text, amount_minor bigint,
               currency char(3), score numeric, rating_avg_milli integer, rating_count integer,
               completion_rate_bps integer, factors jsonb, distance_km numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_min    bigint;
  v_max    bigint;
  v_pickup extensions.geography;
BEGIN
  SELECT r.pickup_point INTO v_pickup FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT min(o.amount_minor), max(o.amount_minor) INTO v_min, v_max
  FROM public.offers o
  WHERE o.request_id = p_request_id AND o.status IN ('pending', 'countered');

  RETURN QUERY
  SELECT o.id, o.provider_id, p.display_name, o.amount_minor, o.currency,
         round(
           0.5 * CASE WHEN v_max = v_min THEN 1.0
                      ELSE (v_max - o.amount_minor)::numeric / (v_max - v_min) END
         + 0.3 * CASE WHEN pp.rating_count = 0 THEN 0.6
                      ELSE pp.rating_avg_milli / 5000.0 END
         + 0.2 * (pp.completion_rate_bps / 10000.0), 4),
         pp.rating_avg_milli, pp.rating_count, pp.completion_rate_bps,
         jsonb_build_object(
           'cheapest', o.amount_minor = v_min,
           'offers_compared', (SELECT count(*) FROM public.offers o2
                               WHERE o2.request_id = p_request_id
                                 AND o2.status IN ('pending', 'countered')),
           'new_provider', pp.rating_count = 0),
         -- From the provider's last fix in the past 30 minutes to the customer's own pickup, in
         -- half-kilometre steps and never below 0.5: how far, not where.
         (SELECT greatest(round((extensions.ST_Distance(l.pos, v_pickup) / 500)::numeric) * 0.5,
                          0.5)
          FROM public.provider_live_location l
          WHERE l.provider_id = o.provider_id AND v_pickup IS NOT NULL
            AND l.updated_at > now() - interval '30 minutes')
  FROM public.offers o
  JOIN public.profiles p ON p.user_id = o.provider_id
  JOIN public.provider_profiles pp ON pp.user_id = o.provider_id
  WHERE o.request_id = p_request_id AND o.status IN ('pending', 'countered')
  ORDER BY 6 DESC, o.amount_minor;
END $$;

REVOKE ALL ON FUNCTION public.rank_offers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rank_offers(uuid) TO authenticated;

-- How many providers are near, and roughly where. Aggregates only: the answer has a total and grid
-- cells, never a provider. `p_category_key` NULL means any service.
CREATE FUNCTION public.nearby_providers(
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
      AND private.is_active_provider(pp.user_id)
      AND l.updated_at > now() - interval '2 minutes'
      AND extensions.ST_DWithin(l.pos, v_point, v_radius)
      AND (v_category IS NULL OR EXISTS (
            SELECT 1 FROM public.provider_services ps
            WHERE ps.provider_id = pp.user_id AND ps.category_id = v_category))
      AND NOT private.is_blocked_pair(v_uid, pp.user_id)
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

REVOKE ALL ON FUNCTION public.nearby_providers(double precision, double precision, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nearby_providers(double precision, double precision, text, integer)
  TO authenticated;
