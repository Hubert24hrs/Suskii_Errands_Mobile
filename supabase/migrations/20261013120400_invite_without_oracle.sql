-- Audit 2026-10-13, Z.20: `invite_member_by_phone` told a business owner whether a phone number
-- had an account. It raised ERR_PROFILE_NOT_FOUND for a number without one and returned the
-- account's user id for a number with one, so any owner could test numbers, and link a number to
-- a person they had met elsewhere on the platform by that id.
--
-- Now the owner's view is the same either way:
--   * A number with no account becomes a pending invitation, kept as a blind index and the masked
--     number only (the owner typed it; the platform keeps no copy it could read back). It waits
--     for that number to sign up, and is claimed the first time its owner looks at invitations.
--   * Every invitation not yet accepted, account or not, is listed under an opaque id: a keyed
--     hash nobody without the key can compute, so a known user id cannot be matched against it.
--     The real id appears when the person accepts and becomes a member.
--   * The row is identical too: the masked number, `pending`, no jobs, nothing earned, and the
--     business's member count includes both kinds.

SELECT private.create_field_data_key('bidx_org_invite_phone');

CREATE TABLE private.org_phone_invitations (
  organization_id uuid NOT NULL REFERENCES public.organizations (id) ON DELETE CASCADE,
  phone_bidx      bytea NOT NULL,
  phone_masked    text NOT NULL,
  role            public.business_role NOT NULL CHECK (role <> 'owner'),
  invited_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, phone_bidx)
);
CREATE INDEX org_phone_invitations_bidx ON private.org_phone_invitations (phone_bidx);
REVOKE ALL ON private.org_phone_invitations FROM PUBLIC, anon, authenticated;

-- The id an invitation is listed under. Keyed, so it says nothing to anybody without the key.
CREATE FUNCTION private.org_invitation_id(p_organization_id uuid, p_subject text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT encode(substring(
    extensions.hmac(convert_to('org_invitation|' || p_organization_id::text || '|' || p_subject,
                               'UTF8'),
                    private.field_data_key('bidx_org_invite_phone', 1), 'sha256')
    FROM 1 FOR 16), 'hex')::uuid;
$$;
REVOKE ALL ON FUNCTION private.org_invitation_id(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.invite_member_by_phone(
  p_idempotency_key text, p_organization_id uuid, p_phone_e164 text,
  p_role public.business_role)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_phone  text := private.normalise_phone(p_phone_e164);
  v_bidx   bytea;
  v_claim  jsonb;
  v_user   uuid;
  v_status public.org_member_status;
  v_id     uuid;
BEGIN
  IF private.org_role(p_organization_id, v_uid) IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_phone IS NULL OR p_role IS NULL OR p_role = 'owner' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_bidx := private.blind_index('org_invite_phone', v_phone);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'invite_member_by_phone',
    jsonb_build_object('organization_id', p_organization_id, 'phone', encode(v_bidx, 'hex'),
                       'role', p_role));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'invitation_id')::uuid;
  END IF;

  -- GoTrue stores the number without its plus sign.
  SELECT u.id INTO v_user FROM auth.users u WHERE u.phone = ltrim(v_phone, '+');
  IF v_user = v_uid THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  IF v_user IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = v_user) THEN
    INSERT INTO public.organization_members (organization_id, user_id, role, invited_by)
    VALUES (p_organization_id, v_user, p_role, v_uid)
    ON CONFLICT (organization_id, user_id) DO UPDATE
    SET role = excluded.role,
        status = CASE WHEN public.organization_members.status = 'removed' THEN 'invited'
                      ELSE public.organization_members.status END
    RETURNING status INTO v_status;
    -- A member the owner can already see by name keeps their id; an invitation gets its own.
    v_id := CASE WHEN v_status = 'active' THEN v_user
                 ELSE private.org_invitation_id(p_organization_id, 'user:' || v_user::text) END;
    PERFORM private.emit_event('organization', p_organization_id::text,
      'organization.member_invited',
      jsonb_build_object('user_id', v_user, 'role', p_role, 'invited_by', v_uid));
  ELSE
    INSERT INTO private.org_phone_invitations (organization_id, phone_bidx, phone_masked, role,
                                               invited_by)
    VALUES (p_organization_id, v_bidx, private.mask_phone(v_phone), p_role, v_uid)
    ON CONFLICT (organization_id, phone_bidx) DO UPDATE SET role = excluded.role;
    v_id := private.org_invitation_id(p_organization_id, 'phone:' || encode(v_bidx, 'hex'));
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('invitation_id', v_id));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.my_organization_members()
RETURNS TABLE (
  user_id uuid, display_name text, role public.business_role,
  status public.org_member_status, verification_status public.verification_status,
  jobs_completed integer, earnings_minor bigint, currency char(3))
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_org      uuid;
  v_role     public.business_role;
  v_currency char(3);
