-- Marketplace, part 8: favourites, blocks and reports (ERD §2 and §5; RLS matrix §2 and §5;
-- spec phase 3, "Favorites, blocks, reports, two-way ratings, reputation jobs").
--
-- The spec's rule about blocks is one sentence with teeth: **blocked pairs are never matched
-- again**, and the check belongs in matching, offers and chat. So it is applied in all three, and
-- in two different ways on purpose:
--
--   * matching and the feed **filter** — a blocked request should not appear, not appear and then
--     fail;
--   * offers and chat **refuse**, by trigger, so the invariant does not depend on a caller having
--     remembered to ask.
--
-- A block is one-directional in the data and symmetric in effect: if either party has blocked the
-- other, they are not matched, cannot bid and cannot talk. Neither side is told which of them did
-- it, and a blocked provider sees only that the work is not there.

CREATE TABLE public.blocks (
  blocker_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason_code text CHECK (reason_code IS NULL OR length(reason_code) <= 60),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT blocks_not_self CHECK (blocker_id <> blocked_id)
);
CREATE INDEX blocks_blocked ON public.blocks (blocked_id);

ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocks FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.blocks FROM anon, authenticated;
GRANT SELECT ON public.blocks TO authenticated;
GRANT ALL ON public.blocks TO service_role;
-- You see the blocks you made. You are never shown that someone blocked you: that turns a quiet
-- safety tool into a notification, and the person most likely to act on it is the wrong one.
CREATE POLICY blocks_read_own ON public.blocks FOR SELECT TO authenticated
  USING (blocker_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

CREATE TABLE public.favorites (
  customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, provider_id),
  CONSTRAINT favorites_not_self CHECK (customer_id <> provider_id)
);
CREATE INDEX favorites_provider ON public.favorites (provider_id);

ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.favorites FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.favorites FROM anon, authenticated;
GRANT SELECT ON public.favorites TO authenticated;
GRANT ALL ON public.favorites TO service_role;
-- A provider is not told who favourited them either. It is the customer's list, not a score.
CREATE POLICY favorites_read_own ON public.favorites FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

CREATE TYPE public.report_status AS ENUM ('open', 'reviewing', 'actioned', 'dismissed');

CREATE TABLE public.reports (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  subject_user_id uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
  request_id      uuid REFERENCES public.requests (id) ON DELETE SET NULL,
  reason_code     text NOT NULL CHECK (length(reason_code) BETWEEN 2 AND 60),
  details         text CHECK (details IS NULL OR length(details) <= 2000),
  status          public.report_status NOT NULL DEFAULT 'open',
  resolution_note text,
  resolved_by     uuid REFERENCES auth.users (id),
  resolved_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reports_not_self CHECK (subject_user_id IS NULL OR subject_user_id <> reporter_id),
  CONSTRAINT reports_has_subject CHECK (subject_user_id IS NOT NULL OR request_id IS NOT NULL)
);
CREATE INDEX reports_subject ON public.reports (subject_user_id, created_at DESC);
CREATE INDEX reports_open ON public.reports (created_at) WHERE status IN ('open', 'reviewing');

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.reports FROM anon, authenticated;
GRANT SELECT ON public.reports TO authenticated;
GRANT ALL ON public.reports TO service_role;
-- The reporter sees their own report and its status. The subject is never shown that they were
-- reported, or by whom — that is the whole safety argument for having a report button.
CREATE POLICY reports_read_own ON public.reports FOR SELECT TO authenticated
  USING (reporter_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The check itself: symmetric, and definer, because neither side may read the other's blocks.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.is_blocked_pair(p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_a IS NOT NULL AND p_b IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = p_a AND b.blocked_id = p_b)
       OR (b.blocker_id = p_b AND b.blocked_id = p_a));
$$;

-- ---------------------------------------------------------------------------
-- block_user / unblock_user / favorite_provider / unfavorite_provider / report_user
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.block_user(p_user_id uuid, p_reason_code text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_user_id IS NULL OR p_user_id = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = p_user_id) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.blocks (blocker_id, blocked_id, reason_code)
  VALUES (v_uid, p_user_id, p_reason_code)
  ON CONFLICT (blocker_id, blocked_id) DO NOTHING;

  -- Blocking someone you are favouriting is a contradiction; the block wins.
  DELETE FROM public.favorites f
  WHERE (f.customer_id = v_uid AND f.provider_id = p_user_id)
     OR (f.customer_id = p_user_id AND f.provider_id = v_uid);

  PERFORM private.emit_event('user', v_uid::text, 'user.blocked',
    jsonb_build_object('blocked_id', p_user_id, 'reason', p_reason_code));
  RETURN true;
END $$;

