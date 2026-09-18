-- Marketplace, part 1: the service taxonomy and requests (ERD §1 and §5; RLS matrix §5;
-- job lifecycle state machine). Offers, matching and jobs follow in later migrations.
--
-- Shape of the rules here, all from the state machine and the RLS matrix:
--   * a customer inserts a request only as `draft`, and edits only the fields a draft may carry;
--   * every state change goes through a function — no client ever writes `status`;
--   * publishing requires a verified customer and a supported, live or beta country;
--   * a provider never selects from `requests`: the feed arrives through matching (later migration).

CREATE TYPE public.request_channel AS ENUM ('app', 'web', 'concierge', 'voice');

-- ---------------------------------------------------------------------------
-- service_categories — the taxonomy the apps render and the AI maps onto.
-- `embedding` (pgvector) arrives with the AI matching work; the column is left out until the
-- extension and the model are settled (ADR-0006), rather than guessing a dimension now.
-- ---------------------------------------------------------------------------
CREATE TABLE public.service_categories (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                text NOT NULL UNIQUE CHECK (key ~ '^[a-z0-9_]{2,40}$'),
  parent_id          uuid REFERENCES public.service_categories (id),
  name_key           text NOT NULL,
  icon_key           text,
  requires_vehicle   boolean NOT NULL DEFAULT false,
  allows_custom      boolean NOT NULL DEFAULT false,
  proof_requirements jsonb   NOT NULL DEFAULT '{}'::jsonb,
  offer_ttl_seconds  integer NOT NULL DEFAULT 600 CHECK (offer_ttl_seconds BETWEEN 60 AND 86400),
  max_counter_rounds smallint NOT NULL DEFAULT 5 CHECK (max_counter_rounds BETWEEN 1 AND 20),
  sort_order         smallint NOT NULL DEFAULT 100,
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX service_categories_active ON public.service_categories (active, sort_order);
CREATE TRIGGER service_categories_touch BEFORE UPDATE ON public.service_categories
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.service_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_categories FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.service_categories FROM anon, authenticated;
GRANT SELECT ON public.service_categories TO anon, authenticated;
GRANT ALL ON public.service_categories TO service_role;
-- The catalogue is public: the apps show it before sign-in, on the welcome and request screens.
CREATE POLICY service_categories_read ON public.service_categories FOR SELECT TO anon, authenticated
  USING (active);

-- ---------------------------------------------------------------------------
-- requests
-- ---------------------------------------------------------------------------
CREATE TABLE public.requests (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id              uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  country_code             char(2) NOT NULL REFERENCES public.countries (code),
  city_id                  uuid REFERENCES public.cities (id),
  category_id              uuid NOT NULL REFERENCES public.service_categories (id),
  is_custom_category       boolean NOT NULL DEFAULT false,
  custom_category_label    text CHECK (custom_category_label IS NULL OR length(custom_category_label) BETWEEN 2 AND 80),
  description              text NOT NULL CHECK (length(description) BETWEEN 3 AND 2000),
  urgency                  public.urgency NOT NULL DEFAULT 'standard',
  status                   public.job_status NOT NULL DEFAULT 'draft',
  pickup_point             extensions.geography(Point, 4326),
  pickup_label             text NOT NULL CHECK (length(pickup_label) BETWEEN 2 AND 200),
  pickup_landmark_note     text CHECK (pickup_landmark_note IS NULL OR length(pickup_landmark_note) <= 300),
  destination_point        extensions.geography(Point, 4326),
  destination_label        text CHECK (destination_label IS NULL OR length(destination_label) BETWEEN 2 AND 200),
  destination_landmark_note text CHECK (destination_landmark_note IS NULL OR length(destination_landmark_note) <= 300),
  scheduled_at             timestamptz,
  preferred_price_minor    bigint CHECK (preferred_price_minor IS NULL OR preferred_price_minor > 0),
  item_float_minor         bigint CHECK (item_float_minor IS NULL OR item_float_minor > 0),
  declared_value_minor     bigint CHECK (declared_value_minor IS NULL OR declared_value_minor > 0),
  currency                 char(3) NOT NULL REFERENCES public.currencies (code),
  expires_at               timestamptz,
  created_via              public.request_channel NOT NULL DEFAULT 'app',
  -- Optimistic concurrency for the offer and job transitions that follow.
  version                  integer NOT NULL DEFAULT 1,
  published_at             timestamptz,
  cancelled_at             timestamptz,
  cancellation_reason_code text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT requests_custom_category_label CHECK (
    (is_custom_category AND custom_category_label IS NOT NULL) OR
    (NOT is_custom_category AND custom_category_label IS NULL)),
  CONSTRAINT requests_scheduled_future CHECK (scheduled_at IS NULL OR scheduled_at > created_at)
);
CREATE INDEX requests_customer ON public.requests (customer_id, created_at DESC);
CREATE INDEX requests_open_feed ON public.requests (city_id, category_id)
  WHERE status IN ('published', 'offers_received', 'negotiating');
CREATE INDEX requests_pickup ON public.requests USING gist (pickup_point);
CREATE INDEX requests_expiry ON public.requests (expires_at)
  WHERE status IN ('published', 'offers_received', 'negotiating');
CREATE TRIGGER requests_touch BEFORE UPDATE ON public.requests
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.requests FROM anon, authenticated;
GRANT ALL ON public.requests TO service_role;
-- A customer reads their own requests. Providers never select this table: their feed comes from
-- the matching function, so one cannot enumerate the market (RLS matrix §5).
GRANT SELECT ON public.requests TO authenticated;
CREATE POLICY requests_read_own ON public.requests FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- Drafts are edited in place through column grants; `status`, money snapshots and the rest stay
-- server-owned. The WITH CHECK keeps an edit inside `draft` and inside the caller's own rows.
GRANT UPDATE (description, urgency, pickup_label, pickup_landmark_note, destination_label,
              destination_landmark_note, scheduled_at, preferred_price_minor, item_float_minor,
              declared_value_minor)
  ON public.requests TO authenticated;
CREATE POLICY requests_update_own_draft ON public.requests FOR UPDATE TO authenticated
  USING (customer_id = (SELECT auth.uid()) AND status = 'draft')
  WITH CHECK (customer_id = (SELECT auth.uid()) AND status = 'draft');

CREATE TABLE public.request_media (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id   uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  kind         text NOT NULL DEFAULT 'photo' CHECK (kind IN ('photo', 'document')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, storage_path)
);
CREATE INDEX request_media_request ON public.request_media (request_id);
ALTER TABLE public.request_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.request_media FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.request_media FROM anon, authenticated;
GRANT SELECT ON public.request_media TO authenticated;
GRANT ALL ON public.request_media TO service_role;
CREATE POLICY request_media_read_own ON public.request_media FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = request_media.request_id AND r.customer_id = (SELECT auth.uid())));

