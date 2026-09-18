-- Marketplace, part 6: ratings, the reputation job that turns them into the numbers matching
-- uses, and a correction to the provider feed (ERD §5 and §3; RLS matrix §5; PRD SH-30, SH-31,
-- PR-11).
--
-- Two rules from the PRD that the code has to carry, both easy to miss:
--   * **SH-30, the blind period**: a rating is hidden from the other party until both sides have
--     rated or the window closes. Otherwise the second rating is a reply to the first.
--   * **PR-11, the feed card**: a provider sees an *approximate pickup area*, and the exact
--     address only after assignment. My feed returned `pickup_label` — the address the customer
--     typed. That is corrected here, which is why `provider_feed` is replaced rather than added
--     to: its shape changes.
--
-- Aggregates are written by the reputation job, never by a trigger on insert (ERD §5), so one
-- rating cannot move a provider's standing mid-transaction, and the smoothing has the whole set
-- in front of it.

CREATE TYPE public.rating_direction AS ENUM ('customer_to_provider', 'provider_to_customer');
CREATE TYPE public.moderation_status AS ENUM ('pending', 'approved', 'rejected');

CREATE TABLE public.ratings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id        uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  rater_id          uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  ratee_id          uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  direction         public.rating_direction NOT NULL,
  stars             smallint NOT NULL CHECK (stars BETWEEN 1 AND 5),
  tags              text[] NOT NULL DEFAULT '{}'::text[],
  comment           text CHECK (comment IS NULL OR length(comment) BETWEEN 1 AND 1000),
  -- OD-21's default is fail-open: a review publishes and goes into a queue for review, rather
  -- than waiting for a moderator who may not exist. `rejected` is the only status that hides one.
  moderation_status public.moderation_status NOT NULL DEFAULT 'pending',
  moderation_flags  text[] NOT NULL DEFAULT '{}'::text[],
  -- The blind period (SH-30): NULL until both sides have rated or the window closed.
  visible_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, rater_id),
  CONSTRAINT ratings_not_self CHECK (rater_id <> ratee_id)
);
CREATE INDEX ratings_ratee ON public.ratings (ratee_id, created_at DESC);
CREATE INDEX ratings_pending_window ON public.ratings (created_at) WHERE visible_at IS NULL;

ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ratings FROM anon, authenticated;
GRANT SELECT ON public.ratings TO authenticated;
GRANT ALL ON public.ratings TO service_role;
-- Your own rating is always yours to see. Everyone else's becomes readable when it is published
-- and not rejected — that is what makes a reputation checkable (RLS matrix §5, "R published,
-- moderated"). Written only through `rate_job`, so there is no insert grant.
CREATE POLICY ratings_read ON public.ratings FOR SELECT TO authenticated
  USING (rater_id = (SELECT auth.uid())
         OR (visible_at IS NOT NULL AND visible_at <= now() AND moderation_status <> 'rejected')
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- rate_job — one rating per person per job, after the work is confirmed.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rate_job(
  p_idempotency_key text,
  p_request_id uuid,
  p_stars smallint,
  p_tags text[] DEFAULT NULL,
  p_comment text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_request   public.requests%ROWTYPE;
  v_job       public.jobs%ROWTYPE;
  v_direction public.rating_direction;
  v_ratee     uuid;
  v_window    integer := coalesce(private.remote_config_int('ratings_window_hours'), 168);
  v_id        uuid;
  v_other     uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'rate_job',
    jsonb_build_object('request_id', p_request_id, 'stars', p_stars));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'rating_id')::uuid;
  END IF;

  IF p_stars IS NULL OR p_stars NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_uid = v_request.customer_id THEN
    v_direction := 'customer_to_provider'::public.rating_direction;
    v_ratee := coalesce(v_job.worker_id, v_job.provider_id);
  ELSIF v_uid = v_job.provider_id OR v_uid = v_job.worker_id THEN
    v_direction := 'provider_to_customer'::public.rating_direction;
    v_ratee := v_request.customer_id;
  ELSE
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- After confirmation, per SH-30. Settlement and closure are money states that do not exist
  -- yet; when they do they belong in this list, not instead of it.
  IF v_request.status NOT IN ('confirmed', 'settlement_pending', 'settled', 'closed') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.confirmed_at IS NOT NULL
     AND v_job.confirmed_at < now() - make_interval(hours => v_window) THEN
    RAISE EXCEPTION 'ERR_RATING_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.ratings (request_id, rater_id, ratee_id, direction, stars, tags, comment)
  VALUES (p_request_id, v_uid, v_ratee, v_direction, p_stars,
          coalesce(p_tags, '{}'::text[]), nullif(btrim(coalesce(p_comment, '')), ''))
  RETURNING id INTO v_id;

  -- Both sides have now rated, so the blind period ends for both at once.
  SELECT r2.id INTO v_other FROM public.ratings r2
  WHERE r2.request_id = p_request_id AND r2.rater_id <> v_uid;
  IF FOUND THEN
    UPDATE public.ratings r3 SET visible_at = now()
    WHERE r3.request_id = p_request_id AND r3.visible_at IS NULL;
  END IF;

  PERFORM private.emit_event('request', p_request_id::text, 'job.rated',
    jsonb_build_object('rating_id', v_id, 'direction', v_direction, 'ratee_id', v_ratee,
                       'both_rated', v_other IS NOT NULL));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('rating_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- close_rating_windows — the other half of SH-30: a rating the counterparty never answered
-- becomes visible when the window closes.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.close_rating_windows(p_limit integer DEFAULT 1000)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_window integer := coalesce(private.remote_config_int('ratings_window_hours'), 168);
  v_count  integer;
BEGIN
  WITH due AS (
    SELECT r.id FROM public.ratings r
    JOIN public.jobs j ON j.request_id = r.request_id
    WHERE r.visible_at IS NULL
      AND j.confirmed_at IS NOT NULL
      AND j.confirmed_at <= now() - make_interval(hours => v_window)
    ORDER BY r.created_at
    LIMIT p_limit
  ), opened AS (
    UPDATE public.ratings r SET visible_at = now()
    FROM due WHERE r.id = due.id
    RETURNING r.id
  )
  SELECT count(*)::int INTO v_count FROM opened;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- The reputation job. Bayesian smoothing (SH-31, spec): a provider with one five-star job does
-- not outrank one with fifty at 4.8. The prior is a weight and a mean, both remote config.
--
-- Only **visible** ratings count. Counting a rating during its blind period would let the ratee
-- infer it from their own average, which is the thing the blind period exists to prevent.
--
-- Trust level (`profiles.trust_level`) is deliberately not computed here: SH-31 ties TRUSTED and
-- above to address verification, which is Phase 4 work. Setting it from ratings alone would give
-- the badge a meaning the spec does not give it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.recompute_reputation(p_provider uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_prior_weight integer := coalesce(private.remote_config_int('reputation_prior_weight'), 10);
  v_prior_milli  integer := coalesce(private.remote_config_int('reputation_prior_milli'), 4500);
  v_sum          bigint;
  v_n            integer;
  v_avg_milli    integer;
  v_assigned     integer;
  v_confirmed    integer;
  v_cancelled    integer;
  v_p50          integer;
BEGIN
  SELECT coalesce(sum(r.stars), 0), count(*)::int INTO v_sum, v_n
  FROM public.ratings r
  WHERE r.ratee_id = p_provider
    AND r.direction = 'customer_to_provider'
    AND r.visible_at IS NOT NULL AND r.visible_at <= now()
    AND r.moderation_status <> 'rejected';

  -- (prior_weight × prior + Σ stars) / (prior_weight + n), in thousandths of a star.
  v_avg_milli := ((v_prior_weight::bigint * v_prior_milli + v_sum * 1000)
                  / (v_prior_weight + v_n))::integer;

  SELECT count(*) FILTER (WHERE j.assigned_at IS NOT NULL),
         count(*) FILTER (WHERE j.confirmed_at IS NOT NULL),
         count(*) FILTER (WHERE j.assigned_at IS NOT NULL AND r.status = 'cancelled')
  INTO v_assigned, v_confirmed, v_cancelled
  FROM public.jobs j
  JOIN public.requests r ON r.id = j.request_id
  WHERE j.provider_id = p_provider OR j.worker_id = p_provider;

  -- How quickly this provider answers a published request, measured from publication to their
  -- first offer on it. The median, not the mean: one forgotten phone should not define someone.
  SELECT percentile_cont(0.5) WITHIN GROUP (
           ORDER BY extract(epoch FROM (o.created_at - req.published_at))::double precision)::integer
  INTO v_p50
  FROM public.offers o
  JOIN public.requests req ON req.id = o.request_id
  WHERE o.provider_id = p_provider
    AND o.author_side = 'provider'
    AND o.round = 1
    AND req.published_at IS NOT NULL
    AND o.created_at > req.published_at;

  UPDATE public.provider_profiles pp
  SET rating_avg_milli = greatest(least(v_avg_milli, 5000), 0),
      rating_count = v_n,
      completion_rate_bps = CASE WHEN v_assigned = 0 THEN 10000
                                 ELSE (v_confirmed::bigint * 10000 / v_assigned)::integer END,
      cancellation_rate_bps = CASE WHEN v_assigned = 0 THEN 0
                                   ELSE (v_cancelled::bigint * 10000 / v_assigned)::integer END,
      response_time_p50_s = v_p50
  WHERE pp.user_id = p_provider;
END $$;

CREATE FUNCTION private.recompute_reputation_all(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id    uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT pp.user_id FROM public.provider_profiles pp
    WHERE EXISTS (SELECT 1 FROM public.ratings r
                  WHERE r.ratee_id = pp.user_id AND r.visible_at IS NOT NULL)
       OR EXISTS (SELECT 1 FROM public.jobs j
                  WHERE j.provider_id = pp.user_id OR j.worker_id = pp.user_id)
    ORDER BY pp.updated_at
    LIMIT p_limit
  LOOP
    PERFORM private.recompute_reputation(v_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- provider_feed, corrected. PR-11: the card carries an approximate pickup area and the photos;
-- the exact address is revealed after assignment. The previous version returned the address the
-- customer typed, which is the opposite of that rule.
--
-- "Approximate" here is the city when the request names one, plus the pickup point rounded to
-- two decimal places — around a kilometre, enough to draw an area on a map and not enough to
-- find a door.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.provider_feed(integer, integer);

CREATE FUNCTION public.provider_feed(p_limit integer DEFAULT 20, p_radius_m integer DEFAULT 5000)
RETURNS TABLE (
  request_id             uuid,
  category_key           text,
  is_custom_category     boolean,
  custom_category_label  text,
  description            text,
  urgency                public.urgency,
  pickup_area            text,
  pickup_approx_lat      double precision,
  pickup_approx_lng      double precision,
  has_destination        boolean,
  destination_approx_lat double precision,
  destination_approx_lng double precision,
  distance_m             integer,
  media_paths            text[],
  scheduled_at           timestamptz,
  preferred_price_minor  bigint,
  item_float_minor       bigint,
  currency               char(3),
  created_at             timestamptz,
  expires_at             timestamptz,
  already_offered        boolean
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

  RETURN QUERY
  SELECT r.id,
         sc.key,
         r.is_custom_category,
         r.custom_category_label,
         r.description,
         r.urgency,
         ci.name,
         round(extensions.ST_Y(r.pickup_point::extensions.geometry)::numeric, 2)::double precision,
         round(extensions.ST_X(r.pickup_point::extensions.geometry)::numeric, 2)::double precision,
         r.destination_point IS NOT NULL OR r.destination_label IS NOT NULL,
         round(extensions.ST_Y(r.destination_point::extensions.geometry)::numeric, 2)::double precision,
         round(extensions.ST_X(r.destination_point::extensions.geometry)::numeric, 2)::double precision,
         extensions.ST_Distance(r.pickup_point, v_origin)::integer,
         (SELECT coalesce(array_agg(rm.storage_path ORDER BY rm.created_at), '{}'::text[])
          FROM public.request_media rm WHERE rm.request_id = r.id),
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
  LEFT JOIN public.cities ci ON ci.id = r.city_id
  WHERE r.status IN ('published', 'offers_received', 'negotiating')
    AND r.country_code = v_country
    AND r.customer_id <> v_uid
    AND (r.expires_at IS NULL OR r.expires_at > now())
    AND r.pickup_point IS NOT NULL
    AND extensions.ST_DWithin(r.pickup_point, v_origin, v_radius)
  ORDER BY extensions.ST_Distance(r.pickup_point, v_origin)
  LIMIT v_limit;
END $$;

-- The photos are on the card (PR-11), so a provider who could be matched to a request can fetch
-- them, not only the one who wins it. "Could be matched" is the same test the feed applies:
-- active, same country, registered for the category, and the request still open.
CREATE OR REPLACE FUNCTION private.may_read_request_media(p_name text)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.request_media rm
    JOIN public.jobs j ON j.request_id = rm.request_id
    WHERE rm.storage_path = p_name
      AND (j.provider_id = (SELECT auth.uid()) OR j.worker_id = (SELECT auth.uid())))
      OR EXISTS (
    SELECT 1 FROM public.request_media rm
    JOIN public.requests r ON r.id = rm.request_id
    JOIN public.provider_services ps
      ON ps.provider_id = (SELECT auth.uid()) AND ps.category_id = r.category_id
    JOIN public.profiles p ON p.user_id = (SELECT auth.uid())
    WHERE rm.storage_path = p_name
      AND r.status IN ('published', 'offers_received', 'negotiating')
      AND r.country_code = p.country_code
      AND r.customer_id <> (SELECT auth.uid())
      AND private.is_active_provider((SELECT auth.uid())));
$$;

REVOKE ALL ON FUNCTION
  public.rate_job(text, uuid, smallint, text[], text),
  public.provider_feed(integer, integer),
  private.close_rating_windows(integer),
  private.recompute_reputation(uuid),
  private.recompute_reputation_all(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rate_job(text, uuid, smallint, text[], text),
  public.provider_feed(integer, integer)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('ratings-close-windows', '*/30 * * * *',
      $cron$SELECT private.close_rating_windows()$cron$);
    PERFORM cron.schedule('reputation-recompute', '23 * * * *',
      $cron$SELECT private.recompute_reputation_all()$cron$);
  END IF;
END $$;
