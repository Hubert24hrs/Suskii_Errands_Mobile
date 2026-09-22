-- Phase 7, part 1: the concierge's tool surface (`docs/plan/ai-design.md` §4.1, §4.3, §9;
-- spec phase 7; ADR-0012).
--
-- **No model is involved in any of this, and that is the point.** ai-design §4.1's first line is
-- "every tool is a thin wrapper over an RPC the app already calls"; some of those RPCs did not
-- exist. They are built here, as ordinary database functions with ordinary RLS, and they are
-- useful to the app whether or not the AI service is ever deployed: `rank_offers` is what the
-- offers board's "AI compare" actually runs on, `get_price_band` is the price hint on the request
-- form, `get_availability_summary` is "are there people nearby" before somebody types anything.
--
-- What is *not* built here is the FastAPI service that would call them. It runs on Cloud Run
-- against Vertex AI, and both need GCP billing (timeline action 1). Building the tools first is
-- the right order regardless: ADR-0012's containment is that the tool surface is the boundary, so
-- the boundary should exist and be tested before anything is pointed at it.
--
-- **Two of these read beyond the caller's own rows** (§4.3), so both are `SECURITY DEFINER` with
-- an explicit ownership test and a deliberately thin return:
--
--   * `get_availability_summary` returns **counts and a response time, never a provider** — no
--     name, no id, no position. "Seven couriers are online near you" is a useful answer; "Emeka
--     is 400 m away" is a surveillance tool.
--   * `rank_offers` requires the caller to own the request, and returns the provider's display
--     name and nothing else about them. The card comes from `get_provider_card`, which has its
--     own reason test.

-- ---------------------------------------------------------------------------
-- Price bands (§9). Rules first: the cold-start band is the country's own guardrails, which ops
-- already maintain, widened by urgency. History replaces it per cell once there is enough of it.
--
-- `basis` and `sample_size` travel with every band, because a band the UI presents as confident
-- when it rests on four jobs is worse than no band at all.
-- ---------------------------------------------------------------------------
CREATE TABLE public.price_bands (
  country_code  char(2) NOT NULL REFERENCES public.countries (code),
  category_id   uuid    NOT NULL REFERENCES public.service_categories (id) ON DELETE CASCADE,
  city_id       uuid    REFERENCES public.cities (id) ON DELETE CASCADE,
  urgency       public.urgency NOT NULL,
  currency      char(3) NOT NULL REFERENCES public.currencies (code),
  p25_minor     bigint NOT NULL CHECK (p25_minor > 0),
  p50_minor     bigint NOT NULL CHECK (p50_minor > 0),
  p75_minor     bigint NOT NULL CHECK (p75_minor > 0),
  sample_size   integer NOT NULL CHECK (sample_size >= 0),
  computed_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT price_bands_ordered CHECK (p25_minor <= p50_minor AND p50_minor <= p75_minor)
);
-- `coalesce`, because a unique index over a nullable column would let the country-wide band for
-- a cell exist twice — the same trap `ledger.accounts` has for a platform account's NULL owner.
CREATE UNIQUE INDEX price_bands_cell ON public.price_bands
  (country_code, category_id, urgency, currency,
   coalesce(city_id, '00000000-0000-0000-0000-000000000000'::uuid));

ALTER TABLE public.price_bands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_bands FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.price_bands FROM anon, authenticated;
GRANT ALL ON public.price_bands TO service_role;
-- No client policy: a band is read through `get_price_band`, which widens it by urgency and says
-- what it is based on. A raw row read straight would lose the `basis` and be presented as fact.

-- The nightly recompute. `min_price_band_samples` is the [A] threshold from §9 — fifty completed
-- jobs in a cell — and is remote config so it can be lowered for a thin launch country without a
-- migration.
CREATE FUNCTION private.recompute_price_bands()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_min   integer := coalesce(private.remote_config_int('min_price_band_samples'), 50);
  v_count integer;