-- ---------------------------------------------------------------------------
-- create_request — always a draft, never published in the same call (the publish step is a
-- separate tap in every surface, including the concierge's publish card: ai-design §98).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.create_request(
  p_idempotency_key text,
  p_category_key text,
  p_description text,
  p_pickup_label text,
  p_urgency public.urgency DEFAULT 'standard',
  p_is_custom_category boolean DEFAULT false,
  p_custom_category_label text DEFAULT NULL,
  p_pickup_landmark_note text DEFAULT NULL,
  p_pickup_lat double precision DEFAULT NULL,
  p_pickup_lng double precision DEFAULT NULL,
  p_destination_label text DEFAULT NULL,
  p_destination_landmark_note text DEFAULT NULL,
  p_destination_lat double precision DEFAULT NULL,
  p_destination_lng double precision DEFAULT NULL,
  p_scheduled_at timestamptz DEFAULT NULL,
  p_preferred_price_minor bigint DEFAULT NULL,
  p_item_float_minor bigint DEFAULT NULL,
  p_declared_value_minor bigint DEFAULT NULL,
  p_city_code text DEFAULT NULL,
  p_created_via public.request_channel DEFAULT 'app',
  p_media_paths text[] DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_country  char(2);
  v_currency char(3);
  v_city     uuid;
  v_category uuid;
  v_id       uuid;
  v_path     text;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_request',
    jsonb_build_object('category', p_category_key, 'description', p_description,
      'pickup', p_pickup_label, 'destination', p_destination_label, 'urgency', p_urgency,
      'scheduled_at', p_scheduled_at, 'preferred_price_minor', p_preferred_price_minor,
      'item_float_minor', p_item_float_minor, 'declared_value_minor', p_declared_value_minor));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'request_id')::uuid;
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.currency_code INTO v_currency FROM public.countries c WHERE c.code = v_country;

  SELECT sc.id INTO v_category FROM public.service_categories sc
  WHERE sc.key = p_category_key AND sc.active;
  IF v_category IS NULL THEN
    RAISE EXCEPTION 'ERR_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF p_city_code IS NOT NULL THEN
    SELECT ci.id INTO v_city FROM public.cities ci
    WHERE ci.country_code = v_country AND ci.code = p_city_code;
  END IF;

  INSERT INTO public.requests (
    customer_id, country_code, city_id, category_id, is_custom_category, custom_category_label,
    description, urgency, pickup_label, pickup_landmark_note, pickup_point,
    destination_label, destination_landmark_note, destination_point,
    scheduled_at, preferred_price_minor, item_float_minor, declared_value_minor,
    currency, created_via)
  VALUES (
    v_uid, v_country, v_city, v_category, p_is_custom_category, p_custom_category_label,
    p_description, p_urgency, p_pickup_label, p_pickup_landmark_note,
    CASE WHEN p_pickup_lat IS NULL OR p_pickup_lng IS NULL THEN NULL
         ELSE extensions.ST_SetSRID(extensions.ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::extensions.geography END,
    p_destination_label, p_destination_landmark_note,
    CASE WHEN p_destination_lat IS NULL OR p_destination_lng IS NULL THEN NULL
         ELSE extensions.ST_SetSRID(extensions.ST_MakePoint(p_destination_lng, p_destination_lat), 4326)::extensions.geography END,
    p_scheduled_at, p_preferred_price_minor, p_item_float_minor, p_declared_value_minor,
    v_currency, p_created_via)
  RETURNING id INTO v_id;

  IF p_media_paths IS NOT NULL THEN
    FOREACH v_path IN ARRAY p_media_paths LOOP
      INSERT INTO public.request_media (request_id, storage_path) VALUES (v_id, v_path)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, jsonb_build_object('request_id', v_id));
  RETURN v_id;