CREATE FUNCTION public.unblock_user(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  DELETE FROM public.blocks b WHERE b.blocker_id = v_uid AND b.blocked_id = p_user_id;
  RETURN FOUND;
END $$;

CREATE FUNCTION public.favorite_provider(p_provider_id uuid, p_favorite boolean DEFAULT true)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_provider_id IS NULL OR p_provider_id = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  IF NOT coalesce(p_favorite, true) THEN
    DELETE FROM public.favorites f
    WHERE f.customer_id = v_uid AND f.provider_id = p_provider_id;
    RETURN false;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.provider_profiles pp WHERE pp.user_id = p_provider_id) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF private.is_blocked_pair(v_uid, p_provider_id) THEN
    RAISE EXCEPTION 'ERR_BLOCKED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.favorites (customer_id, provider_id) VALUES (v_uid, p_provider_id)
  ON CONFLICT DO NOTHING;
  RETURN true;
END $$;

CREATE FUNCTION public.report_user(
  p_idempotency_key text,
  p_reason_code text,
  p_subject_user_id uuid DEFAULT NULL,
  p_request_id uuid DEFAULT NULL,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_id    uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'report_user',
    jsonb_build_object('subject', p_subject_user_id, 'request', p_request_id,
                       'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'report_id')::uuid;
  END IF;

  IF p_reason_code IS NULL
     OR (p_subject_user_id IS NULL AND p_request_id IS NULL)
     OR p_subject_user_id = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.reports (reporter_id, subject_user_id, request_id, reason_code, details)
  VALUES (v_uid, p_subject_user_id, p_request_id, p_reason_code,
          nullif(btrim(coalesce(p_details, '')), ''))
  RETURNING id INTO v_id;

  -- Reports go to a human queue, so the event is the point: nothing here judges anything.
  PERFORM private.emit_event('report', v_id::text, 'report.opened',
    jsonb_build_object('reporter_id', v_uid, 'subject_user_id', p_subject_user_id,
                       'request_id', p_request_id, 'reason', p_reason_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('report_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Where the rule bites. Offers and chat refuse by trigger: an invariant that lives in one
-- function is one refactor away from not existing.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.offers_refuse_blocked()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
BEGIN
  SELECT r.customer_id INTO v_customer FROM public.requests r WHERE r.id = NEW.request_id;
  IF private.is_blocked_pair(v_customer, NEW.provider_id) THEN
    RAISE EXCEPTION 'ERR_BLOCKED' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER offers_refuse_blocked BEFORE INSERT ON public.offers
  FOR EACH ROW EXECUTE FUNCTION private.offers_refuse_blocked();

CREATE FUNCTION private.messages_refuse_blocked()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
  v_provider uuid;
BEGIN
  SELECT r.customer_id, j.provider_id INTO v_customer, v_provider
  FROM public.conversations c
  JOIN public.requests r ON r.id = c.request_id
  LEFT JOIN public.jobs j ON j.request_id = c.request_id
  WHERE c.id = NEW.conversation_id;
  IF private.is_blocked_pair(v_customer, v_provider) THEN
    RAISE EXCEPTION 'ERR_BLOCKED' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER messages_refuse_blocked BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_refuse_blocked();

-- Matching and the feed filter instead: a request a provider may not take should not be on the
-- card at all. Both functions are replaced for the one added clause.
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
           -- A provider this customer has chosen before starts ahead. The weight is small on
           -- purpose: a favourite should win a close call, not a distant one.
           + CASE WHEN c.favoured THEN 0.1 * w_total ELSE 0 END
         ) / w_total)::integer
  FROM candidate c
  ORDER BY 3 DESC, 2 ASC
  LIMIT v_limit;
END $$;

CREATE OR REPLACE FUNCTION public.provider_feed(p_limit integer DEFAULT 20,
                                                p_radius_m integer DEFAULT 5000)
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
    -- Blocked either way: the request is simply not there, rather than there and unbiddable.
    AND NOT private.is_blocked_pair(r.customer_id, v_uid)
    AND extensions.ST_DWithin(r.pickup_point, v_origin, v_radius)
  ORDER BY extensions.ST_Distance(r.pickup_point, v_origin)
  LIMIT v_limit;
END $$;

REVOKE ALL ON FUNCTION
  public.block_user(uuid, text),
  public.unblock_user(uuid),
  public.favorite_provider(uuid, boolean),
  public.report_user(text, text, uuid, uuid, text),
  private.is_blocked_pair(uuid, uuid),
  private.offers_refuse_blocked(),
  private.messages_refuse_blocked()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.block_user(uuid, text),
  public.unblock_user(uuid),
  public.favorite_provider(uuid, boolean),
  public.report_user(text, text, uuid, uuid, text)
  TO authenticated;
