-- Suskii Meet (owner decision 2026-10-24): people create and join social meet-ups and events.
--
-- It is the platform's first feature where strangers arrange to be in the same place without a
-- job, a payment or a verified provider between them, so the design is mostly about who can see
-- what:
--
--   * Signed-in people in the meet-up's own country see it; nobody signed out does. A venue is a
--     named public place and one point, chosen by the host; nobody's home address or live
--     location is stored, and the caller's own position is used to sort and never kept.
--   * The attendee list is visible only to the host and to people who are going. Everyone else
--     sees a count. Names are first names only.
--   * People who have blocked each other never see each other's meet-ups and cannot join them.
--   * Title and description go through the same deterministic rules as a request
--     (`private.moderate_text`): `block` refuses, `hold` publishes and opens a moderation case
--     (OD-21 fail-open), and upholding that case cancels the meet-up.
--   * A host has at most `meetup_max_active_hosted` (3) upcoming meet-ups, a meet-up starts at
--     least 30 minutes and at most 90 days ahead and lasts at most 24 hours, and capacity is 2-500.
--
-- No identity verification is required (verification is for service providers). Reporting a host
-- uses the existing `reports` flow against the host's user id.
--
-- Clients reach the tables only through the functions below: no table grant to `authenticated`.

CREATE TYPE public.meetup_topic AS ENUM (
  'social', 'sports_fitness', 'business_networking', 'learning', 'faith', 'arts_culture',
  'food_drink', 'outdoors', 'other');
CREATE TYPE public.meetup_status AS ENUM ('published', 'cancelled');

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('meetup_max_active_hosted', NULL, '3', false);

CREATE TABLE public.meetups (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  host_id           uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  country_code      char(2) NOT NULL REFERENCES public.countries (code),
  title             text NOT NULL CHECK (length(btrim(title)) BETWEEN 3 AND 80),
  description       text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  topic             public.meetup_topic NOT NULL DEFAULT 'social',
  venue_name        text NOT NULL CHECK (length(btrim(venue_name)) BETWEEN 2 AND 120),
  venue_point       extensions.geography(Point, 4326) NOT NULL,
  starts_at         timestamptz NOT NULL,
  ends_at           timestamptz NOT NULL,
  capacity          smallint NOT NULL CHECK (capacity BETWEEN 2 AND 500),
  status            public.meetup_status NOT NULL DEFAULT 'published',
  moderation_status public.moderation_status NOT NULL DEFAULT 'pending',
  moderation_flags  text[] NOT NULL DEFAULT '{}'::text[],
  cancelled_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  version           integer NOT NULL DEFAULT 1,
  CONSTRAINT meetups_window CHECK (ends_at > starts_at AND ends_at <= starts_at + interval '24 hours')
);
CREATE INDEX meetups_upcoming ON public.meetups (country_code, starts_at) WHERE status = 'published';
CREATE INDEX meetups_host ON public.meetups (host_id, starts_at);
CREATE INDEX meetups_venue ON public.meetups USING gist (venue_point);
CREATE TRIGGER meetups_touch BEFORE UPDATE ON public.meetups
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

CREATE TABLE public.meetup_attendees (
  meetup_id uuid NOT NULL REFERENCES public.meetups (id) ON DELETE CASCADE,
  user_id   uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (meetup_id, user_id)
);
CREATE INDEX meetup_attendees_user ON public.meetup_attendees (user_id);

ALTER TABLE public.meetups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_attendees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_attendees FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.meetups, public.meetup_attendees FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.meetups, public.meetup_attendees TO service_role;

-- Moderation: a meet-up is a fifth kind of subject. The case's author is the host, which is how
-- `private.moderation_subject_countries` scopes it, so that resolver needs no new branch.
ALTER TABLE public.moderation_cases DROP CONSTRAINT moderation_cases_subject_kind_check;
ALTER TABLE public.moderation_cases ADD CONSTRAINT moderation_cases_subject_kind_check
  CHECK (subject_kind IN ('request', 'message', 'rating', 'profile', 'meetup'));

CREATE FUNCTION private.meetups_moderate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_verdict jsonb;
  v_action  public.moderation_action;
