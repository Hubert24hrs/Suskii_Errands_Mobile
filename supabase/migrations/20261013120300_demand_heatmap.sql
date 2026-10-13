-- The provider's demand heatmap, the last provider tool (CR-20260923-05). Audit 2026-10-13 left it
-- "not available" because aggregating customers' pickup points needs a privacy design of its own.
-- This is that design:
--
--   * Cells, not points. Open requests are counted on a fixed grid (`demand_heatmap_cell_deg`,
--     0.02 degrees, about 2 km of latitude) and a cell reports its centre, never a pickup.
--   * k-anonymity. A cell with fewer than `demand_heatmap_min_requests` (5) open requests is not
--     reported at all, so a lone request -- one customer's home -- never shows. The floor cannot
--     be configured below 2.
--   * Who and what. An active, verified provider, for their own country and the categories they
--     serve: requests the feed would put in front of them one by one anyway. Open requests only,
--     and nothing in the answer names a customer, a category or a price.

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('demand_heatmap_cell_deg', NULL, '0.02', false),
  ('demand_heatmap_min_requests', NULL, '5', false);

CREATE FUNCTION public.provider_demand_heatmap()
RETURNS TABLE (cell_id text, center_lat double precision, center_lng double precision,
               open_requests integer, intensity numeric, label text)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_cell    numeric;
  v_k       integer;
BEGIN
  PERFORM private.require_active_provider(v_uid);
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;

  SELECT (rc.value #>> '{}')::numeric INTO v_cell FROM public.remote_config rc
  WHERE rc.key = 'demand_heatmap_cell_deg' AND rc.country_code IS NULL
    AND jsonb_typeof(rc.value) = 'number';
  v_cell := least(greatest(coalesce(v_cell, 0.02), 0.005), 0.5);
  v_k := greatest(coalesce(private.remote_config_int('demand_heatmap_min_requests'), 5), 2);

  RETURN QUERY
  WITH cells AS (
    SELECT floor(extensions.ST_Y(r.pickup_point::extensions.geometry) / v_cell)::bigint AS cy,
           floor(extensions.ST_X(r.pickup_point::extensions.geometry) / v_cell)::bigint AS cx,
           count(*)::integer AS n
    FROM public.requests r
    WHERE r.status IN ('published', 'offers_received', 'negotiating')
      AND r.country_code = v_country
      AND r.customer_id <> v_uid
      AND (r.expires_at IS NULL OR r.expires_at > now())
      AND r.pickup_point IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.provider_services ps
                  WHERE ps.provider_id = v_uid AND ps.category_id = r.category_id)
    GROUP BY 1, 2
    HAVING count(*) >= v_k
  ), centred AS (
    SELECT c.cy, c.cx, c.n,
           extensions.ST_SetSRID(extensions.ST_MakePoint(((c.cx + 0.5) * v_cell)::float8,
                                                         ((c.cy + 0.5) * v_cell)::float8),
                                 4326)::extensions.geography AS centre
    FROM cells c
  )
  SELECT c.cy::text || ':' || c.cx::text,
         extensions.ST_Y(c.centre::extensions.geometry),
         extensions.ST_X(c.centre::extensions.geometry),
         c.n,
         round(c.n::numeric / max(c.n) OVER (), 2),
         coalesce(
           (SELECT z.name FROM public.zones z
            JOIN public.cities ci ON ci.id = z.city_id AND ci.country_code = v_country
            WHERE extensions.ST_Intersects(z.boundary, c.centre) LIMIT 1),
           (SELECT ci.name FROM public.cities ci
            WHERE ci.country_code = v_country AND ci.center IS NOT NULL
            ORDER BY ci.center OPERATOR(extensions.<->) c.centre LIMIT 1),
           '')
  FROM centred c
  ORDER BY c.n DESC, 1
  LIMIT 50;
END $$;

REVOKE ALL ON FUNCTION public.provider_demand_heatmap() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provider_demand_heatmap() TO authenticated;
