-- Marketplace, part 3: the provider side and matching (ERD §3 and §9; RLS matrix §3;
-- ADR-0009 and spike S-06; matching design in docs/plan/ai-design.md §9).
--
-- The rule this migration exists to keep: **a provider never selects `requests`.** The feed is a
-- function that takes the provider's own position, their registered categories and their country,
-- and returns only what they are allowed to bid on. Nothing here lets one enumerate the market.
--
-- Three things S-06 measured, applied as written:
--   * heartbeats are gated on movement, because write rate — not query shape — is the limit;
--   * the hot location table is tuned for churn (fillfactor, aggressive autovacuum), because
--     bloat is what eventually degrades the query;
--   * the feed searches a **single** radius; the widening variant was the worst under write load.
--
-- Two departures from the ERD, both deliberate and recorded there: `rating_bayes numeric(3,2)`
-- is `rating_avg_milli integer` (public has no numeric or floating-point columns — the structure
-- test enforces it), and `provider_service_areas.zone_ids` waits for a zones table rather than
-- being a uuid[] pointing at nothing.

-- ---------------------------------------------------------------------------
-- provider_profiles
-- ---------------------------------------------------------------------------
CREATE TABLE public.provider_profiles (
  user_id               uuid PRIMARY KEY REFERENCES public.profiles (user_id) ON DELETE RESTRICT,
  kind                  public.provider_kind NOT NULL DEFAULT 'individual',
  bio                   text CHECK (bio IS NULL OR length(bio) <= 500),
  vehicle_type          public.vehicle_type,
  online                boolean NOT NULL DEFAULT false,
  online_since          timestamptz,
  suspended_until       timestamptz,
  suspension_reason_key text CHECK (suspension_reason_key IS NULL OR length(suspension_reason_key) <= 60),
  -- Reputation aggregates, written by the reputation job only — never by a client, and never by
  -- a trigger on rating insert (ERD §5). Stars are thousandths of a star: 4.73 is 4730.
  rating_avg_milli      integer NOT NULL DEFAULT 0 CHECK (rating_avg_milli BETWEEN 0 AND 5000),
  rating_count          integer NOT NULL DEFAULT 0 CHECK (rating_count >= 0),
  -- A provider with no history has nothing held against them: the cold-start defaults favour
  -- newcomers, which is the right bias while supply is thin. The reputation job overwrites them.
  completion_rate_bps   integer NOT NULL DEFAULT 10000 CHECK (completion_rate_bps BETWEEN 0 AND 10000),
  cancellation_rate_bps integer NOT NULL DEFAULT 0 CHECK (cancellation_rate_bps BETWEEN 0 AND 10000),
  response_time_p50_s   integer CHECK (response_time_p50_s IS NULL OR response_time_p50_s >= 0),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX provider_profiles_available ON public.provider_profiles (user_id)
  WHERE online AND suspended_until IS NULL;
CREATE TRIGGER provider_profiles_touch BEFORE UPDATE ON public.provider_profiles
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.provider_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_profiles FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.provider_profiles FROM anon, authenticated;
GRANT SELECT ON public.provider_profiles TO authenticated;
-- `online`, the suspension fields and every aggregate are server-owned: `online` moves through
-- `set_online()`, which has checks a column grant cannot express (RLS matrix §3).
GRANT UPDATE (bio, vehicle_type) ON public.provider_profiles TO authenticated;
GRANT ALL ON public.provider_profiles TO service_role;
CREATE POLICY provider_profiles_read_own ON public.provider_profiles FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));
CREATE POLICY provider_profiles_update_own ON public.provider_profiles FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- What a provider does, and where. Rows rather than array columns, so matching can index them.
-- ---------------------------------------------------------------------------
CREATE TABLE public.provider_services (
  provider_id       uuid NOT NULL REFERENCES public.provider_profiles (user_id) ON DELETE CASCADE,
  category_id       uuid NOT NULL REFERENCES public.service_categories (id) ON DELETE CASCADE,
  credential_status public.verification_status NOT NULL DEFAULT 'unverified',
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_id, category_id)
);
CREATE INDEX provider_services_category ON public.provider_services (category_id, provider_id);