BEGIN
  v_verdict := private.moderate_text(
    NEW.title || ' ' || NEW.description || ' ' || NEW.venue_name, NEW.country_code);
  v_action := (v_verdict ->> 'action')::public.moderation_action;
  IF v_action = 'block' THEN
    RAISE EXCEPTION 'ERR_CONTENT_NOT_ALLOWED' USING ERRCODE = 'P0001',
      DETAIL = coalesce(v_verdict -> 'labels' -> 0 ->> 'rule_key', 'restricted');
  END IF;
  IF v_action = 'hold' THEN
    NEW.moderation_flags := ARRAY(SELECT l ->> 'rule_key'
                            FROM jsonb_array_elements(v_verdict -> 'labels') AS l);
    NEW.moderation_status := 'pending';
    PERFORM private.open_moderation_case('meetup', NEW.id::text, NEW.host_id, v_verdict);
  ELSE
    NEW.moderation_status := 'approved';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER meetups_moderate BEFORE INSERT ON public.meetups
  FOR EACH ROW EXECUTE FUNCTION private.meetups_moderate();

-- `decide_moderation_case` knows the four original kinds; a meet-up follows its decision here,
-- so that function is not replaced for one branch.
CREATE FUNCTION private.meetup_case_decided()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'upheld' THEN
    UPDATE public.meetups m
    SET moderation_status = 'rejected', status = 'cancelled', cancelled_at = now(),
        version = m.version + 1
    WHERE m.id = private.try_uuid(NEW.subject_id) AND m.status = 'published';
  ELSIF NEW.status = 'overturned' THEN
    UPDATE public.meetups m SET moderation_status = 'approved', version = m.version + 1
    WHERE m.id = private.try_uuid(NEW.subject_id);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER moderation_cases_meetup_decided AFTER UPDATE OF status ON public.moderation_cases
  FOR EACH ROW
  WHEN (NEW.subject_kind = 'meetup' AND OLD.status = 'open' AND NEW.status <> 'open')
  EXECUTE FUNCTION private.meetup_case_decided();

-- Visible to the caller: same country, published, not rejected, and no block either way.
CREATE FUNCTION private.meetup_visible_to(p_meetup public.meetups, p_user uuid, p_country char(2))
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT p_meetup.country_code = p_country
     AND p_meetup.moderation_status <> 'rejected'
     AND (p_meetup.status = 'published' OR p_meetup.host_id = p_user
          OR EXISTS (SELECT 1 FROM public.meetup_attendees a
                     WHERE a.meetup_id = p_meetup.id AND a.user_id = p_user))
     AND NOT private.is_blocked_pair(p_meetup.host_id, p_user);
$$;

CREATE FUNCTION private.first_name(p_display_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT split_part(btrim(coalesce(p_display_name, '')), ' ', 1);
$$;

CREATE FUNCTION private.require_profile_country(p_user uuid)
RETURNS char(2)
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = p_user;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SET' USING ERRCODE = 'P0001';
  END IF;
  RETURN v_country;
END $$;

-- One projection for every read, so a column added later is added once.
CREATE FUNCTION private.meetup_rows(p_uid uuid, p_lat double precision, p_lng double precision)
RETURNS TABLE (id uuid, title text, description text, topic public.meetup_topic, venue_name text,
               venue_lat double precision, venue_lng double precision, starts_at timestamptz,
               ends_at timestamptz, capacity integer, attendee_count integer,
               status public.meetup_status, host_first_name text, is_host boolean,
               is_attending boolean, distance_km numeric)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.id, m.title, m.description, m.topic, m.venue_name,
         extensions.ST_Y(m.venue_point::extensions.geometry),
         extensions.ST_X(m.venue_point::extensions.geometry),
         m.starts_at, m.ends_at, m.capacity::integer,
         (SELECT count(*)::integer FROM public.meetup_attendees a WHERE a.meetup_id = m.id),
         m.status,
         private.first_name(hp.display_name),
         m.host_id = p_uid,
         EXISTS (SELECT 1 FROM public.meetup_attendees a
                 WHERE a.meetup_id = m.id AND a.user_id = p_uid),
         CASE WHEN p_lat IS NULL OR p_lng IS NULL THEN NULL
              ELSE round((extensions.ST_Distance(m.venue_point,
                     extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)
                       ::extensions.geography) / 1000)::numeric, 1) END
  FROM public.meetups m
  JOIN public.profiles hp ON hp.user_id = m.host_id
  WHERE private.meetup_visible_to(m, p_uid,
          (SELECT p.country_code FROM public.profiles p WHERE p.user_id = p_uid));
