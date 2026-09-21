-- Phase 4, part 1: SOS, trusted contacts and trip sharing (ERD §2 and §10; RLS matrix §2 and §9;
-- PRD SH-24, SH-25, SH-26; runbook RB-06; data flows 14 and 23).
--
-- Continues under ADR-0013 and ADR-0014: built before contracts v1, on the same terms.
--
-- Three rules from the PRD shape everything here:
--
--   * **SH-24 — raising SOS is one tap and must not fail quietly.** It writes the incident,
--     notifies operations, records the partner dispatch attempt and tells the user's trusted
--     contacts, in one transaction. Re-raising while one is open returns the same incident: a
--     frightened person pressing twice must not open two cases.
--   * **SH-25 — at most five trusted contacts**, enforced in the database rather than in a screen.
--     Phone numbers arrive encrypted with their blind index (ADR-0007); nothing in SQL decrypts.
--   * **SH-26 — a share link is a token, and only its hash is stored.** The token is returned once
--     and never again, it expires, it can be revoked, and reading it is the **one intentional
--     anonymous read in the system** (RLS matrix §9) — so it returns the least that is useful: is
--     the job still active, where is the provider, nothing about who anyone is.
--
-- **The partner integration is a seam, not an integration.** No security partner is contracted
-- (client action 12), so `sos_partners` ships empty and dispatch records the attempt and escalates
-- when nobody acknowledges. When a partner exists, the worker that calls their API reads the
-- dispatch rows; `secret_ref` names a Vault entry and never holds the secret itself.

CREATE TYPE public.sos_status AS ENUM
  ('open', 'acknowledged', 'dispatched', 'resolved', 'false_alarm');

CREATE TYPE public.sos_partner_integration AS ENUM ('api', 'console', 'phone');

-- ---------------------------------------------------------------------------
-- trusted_contacts
-- ---------------------------------------------------------------------------
CREATE TABLE public.trusted_contacts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name              text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  -- ADR-0007: ciphertext and a keyed blind index, both produced outside the database.
  phone_ciphertext  bytea NOT NULL,
  phone_blind_index bytea NOT NULL,
  relationship_key  text CHECK (relationship_key IS NULL OR length(relationship_key) <= 40),
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- The same number twice is a mistake, not a second contact.
  UNIQUE (user_id, phone_blind_index)
);
CREATE INDEX trusted_contacts_user ON public.trusted_contacts (user_id, created_at);

ALTER TABLE public.trusted_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trusted_contacts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.trusted_contacts FROM anon, authenticated;
GRANT SELECT ON public.trusted_contacts TO authenticated;
GRANT ALL ON public.trusted_contacts TO service_role;
-- Your own list, and nobody else's — including support. The RLS matrix is deliberate about this:
-- nobody operates on trusted contacts, so nobody reads them.
CREATE POLICY trusted_contacts_read_own ON public.trusted_contacts FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Five, enforced where it cannot be forgotten (SH-25).
CREATE FUNCTION private.trusted_contacts_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_max integer := coalesce(private.remote_config_int('trusted_contacts_max'), 5);
BEGIN
  IF (SELECT count(*) FROM public.trusted_contacts t WHERE t.user_id = NEW.user_id) >= v_max THEN
    RAISE EXCEPTION 'ERR_TRUSTED_CONTACT_LIMIT' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trusted_contacts_limit BEFORE INSERT ON public.trusted_contacts
  FOR EACH ROW EXECUTE FUNCTION private.trusted_contacts_limit();