EXCEPTION
  WHEN check_violation OR invalid_text_representation THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
END $$;

-- ---------------------------------------------------------------------------
-- publish_request — draft → published. Verified customers only, in a country that is open,
-- and the request TTL starts here (offer TTLs are per category, set when offers arrive).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.publish_request(p_request_id uuid, p_idempotency_key text)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_status  public.country_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'publish_request',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_request FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status <> 'draft' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.user_id = v_uid AND p.customer_verification = 'verified') THEN
    RAISE EXCEPTION 'ERR_VERIFICATION_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.status INTO v_status FROM public.countries c WHERE c.code = v_request.country_code;
  IF v_status NOT IN ('live', 'beta') THEN
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
                       'country_code', v_request.country_code, 'urgency', v_request.urgency));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'published'));
  RETURN 'published'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- cancel_request — customer-side cancellation before anyone is paid. Cancelling after a job is
-- agreed involves fees and refunds (money flows, Phase 5), so only the pre-agreement states are
-- allowed here; the rest arrive with the job state machine.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.cancel_request(
  p_request_id uuid, p_idempotency_key text, p_reason_code text DEFAULT NULL)
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
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'cancel_request',
    jsonb_build_object('request_id', p_request_id, 'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('draft', 'published', 'offers_received', 'negotiating') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.requests r
  SET status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason_code = p_reason_code,
      expires_at = NULL,
      version = r.version + 1
  WHERE r.id = p_request_id;

  PERFORM private.emit_event('request', p_request_id::text, 'request.cancelled',
    jsonb_build_object('from_status', v_status, 'reason', p_reason_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'cancelled'));
  RETURN 'cancelled'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- expire_requests — called by the scheduler; a published request nobody took goes `expired`.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.expire_requests(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH due AS (
    SELECT r.id FROM public.requests r
    WHERE r.status IN ('published', 'offers_received', 'negotiating')
      AND r.expires_at IS NOT NULL AND r.expires_at <= now()
    ORDER BY r.expires_at
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), updated AS (
    UPDATE public.requests r
    SET status = 'expired', expires_at = NULL, version = r.version + 1
    FROM due WHERE r.id = due.id
    RETURNING r.id
  )
  SELECT count(*)::int INTO v_count FROM updated;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.create_request(text, text, text, text, public.urgency, boolean, text, text,
                        double precision, double precision, text, text, double precision,
                        double precision, timestamptz, bigint, bigint, bigint, text,
                        public.request_channel, text[]),
  public.publish_request(uuid, text),
  public.cancel_request(uuid, text, text),
  private.expire_requests(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.create_request(text, text, text, text, public.urgency, boolean, text, text,
                        double precision, double precision, text, text, double precision,
                        double precision, timestamptz, bigint, bigint, bigint, text,
                        public.request_channel, text[]),
  public.publish_request(uuid, text),
  public.cancel_request(uuid, text, text)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('requests-expire', '*/5 * * * *',
      $cron$SELECT private.expire_requests()$cron$);
  END IF;
END $$;