$$;

CREATE FUNCTION public.create_meetup(
  p_idempotency_key text, p_title text, p_description text, p_topic public.meetup_topic,
  p_venue_name text, p_venue_lat double precision, p_venue_lng double precision,
  p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_claim   jsonb;
  v_max     integer;
  v_id      uuid;
BEGIN
  v_country := private.require_profile_country(v_uid);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_meetup',
    jsonb_build_object('title', p_title, 'starts_at', p_starts_at));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'meetup_id')::uuid;
  END IF;

  IF p_title IS NULL OR p_venue_name IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL
     OR p_capacity IS NULL OR p_venue_lat IS NULL OR p_venue_lng IS NULL
     OR p_venue_lat NOT BETWEEN -90 AND 90 OR p_venue_lng NOT BETWEEN -180 AND 180
     OR length(btrim(p_title)) NOT BETWEEN 3 AND 80
     OR length(btrim(p_venue_name)) NOT BETWEEN 2 AND 120
     OR length(coalesce(p_description, '')) > 1000
     OR p_capacity NOT BETWEEN 2 AND 500 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at < now() + interval '30 minutes' OR p_starts_at > now() + interval '90 days'
     OR p_ends_at <= p_starts_at OR p_ends_at > p_starts_at + interval '24 hours' THEN
    RAISE EXCEPTION 'ERR_MEETUP_TIME_INVALID' USING ERRCODE = 'P0001';
  END IF;

  v_max := greatest(coalesce(private.remote_config_int('meetup_max_active_hosted'), 3), 1);
  IF (SELECT count(*) FROM public.meetups m
      WHERE m.host_id = v_uid AND m.status = 'published' AND m.ends_at > now()) >= v_max THEN
    RAISE EXCEPTION 'ERR_MEETUP_LIMIT_REACHED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.meetups (host_id, country_code, title, description, topic, venue_name,
                              venue_point, starts_at, ends_at, capacity)
  VALUES (v_uid, v_country, btrim(p_title), btrim(coalesce(p_description, '')),
          coalesce(p_topic, 'social'), btrim(p_venue_name),
          extensions.ST_SetSRID(extensions.ST_MakePoint(p_venue_lng, p_venue_lat), 4326)
            ::extensions.geography,
          p_starts_at, p_ends_at, p_capacity)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('meetup', v_id::text, 'meetup.created',
    jsonb_build_object('country_code', v_country, 'starts_at', p_starts_at));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('meetup_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.list_meetups(
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL,
  p_radius_km integer DEFAULT 50, p_topic public.meetup_topic DEFAULT NULL,
  p_limit integer DEFAULT 50)
RETURNS TABLE (id uuid, title text, description text, topic public.meetup_topic, venue_name text,
               venue_lat double precision, venue_lng double precision, starts_at timestamptz,
               ends_at timestamptz, capacity integer, attendee_count integer,
               status public.meetup_status, host_first_name text, is_host boolean,
               is_attending boolean, distance_km numeric)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  PERFORM private.require_profile_country(v_uid);
  RETURN QUERY
  SELECT r.* FROM private.meetup_rows(v_uid, p_lat, p_lng) r
  WHERE r.status = 'published' AND r.ends_at > now()
    AND (p_topic IS NULL OR r.topic = p_topic)
    AND (r.distance_km IS NULL
         OR r.distance_km <= least(greatest(coalesce(p_radius_km, 50), 1), 500))
  ORDER BY r.starts_at, r.distance_km NULLS LAST, r.id
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 100);
END $$;

CREATE FUNCTION public.get_meetup(p_meetup_id uuid)
RETURNS TABLE (id uuid, title text, description text, topic public.meetup_topic, venue_name text,
               venue_lat double precision, venue_lng double precision, starts_at timestamptz,
               ends_at timestamptz, capacity integer, attendee_count integer,
               status public.meetup_status, host_first_name text, is_host boolean,
               is_attending boolean, distance_km numeric)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY SELECT r.* FROM private.meetup_rows(v_uid, NULL, NULL) r WHERE r.id = p_meetup_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEETUP_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE FUNCTION public.my_meetups()
