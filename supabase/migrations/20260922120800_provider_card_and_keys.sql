-- Phase 9, part 5: the provider card the matrix names, and the four idempotency keys the last
-- audit recorded (`docs/audit/AUDIT-2026-09-22b.md` U.3; `AUDIT-2026-09-22.md` N.1).
--
-- **U.3 — `get_provider_card()` is named in the RLS matrix and does not exist.**
--
-- `profiles` is own-read-only and `provider_profiles` is own-read-only, which is right. The
-- matrix's answer to "then how does a customer choose between three offers" is a narrow,
-- function-mediated read of a few public fields — `R (public card fields via get_provider_card()
-- only)` — and that function was never written. The result is that a customer comparing offers
-- can learn nothing at all about the providers: not a name, not a rating, not whether they are
-- verified. The PRD's offer card ("provider rating, level, distance, ETA, price") has no source,
-- and the offers board cannot be built against the real backend.
--
-- So it is built here, with the two properties that make it a card rather than a directory:
--
--   * **A reason is required.** The caller has an offer from that provider, is on a job with
--     them, or is an admin who may read them. Asking about a provider you have no relationship
--     with is `ERR_PERMISSION_DENIED`, not an empty row — an empty row is a lookup service.
--   * **Only what a decision needs.** No phone number, no address, no email, no document, no
--     suspension reason. A rating and a count, because a 5.0 from one job is not a 5.0 from two
--     hundred and hiding the count is how a number lies.

CREATE FUNCTION public.get_provider_card(p_provider_id uuid)
RETURNS TABLE (
  provider_id       uuid,
  display_name      text,
  avatar_path       text,
  trust_level       public.trust_level,
  verified          boolean,
  rating_avg_milli  integer,
  rating_count      integer,
  jobs_completed    integer,
  vehicle_type      public.vehicle_type,
  business_name     text,
  member_since      timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_provider_id IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  IF NOT (
    -- They have made this caller an offer, or are on a job with them, either way round.
    EXISTS (SELECT 1 FROM public.offer_threads t
            JOIN public.requests r ON r.id = t.request_id
            WHERE t.provider_id = p_provider_id AND r.customer_id = v_uid)
    OR EXISTS (SELECT 1 FROM public.jobs j
               JOIN public.requests r ON r.id = j.request_id
               WHERE (j.provider_id = p_provider_id OR j.worker_id = p_provider_id)
                 AND (r.customer_id = v_uid OR j.provider_id = v_uid OR j.worker_id = v_uid))
    OR p_provider_id = v_uid
    OR private.admin_may_read_user(p_provider_id,
         ARRAY['support_agent', 'verification_officer', 'dispute_officer']::public.admin_role[])
  ) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'a card is for a provider you are dealing with, not a lookup';
  END IF;

  RETURN QUERY
  SELECT p.user_id, p.display_name, p.avatar_path, p.trust_level,
         p.provider_verification = 'verified',
         pp.rating_avg_milli, pp.rating_count,
         (SELECT count(*)::integer FROM public.jobs j
          WHERE (j.provider_id = p.user_id OR j.worker_id = p.user_id)
            AND j.confirmed_at IS NOT NULL),
         pp.vehicle_type,
         -- The business they work for, if any, and only its name: a customer is entitled to know
         -- who they are actually dealing with.
         (SELECT o.legal_name FROM public.organizations o
          JOIN public.organization_members m ON m.organization_id = o.id
          WHERE m.user_id = p.user_id AND m.status = 'active'
            AND o.verification_status = 'verified'
          LIMIT 1),
         pp.created_at
  FROM public.profiles p
  JOIN public.provider_profiles pp ON pp.user_id = p.user_id
  WHERE p.user_id = p_provider_id;
END $$;

-- ---------------------------------------------------------------------------
-- N.1 — four creates that wrote without an idempotency key.
--
-- CLAUDE.md's rule is "idempotency keys on every create, transition and money operation", and
-- these four were the exceptions. Three had natural uniqueness, which makes a double-tap a
-- constraint violation rather than a duplicate — but a constraint violation is the wrong answer
-- to a client retrying after a lost response, because it looks like a failure. The fourth,
-- `start_verification_session`, had neither, and a double-tap made two sessions.
--
-- **The key goes first, as it does everywhere else**, so each of these is a DROP and a CREATE
-- rather than a replace: adding a parameter to `CREATE OR REPLACE` makes an overload, and two
-- overloads is how a defaulted call becomes ambiguous (the `start_payment` lesson).
--
-- This is a **breaking signature change** for four client functions. It is free today because
-- contracts are `v1-preview`, explicitly non-binding, and no client calls the backend yet;
-- `contracts/CHANGELOG.md` and `HANDOFF.md` both say so.
-- ---------------------------------------------------------------------------

DROP FUNCTION public.add_trusted_contact(text, bytea, bytea, text);
CREATE FUNCTION public.add_trusted_contact(
  p_idempotency_key text, p_name text, p_phone_ciphertext bytea, p_phone_blind_index bytea,
  p_relationship_key text DEFAULT NULL)
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
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'add_trusted_contact',
    jsonb_build_object('blind_index', encode(p_phone_blind_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'contact_id')::uuid;
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' OR p_phone_ciphertext IS NULL
     OR p_phone_blind_index IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.trusted_contacts (user_id, name, phone_ciphertext, phone_blind_index,
                                       relationship_key)
  VALUES (v_uid, btrim(p_name), p_phone_ciphertext, p_phone_blind_index, p_relationship_key)
  RETURNING id INTO v_id;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('contact_id', v_id));
  RETURN v_id;
END $$;

DROP FUNCTION public.invite_member(uuid, uuid, public.business_role);
CREATE FUNCTION public.invite_member(
  p_idempotency_key text, p_organization_id uuid, p_user_id uuid, p_role public.business_role)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
BEGIN
  IF private.org_role(p_organization_id, v_uid) IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'invite_member',
    jsonb_build_object('organization_id', p_organization_id, 'user_id', p_user_id,
                       'role', p_role));
  IF v_claim IS NOT NULL THEN
    RETURN true;
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
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, jsonb_build_object('ok', true));
  RETURN true;