ALTER TABLE public.provider_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_services FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.provider_services FROM anon, authenticated;
GRANT SELECT ON public.provider_services TO authenticated;
GRANT ALL ON public.provider_services TO service_role;
CREATE POLICY provider_services_read_own ON public.provider_services FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));

CREATE TABLE public.provider_service_areas (
  provider_id uuid NOT NULL REFERENCES public.provider_profiles (user_id) ON DELETE CASCADE,
  city_id     uuid NOT NULL REFERENCES public.cities (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_id, city_id)
);
CREATE INDEX provider_service_areas_city ON public.provider_service_areas (city_id, provider_id);

ALTER TABLE public.provider_service_areas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_service_areas FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.provider_service_areas FROM anon, authenticated;
GRANT SELECT ON public.provider_service_areas TO authenticated;
GRANT ALL ON public.provider_service_areas TO service_role;
CREATE POLICY provider_service_areas_read_own ON public.provider_service_areas
  FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- provider_live_location — the hot table. Written only by `heartbeat()`, read only by matching
-- and the feed. **No role selects it**, not even an admin: live position is personal location
-- data (DPIA), and ops reaches it through the SOS console for an open incident, not through SQL.
-- The storage settings are S-06 finding 3: bloat, not the query plan, is what degrades this.
-- ---------------------------------------------------------------------------
CREATE TABLE public.provider_live_location (
  provider_id uuid PRIMARY KEY REFERENCES public.provider_profiles (user_id) ON DELETE CASCADE,
  pos         extensions.geography(Point, 4326) NOT NULL,
  heading     smallint CHECK (heading IS NULL OR heading BETWEEN 0 AND 359),
  -- Centimetres per second: an integer column, because public carries no floating point.
  speed_cm_s  integer CHECK (speed_cm_s IS NULL OR speed_cm_s >= 0),
  accuracy_m  integer CHECK (accuracy_m IS NULL OR accuracy_m >= 0),
  is_mock     boolean NOT NULL DEFAULT false,
  updated_at  timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 75,
        autovacuum_vacuum_scale_factor = 0.01,
        autovacuum_analyze_scale_factor = 0.02,
        autovacuum_vacuum_cost_limit = 2000);
CREATE INDEX provider_live_location_pos ON public.provider_live_location USING gist (pos);
CREATE INDEX provider_live_location_fresh ON public.provider_live_location (updated_at);

ALTER TABLE public.provider_live_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_live_location FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.provider_live_location FROM anon, authenticated;
GRANT ALL ON public.provider_live_location TO service_role;
-- No policy for `authenticated` on purpose: with RLS forced and no policy, every client read
-- returns nothing even if a grant were added by mistake.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Config with a country override, falling back to the global row. Weights and thresholds live
-- here so ops can tune matching without a release (ai-design §9).
CREATE FUNCTION private.remote_config_json(p_key text, p_country char(2) DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT rc.value FROM public.remote_config rc
  WHERE rc.key = p_key AND (rc.country_code = p_country OR rc.country_code IS NULL)
  ORDER BY rc.country_code NULLS LAST
  LIMIT 1;
$$;

-- Eligibility, as the RLS matrix defines the "provider (acting)" actor: verified, has a provider
-- profile, and not serving a suspension.
CREATE FUNCTION private.is_active_provider(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.provider_profiles pp
    JOIN public.profiles p ON p.user_id = pp.user_id
    WHERE pp.user_id = p_user
      AND p.provider_verification = 'verified'
      AND (pp.suspended_until IS NULL OR pp.suspended_until <= now()));
$$;

-- The same check, as a guard that says which of the two failed.
CREATE FUNCTION private.require_active_provider(p_user uuid)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.provider_profiles pp
             WHERE pp.user_id = p_user AND pp.suspended_until > now()) THEN
    RAISE EXCEPTION 'ERR_PROVIDER_SUSPENDED' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.is_active_provider(p_user) THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- A provider profile appears the first time someone acts as a provider. Verification still