RETURNS TABLE (id uuid, title text, description text, topic public.meetup_topic, venue_name text,
               venue_lat double precision, venue_lng double precision, starts_at timestamptz,
               ends_at timestamptz, capacity integer, attendee_count integer,
               status public.meetup_status, host_first_name text, is_host boolean,
               is_attending boolean, distance_km numeric)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY
  SELECT r.* FROM private.meetup_rows(v_uid, NULL, NULL) r
  WHERE (r.is_host OR r.is_attending) AND r.ends_at > now() - interval '30 days'
  ORDER BY r.starts_at DESC, r.id
  LIMIT 100;
END $$;

CREATE FUNCTION public.join_meetup(p_idempotency_key text, p_meetup_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_claim   jsonb;
  v_meetup  public.meetups%ROWTYPE;
  v_count   integer;
BEGIN
  v_country := private.require_profile_country(v_uid);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'join_meetup',
    jsonb_build_object('meetup_id', p_meetup_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'attendee_count')::integer;
  END IF;

  -- The row lock serialises joins, so two people cannot both take the last place.
  SELECT * INTO v_meetup FROM public.meetups m WHERE m.id = p_meetup_id FOR UPDATE;
  IF NOT FOUND OR NOT private.meetup_visible_to(v_meetup, v_uid, v_country) THEN
    RAISE EXCEPTION 'ERR_MEETUP_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_meetup.host_id = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF v_meetup.status <> 'published' OR v_meetup.starts_at <= now() THEN
    RAISE EXCEPTION 'ERR_MEETUP_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.meetup_attendees a
                 WHERE a.meetup_id = p_meetup_id AND a.user_id = v_uid) THEN
    SELECT count(*)::integer INTO v_count FROM public.meetup_attendees a
    WHERE a.meetup_id = p_meetup_id;
    IF v_count >= v_meetup.capacity THEN
      RAISE EXCEPTION 'ERR_MEETUP_FULL' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.meetup_attendees (meetup_id, user_id) VALUES (p_meetup_id, v_uid);
  END IF;

  SELECT count(*)::integer INTO v_count FROM public.meetup_attendees a
  WHERE a.meetup_id = p_meetup_id;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('attendee_count', v_count));
  RETURN v_count;
END $$;

CREATE FUNCTION public.leave_meetup(p_meetup_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  DELETE FROM public.meetup_attendees a WHERE a.meetup_id = p_meetup_id AND a.user_id = v_uid;
  RETURN FOUND;
END $$;

CREATE FUNCTION public.cancel_meetup(p_idempotency_key text, p_meetup_id uuid)
RETURNS public.meetup_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_meetup public.meetups%ROWTYPE;
  v_user   uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'cancel_meetup',
    jsonb_build_object('meetup_id', p_meetup_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.meetup_status;
  END IF;

  SELECT * INTO v_meetup FROM public.meetups m
  WHERE m.id = p_meetup_id AND m.host_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEETUP_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_meetup.status = 'published' THEN
    IF v_meetup.ends_at <= now() THEN
      RAISE EXCEPTION 'ERR_MEETUP_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.meetups m
    SET status = 'cancelled', cancelled_at = now(), version = m.version + 1
    WHERE m.id = p_meetup_id;
    -- The push carries no title or venue: a lock screen shows only that a meet-up was cancelled.
    FOR v_user IN SELECT a.user_id FROM public.meetup_attendees a WHERE a.meetup_id = p_meetup_id
    LOOP
      PERFORM private.notify(v_user, 'system', 'notification.meetup.cancelled.title',
        'notification.meetup.cancelled.body', jsonb_build_object('meetup_id', p_meetup_id),
        '/meet/' || p_meetup_id::text);
    END LOOP;
    PERFORM private.emit_event('meetup', p_meetup_id::text, 'meetup.cancelled', '{}'::jsonb);
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'cancelled'));
  RETURN 'cancelled'::public.meetup_status;
END $$;