CREATE FUNCTION public.add_trusted_contact(
  p_name text, p_phone_ciphertext bytea, p_phone_blind_index bytea,
  p_relationship_key text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
  v_id  uuid;
BEGIN
  IF p_name IS NULL OR btrim(p_name) = '' OR p_phone_ciphertext IS NULL
     OR p_phone_blind_index IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.trusted_contacts (user_id, name, phone_ciphertext, phone_blind_index,
                                       relationship_key)
  VALUES (v_uid, btrim(p_name), p_phone_ciphertext, p_phone_blind_index, p_relationship_key)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION public.remove_trusted_contact(p_contact_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  DELETE FROM public.trusted_contacts t
  WHERE t.id = p_contact_id AND t.user_id = v_uid;
  RETURN FOUND;
END $$;

-- ---------------------------------------------------------------------------
-- sos_partners — who to call in a given city. Empty until one is contracted.
-- ---------------------------------------------------------------------------
CREATE TABLE public.sos_partners (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code     char(2) NOT NULL REFERENCES public.countries (code),
  city_id          uuid REFERENCES public.cities (id),
  name             text NOT NULL,
  integration      public.sos_partner_integration NOT NULL DEFAULT 'phone',
  -- The name of a Vault entry. The secret itself is never in this table, or in any migration.
  secret_ref       text CHECK (secret_ref IS NULL OR length(secret_ref) <= 120),
  escalation_phone text,
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sos_partners_area ON public.sos_partners (country_code, city_id) WHERE active;

ALTER TABLE public.sos_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sos_partners FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sos_partners FROM anon, authenticated;
GRANT SELECT ON public.sos_partners TO authenticated;
GRANT ALL ON public.sos_partners TO service_role;
-- Support and ops see the partner's name and escalation number; users never do.
CREATE POLICY sos_partners_read_ops ON public.sos_partners FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(
            ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- sos_incidents
-- ---------------------------------------------------------------------------
CREATE TABLE public.sos_incidents (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                uuid REFERENCES public.requests (id) ON DELETE SET NULL,
  raised_by                 uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  point                     extensions.geography(Point, 4326),
  status                    public.sos_status NOT NULL DEFAULT 'open',
  partner_id                uuid REFERENCES public.sos_partners (id),
  partner_notified_at       timestamptz,
  partner_ack_at            timestamptz,
  ops_assignee_id           uuid REFERENCES auth.users (id),
  ops_ack_at                timestamptz,
  trusted_contacts_notified integer NOT NULL DEFAULT 0,
  resolution_note           text,
  resolved_at               timestamptz,
  escalated_at              timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);
-- The ops queue: everything still live, cheapest to find.
CREATE INDEX sos_incidents_queue ON public.sos_incidents (created_at)
  WHERE status IN ('open', 'acknowledged', 'dispatched');
-- One open incident per person per job; a second press joins the first (SH-24).
CREATE UNIQUE INDEX sos_incidents_one_open ON public.sos_incidents (raised_by, request_id)
  WHERE status IN ('open', 'acknowledged', 'dispatched');
CREATE INDEX sos_incidents_request ON public.sos_incidents (request_id, created_at DESC);
CREATE TRIGGER sos_incidents_touch BEFORE UPDATE ON public.sos_incidents
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.sos_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sos_incidents FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.sos_incidents FROM anon, authenticated;
GRANT SELECT ON public.sos_incidents TO authenticated;
GRANT ALL ON public.sos_incidents TO service_role;
-- The person who raised it, the other party on that job, and ops. The counterparty sees it
-- because on an active job they may be the one who can help first.
CREATE POLICY sos_incidents_read ON public.sos_incidents FOR SELECT TO authenticated
  USING (raised_by = (SELECT auth.uid())
         OR (request_id IS NOT NULL AND (SELECT private.is_job_participant(sos_incidents.request_id)))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- raise_sos — the one-tap path. Everything it must do happens in this transaction.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.raise_sos(
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_existing  uuid;
  v_id        uuid;
  v_point     extensions.geography(Point, 4326);
  v_country   char(2);
  v_city      uuid;
  v_partner   uuid;
  v_contacts  integer;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'raise_sos',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'incident_id')::uuid;
  END IF;

  -- A second press while one is open joins the first. Someone in trouble pressing twice must not
  -- open two cases, and must not be told "you already did that" either.
  SELECT s.id INTO v_existing FROM public.sos_incidents s
  WHERE s.raised_by = v_uid
    AND s.request_id IS NOT DISTINCT FROM p_request_id
    AND s.status IN ('open', 'acknowledged', 'dispatched');
  IF FOUND THEN
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('incident_id', v_existing));
    RETURN v_existing;
  END IF;

  IF p_request_id IS NOT NULL AND NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  SELECT r.city_id INTO v_city FROM public.requests r WHERE r.id = p_request_id;
  SELECT sp.id INTO v_partner FROM public.sos_partners sp
  WHERE sp.active AND sp.country_code = v_country
    AND (sp.city_id = v_city OR sp.city_id IS NULL)
  ORDER BY sp.city_id NULLS LAST
  LIMIT 1;

  SELECT count(*)::int INTO v_contacts FROM public.trusted_contacts t WHERE t.user_id = v_uid;

  INSERT INTO public.sos_incidents (request_id, raised_by, point, partner_id,
                                    partner_notified_at, trusted_contacts_notified)
  VALUES (p_request_id, v_uid, v_point, v_partner,
          CASE WHEN v_partner IS NOT NULL THEN now() END, v_contacts)
  RETURNING id INTO v_id;

  -- Operations, the partner and the contacts are all told through the outbox, in this
  -- transaction: an incident that exists but was never dispatched is the failure mode this
  -- design exists to prevent. The senders decrypt the contact numbers; SQL never sees them.
  PERFORM private.emit_event('sos', v_id::text, 'sos.raised',
    jsonb_build_object('incident_id', v_id, 'request_id', p_request_id, 'raised_by', v_uid,
                       'country_code', v_country, 'city_id', v_city, 'partner_id', v_partner,
                       'trusted_contact_count', v_contacts,
                       'has_location', v_point IS NOT NULL));
  PERFORM private.broadcast('ops:sos', 'sos.raised',
    jsonb_build_object('incident_id', v_id, 'request_id', p_request_id,
                       'country_code', v_country, 'city_id', v_city));

  -- The counterparty on the job is told something is wrong, without detail.
  IF p_request_id IS NOT NULL THEN
    PERFORM private.broadcast('job:' || p_request_id::text, 'sos.raised',
      jsonb_build_object('incident_id', v_id));
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('incident_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- The ops console's three verbs (RLS matrix §9: support acknowledges, escalates, resolves).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.update_sos_incident(
  p_idempotency_key text,
  p_incident_id uuid,
  p_status public.sos_status,
  p_note text DEFAULT NULL
)
RETURNS public.sos_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_from  public.sos_status;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'update_sos_incident',
    jsonb_build_object('incident_id', p_incident_id, 'status', p_status));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.sos_status;
  END IF;

  SELECT s.status INTO v_from FROM public.sos_incidents s
  WHERE s.id = p_incident_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_SOS_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- A closed incident stays closed: reopening hides how long the first one really took.
  IF v_from IN ('resolved', 'false_alarm') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.sos_incidents s
  SET status = p_status,
      ops_assignee_id = coalesce(s.ops_assignee_id, v_uid),
      ops_ack_at = coalesce(s.ops_ack_at, now()),
      partner_ack_at = CASE WHEN p_status = 'dispatched' THEN coalesce(s.partner_ack_at, now())
                            ELSE s.partner_ack_at END,
      resolution_note = coalesce(p_note, s.resolution_note),
      resolved_at = CASE WHEN p_status IN ('resolved', 'false_alarm') THEN now()
                         ELSE s.resolved_at END
  WHERE s.id = p_incident_id;

  PERFORM private.emit_event('sos', p_incident_id::text, 'sos.' || p_status::text,
    jsonb_build_object('incident_id', p_incident_id, 'from_status', v_from,
                       'to_status', p_status, 'by', v_uid, 'note', p_note));
  PERFORM private.broadcast('ops:sos', 'sos.updated',
    jsonb_build_object('incident_id', p_incident_id, 'status', p_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', p_status));
  RETURN p_status;
END $$;

-- AD-21: an incident nobody has acknowledged escalates rather than sitting in a queue.
CREATE FUNCTION private.escalate_unacked_sos(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_minutes integer := coalesce(private.remote_config_int('sos_escalate_after_minutes'), 3);
  v_row     record;
  v_count   integer := 0;
BEGIN
  FOR v_row IN
    SELECT s.id, s.request_id FROM public.sos_incidents s
    WHERE s.status = 'open'
      AND s.escalated_at IS NULL
      AND s.created_at <= now() - make_interval(mins => v_minutes)
    ORDER BY s.created_at
    LIMIT p_limit
  LOOP
    UPDATE public.sos_incidents s SET escalated_at = now() WHERE s.id = v_row.id;
    PERFORM private.emit_event('sos', v_row.id::text, 'sos.escalated',
      jsonb_build_object('incident_id', v_row.id, 'request_id', v_row.request_id,
                         'after_minutes', v_minutes));
    PERFORM private.broadcast('ops:sos', 'sos.escalated',
      jsonb_build_object('incident_id', v_row.id));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- trip_share_links — SH-26. Only the hash is stored; the token is returned once.
-- ---------------------------------------------------------------------------
CREATE TABLE public.trip_share_links (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,
  created_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX trip_share_links_request ON public.trip_share_links (request_id, created_at DESC);

ALTER TABLE public.trip_share_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_share_links FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.trip_share_links FROM anon, authenticated;
GRANT SELECT ON public.trip_share_links TO authenticated;
GRANT ALL ON public.trip_share_links TO service_role;
-- You can see and revoke the links you made. Nobody can read the hash back into a token.
CREATE POLICY trip_share_links_read_own ON public.trip_share_links FOR SELECT TO authenticated
  USING (created_by = (SELECT auth.uid()));

CREATE FUNCTION public.create_trip_share(
  p_idempotency_key text, p_request_id uuid, p_ttl_minutes integer DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_ttl    integer := coalesce(p_ttl_minutes,
                               private.remote_config_int('trip_share_ttl_minutes'), 60);
  v_token  text;
  v_id     uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_trip_share',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    -- A replay cannot return the token: it was never stored. It returns the link's id, and the
    -- caller that lost the token asks for a new link.
    RETURN v_claim ->> 'share_id';
  END IF;

  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- 32 bytes of uuid entropy, hex: unguessable, and nothing about it identifies the job.
  v_token := replace(gen_random_uuid()::text, '-', '') ||
             replace(gen_random_uuid()::text, '-', '');
  v_ttl := least(greatest(v_ttl, 5), 1440);

  INSERT INTO public.trip_share_links (request_id, token_hash, created_by, expires_at)
  VALUES (p_request_id, sha256(convert_to(v_token, 'UTF8')), v_uid,
          now() + make_interval(mins => v_ttl))
  RETURNING id INTO v_id;

  PERFORM private.emit_event('request', p_request_id::text, 'trip.shared',
    jsonb_build_object('share_id', v_id, 'created_by', v_uid, 'ttl_minutes', v_ttl));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('share_id', v_id));
  RETURN v_token;
END $$;

CREATE FUNCTION public.revoke_trip_share(p_share_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  UPDATE public.trip_share_links l SET revoked_at = now()
  WHERE l.id = p_share_id AND l.created_by = v_uid AND l.revoked_at IS NULL;
  RETURN FOUND;
END $$;

-- ---------------------------------------------------------------------------
-- get_shared_trip — the one intentional anonymous read (RLS matrix §9).
--
-- Whoever holds the token sees the least that makes the link useful: whether the job is still
-- running, roughly where the provider is, and when the link dies. No names, no phone numbers, no
-- addresses, no amounts. The link stops working the moment the job ends, the window passes or the
-- person who made it revokes it — the query enforces all three rather than trusting the caller.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_shared_trip(p_token text)
RETURNS TABLE (
  status          public.job_status,
  provider_lat    double precision,
  provider_lng    double precision,
  updated_at      timestamptz,
  destination_lat double precision,
  destination_lng double precision,
  expires_at      timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_link public.trip_share_links%ROWTYPE;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN
    RETURN;
  END IF;

  SELECT * INTO v_link FROM public.trip_share_links l
  WHERE l.token_hash = sha256(convert_to(p_token, 'UTF8'));
  -- An unknown, expired or revoked token returns nothing at all: no row, no error, nothing to
  -- tell someone guessing whether they guessed a real one.
  IF NOT FOUND OR v_link.revoked_at IS NOT NULL OR v_link.expires_at <= now() THEN
    RETURN;
  END IF;

  UPDATE public.trip_share_links l SET last_seen_at = now() WHERE l.id = v_link.id;

  RETURN QUERY
  SELECT r.status,
         extensions.ST_Y(pl.pos::extensions.geometry),
         extensions.ST_X(pl.pos::extensions.geometry),
         pl.updated_at,
         extensions.ST_Y(r.destination_point::extensions.geometry),
         extensions.ST_X(r.destination_point::extensions.geometry),
         v_link.expires_at
  FROM public.requests r
  LEFT JOIN public.jobs j ON j.request_id = r.id
  LEFT JOIN public.provider_live_location pl
    ON pl.provider_id = coalesce(j.worker_id, j.provider_id)
  WHERE r.id = v_link.request_id
    -- Only while the job is actually running (SH-26).
    AND r.status IN ('assigned', 'en_route', 'arrived', 'in_progress', 'completed_by_provider');
END $$;

REVOKE ALL ON FUNCTION
  public.add_trusted_contact(text, bytea, bytea, text),
  public.remove_trusted_contact(uuid),
  public.raise_sos(text, uuid, double precision, double precision),
  public.update_sos_incident(text, uuid, public.sos_status, text),
  public.create_trip_share(text, uuid, integer),
  public.revoke_trip_share(uuid),
  public.get_shared_trip(text),
  private.trusted_contacts_limit(),
  private.escalate_unacked_sos(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.add_trusted_contact(text, bytea, bytea, text),
  public.remove_trusted_contact(uuid),
  public.raise_sos(text, uuid, double precision, double precision),
  public.update_sos_incident(text, uuid, public.sos_status, text),
  public.create_trip_share(text, uuid, integer),
  public.revoke_trip_share(uuid)
  TO authenticated;
-- The one function anon may call, and the only one (RLS matrix §9). A shared trip is meant to
-- work for someone who does not have the app.
GRANT EXECUTE ON FUNCTION public.get_shared_trip(text) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('sos-escalate', '* * * * *',
      $cron$SELECT private.escalate_unacked_sos()$cron$);
  END IF;
END $$;