BEGIN
  SELECT m.organization_id, m.role INTO v_org, v_role
  FROM public.organization_members m
  WHERE m.user_id = v_uid AND m.status = 'active'
  ORDER BY m.joined_at LIMIT 1;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT c.currency_code INTO v_currency FROM public.organizations o
  JOIN public.countries c ON c.code = o.country_code WHERE o.id = v_org;

  RETURN QUERY
  WITH listed AS (
    SELECT m.user_id AS id, coalesce(p.display_name, '') AS name, m.role, m.status,
           coalesce(p.provider_verification, 'unverified') AS verification,
           (SELECT count(*)::integer FROM public.jobs j
            WHERE j.confirmed_at IS NOT NULL
              AND (j.worker_id = m.user_id
                   OR (j.provider_id = m.user_id AND j.worker_id IS NULL))) AS jobs,
           (SELECT coalesce(sum(j.net_minor), 0)::bigint FROM public.jobs j
            WHERE j.confirmed_at IS NOT NULL
              AND (j.worker_id = m.user_id
                   OR (j.provider_id = m.user_id AND j.worker_id IS NULL))) AS earned,
           m.created_at
    FROM public.organization_members m
    LEFT JOIN public.profiles p ON p.user_id = m.user_id
    WHERE m.organization_id = v_org AND m.status = 'active'
    UNION ALL
    -- Invitations, both kinds, in one shape: nothing here differs between a number that has an
    -- account and one that does not.
    SELECT private.org_invitation_id(v_org, 'user:' || m.user_id::text),
           coalesce(private.mask_phone('+' || u.phone), ''), m.role, 'invited',
           'pending', 0, 0::bigint, m.created_at
    FROM public.organization_members m
    JOIN auth.users u ON u.id = m.user_id
    WHERE m.organization_id = v_org AND m.status = 'invited'
    UNION ALL
    SELECT private.org_invitation_id(v_org, 'phone:' || encode(i.phone_bidx, 'hex')),
           i.phone_masked, i.role, 'invited', 'pending', 0, 0::bigint, i.created_at
    FROM private.org_phone_invitations i
    WHERE i.organization_id = v_org
  )
  SELECT l.id, l.name, l.role, l.status::public.org_member_status,
         l.verification::public.verification_status, l.jobs,
         CASE WHEN v_role = 'owner' THEN l.earned END, v_currency
  FROM listed l
  ORDER BY l.role, l.created_at;
END $$;

CREATE OR REPLACE FUNCTION public.my_organization()
RETURNS TABLE (
  id uuid, name text, owner_id uuid, country_code char(2),
  verification_status public.verification_status, payout_account_set boolean,
  member_count integer, active_vehicle_count integer, my_role public.business_role)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT o.id, o.legal_name,
         (SELECT m2.user_id FROM public.organization_members m2
          WHERE m2.organization_id = o.id AND m2.role = 'owner' AND m2.status = 'active'
          LIMIT 1),
         o.country_code, o.verification_status,
         EXISTS (SELECT 1 FROM public.payout_accounts pa
                 WHERE pa.user_id = o.created_by AND pa.verified_at IS NOT NULL),
         (SELECT count(*)::integer FROM public.organization_members m3
          WHERE m3.organization_id = o.id AND m3.status <> 'removed')
           + (SELECT count(*)::integer FROM private.org_phone_invitations i
              WHERE i.organization_id = o.id),
         (SELECT count(*)::integer FROM public.vehicles v WHERE v.organization_id = o.id),
         m.role
  FROM public.organization_members m
  JOIN public.organizations o ON o.id = m.organization_id
  WHERE m.user_id = auth.uid() AND m.status = 'active'
  ORDER BY m.joined_at
  LIMIT 1;
$$;

-- An invitation is removed by the id the member list showed for it; a member by their own id.
CREATE OR REPLACE FUNCTION public.remove_member(p_organization_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF private.org_role(p_organization_id, v_uid) IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_user_id = v_uid THEN
    -- An owner removing themselves would leave a business nobody can administer.
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  DELETE FROM private.org_phone_invitations i
  WHERE i.organization_id = p_organization_id
    AND private.org_invitation_id(p_organization_id, 'phone:' || encode(i.phone_bidx, 'hex'))
        = p_user_id;
  IF FOUND THEN
    RETURN true;
  END IF;

  UPDATE public.organization_members m SET status = 'removed'
  WHERE m.organization_id = p_organization_id AND m.status = 'invited'
    AND private.org_invitation_id(p_organization_id, 'user:' || m.user_id::text) = p_user_id;
  IF FOUND THEN
    RETURN true;
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

-- The invitee's side. A pending invitation to the caller's number becomes a real one the first
-- time they look, which is the first moment the platform knows the number is theirs.
CREATE OR REPLACE FUNCTION public.my_organization_invitations()
RETURNS TABLE (organization_id uuid, name text, role public.business_role,
               invited_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_phone text;
  v_bidx  bytea;
BEGIN
  SELECT private.normalise_phone('+' || u.phone) INTO v_phone
  FROM auth.users u WHERE u.id = v_uid AND coalesce(u.phone, '') <> '';
  IF v_phone IS NOT NULL THEN
    v_bidx := private.blind_index('org_invite_phone', v_phone);
    INSERT INTO public.organization_members (organization_id, user_id, role, invited_by)
    SELECT i.organization_id, v_uid, i.role, i.invited_by
    FROM private.org_phone_invitations i WHERE i.phone_bidx = v_bidx
    ON CONFLICT ON CONSTRAINT organization_members_pkey DO NOTHING;
    DELETE FROM private.org_phone_invitations i WHERE i.phone_bidx = v_bidx;
  END IF;

  RETURN QUERY
  SELECT o.id, o.legal_name, m.role, m.created_at
  FROM public.organization_members m
  JOIN public.organizations o ON o.id = m.organization_id
  WHERE m.user_id = v_uid AND m.status = 'invited'
  ORDER BY m.created_at DESC;
END $$;
