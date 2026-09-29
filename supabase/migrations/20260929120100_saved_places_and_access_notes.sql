-- Saved places and access notes (RLS matrix §2, `saved_places`; ERD §2; data flow 8; audit
-- 2026-09-22c, which asked for both before the first live country).
--
-- An access note is the most sensitive location detail a customer gives: the gate code, the
-- key under the mat, "the dog is friendly". The matrix time-boxes it, and the design follows:
--
--   * **Sealed at rest** with the `access_note` data key (ADR-0018). No client role can select
--     the ciphertext, and nothing but the functions below opens it.
--   * **The assigned provider reads it only while they are working**: en_route, arrived or
--     in_progress. Before that they do not need it, since a provider who accepted and walked away
--     must not leave with a gate code (R-05). After that it is gone. Each read is a
--     `job_events` row the customer can see.
--   * **A request's note is deleted when the job leaves the window**, whatever way it leaves:
--     completion, cancellation, expiry or dispute (data flow 8, "deleted at job close").
--   * **Nobody else reads it.** Not support and not super admin. The matrix is deliberate:
--     nobody operates on it, so nobody sees it.
--
-- A request's note does not live on `requests`. That table is granted to its readers whole, so a
-- new column there would be readable by every one of them. It lives in `private`, keyed by the
-- request, and dies with it.

SELECT private.create_field_data_key('access_note');

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('saved_places_max', NULL, '20', true)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- saved_places
-- ---------------------------------------------------------------------------
CREATE TABLE public.saved_places (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  -- What a request's pickup or destination label would say, so a saved place fills one in
  -- directly: the same bounds as `requests.pickup_label`.
  label                  text NOT NULL CHECK (length(btrim(label)) BETWEEN 2 AND 200),
  point                  extensions.geography(Point, 4326) NOT NULL,
  landmark_note          text CHECK (landmark_note IS NULL OR length(landmark_note) <= 300),
  access_note_ciphertext bytea,
  has_access_note        boolean GENERATED ALWAYS AS (access_note_ciphertext IS NOT NULL) STORED,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX saved_places_user ON public.saved_places (user_id, created_at);
CREATE TRIGGER saved_places_touch BEFORE UPDATE ON public.saved_places
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.saved_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_places FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.saved_places FROM anon, authenticated;
GRANT ALL ON public.saved_places TO service_role;
-- Everything but the ciphertext; `has_access_note` says whether there is one.
GRANT SELECT (id, user_id, label, point, landmark_note, has_access_note, created_at, updated_at)
  ON public.saved_places TO authenticated;
GRANT UPDATE (label, point, landmark_note) ON public.saved_places TO authenticated;
-- Your own, and nobody else's. Super admin included (matrix §2).
CREATE POLICY saved_places_read_own ON public.saved_places FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));
CREATE POLICY saved_places_update_own ON public.saved_places FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE FUNCTION private.saved_places_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_max integer := coalesce(private.remote_config_int('saved_places_max'), 20);
BEGIN
  IF (SELECT count(*) FROM public.saved_places p WHERE p.user_id = NEW.user_id) >= v_max THEN
    RAISE EXCEPTION 'ERR_SAVED_PLACE_LIMIT' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER saved_places_limit BEFORE INSERT ON public.saved_places
  FOR EACH ROW EXECUTE FUNCTION private.saved_places_limit();

-- The note is sealed to its place's id, so the id is chosen before the insert.
CREATE FUNCTION public.add_saved_place(
  p_idempotency_key text,
  p_label text,
  p_lat double precision,
  p_lng double precision,
  p_landmark_note text DEFAULT NULL,
  p_access_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_id    uuid := gen_random_uuid();
  v_note  text := nullif(btrim(p_access_note), '');
BEGIN
  -- The note is left out of the fingerprint: a hash of a four-digit gate code is the gate code.
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'add_saved_place',
    jsonb_build_object('label', p_label, 'lat', p_lat, 'lng', p_lng));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'place_id')::uuid;
  END IF;

  IF p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 2 AND 200
     OR p_lat IS NULL OR p_lng IS NULL
     OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180
     OR length(p_landmark_note) > 300 OR length(v_note) > 500 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.saved_places (id, user_id, label, point, landmark_note, access_note_ciphertext)
  VALUES (v_id, v_uid, btrim(p_label),
          extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography,
          nullif(btrim(p_landmark_note), ''),
          private.seal('access_note', v_note, 'saved_place:' || v_id));

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('place_id', v_id));
  RETURN v_id;
END $$;

