-- Marketplace, part 9: businesses, fleets, vehicles and city zone rules (ERD §1 and §3; RLS
-- matrix §3; PRD BU-01…BU-10; spec phase 3, "Business accounts, members, dispatch, vehicles,
-- zone rules").
--
-- What is here: the organisation, its members and their roles, the vehicle register, dispatch to
-- a worker, worker self-accept, and the zone rule that decides which vehicle may work where.
--
-- What is not, and why:
--   * **Business verification and worker KYC are Phase 4.** An organisation carries a
--     `verification_status` that only the Verification Officer's queue will move; until then it
--     is `unverified` and `private.org_can_bid()` says no.
--   * **Payouts are Phase 5** (BU-10). No payout account column is invented here — OD-12 has not
--     settled what a Suskii entity even is per country.
--   * **Encryption follows ADR-0007**: registration numbers and plates arrive already encrypted,
--     with their blind index, from the Edge Function that holds the key. Nothing in SQL reaches a
--     secret manager, so nothing in SQL pretends to encrypt.
--
-- Zone boundaries are the client's data, not ours: the NG pack says the okada and keke polygons
-- "must come from the current state gazette", and its `_status` marks them an assumption. So the
-- table and the rule exist and are tested; the polygons stay empty until someone authoritative
-- draws them. With no zone covering a point, every vehicle is allowed — an empty map must not
-- silently ban everybody.

CREATE TABLE public.zones (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id               uuid NOT NULL REFERENCES public.cities (id) ON DELETE CASCADE,
  code                  text NOT NULL CHECK (code ~ '^[A-Z0-9-]{2,40}$'),
  name                  text NOT NULL,
  boundary              extensions.geography(MultiPolygon, 4326) NOT NULL,
  allowed_vehicle_types public.vehicle_type[] NOT NULL
                        CHECK (cardinality(allowed_vehicle_types) > 0),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (city_id, code)
);
CREATE INDEX zones_boundary ON public.zones USING gist (boundary);
CREATE TRIGGER zones_touch BEFORE UPDATE ON public.zones
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.zones FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.zones FROM anon, authenticated;
GRANT SELECT ON public.zones TO authenticated;
GRANT ALL ON public.zones TO service_role;
-- Zone rules are public knowledge: a rider is entitled to know where they may not ride.
CREATE POLICY zones_read ON public.zones FOR SELECT TO authenticated USING (true);

-- True when no zone covers the point, or every zone that does allows the vehicle.
CREATE FUNCTION private.vehicle_allowed_at(
  p_point extensions.geography, p_vehicle public.vehicle_type)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT p_point IS NULL OR p_vehicle IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.zones z
    WHERE extensions.ST_Intersects(z.boundary, p_point)
      AND NOT (p_vehicle = ANY (z.allowed_vehicle_types)));
$$;

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
CREATE TABLE public.organizations (
  id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name                     text NOT NULL CHECK (length(legal_name) BETWEEN 2 AND 200),
  country_code                   char(2) NOT NULL REFERENCES public.countries (code),
  -- ADR-0007: ciphertext and a keyed blind index, both produced outside the database.
  registration_number_ciphertext bytea NOT NULL,
  registration_blind_index       bytea NOT NULL,
  verification_status            public.verification_status NOT NULL DEFAULT 'unverified',
  created_by                     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  created_at                     timestamptz NOT NULL DEFAULT now(),
  updated_at                     timestamptz NOT NULL DEFAULT now(),
  -- One registration number cannot back two organisations in a country (BU-01).
  UNIQUE (country_code, registration_blind_index)
);
CREATE TRIGGER organizations_touch BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

CREATE TYPE public.org_member_status AS ENUM ('invited', 'active', 'removed');

CREATE TABLE public.organization_members (
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role            public.business_role NOT NULL,
  status          public.org_member_status NOT NULL DEFAULT 'invited',
  -- BU-07: a trusted worker may take a job without waiting for a dispatcher.
  can_self_accept boolean NOT NULL DEFAULT false,
  invited_by      uuid REFERENCES auth.users (id),
  joined_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, user_id)
);
CREATE INDEX organization_members_user ON public.organization_members (user_id, status);