-- decides whether they may do anything with it.
CREATE FUNCTION private.ensure_provider_profile(p_user uuid)
RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO public.provider_profiles (user_id) VALUES (p_user)
  ON CONFLICT (user_id) DO NOTHING;
$$;

-- ---------------------------------------------------------------------------
-- set_online — the one way `online` changes. Document expiry and the periodic selfie check join
-- these guards when the KYC tables land; the busy-as-customer rule is enforced now.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.set_online(p_online boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_online IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  IF p_online THEN
    -- The profile row appears on the first provider action; verification still decides the rest.
    PERFORM private.ensure_provider_profile(v_uid);
    PERFORM private.require_active_provider(v_uid);
    -- Nobody works both sides at once: a customer with a job under way cannot also be taking
    -- work (spec; `ERR_PROVIDER_BUSY_AS_CUSTOMER`).
    IF EXISTS (SELECT 1 FROM public.requests r
               WHERE r.customer_id = v_uid AND r.status = 'agreed') THEN
      RAISE EXCEPTION 'ERR_PROVIDER_BUSY_AS_CUSTOMER' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  UPDATE public.provider_profiles pp
  SET online = p_online,
      online_since = CASE WHEN p_online AND NOT pp.online THEN now()
                          WHEN p_online THEN pp.online_since
                          ELSE NULL END
  WHERE pp.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
  END IF;

  -- Going offline drops the last position: a stale point must never be matched against.
  IF NOT p_online THEN
    DELETE FROM public.provider_live_location WHERE provider_id = v_uid;
  END IF;

  PERFORM private.emit_event('provider', v_uid::text,
    CASE WHEN p_online THEN 'provider.online' ELSE 'provider.offline' END, '{}'::jsonb);
  RETURN p_online;
END $$;

-- ---------------------------------------------------------------------------
-- What a provider offers, and where they work. Both replace the whole set, which is how the
-- screens behave: a list of chips the provider ticks.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.update_provider_services(p_category_keys text[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_ids   uuid[];
  v_count integer;
BEGIN
  IF p_category_keys IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  PERFORM private.ensure_provider_profile(v_uid);

  SELECT coalesce(array_agg(sc.id), '{}'::uuid[]) INTO v_ids
  FROM public.service_categories sc
  WHERE sc.key = ANY (p_category_keys) AND sc.active;
  IF cardinality(v_ids) <> cardinality(p_category_keys) THEN
    RAISE EXCEPTION 'ERR_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.provider_services ps
  WHERE ps.provider_id = v_uid AND NOT (ps.category_id = ANY (v_ids));
  INSERT INTO public.provider_services (provider_id, category_id)
  SELECT v_uid, id FROM unnest(v_ids) AS id
  ON CONFLICT DO NOTHING;

  SELECT count(*)::int INTO v_count FROM public.provider_services ps WHERE ps.provider_id = v_uid;
  RETURN v_count;
END $$;

CREATE FUNCTION public.update_provider_service_areas(p_city_codes text[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_ids     uuid[];
  v_count   integer;
BEGIN
  IF p_city_codes IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  PERFORM private.ensure_provider_profile(v_uid);

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- Cities are checked against the provider's own country: a Lagos rider does not serve Nairobi.
  SELECT coalesce(array_agg(c.id), '{}'::uuid[]) INTO v_ids
  FROM public.cities c
  WHERE c.country_code = v_country AND c.code = ANY (p_city_codes);
  IF cardinality(v_ids) <> cardinality(p_city_codes) THEN
    RAISE EXCEPTION 'ERR_CITY_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.provider_service_areas psa
  WHERE psa.provider_id = v_uid AND NOT (psa.city_id = ANY (v_ids));
  INSERT INTO public.provider_service_areas (provider_id, city_id)
  SELECT v_uid, id FROM unnest(v_ids) AS id
  ON CONFLICT DO NOTHING;

  SELECT count(*)::int INTO v_count FROM public.provider_service_areas psa
  WHERE psa.provider_id = v_uid;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- heartbeat — movement-gated, per ADR-0009 and S-06 finding 1. A stationary provider writes at
-- most once a minute; live tracking during a job goes over Broadcast and never through here.
-- Returns true when the row was written, so a client can tell the gate is working.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.heartbeat(
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
  RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- provider_feed — the only way a provider sees open work (RLS matrix §5). Single radius, per
-- S-06 finding 4.
--
-- The card carries a **distance**, not the customer's coordinates. A provider who has not been
-- chosen has no business knowing where someone lives; if a map pin is wanted later, it should be
-- a coarsened point, decided deliberately rather than by leaving the column in a result set.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.provider_feed(p_limit integer DEFAULT 20, p_radius_m integer DEFAULT 5000)
RETURNS TABLE (
  request_id            uuid,
  category_key          text,
  is_custom_category    boolean,
  custom_category_label text,
  description           text,
  urgency               public.urgency,
  pickup_label          text,
  destination_label     text,
  distance_m            integer,
  scheduled_at          timestamptz,
  preferred_price_minor bigint,
  item_float_minor      bigint,
  currency              char(3),
  created_at            timestamptz,
  expires_at            timestamptz,
  already_offered       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_origin  extensions.geography(Point, 4326);
  v_limit   integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_radius  integer := least(greatest(coalesce(p_radius_m, 5000), 100), 50000);
BEGIN
  PERFORM private.require_active_provider(v_uid);
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;

  -- The live position if it is fresh, otherwise the centre of a city they serve. A provider with
  -- neither has nothing to measure distance from, and is told so rather than shown the country.
  SELECT l.pos INTO v_origin FROM public.provider_live_location l
  WHERE l.provider_id = v_uid AND l.updated_at > now() - interval '10 minutes';
  IF v_origin IS NULL THEN
    SELECT c.center INTO v_origin
    FROM public.provider_service_areas psa
    JOIN public.cities c ON c.id = psa.city_id
    WHERE psa.provider_id = v_uid AND c.center IS NOT NULL
    ORDER BY psa.created_at
    LIMIT 1;
  END IF;
  IF v_origin IS NULL THEN
    RAISE EXCEPTION 'ERR_LOCATION_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;

  -- A provider who has registered no categories matches nothing. That is deliberate: matching a
  -- provider to work they never said they do is how a marketplace loses both sides.
  RETURN QUERY
  SELECT r.id,
         sc.key,
         r.is_custom_category,
         r.custom_category_label,
         r.description,
         r.urgency,
         r.pickup_label,
         r.destination_label,
         extensions.ST_Distance(r.pickup_point, v_origin)::integer,
         r.scheduled_at,
         r.preferred_price_minor,
         r.item_float_minor,
         r.currency,
         r.created_at,
         r.expires_at,
         EXISTS (SELECT 1 FROM public.offer_threads t
                 WHERE t.request_id = r.id AND t.provider_id = v_uid)
  FROM public.requests r
  JOIN public.service_categories sc ON sc.id = r.category_id
  JOIN public.provider_services ps
    ON ps.provider_id = v_uid AND ps.category_id = r.category_id
  WHERE r.status IN ('published', 'offers_received', 'negotiating')
    AND r.country_code = v_country
    AND r.customer_id <> v_uid
    AND (r.expires_at IS NULL OR r.expires_at > now())
    AND r.pickup_point IS NOT NULL
    AND extensions.ST_DWithin(r.pickup_point, v_origin, v_radius)
  ORDER BY extensions.ST_Distance(r.pickup_point, v_origin)
  LIMIT v_limit;
END $$;

-- ---------------------------------------------------------------------------
-- match_providers — the fan-out side: who to notify about a new request. A weighted SQL score,
-- no model (ai-design §9: matching is deliberately not an LLM). Weights are config, per country,
-- so ops can tune without a release.
--
-- Terms still missing their data, and left out rather than faked: category experience (needs
-- completed-job counts per category) and the learning-to-rank variant, which the same document
-- puts behind a shadow-run gate.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.match_providers(
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
              AND r2.status = 'agreed') AS active_jobs
    FROM public.provider_profiles pp
    JOIN public.profiles p ON p.user_id = pp.user_id
    JOIN public.provider_services ps
      ON ps.provider_id = pp.user_id AND ps.category_id = v_request.category_id
    -- S-06's `live_hot` shape: join the hot table and require a fresh fix, single radius.
    JOIN public.provider_live_location l
      ON l.provider_id = pp.user_id AND l.updated_at > now() - interval '2 minutes'
    WHERE pp.online
      AND (pp.suspended_until IS NULL OR pp.suspended_until <= now())
      AND p.provider_verification = 'verified'
      AND p.country_code = v_request.country_code
      AND pp.user_id <> v_request.customer_id
      AND extensions.ST_DWithin(l.pos, v_request.pickup_point, v_radius)
      AND NOT EXISTS (SELECT 1 FROM public.offer_threads t
                      WHERE t.request_id = v_request.id AND t.provider_id = pp.user_id)
  )
  SELECT c.user_id,
         c.d::integer,
         (1000 * (
             w_dist   * (1 - least(c.d, v_radius::double precision) / v_radius)
           -- A provider with no ratings yet is neither punished nor flattered.
           + w_rating * (CASE WHEN c.rating_count = 0 THEN 0.6::double precision
                              ELSE c.rating_avg_milli::double precision / 5000 END)
           + w_compl  * (c.completion_rate_bps::double precision / 10000)
           + w_resp   * (1 - least(coalesce(c.response_time_p50_s, 300), 900)::double precision / 900)
           - w_cancel * (c.cancellation_rate_bps::double precision / 10000)
           - w_load   * (least(c.active_jobs, 3)::double precision / 3)
         ) / w_total)::integer
  FROM candidate c
  ORDER BY 3 DESC, 2 ASC
  LIMIT v_limit;
END $$;

-- ---------------------------------------------------------------------------
-- Offers were built before providers existed, so their eligibility check was "verified" and
-- nothing more. Now that a suspension can exist, both ends of a negotiation go through the same
-- guard: a suspended provider can neither offer nor win one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_offer(
  p_idempotency_key text,
  p_request_id uuid,
  p_amount_minor bigint,
  p_message text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_country char(2);
  v_ttl     integer;
  v_max     smallint;
  v_round   smallint;
  v_expires timestamptz;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_offer',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', p_amount_minor,
                       'message', p_message));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'offer_id')::uuid;
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.customer_id = v_uid THEN
    RAISE EXCEPTION 'ERR_SELF_DEALING_BLOCKED' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status NOT IN ('published', 'offers_received', 'negotiating')
     OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= now()) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.require_active_provider(v_uid);
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  -- The feed is country-scoped, so an offer from another country is a bug or an attack.
  IF v_country IS DISTINCT FROM v_request.country_code THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.offer_guardrail_check(v_request.country_code, v_request.category_id,
                                        p_amount_minor);

  SELECT sc.offer_ttl_seconds, sc.max_counter_rounds INTO v_ttl, v_max
  FROM public.service_categories sc WHERE sc.id = v_request.category_id;

  SELECT * INTO v_thread FROM public.offer_threads t
  WHERE t.request_id = p_request_id AND t.provider_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.offer_threads (request_id, provider_id) VALUES (p_request_id, v_uid)
    RETURNING * INTO v_thread;
  ELSE
    IF v_thread.status <> 'open' THEN
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.offers o
               WHERE o.thread_id = v_thread.id AND o.status = 'pending') THEN
      RAISE EXCEPTION 'ERR_OFFER_ALREADY_PENDING' USING ERRCODE = 'P0001';
    END IF;
    IF v_thread.round_count >= v_max THEN
      RAISE EXCEPTION 'ERR_OFFER_ROUNDS_EXHAUSTED' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_round := v_thread.round_count + 1;
  v_expires := now() + make_interval(secs => v_ttl);
  INSERT INTO public.offers (thread_id, request_id, provider_id, author_side, amount_minor,
                             currency, message, round, expires_at)
  VALUES (v_thread.id, p_request_id, v_uid, 'provider', p_amount_minor, v_request.currency,
          p_message, v_round, v_expires)
  RETURNING id INTO v_id;
  UPDATE public.offer_threads t SET round_count = v_round WHERE t.id = v_thread.id;

  IF v_request.status = 'published' THEN
    UPDATE public.requests r SET status = 'offers_received', version = r.version + 1
    WHERE r.id = p_request_id;
  END IF;

  PERFORM private.emit_event('request', p_request_id::text, 'offer.created',
    jsonb_build_object('offer_id', v_id, 'thread_id', v_thread.id, 'provider_id', v_uid,
                       'amount_minor', p_amount_minor, 'currency', v_request.currency,
                       'round', v_round, 'expires_at', v_expires));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('offer_id', v_id));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.accept_offer(p_idempotency_key text, p_offer_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_offer   public.offers%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_side    public.user_mode;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'accept_offer',
    jsonb_build_object('offer_id', p_offer_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = v_offer.request_id FOR UPDATE;
  SELECT * INTO v_thread FROM public.offer_threads t WHERE t.id = v_offer.thread_id FOR UPDATE;
  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id FOR UPDATE;

  IF v_uid = v_request.customer_id THEN
    v_side := 'customer'::public.user_mode;
  ELSIF v_uid = v_thread.provider_id THEN
    v_side := 'provider'::public.user_mode;
  ELSE
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_side = v_offer.author_side THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_YOUR_TURN' USING ERRCODE = 'P0001';
  END IF;

  -- The offer's own state first: a caller who lost the race is told "this offer is no longer
  -- live", which the apps turn into "another provider was just selected" (S-10 finding 3),
  -- rather than a transition error about a request they may not be able to see.
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
  IF v_offer.expires_at <= now() THEN
    RAISE EXCEPTION 'ERR_OFFER_EXPIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status NOT IN ('published', 'offers_received', 'negotiating') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- The provider must still be eligible at the moment of acceptance, not only when they offered:
  -- a suspension between the two is exactly the case this catches.
  PERFORM private.require_active_provider(v_thread.provider_id);

  UPDATE public.offers o SET status = 'accepted', status_changed_at = now()
  WHERE o.id = p_offer_id;

  -- Every other live offer on this request loses, in this transaction.
  WITH lost AS (
    UPDATE public.offers o
    SET status = 'expired', status_reason = 'sibling_accepted', status_changed_at = now()
    WHERE o.request_id = v_request.id AND o.status = 'pending' AND o.id <> p_offer_id
    RETURNING o.id, o.provider_id
  )
  INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload)
  SELECT 'request', v_request.id::text, 'offer.expired',
         jsonb_build_object('offer_id', l.id, 'provider_id', l.provider_id,
                            'reason', 'sibling_accepted')
  FROM lost l;

  UPDATE public.offer_threads t SET status = 'closed' WHERE t.request_id = v_request.id;
  UPDATE public.requests r
  SET status = 'agreed', expires_at = NULL, version = r.version + 1
  WHERE r.id = v_request.id;

  -- One event per acceptance: payment, notifications and analytics all hang off it, so a double
  -- fire would double-charge (S-10 invariant 3).
  PERFORM private.emit_event('request', v_request.id::text, 'offer.accepted',
    jsonb_build_object('offer_id', p_offer_id, 'thread_id', v_thread.id,
                       'provider_id', v_thread.provider_id, 'customer_id', v_request.customer_id,
                       'amount_minor', v_offer.amount_minor, 'currency', v_offer.currency,
                       'accepted_by', v_side));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'agreed', 'offer_id', p_offer_id));
  RETURN 'agreed'::public.job_status;
END $$;

REVOKE ALL ON FUNCTION
  public.set_online(boolean),
  public.update_provider_services(text[]),
  public.update_provider_service_areas(text[]),
  public.heartbeat(double precision, double precision, smallint, integer, integer, boolean),
  public.provider_feed(integer, integer),
  private.remote_config_json(text, char),
  private.is_active_provider(uuid),
  private.require_active_provider(uuid),
  private.ensure_provider_profile(uuid),
  private.match_providers(uuid, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.set_online(boolean),
  public.update_provider_services(text[]),
  public.update_provider_service_areas(text[]),
  public.heartbeat(double precision, double precision, smallint, integer, integer, boolean),
  public.provider_feed(integer, integer)
  TO authenticated;