BEGIN
  -- Currency-native throughout: a band is never converted, because a converted band is a
  -- statement about an exchange rate rather than about a market.
  WITH agreed AS (
    SELECT r.country_code, r.category_id, r.city_id, r.urgency, j.currency,
           j.agreed_amount_minor AS amount
    FROM public.jobs j
    JOIN public.requests r ON r.id = j.request_id
    WHERE j.confirmed_at IS NOT NULL
      AND j.confirmed_at > now() - interval '90 days'
  ),
  bounds AS (
    -- Outliers cut at the 5th and 95th percentile of the cell before the quantiles are taken, so
    -- one 500,000 errand does not become the market. Two passes rather than a window, because
    -- `percentile_cont` is an ordered-set aggregate and cannot be one.
    SELECT a.country_code, a.category_id, a.city_id, a.urgency, a.currency,
           percentile_cont(0.05) WITHIN GROUP (ORDER BY a.amount) AS lo,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY a.amount) AS hi
    FROM agreed a
    GROUP BY 1, 2, 3, 4, 5
  ),
  trimmed AS (
    SELECT a.*
    FROM agreed a
    JOIN bounds b
      ON b.country_code = a.country_code AND b.category_id = a.category_id
     -- `IS NOT DISTINCT FROM`: a country-wide cell has a NULL city, and `=` would drop it.
     AND b.city_id IS NOT DISTINCT FROM a.city_id
     AND b.urgency = a.urgency AND b.currency = a.currency
    WHERE a.amount BETWEEN b.lo AND b.hi
  ),
  bands AS (
    SELECT country_code, category_id, city_id, urgency, currency,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY amount)::bigint AS p25,
           percentile_cont(0.50) WITHIN GROUP (ORDER BY amount)::bigint AS p50,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY amount)::bigint AS p75,
           count(*)::integer AS n
    FROM trimmed
    GROUP BY country_code, category_id, city_id, urgency, currency
    HAVING count(*) >= v_min
  )
  INSERT INTO public.price_bands (country_code, category_id, city_id, urgency, currency,
                                  p25_minor, p50_minor, p75_minor, sample_size, computed_at)
  SELECT country_code, category_id, city_id, urgency, currency,
         greatest(p25, 1), greatest(p50, 1), greatest(p75, 1), n, now()
  FROM bands
  ON CONFLICT (country_code, category_id, urgency, currency,
               coalesce(city_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET p25_minor = excluded.p25_minor, p50_minor = excluded.p50_minor,
                p75_minor = excluded.p75_minor, sample_size = excluded.sample_size,
                computed_at = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

CREATE FUNCTION public.get_price_band(
  p_category_id uuid, p_urgency public.urgency DEFAULT 'standard', p_city_id uuid DEFAULT NULL)
RETURNS TABLE (p25_minor bigint, p50_minor bigint, p75_minor bigint, currency char(3),
               sample_size integer, basis text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_country  char(2);
  v_currency char(3);
  v_band     public.price_bands%ROWTYPE;
  v_rail     public.pricing_guardrails%ROWTYPE;
  v_mult     numeric;
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.currency_code INTO v_currency FROM public.countries c WHERE c.code = v_country;

  -- The city's own band first, the country's as a fallback: a Lagos price is not an Abuja price,
  -- but an Abuja price beats no price.
  SELECT * INTO v_band FROM public.price_bands b
  WHERE b.country_code = v_country AND b.category_id = p_category_id
    AND b.urgency = p_urgency AND b.currency = v_currency
    AND (b.city_id = p_city_id OR b.city_id IS NULL)
  ORDER BY b.city_id NULLS LAST
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY SELECT v_band.p25_minor, v_band.p50_minor, v_band.p75_minor, v_currency,
                        v_band.sample_size, 'history'::text;
    RETURN;
  END IF;

  -- Cold start: the country's guardrails, which ops already maintain for the offer rules, so a
  -- band and a refusal can never disagree about what this category is worth.
  SELECT * INTO v_rail FROM public.pricing_guardrails g
  WHERE g.country_code = v_country AND g.category_id = p_category_id;
  IF NOT FOUND THEN
    RETURN;   -- no band at all is an honest answer; the form shows no hint
  END IF;

  -- Urgency moves the band, because it moves what people actually agree to. Multipliers are
  -- the cold-start guess and the history path replaces them cell by cell.
  v_mult := CASE p_urgency WHEN 'emergency' THEN 1.5 WHEN 'urgent' THEN 1.25
                           WHEN 'flexible' THEN 0.9 ELSE 1.0 END;
  RETURN QUERY SELECT
    private.round_half_even(v_rail.soft_min_minor * v_mult)::bigint,
    private.round_half_even((v_rail.soft_min_minor + v_rail.soft_max_minor) / 2.0 * v_mult)::bigint,
    private.round_half_even(v_rail.soft_max_minor * v_mult)::bigint,
    v_currency, 0, 'rules'::text;
END $$;

-- ---------------------------------------------------------------------------
-- Availability (§4.3). Counts and a response time. **Never a provider.**
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_availability_summary(
  p_category_id uuid, p_lat double precision, p_lng double precision,
  p_radius_m integer DEFAULT 5000)
RETURNS TABLE (providers_online integer, response_time_p50_s integer, radius_m integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_point   extensions.geography(Point, 4326);
  v_radius  integer := least(greatest(coalesce(p_radius_m, 5000), 500), 20000);
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL
     OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;

  RETURN QUERY
  SELECT count(*)::integer,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY pp.response_time_p50_s)::integer,
         v_radius
  FROM public.provider_profiles pp
  JOIN public.profiles pr ON pr.user_id = pp.user_id
  JOIN public.provider_live_location l ON l.provider_id = pp.user_id
  JOIN public.provider_services ps ON ps.provider_id = pp.user_id
                                  AND ps.category_id = p_category_id
  WHERE pp.online
    AND pr.country_code = v_country
    AND private.is_active_provider(pp.user_id)
    AND l.updated_at > now() - interval '2 minutes'
    AND extensions.ST_DWithin(l.pos, v_point, v_radius);
END $$;

-- ---------------------------------------------------------------------------
-- Offer ranking (§4.1 `compare_offers`). Deterministic, and the same weights the matcher uses so
-- the platform does not rank providers one way when it suggests them and another way when it
-- compares them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rank_offers(p_request_id uuid)
RETURNS TABLE (offer_id uuid, provider_id uuid, display_name text, amount_minor bigint,
               currency char(3), score numeric, rating_avg_milli integer, rating_count integer,
               completion_rate_bps integer, factors jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
  v_min bigint;
  v_max bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = p_request_id AND r.customer_id = v_uid) THEN
    -- Somebody else's offers are not admitted to exist, the same answer the table gives.
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT min(o.amount_minor), max(o.amount_minor) INTO v_min, v_max
  FROM public.offers o
  WHERE o.request_id = p_request_id AND o.status IN ('pending', 'countered');

  RETURN QUERY
  SELECT o.id, o.provider_id, p.display_name, o.amount_minor, o.currency,
         -- Price is half the answer and reputation the other half. Price is scored relative to
         -- the offers actually on the table rather than against an absolute, because "cheap" only
         -- means anything next to the alternatives.
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
           -- A provider with no ratings scores a neutral 0.6 rather than zero, the same bias the
           -- matcher takes: a marketplace that starves newcomers never gets a second provider.
           'new_provider', pp.rating_count = 0)
  FROM public.offers o
  JOIN public.profiles p ON p.user_id = o.provider_id
  JOIN public.provider_profiles pp ON pp.user_id = o.provider_id
  WHERE o.request_id = p_request_id AND o.status IN ('pending', 'countered')
  ORDER BY 6 DESC, o.amount_minor;
END $$;

-- ---------------------------------------------------------------------------
-- Job summary and category requirements: thin reads the app wants anyway.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_job_summary(p_request_id uuid)
RETURNS TABLE (request_id uuid, status public.job_status, category_key text,
               agreed_amount_minor bigint, currency char(3), assigned_at timestamptz,
               en_route_at timestamptz, arrived_at timestamptz, completed_at timestamptz,
               confirmed_at timestamptz, delivery_pin_required boolean, next_step text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Read-only, so nothing here needs the caller's id; `is_job_participant` reads `auth.uid()`
  -- itself, and it needs there to be a caller.
  PERFORM private.require_user();
  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  SELECT r.id, r.status, sc.key, j.agreed_amount_minor, j.currency,
         j.assigned_at, j.en_route_at, j.arrived_at, j.completed_at, j.confirmed_at,
         j.delivery_pin_required,
         -- A key, not a sentence: the app translates it, and the concierge reads it rather than
         -- inventing one.
         CASE r.status
           WHEN 'paid_held'              THEN 'job.next.await_assignment'
           WHEN 'assigned'               THEN 'job.next.provider_on_the_way'
           WHEN 'en_route'               THEN 'job.next.track'
           WHEN 'arrived'                THEN 'job.next.share_pickup_pin'
           WHEN 'in_progress'            THEN 'job.next.in_progress'
           WHEN 'completed_by_provider'  THEN 'job.next.confirm_completion'
           WHEN 'confirmed'              THEN 'job.next.rate'
           WHEN 'disputed'               THEN 'job.next.dispute_open'
           ELSE 'job.next.none'
         END
  FROM public.requests r
  LEFT JOIN public.jobs j ON j.request_id = r.id
  LEFT JOIN public.service_categories sc ON sc.id = r.category_id
  WHERE r.id = p_request_id;
END $$;

CREATE FUNCTION public.get_category_requirements(p_category_id uuid)
RETURNS TABLE (category_id uuid, category_key text, requires_vehicle boolean,
               allows_custom boolean, proof_requirements jsonb, offer_ttl_seconds integer,
               allows_item_float boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  RETURN QUERY
  SELECT sc.id, sc.key, sc.requires_vehicle, sc.allows_custom, sc.proof_requirements,
         sc.offer_ttl_seconds,
         -- A float is for categories that involve buying something; the receipt requirement is
         -- the honest signal for that, rather than a second column somebody has to remember.
         coalesce(sc.proof_requirements ? 'receipt', false)
  FROM public.service_categories sc
  WHERE sc.id = p_category_id AND sc.active;
END $$;

REVOKE ALL ON FUNCTION
  private.recompute_price_bands(),
  public.get_price_band(uuid, public.urgency, uuid),
  public.get_availability_summary(uuid, double precision, double precision, integer),
  public.rank_offers(uuid),
  public.get_job_summary(uuid),
  public.get_category_requirements(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.get_price_band(uuid, public.urgency, uuid),
  public.get_availability_summary(uuid, double precision, double precision, integer),
  public.rank_offers(uuid),
  public.get_job_summary(uuid),
  public.get_category_requirements(uuid)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- §9's [A]: fifty completed jobs in a cell before history replaces the rules. Config, so a thin
  -- launch country can lower it without a migration and without pretending it is the same number.
  ('min_price_band_samples', NULL, '50', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('price-bands', '41 2 * * *',
      $cron$SELECT private.recompute_price_bands()$cron$);
  END IF;
END $$;