-- First names of who is going, for the host and the people going; nobody else.
CREATE FUNCTION public.meetup_attendees(p_meetup_id uuid)
RETURNS TABLE (first_name text, is_host boolean, joined_at timestamptz)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM private.meetup_rows(v_uid, NULL, NULL) r
                 WHERE r.id = p_meetup_id AND (r.is_host OR r.is_attending)) THEN
    RAISE EXCEPTION 'ERR_MEETUP_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  SELECT private.first_name(p.display_name), true, m.created_at
  FROM public.meetups m JOIN public.profiles p ON p.user_id = m.host_id
  WHERE m.id = p_meetup_id
  UNION ALL
  (SELECT private.first_name(p.display_name), false, a.joined_at
   FROM public.meetup_attendees a JOIN public.profiles p ON p.user_id = a.user_id
   WHERE a.meetup_id = p_meetup_id
     AND NOT private.is_blocked_pair(a.user_id, v_uid)
   ORDER BY a.joined_at);
END $$;

REVOKE ALL ON FUNCTION
  private.meetups_moderate(), private.meetup_case_decided(),
  private.meetup_visible_to(public.meetups, uuid, char), private.first_name(text),
  private.require_profile_country(uuid),
  private.meetup_rows(uuid, double precision, double precision)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.create_meetup(text, text, text, public.meetup_topic, text, double precision,
                       double precision, timestamptz, timestamptz, integer),
  public.list_meetups(double precision, double precision, integer, public.meetup_topic, integer),
  public.get_meetup(uuid), public.my_meetups(), public.join_meetup(text, uuid),
  public.leave_meetup(uuid), public.cancel_meetup(text, uuid), public.meetup_attendees(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.create_meetup(text, text, text, public.meetup_topic, text, double precision,
                       double precision, timestamptz, timestamptz, integer),
  public.list_meetups(double precision, double precision, integer, public.meetup_topic, integer),
  public.get_meetup(uuid), public.my_meetups(), public.join_meetup(text, uuid),
  public.leave_meetup(uuid), public.cancel_meetup(text, uuid), public.meetup_attendees(uuid)
TO authenticated;

-- Export and erasure learn about meet-ups. Both are replaced whole, from their latest versions
-- (20261012130000 and 20260929120100), with only the meet-up lines added.
CREATE OR REPLACE FUNCTION private.collect_personal_data(p_user uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'generated_at', now(),
    'account', (SELECT jsonb_build_object('id', u.id, 'phone', u.phone, 'email', u.email,
                                          'created_at', u.created_at)
                FROM auth.users u WHERE u.id = p_user),
    'profile', (SELECT to_jsonb(p) - 'version' FROM public.profiles p WHERE p.user_id = p_user),
    'consents', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'granted', c.granted,
                                                              'recorded_at', c.recorded_at)
                                           ORDER BY c.id), '[]'::jsonb)
                 FROM public.consents c WHERE c.user_id = p_user),
    'devices', (SELECT coalesce(jsonb_agg(jsonb_build_object('platform', d.platform,
                                                             'app_version', d.app_version,
                                                             'created_at', d.created_at,
                                                             'last_seen_at', d.last_seen_at)
                                          ORDER BY d.created_at), '[]'::jsonb)
                FROM public.user_devices d WHERE d.user_id = p_user),
    'saved_places', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                       'label', sp.label,
                                       'lat', extensions.ST_Y(sp.point::extensions.geometry),
                                       'lng', extensions.ST_X(sp.point::extensions.geometry),
                                       'landmark_note', sp.landmark_note,
                                       'access_note', private.open('access_note',
                                          sp.access_note_ciphertext, 'saved_place:' || sp.id),
                                       'created_at', sp.created_at)
                                     ORDER BY sp.created_at), '[]'::jsonb)
                     FROM public.saved_places sp WHERE sp.user_id = p_user),
    'trusted_contacts', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                           'name', tc.name,
                                           -- Rows written before this migration carried bytes
                                           -- nothing can open; they export masked or empty.
                                           'phone', CASE WHEN tc.phone_masked IS NOT NULL THEN
                                             private.open('trusted_contact_phone',
                                               tc.phone_ciphertext, 'trusted_contact:' || tc.id)
                                           END,
                                           'relationship_key', tc.relationship_key,
                                           'created_at', tc.created_at)
                                         ORDER BY tc.created_at), '[]'::jsonb)
                         FROM public.trusted_contacts tc WHERE tc.user_id = p_user),
    'requests', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status,
                                                              'created_at', r.created_at)
                                           ORDER BY r.created_at), '[]'::jsonb)
                 FROM public.requests r WHERE r.customer_id = p_user),
    'jobs_as_provider', (SELECT coalesce(jsonb_agg(jsonb_build_object('request_id', j.request_id,
                                                                      'assigned_at', j.assigned_at)
                                                   ORDER BY j.assigned_at), '[]'::jsonb)
                         FROM public.jobs j WHERE j.provider_id = p_user OR j.worker_id = p_user),
    'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pm.id, 'status', pm.status,
                                                              'amount_minor', pm.amount_minor,
                                                              'currency', pm.currency,
                                                              'created_at', pm.created_at)
                                           ORDER BY pm.created_at), '[]'::jsonb)
                 FROM public.payments pm WHERE pm.payer_id = p_user),
    'ratings_given', (SELECT coalesce(jsonb_agg(jsonb_build_object('request_id', rt.request_id,
                                                                   'stars', rt.stars,
                                                                   'comment', rt.comment)), '[]'::jsonb)
                      FROM public.ratings rt WHERE rt.rater_id = p_user),
    'support_tickets', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'category', t.category,
                                                                     'status', t.status,
                                                                     'created_at', t.created_at)
                                                  ORDER BY t.created_at), '[]'::jsonb)
                        FROM public.support_tickets t WHERE t.user_id = p_user),
    'meetups_hosted', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title,
                                                                    'description', m.description,
                                                                    'venue_name', m.venue_name,
                                                                    'starts_at', m.starts_at,
                                                                    'status', m.status)
                                                 ORDER BY m.starts_at), '[]'::jsonb)
                       FROM public.meetups m WHERE m.host_id = p_user),
    'meetups_joined', (SELECT coalesce(jsonb_agg(jsonb_build_object('meetup_id', a.meetup_id,
                                                                    'joined_at', a.joined_at)
                                                 ORDER BY a.joined_at), '[]'::jsonb)
                       FROM public.meetup_attendees a WHERE a.user_id = p_user)
  );