END $$;

DROP FUNCTION public.accept_organization_invite(uuid);
CREATE FUNCTION public.accept_organization_invite(
  p_idempotency_key text, p_organization_id uuid)
RETURNS public.business_role
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_role  public.business_role;
BEGIN
  -- The replay matters most here: the UPDATE matches on `status = 'invited'`, so a client
  -- retrying after a lost response used to be told the organisation did not exist.
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'accept_organization_invite',
    jsonb_build_object('organization_id', p_organization_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'role')::public.business_role;
  END IF;

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
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('role', v_role));
  RETURN v_role;
END $$;

DROP FUNCTION public.start_verification_session(public.kyc_step_kind);
CREATE FUNCTION public.start_verification_session(
  p_idempotency_key text, p_kind public.kyc_step_kind)
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
  -- The one of the four with no natural uniqueness behind it: a double-tap made two sessions,
  -- and a verification session is a vendor call somebody is billed for.
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'start_verification_session',
    jsonb_build_object('kind', p_kind));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'session_id')::uuid;
  END IF;

  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_kind IN ('customer_facial', 'provider_facial')
     AND NOT private.has_consent(v_uid, 'biometric') THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'police_clearance'
     AND NOT private.has_consent(v_uid, 'criminal_record_check') THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO kyc.verification_sessions (user_id, kind, consent_id)
  VALUES (v_uid, p_kind,
          (SELECT c.id FROM public.consents c
           WHERE c.user_id = v_uid AND c.granted
             -- The CASE resolves to text, and with an empty search_path there is no implicit
             -- cast to the enum, so it is spelled out.
             AND c.kind = (CASE WHEN p_kind = 'police_clearance' THEN 'criminal_record_check'
                                ELSE 'biometric' END)::public.consent_kind
           ORDER BY c.id DESC LIMIT 1))
  RETURNING id INTO v_id;

  PERFORM private.emit_event('kyc', v_id::text, 'kyc.session_started',
    jsonb_build_object('session_id', v_id, 'user_id', v_uid, 'kind', p_kind));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('session_id', v_id));
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION
  public.get_provider_card(uuid),
  public.add_trusted_contact(text, text, bytea, bytea, text),
  public.invite_member(text, uuid, uuid, public.business_role),
  public.accept_organization_invite(text, uuid),
  public.start_verification_session(text, public.kyc_step_kind)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.get_provider_card(uuid),
  public.add_trusted_contact(text, text, bytea, bytea, text),
  public.invite_member(text, uuid, uuid, public.business_role),
  public.accept_organization_invite(text, uuid),
  public.start_verification_session(text, public.kyc_step_kind)
  TO authenticated;