CREATE TABLE public.vehicles (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     uuid REFERENCES public.organizations (id) ON DELETE CASCADE,
  owner_user_id       uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  type                public.vehicle_type NOT NULL,
  plate_ciphertext    bytea NOT NULL,
  plate_blind_index   bytea NOT NULL,
  assigned_worker_id  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  documents_status    public.verification_status NOT NULL DEFAULT 'unverified',
  documents_expire_on date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  -- A vehicle belongs to a business or to a person, never to both and never to neither.
  CONSTRAINT vehicles_one_owner CHECK (num_nonnulls(organization_id, owner_user_id) = 1),
  UNIQUE (plate_blind_index)
);
CREATE INDEX vehicles_org ON public.vehicles (organization_id);
CREATE INDEX vehicles_worker ON public.vehicles (assigned_worker_id);
CREATE INDEX vehicles_expiry ON public.vehicles (documents_expire_on)
  WHERE documents_expire_on IS NOT NULL;
CREATE TRIGGER vehicles_touch BEFORE UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.provider_profiles ADD COLUMN organization_id uuid
  REFERENCES public.organizations (id) ON DELETE SET NULL;
ALTER TABLE public.offer_threads ADD COLUMN organization_id uuid
  REFERENCES public.organizations (id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- Membership helpers. A removed member loses access immediately, including to jobs in flight
-- (BU-03), which is why every check asks for `active` rather than merely for a row.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.org_role(p_org uuid, p_user uuid)
RETURNS public.business_role
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.role FROM public.organization_members m
  WHERE m.organization_id = p_org AND m.user_id = p_user AND m.status = 'active';
$$;

CREATE FUNCTION private.is_org_member(p_org uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.organization_members m
                 WHERE m.organization_id = p_org AND m.user_id = (SELECT auth.uid())
                   AND m.status = 'active');
$$;

CREATE FUNCTION private.org_can_bid(p_org uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.organizations o
                 WHERE o.id = p_org AND o.verification_status = 'verified');
$$;

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.organizations FROM anon, authenticated;
GRANT SELECT ON public.organizations TO authenticated;
GRANT UPDATE (legal_name) ON public.organizations TO authenticated;
GRANT ALL ON public.organizations TO service_role;
CREATE POLICY organizations_read_member ON public.organizations FOR SELECT TO authenticated
  USING ((SELECT private.is_org_member(organizations.id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));
-- The owner may correct the name until verification fixes it (BU-03 wording, RLS matrix §3).
CREATE POLICY organizations_update_owner ON public.organizations FOR UPDATE TO authenticated
  USING ((SELECT private.org_role(organizations.id, (SELECT auth.uid()))) = 'owner'
         AND verification_status <> 'verified')
  WITH CHECK ((SELECT private.org_role(organizations.id, (SELECT auth.uid()))) = 'owner'
              AND verification_status <> 'verified');

ALTER TABLE public.organization_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_members FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.organization_members FROM anon, authenticated;
GRANT SELECT ON public.organization_members TO authenticated;
GRANT ALL ON public.organization_members TO service_role;
CREATE POLICY organization_members_read ON public.organization_members FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.is_org_member(organization_members.organization_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));

ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.vehicles FROM anon, authenticated;
GRANT SELECT ON public.vehicles TO authenticated;
GRANT ALL ON public.vehicles TO service_role;
-- Plates are ciphertext, so a member reading the row learns nothing they should not; the
-- decryption function is the Verification Officer's, and it is Phase 4.
CREATE POLICY vehicles_read ON public.vehicles FOR SELECT TO authenticated
  USING (owner_user_id = (SELECT auth.uid())
         OR assigned_worker_id = (SELECT auth.uid())
         OR (organization_id IS NOT NULL AND (SELECT private.is_org_member(vehicles.organization_id)))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- register_organization / invite_member / set_member_role / remove_member
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.register_organization(
  p_idempotency_key text,
  p_legal_name text,
  p_registration_ciphertext bytea,
  p_registration_blind_index bytea
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_country char(2);
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'register_organization',
    jsonb_build_object('legal_name', p_legal_name, 'blind_index', encode(p_registration_blind_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'organization_id')::uuid;
  END IF;

  IF p_legal_name IS NULL OR p_registration_ciphertext IS NULL
     OR p_registration_blind_index IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.organizations (legal_name, country_code, registration_number_ciphertext,
                                    registration_blind_index, created_by)
  VALUES (btrim(p_legal_name), v_country, p_registration_ciphertext, p_registration_blind_index,
          v_uid)
  RETURNING id INTO v_id;

  INSERT INTO public.organization_members (organization_id, user_id, role, status, joined_at)
  VALUES (v_id, v_uid, 'owner', 'active', now());

  PERFORM private.ensure_provider_profile(v_uid);
  UPDATE public.provider_profiles pp SET organization_id = v_id, kind = 'business'
  WHERE pp.user_id = v_uid;

  PERFORM private.emit_event('organization', v_id::text, 'organization.registered',
    jsonb_build_object('created_by', v_uid, 'country_code', v_country));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('organization_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.invite_member(
  p_organization_id uuid, p_user_id uuid, p_role public.business_role)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF private.org_role(p_organization_id, v_uid) <> 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_user_id IS NULL OR p_role IS NULL OR p_user_id = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = p_user_id) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.organization_members (organization_id, user_id, role, invited_by)
  VALUES (p_organization_id, p_user_id, p_role, v_uid)
  ON CONFLICT (organization_id, user_id) DO UPDATE
  SET role = excluded.role,
      status = CASE WHEN public.organization_members.status = 'removed' THEN 'invited'
                    ELSE public.organization_members.status END;

  PERFORM private.emit_event('organization', p_organization_id::text, 'organization.member_invited',
    jsonb_build_object('user_id', p_user_id, 'role', p_role, 'invited_by', v_uid));
  RETURN true;
END $$;

-- The invitee joins themselves: an owner cannot add someone to a business without their consent.
CREATE FUNCTION public.accept_organization_invite(p_organization_id uuid)
RETURNS public.business_role
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_role public.business_role;
BEGIN
  UPDATE public.organization_members m
  SET status = 'active', joined_at = now()
  WHERE m.organization_id = p_organization_id AND m.user_id = v_uid AND m.status = 'invited'
  RETURNING m.role INTO v_role;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.ensure_provider_profile(v_uid);
  UPDATE public.provider_profiles pp SET organization_id = p_organization_id
  WHERE pp.user_id = v_uid;

  PERFORM private.emit_event('organization', p_organization_id::text,
    'organization.member_joined', jsonb_build_object('user_id', v_uid, 'role', v_role));
  RETURN v_role;
END $$;

CREATE FUNCTION public.remove_member(p_organization_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF private.org_role(p_organization_id, v_uid) <> 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_user_id = v_uid THEN
    -- An owner removing themselves would leave a business nobody can administer.
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  UPDATE public.organization_members m SET status = 'removed'
  WHERE m.organization_id = p_organization_id AND m.user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- Access ends now, including to work in flight (BU-03).
  UPDATE public.provider_profiles pp SET organization_id = NULL, online = false
  WHERE pp.user_id = p_user_id AND pp.organization_id = p_organization_id;
  DELETE FROM public.provider_live_location l WHERE l.provider_id = p_user_id;

  PERFORM private.emit_event('organization', p_organization_id::text,
    'organization.member_removed', jsonb_build_object('user_id', p_user_id, 'by', v_uid));
  RETURN true;
END $$;

CREATE FUNCTION public.set_member_options(
  p_organization_id uuid, p_user_id uuid, p_role public.business_role DEFAULT NULL,
  p_can_self_accept boolean DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF private.org_role(p_organization_id, v_uid) <> 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.organization_members m
  SET role = coalesce(p_role, m.role),
      can_self_accept = coalesce(p_can_self_accept, m.can_self_accept)
  WHERE m.organization_id = p_organization_id AND m.user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- register_vehicle — the register itself; the documents are checked in Phase 4.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.register_vehicle(
  p_idempotency_key text,
  p_type public.vehicle_type,
  p_plate_ciphertext bytea,
  p_plate_blind_index bytea,
  p_organization_id uuid DEFAULT NULL,
  p_assigned_worker_id uuid DEFAULT NULL,
  p_documents_expire_on date DEFAULT NULL
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
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'register_vehicle',
    jsonb_build_object('type', p_type, 'blind_index', encode(p_plate_blind_index, 'hex'),
                       'organization_id', p_organization_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'vehicle_id')::uuid;
  END IF;

  IF p_type IS NULL OR p_plate_ciphertext IS NULL OR p_plate_blind_index IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NOT NULL
     AND private.org_role(p_organization_id, v_uid) NOT IN ('owner', 'dispatcher') THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.vehicles (organization_id, owner_user_id, type, plate_ciphertext,
                               plate_blind_index, assigned_worker_id, documents_expire_on)
  VALUES (p_organization_id,
          CASE WHEN p_organization_id IS NULL THEN v_uid END,
          p_type, p_plate_ciphertext, p_plate_blind_index, p_assigned_worker_id,
          p_documents_expire_on)
  RETURNING id INTO v_id;

  -- An individual provider's own vehicle is the one their profile advertises.
  IF p_organization_id IS NULL THEN
    PERFORM private.ensure_provider_profile(v_uid);
    UPDATE public.provider_profiles pp SET vehicle_type = p_type WHERE pp.user_id = v_uid;
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('vehicle_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Eligibility, in one place. Matching and the feed both ask this, so a rule added later lands
-- once rather than in two query bodies that drift.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.request_open_to_provider(p_request_id uuid, p_provider uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_vehicle public.vehicle_type;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF private.is_blocked_pair(v_request.customer_id, p_provider) THEN
    RETURN false;
  END IF;

  SELECT pp.vehicle_type INTO v_vehicle FROM public.provider_profiles pp
  WHERE pp.user_id = p_provider;
  -- BU-09: a vehicle the zone bans cannot take work that starts inside it.
  RETURN private.vehicle_allowed_at(v_request.pickup_point, v_vehicle);
END $$;

-- A thread bids in the organisation's name when its provider belongs to one (BU-05). A trigger,
-- so the two offer paths cannot disagree about whose name is on it.
CREATE FUNCTION private.offer_threads_set_org()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.organization_id IS NULL THEN
    SELECT pp.organization_id INTO NEW.organization_id
    FROM public.provider_profiles pp WHERE pp.user_id = NEW.provider_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER offer_threads_set_org BEFORE INSERT ON public.offer_threads
  FOR EACH ROW EXECUTE FUNCTION private.offer_threads_set_org();

-- ---------------------------------------------------------------------------
-- dispatch_job — a dispatcher names the worker (BU-06); claim_job — a trusted worker takes it
-- themselves (BU-07). Both end in the same place: `private.assign_job`, which issues the PINs.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.require_dispatchable_worker(p_org uuid, p_worker uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF private.org_role(p_org, p_worker) IS NULL THEN
    RAISE EXCEPTION 'ERR_WORKER_NOT_ELIGIBLE' USING ERRCODE = 'P0001';
  END IF;
  -- Every worker is verified like an individual provider (BU-04).
  IF NOT private.is_active_provider(p_worker) THEN
    RAISE EXCEPTION 'ERR_WORKER_NOT_ELIGIBLE' USING ERRCODE = 'P0001';
  END IF;
END $$;

CREATE FUNCTION public.dispatch_job(
  p_idempotency_key text, p_request_id uuid, p_worker_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_job    public.jobs%ROWTYPE;
  v_org    uuid;
  v_status public.job_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'dispatch_job',
    jsonb_build_object('request_id', p_request_id, 'worker_id', p_worker_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT pp.organization_id INTO v_org FROM public.provider_profiles pp
  WHERE pp.user_id = v_job.provider_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF private.org_role(v_org, v_uid) NOT IN ('owner', 'dispatcher') THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.require_dispatchable_worker(v_org, p_worker_id);
  IF NOT private.request_open_to_provider(p_request_id, p_worker_id) THEN
    RAISE EXCEPTION 'ERR_VEHICLE_NOT_ALLOWED_IN_ZONE' USING ERRCODE = 'P0001';
  END IF;

  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id;
  IF v_status = 'paid_held' THEN
    v_status := private.assign_job(p_request_id, p_worker_id);
  ELSIF v_status = 'assigned' THEN
    -- Reassignment before anyone sets off is allowed, and logged (BU-06).
    UPDATE public.jobs j SET worker_id = p_worker_id WHERE j.request_id = p_request_id;
    INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                   reason_code, idempotency_key, payload)
    VALUES (p_request_id, v_status, v_status, v_uid, 'admin', 'reassigned', p_idempotency_key,
            jsonb_build_object('worker_id', p_worker_id));
  ELSE
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

CREATE FUNCTION public.claim_job(p_idempotency_key text, p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_job    public.jobs%ROWTYPE;
  v_org    uuid;
  v_status public.job_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'claim_job',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT pp.organization_id INTO v_org FROM public.provider_profiles pp
  WHERE pp.user_id = v_job.provider_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.organization_members m
                 WHERE m.organization_id = v_org AND m.user_id = v_uid
                   AND m.status = 'active' AND m.can_self_accept) THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.require_dispatchable_worker(v_org, v_uid);
  IF NOT private.request_open_to_provider(p_request_id, v_uid) THEN
    RAISE EXCEPTION 'ERR_VEHICLE_NOT_ALLOWED_IN_ZONE' USING ERRCODE = 'P0001';
  END IF;

  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id;
  IF v_status <> 'paid_held' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  v_status := private.assign_job(p_request_id, v_uid);

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- Matching and the feed learn the zone rule. Both are replaced whole, since a function body
-- cannot be patched; the check is inline rather than through `request_open_to_provider` so that
-- neither re-reads the request once per candidate row.
-- ---------------------------------------------------------------------------
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
  v_vehicle public.vehicle_type;
BEGIN
  PERFORM private.require_active_provider(v_uid);
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  SELECT pp.vehicle_type INTO v_vehicle FROM public.provider_profiles pp WHERE pp.user_id = v_uid;

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
    -- And nothing whose pickup sits in a zone this provider's vehicle may not enter (BU-09):
    -- a request they would be refused on arrival is not work, it is a wasted trip.
    AND private.vehicle_allowed_at(r.pickup_point, v_vehicle)
    AND extensions.ST_DWithin(r.pickup_point, v_origin, v_radius)
  ORDER BY extensions.ST_Distance(r.pickup_point, v_origin)
  LIMIT v_limit;
END $$;

REVOKE ALL ON FUNCTION
  public.register_organization(text, text, bytea, bytea),
  public.invite_member(uuid, uuid, public.business_role),
  public.accept_organization_invite(uuid),
  public.remove_member(uuid, uuid),
  public.set_member_options(uuid, uuid, public.business_role, boolean),
  public.register_vehicle(text, public.vehicle_type, bytea, bytea, uuid, uuid, date),
  public.dispatch_job(text, uuid, uuid),
  public.claim_job(text, uuid),
  private.vehicle_allowed_at(extensions.geography, public.vehicle_type),
  private.org_role(uuid, uuid),
  private.is_org_member(uuid),
  private.org_can_bid(uuid),
  private.request_open_to_provider(uuid, uuid),
  private.require_dispatchable_worker(uuid, uuid),
  private.offer_threads_set_org()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.register_organization(text, text, bytea, bytea),
  public.invite_member(uuid, uuid, public.business_role),
  public.accept_organization_invite(uuid),
  public.remove_member(uuid, uuid),
  public.set_member_options(uuid, uuid, public.business_role, boolean),
  public.register_vehicle(text, public.vehicle_type, bytea, bytea, uuid, uuid, date),
  public.dispatch_job(text, uuid, uuid),
  public.claim_job(text, uuid)
  TO authenticated;
-- The organisation policies call these as the invoking role.
GRANT EXECUTE ON FUNCTION
  private.is_org_member(uuid),
  private.org_role(uuid, uuid)
  TO authenticated;