-- Setting a value twice leaves the same state, so this carries no idempotency key. NULL or
-- blank clears the note.
CREATE FUNCTION public.set_saved_place_access_note(p_place_id uuid, p_access_note text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_note text := nullif(btrim(p_access_note), '');
BEGIN
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  UPDATE public.saved_places p
  SET access_note_ciphertext = private.seal('access_note', v_note, 'saved_place:' || p.id)
  WHERE p.id = p_place_id AND p.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_SAVED_PLACE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN v_note IS NOT NULL;
END $$;

CREATE FUNCTION public.get_saved_place_access_note(p_place_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_blob bytea;
BEGIN
  SELECT p.access_note_ciphertext INTO v_blob FROM public.saved_places p
  WHERE p.id = p_place_id AND p.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_SAVED_PLACE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN private.open('access_note', v_blob, 'saved_place:' || p_place_id);
END $$;

-- A table-level DELETE grant would be the only one in `public` (00_structure_test), so removal is
-- a function, as it is for trusted contacts.
CREATE FUNCTION public.remove_saved_place(p_place_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  DELETE FROM public.saved_places p WHERE p.id = p_place_id AND p.user_id = v_uid;
  RETURN FOUND;
END $$;

-- ---------------------------------------------------------------------------
-- A request's access note
-- ---------------------------------------------------------------------------
CREATE TABLE private.request_access_notes (
  request_id uuid PRIMARY KEY REFERENCES public.requests (id) ON DELETE CASCADE,
  ciphertext bytea NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON private.request_access_notes FROM PUBLIC, anon, authenticated;

-- The statuses in which a note is still worth keeping: everything up to and including the work.
CREATE FUNCTION private.access_note_retained(p_status public.job_status)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_status IN ('draft', 'published', 'offers_received', 'negotiating', 'agreed',
                      'payment_pending', 'paid_held', 'assigned', 'en_route', 'arrived',
                      'in_progress');
$$;

CREATE FUNCTION private.purge_access_note()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.request_access_notes n WHERE n.request_id = NEW.id;
  RETURN NULL;
END $$;

-- The list is written out rather than calling access_note_retained: a WHEN clause runs with the
-- privileges of whoever updates the row, and that function is granted to nobody.
CREATE TRIGGER requests_purge_access_note AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status
        AND NEW.status NOT IN ('draft', 'published', 'offers_received', 'negotiating', 'agreed',
                               'payment_pending', 'paid_held', 'assigned', 'en_route', 'arrived',
                               'in_progress'))
  EXECUTE FUNCTION private.purge_access_note();

-- The customer sets it, as text or from one of their saved places, until the work is done. It can
-- change while the provider travels, because gate codes do.
CREATE FUNCTION public.set_request_access_note(
  p_request_id uuid,
  p_access_note text DEFAULT NULL,
  p_saved_place_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_status public.job_status;
  v_note   text := nullif(btrim(p_access_note), '');
BEGIN
  IF v_note IS NOT NULL AND p_saved_place_id IS NOT NULL OR length(v_note) > 500 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.access_note_retained(v_status) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF p_saved_place_id IS NOT NULL THEN
    SELECT private.open('access_note', p.access_note_ciphertext, 'saved_place:' || p.id)
    INTO v_note
    FROM public.saved_places p
    WHERE p.id = p_saved_place_id AND p.user_id = v_uid;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ERR_SAVED_PLACE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_note IS NULL THEN
    DELETE FROM private.request_access_notes n WHERE n.request_id = p_request_id;
    RETURN false;
  END IF;

  INSERT INTO private.request_access_notes (request_id, ciphertext)
  VALUES (p_request_id, private.seal('access_note', v_note, 'request:' || p_request_id))
  ON CONFLICT (request_id) DO UPDATE
    SET ciphertext = EXCLUDED.ciphertext, updated_at = now();
  RETURN true;
END $$;

-- The one door, as the matrix names it. The customer who wrote the note reads it back while it
-- exists. The assigned provider, or the worker their business dispatched, reads it only while
-- the job is en_route, arrived or in_progress, and each read is written down where the customer
-- can see it. Anyone else is told the request does not exist, so an id cannot be probed. NULL
-- means there is no note.
CREATE FUNCTION public.reveal_access_note(p_request_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_customer uuid;
  v_status   public.job_status;
  v_blob     bytea;
  v_actor    public.job_actor_kind;
BEGIN
  SELECT r.customer_id, r.status INTO v_customer, v_status
  FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT n.ciphertext INTO v_blob FROM private.request_access_notes n
  WHERE n.request_id = p_request_id;

  IF v_customer = v_uid THEN
    RETURN private.open('access_note', v_blob, 'request:' || p_request_id);
  END IF;

  SELECT CASE WHEN j.provider_id = v_uid THEN 'provider' ELSE 'worker' END::public.job_actor_kind
  INTO v_actor
  FROM public.jobs j
  WHERE j.request_id = p_request_id AND j.assigned_at IS NOT NULL
    AND (j.provider_id = v_uid OR j.worker_id = v_uid);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('en_route', 'arrived', 'in_progress') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF v_blob IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                 reason_code)
  VALUES (p_request_id, v_status, v_status, v_uid, v_actor, 'access_note_revealed');
  RETURN private.open('access_note', v_blob, 'request:' || p_request_id);
END $$;

REVOKE ALL ON FUNCTION
  private.saved_places_limit(),
  private.access_note_retained(public.job_status),
  private.purge_access_note(),
  public.add_saved_place(text, text, double precision, double precision, text, text),
  public.set_saved_place_access_note(uuid, text),
  public.get_saved_place_access_note(uuid),
  public.remove_saved_place(uuid),
  public.set_request_access_note(uuid, text, uuid),
  public.reveal_access_note(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.add_saved_place(text, text, double precision, double precision, text, text),
  public.set_saved_place_access_note(uuid, text),
  public.get_saved_place_access_note(uuid),
  public.remove_saved_place(uuid),
  public.set_request_access_note(uuid, text, uuid),
  public.reveal_access_note(uuid)
TO authenticated;

-- ---------------------------------------------------------------------------
-- Export and erasure learn about saved places. The export carries the notes in the clear: it is
-- the user's own data, going to the user, and what we can read is what we know about them.
-- ---------------------------------------------------------------------------
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
                        FROM public.support_tickets t WHERE t.user_id = p_user)
  );
$$;

-- As in 20260928120000, plus saved places and any access note still on a request. Erasure waits
-- until no job is active (private.account_deletion_blocker), so the second should already be
-- empty; it is deleted anyway rather than trusted to be.
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
