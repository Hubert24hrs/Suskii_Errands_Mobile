-- Phase 9, part 3: the admin verbs for people and businesses (spec phase 8, "Admin functions for
-- users, businesses, verification…"; RLS matrix §1 and §9; admin dashboard scope).
--
-- What Phase 8 shipped was tickets, suspension and configuration. What it did not was the part
-- of an admin console people actually spend their day in: finding a user, reading their standing,
-- and dealing with a business. Three gaps, and the third is the one that matters most.
--
-- **`organizations.verification_status` has existed since Phase 3 and nothing has ever decided
-- it.** Every business on the platform is `unverified` for ever, because the column was created
-- with no verb behind it. The spec requires business registration documents to be checked before
-- a business takes work; the Phase 3 note called business verification blocked on Phase 4, and
-- Phase 4 built individual KYC and never came back for it. A queue and a decision, here, with
-- the same rules the individual one has: an officer never reviews an organisation they belong
-- to, a rejection carries a reason key rather than prose, and the decision is audited.
--
-- **Looking somebody up is itself an access event.** `admin_user_search` and
-- `admin_user_summary` write an audit row before they return anything, for the same reason
-- `request_document_access` does: the control on staff reading customer data is not that they
-- cannot, it is that it is on the record when they do. Both return the least that is useful —
-- no phone number, no address, no document, no money beyond a count.

ALTER TABLE public.organizations
  ADD COLUMN suspended_until       timestamptz,
  ADD COLUMN suspension_reason_key text CHECK (suspension_reason_key IS NULL
                                               OR suspension_reason_key ~ '^[a-z0-9_]{3,60}$'),
  ADD COLUMN verification_note_key text CHECK (verification_note_key IS NULL
                                               OR verification_note_key ~ '^[a-z0-9_]{3,60}$'),
  ADD COLUMN verified_at           timestamptz,
  ADD COLUMN reviewed_by           uuid REFERENCES auth.users (id);

-- ---------------------------------------------------------------------------
-- A suspended organisation cannot send anybody to work.
--
-- `is_active_provider` is the one place eligibility is decided — matching, the feed and the offer
-- guards all call it — so suspending a business is enforced by replacing that rather than by
-- adding a check to each of them and hoping the next one remembers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.is_active_provider(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.provider_profiles pp
    JOIN public.profiles p ON p.user_id = pp.user_id
    WHERE pp.user_id = p_user
      AND p.provider_verification = 'verified'
      AND (pp.suspended_until IS NULL OR pp.suspended_until <= now()))
  AND NOT EXISTS (
    -- A worker is not suspended for their own conduct here; the business they work for is
    -- suspended, and while it is, nobody it sends can take a job.
    SELECT 1 FROM public.organization_members m
    JOIN public.organizations o ON o.id = m.organization_id
    WHERE m.user_id = p_user AND m.status = 'active'
      AND o.suspended_until IS NOT NULL AND o.suspended_until > now());
$$;

-- ---------------------------------------------------------------------------
-- Business verification.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.business_verification_queue(p_limit integer DEFAULT 100)
RETURNS TABLE (
  organization_id uuid, legal_name text, country_code char(2),
  verification_status public.verification_status, members integer, vehicles integer,
  created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'verification_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT o.id, o.legal_name, o.country_code, o.verification_status,
         (SELECT count(*)::integer FROM public.organization_members m
          WHERE m.organization_id = o.id AND m.status = 'active'),
         (SELECT count(*)::integer FROM public.vehicles v WHERE v.organization_id = o.id),
         o.created_at
  FROM public.organizations o
  WHERE o.verification_status IN ('unverified', 'pending', 'in_review')
  ORDER BY o.created_at
  LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END $$;

CREATE FUNCTION public.decide_business_verification(
  p_idempotency_key text, p_organization_id uuid, p_approve boolean,
  p_reason_key text DEFAULT NULL)
RETURNS public.verification_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_org    public.organizations%ROWTYPE;
  v_status public.verification_status;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'verification_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- A rejection has to say why, in a key a screen can translate rather than prose a lawyer
  -- would have to read.
  IF NOT p_approve AND (p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a rejection needs a reason key';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'decide_business_verification',
    jsonb_build_object('organization_id', p_organization_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.verification_status;
  END IF;

  SELECT * INTO v_org FROM public.organizations o WHERE o.id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORGANIZATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- Nobody verifies a business they are part of, however senior they are. The same rule the
  -- individual KYC queue has, and for the same reason — and it is checked **before** the
  -- already-decided shortcut below, because somebody who should not be touching this
  -- organisation should be refused whatever state it happens to be in.
  IF EXISTS (SELECT 1 FROM public.organization_members m
             WHERE m.organization_id = p_organization_id AND m.user_id = v_uid
               AND m.status <> 'removed')
     OR v_org.created_by = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you are part of this organisation';
  END IF;
  IF v_org.verification_status = 'verified' AND p_approve THEN
    RETURN 'verified'::public.verification_status;   -- already decided; nothing new happened
  END IF;

  v_status := (CASE WHEN p_approve THEN 'verified' ELSE 'rejected' END)::public.verification_status;

  UPDATE public.organizations o
  SET verification_status = v_status,
      verification_note_key = p_reason_key,
      verified_at = CASE WHEN p_approve THEN now() END,
      reviewed_by = v_uid
  WHERE o.id = p_organization_id;

  PERFORM private.notify(v_org.created_by, 'system',
    CASE WHEN p_approve THEN 'notification.business.verified.title'
         ELSE 'notification.business.rejected.title' END,
    CASE WHEN p_approve THEN 'notification.business.verified.body'
         ELSE 'notification.business.rejected.body' END,
    jsonb_build_object('organization_id', p_organization_id, 'reason_key', p_reason_key),
    '/business');
  PERFORM private.audit_write('admin.decide_business_verification', 'public.organizations',
    p_organization_id::text,
    jsonb_build_object('verification_status', v_org.verification_status),
    jsonb_build_object('verification_status', v_status), p_reason_key);
  PERFORM private.emit_event('admin', p_organization_id::text, 'business.verification_decided',
    jsonb_build_object('organization_id', p_organization_id, 'status', v_status,
                       'reason_key', p_reason_key, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- Suspending a business. Bounded and reasoned, exactly as `suspend_provider` is: an end date is
-- required, so closing a company down permanently is not something one function call can do.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.suspend_organization(
  p_idempotency_key text, p_organization_id uuid, p_reason_key text, p_until timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_before timestamptz;
  v_owner  uuid;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$'
     OR p_until IS NULL OR p_until <= now() OR p_until > now() + interval '365 days' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'suspend_organization',
    jsonb_build_object('organization_id', p_organization_id, 'reason_key', p_reason_key,
                       'until', p_until));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'until')::timestamptz;
  END IF;

  SELECT o.suspended_until, o.created_by INTO v_before, v_owner
  FROM public.organizations o WHERE o.id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORGANIZATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.organizations o
  SET suspended_until = p_until, suspension_reason_key = p_reason_key
  WHERE o.id = p_organization_id;
  -- Its workers go offline with it. Leaving them online would show them jobs they cannot take.
  UPDATE public.provider_profiles pp SET online = false
  WHERE pp.user_id IN (SELECT m.user_id FROM public.organization_members m
                       WHERE m.organization_id = p_organization_id AND m.status = 'active');

  PERFORM private.notify(v_owner, 'system',
    'notification.business.suspended.title', 'notification.business.suspended.body',
    jsonb_build_object('organization_id', p_organization_id, 'reason_key', p_reason_key,
                       'until', p_until), '/business');
  PERFORM private.audit_write('admin.suspend_organization', 'public.organizations',
    p_organization_id::text, jsonb_build_object('suspended_until', v_before),
    jsonb_build_object('suspended_until', p_until), p_reason_key);
  PERFORM private.emit_event('admin', p_organization_id::text, 'business.suspended',
    jsonb_build_object('organization_id', p_organization_id, 'until', p_until,
                       'reason_key', p_reason_key, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('until', p_until));
  RETURN p_until;
END $$;

CREATE FUNCTION public.reinstate_organization(
  p_idempotency_key text, p_organization_id uuid, p_reason_key text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_owner uuid;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'reinstate_organization',
    jsonb_build_object('organization_id', p_organization_id, 'reason_key', p_reason_key));
  IF v_claim IS NOT NULL THEN
    RETURN true;
  END IF;

  SELECT o.created_by INTO v_owner FROM public.organizations o
  WHERE o.id = p_organization_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ORGANIZATION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.organizations o
  SET suspended_until = NULL, suspension_reason_key = NULL
  WHERE o.id = p_organization_id;

  PERFORM private.notify(v_owner, 'system',
    'notification.business.reinstated.title', 'notification.business.reinstated.body',
    jsonb_build_object('organization_id', p_organization_id), '/business');
  PERFORM private.audit_write('admin.reinstate_organization', 'public.organizations',
    p_organization_id::text, NULL, jsonb_build_object('suspended_until', NULL), p_reason_key);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, jsonb_build_object('ok', true));
  RETURN true;
END $$;

CREATE FUNCTION public.admin_organization_summary(p_organization_id uuid)
RETURNS TABLE (
  organization_id uuid, legal_name text, country_code char(2),
  verification_status public.verification_status, suspended_until timestamptz,
  members integer, active_workers integer, vehicles integer,
  jobs_completed integer, disputes_open integer, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Read-only, so nothing here needs the caller's id; it still needs there to be a caller.
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'verification_officer', 'support_agent',
             'finance_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- The registration number is not here and cannot be: it is ciphertext with a blind index
  -- (ADR-0007) and nothing in SQL reads either.
  PERFORM private.audit_write('admin.read_organization', 'public.organizations',
    p_organization_id::text, NULL, NULL, NULL);

  RETURN QUERY
  SELECT o.id, o.legal_name, o.country_code, o.verification_status, o.suspended_until,
         (SELECT count(*)::integer FROM public.organization_members m
          WHERE m.organization_id = o.id),
         (SELECT count(*)::integer FROM public.organization_members m
          WHERE m.organization_id = o.id AND m.status = 'active'),
         (SELECT count(*)::integer FROM public.vehicles v WHERE v.organization_id = o.id),
         (SELECT count(*)::integer FROM public.jobs j
          JOIN public.organization_members m ON m.user_id = j.provider_id
          WHERE m.organization_id = o.id AND j.confirmed_at IS NOT NULL),
         (SELECT count(*)::integer FROM public.disputes d
          JOIN public.jobs j ON j.request_id = d.request_id
          JOIN public.organization_members m ON m.user_id = j.provider_id
          WHERE m.organization_id = o.id AND d.status IN ('open', 'under_review')),
         o.created_at
  FROM public.organizations o
  WHERE o.id = p_organization_id;
END $$;

-- ---------------------------------------------------------------------------
-- Finding a person, and reading their standing.
--
-- Search is by **exact** id, or by the last digits of a phone number, or by a display-name
-- prefix. Deliberately not a substring match on everything: a search that returns half the
-- platform for the letter "a" is a browse, and browsing is what the ticket scope exists to stop.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_user_search(p_query text, p_limit integer DEFAULT 20)
RETURNS TABLE (user_id uuid, display_name text, country_code char(2),
               customer_verification public.verification_status,
               provider_verification public.verification_status,
               created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_term text := btrim(coalesce(p_query, ''));
BEGIN
  -- Read-only, so nothing here needs the caller's id; it still needs there to be a caller.
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF length(v_term) < 4 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'give at least four characters; a shorter search is a browse';
  END IF;

  PERFORM private.audit_write('admin.user_search', 'public.profiles', NULL, NULL,
    jsonb_build_object('term_length', length(v_term)), NULL);

  RETURN QUERY
  SELECT p.user_id, p.display_name, p.country_code,
         p.customer_verification, p.provider_verification, p.created_at
  FROM public.profiles p
  JOIN auth.users u ON u.id = p.user_id
  WHERE p.user_id = private.try_uuid(v_term)
     -- The last digits only: a staff member who already has the number confirms an account with
     -- it; nobody discovers a number they did not have.
     OR (v_term ~ '^[0-9]{4,}$' AND u.phone LIKE '%' || v_term)
     OR (v_term !~ '^[0-9]+$' AND p.display_name ILIKE v_term || '%')
  ORDER BY p.created_at DESC
  LIMIT least(greatest(coalesce(p_limit, 20), 1), 50);
END $$;

CREATE FUNCTION public.admin_user_summary(p_user_id uuid)
RETURNS TABLE (
  user_id uuid, display_name text, country_code char(2),
  customer_verification public.verification_status,
  provider_verification public.verification_status,
  trust_level text, suspended_until timestamptz, suspension_reason_key text,
  requests integer, jobs_as_provider integer, disputes integer, open_flags integer,
  open_tickets integer, devices integer, organizations integer, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Read-only, so nothing here needs the caller's id; it still needs there to be a caller.
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent', 'verification_officer',
             'finance_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.audit_write('admin.read_user', 'public.profiles', p_user_id::text,
    NULL, NULL, NULL);

  -- Counts, not contents. Whether somebody has three open disputes is standing; what is in them
  -- is the dispute officer's, through the dispute.
  RETURN QUERY
  SELECT p.user_id, p.display_name, p.country_code,
         p.customer_verification, p.provider_verification, p.trust_level::text,
         pp.suspended_until, pp.suspension_reason_key,
         (SELECT count(*)::integer FROM public.requests r WHERE r.customer_id = p.user_id),
         (SELECT count(*)::integer FROM public.jobs j WHERE j.provider_id = p.user_id),
         (SELECT count(*)::integer FROM public.disputes d WHERE d.opened_by = p.user_id),
         (SELECT count(*)::integer FROM public.fraud_flags f
          WHERE f.subject_kind = 'user' AND f.subject_id = p.user_id::text AND f.status = 'open'),
         (SELECT count(*)::integer FROM public.support_tickets t
          WHERE t.user_id = p.user_id AND t.status <> 'closed'),
         (SELECT count(*)::integer FROM public.user_devices d WHERE d.user_id = p.user_id),
         (SELECT count(*)::integer FROM public.organization_members m
          WHERE m.user_id = p.user_id AND m.status = 'active'),
         p.created_at
  FROM public.profiles p
  LEFT JOIN public.provider_profiles pp ON pp.user_id = p.user_id
  WHERE p.user_id = p_user_id;
END $$;

-- ---------------------------------------------------------------------------
-- Signing somebody out of everywhere. The response to a reported account takeover, which is a
-- support call, not a database migration.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_revoke_user_sessions(
  p_idempotency_key text, p_user_id uuid, p_reason_key text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_count integer;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'admin_revoke_user_sessions',
    jsonb_build_object('user_id', p_user_id, 'reason_key', p_reason_key));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'revoked')::integer;
  END IF;

  DELETE FROM auth.sessions s WHERE s.user_id = p_user_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM private.notify(p_user_id, 'system',
    'notification.account.sessions_revoked.title', 'notification.account.sessions_revoked.body',
    jsonb_build_object('reason_key', p_reason_key), '/settings/security');
  PERFORM private.audit_write('admin.revoke_sessions', 'auth.sessions', p_user_id::text,
    NULL, jsonb_build_object('revoked', v_count), p_reason_key);
  PERFORM private.emit_event('admin', p_user_id::text, 'user.sessions_revoked',
    jsonb_build_object('user_id', p_user_id, 'revoked', v_count, 'reason_key', p_reason_key,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('revoked', v_count));
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.business_verification_queue(integer),
  public.decide_business_verification(text, uuid, boolean, text),
  public.suspend_organization(text, uuid, text, timestamptz),
  public.reinstate_organization(text, uuid, text),
  public.admin_organization_summary(uuid),
  public.admin_user_search(text, integer),
  public.admin_user_summary(uuid),
  public.admin_revoke_user_sessions(text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.business_verification_queue(integer),
  public.decide_business_verification(text, uuid, boolean, text),
  public.suspend_organization(text, uuid, text, timestamptz),
  public.reinstate_organization(text, uuid, text),
  public.admin_organization_summary(uuid),
  public.admin_user_search(text, integer),
  public.admin_user_summary(uuid),
  public.admin_revoke_user_sessions(text, uuid, text)
  TO authenticated;