$$;


CREATE OR REPLACE FUNCTION private.erase_account(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = '', avatar_path = NULL, timezone = NULL
  WHERE user_id = p_user;

  DELETE FROM public.trusted_contacts WHERE user_id = p_user;
  DELETE FROM public.saved_places WHERE user_id = p_user;
  -- Meet-ups the person hosted are their words and their chosen place; attendance is who they
  -- met. Both go, and anybody still going to an upcoming one is told it is off.
  PERFORM private.notify(a.user_id, 'system', 'notification.meetup.cancelled.title',
    'notification.meetup.cancelled.body', jsonb_build_object('meetup_id', m.id))
  FROM public.meetups m JOIN public.meetup_attendees a ON a.meetup_id = m.id
  WHERE m.host_id = p_user AND m.status = 'published' AND m.ends_at > now();
  DELETE FROM public.meetups WHERE host_id = p_user;
  DELETE FROM public.meetup_attendees WHERE user_id = p_user;
  DELETE FROM private.request_access_notes n
  USING public.requests r
  WHERE r.id = n.request_id AND r.customer_id = p_user;
  DELETE FROM public.favorites WHERE customer_id = p_user OR provider_id = p_user;
  -- Device rows are referenced by consents, which are the record of what was agreed; the
  -- addresses a push could still reach are what identify the handset, so those go.
  UPDATE public.user_devices SET push_token = NULL, voip_token = NULL WHERE user_id = p_user;
  UPDATE public.provider_profiles SET online = false WHERE user_id = p_user;

  DELETE FROM auth.sessions WHERE user_id = p_user;
  DELETE FROM auth.identities WHERE user_id = p_user;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user;
  UPDATE auth.users
  SET phone = NULL, email = NULL, encrypted_password = NULL,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = 'infinity', deleted_at = now()
  WHERE id = p_user;

  -- The user's folder in `avatars` (one folder per user, named by id).
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'avatars', 'prefix', p_user::text || '/'));

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;

