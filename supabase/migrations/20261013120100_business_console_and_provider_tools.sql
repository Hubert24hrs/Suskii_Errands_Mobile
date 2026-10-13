-- The business console and the provider tools the app had been drawing from mock data in every
-- build, real backend or not (audit 2026-10-13, Z.9 and Z.15).
--
--   * `my_organization`, `my_organization_members`: a business could not see who worked for it.
--     `profiles` is readable by its owner only, so a member list showed ids. Names come from
--     here, for the caller's own organization only, and earnings to date for the owner only.
--     A member who has not accepted yet shows a masked number, not a name: an owner who types
--     a number learns nothing they did not already have.
--   * `invite_member_by_phone` (audit Y.19's remainder): the console invites by phone; the
--     backend took a user id, which no business owner has. The person must already have an
--     account under that number, and `invite_member` does the rest, so the rules live once.
--   * `my_organization_invitations`: an invitee is not a member yet, so `organizations` hides the
--     business from them and the app had no way to show what they were accepting.
--   * `register_organization` names a registration number that is already in use
--     (`ERR_ORGANIZATION_ALREADY_REGISTERED`) instead of failing on the UNIQUE constraint.
--   * `assign_vehicle`: the registry had no way to give a vehicle to a worker.
--   * `org_assignable_jobs`: funded jobs the business accepted and has not handed to a worker, as the
--     request rows `dispatch_job` acts on. Landmark notes are left out; the worker gets them on
--     assignment through the usual participant path.
--   * `availability_schedules` (RLS matrix §3, which has specified it since Phase 1 and waived it
--     as not built), with `set_availability` replacing a provider's week in one call.
--   * `provider_earnings_goals`: a target the provider sets; progress is what they earned in
--     the period, computed here.
--   * `my_provider_insights`: the provider's own reputation numbers, with the five-star share
--     counted only from reviews already out of their blind period (SH-30).
--
-- Still not built, and the app says so rather than showing invented numbers: the demand heatmap
-- (aggregating customers' pickup points needs a privacy design of its own) and instant payout
-- (a gateway, client action 4).

-- ---------------------------------------------------------------------------
-- The caller's organization.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_organization()
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
          WHERE m3.organization_id = o.id AND m3.status <> 'removed'),
         (SELECT count(*)::integer FROM public.vehicles v WHERE v.organization_id = o.id),
         m.role
  FROM public.organization_members m
  JOIN public.organizations o ON o.id = m.organization_id
  WHERE m.user_id = auth.uid() AND m.status = 'active'
  ORDER BY m.joined_at
  LIMIT 1;
$$;

CREATE FUNCTION public.my_organization_members()
RETURNS TABLE (
  user_id uuid, display_name text, role public.business_role,
  status public.org_member_status, verification_status public.verification_status,
  jobs_completed integer, earnings_minor bigint, currency char(3))
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_org  uuid;
  v_role public.business_role;
BEGIN
  SELECT m.organization_id, m.role INTO v_org, v_role
  FROM public.organization_members m
  WHERE m.user_id = v_uid AND m.status = 'active'
  ORDER BY m.joined_at LIMIT 1;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT m.user_id,
         CASE WHEN m.status = 'active' THEN coalesce(p.display_name, '')
              ELSE coalesce(private.mask_phone('+' || u.phone), '') END,
         m.role, m.status, coalesce(p.provider_verification, 'unverified'),
         (SELECT count(*)::integer FROM public.jobs j
          WHERE j.confirmed_at IS NOT NULL
            AND (j.worker_id = m.user_id OR (j.provider_id = m.user_id AND j.worker_id IS NULL))),
         CASE WHEN v_role = 'owner' THEN
           (SELECT coalesce(sum(j.net_minor), 0)::bigint FROM public.jobs j
            WHERE j.confirmed_at IS NOT NULL
              AND (j.worker_id = m.user_id
                   OR (j.provider_id = m.user_id AND j.worker_id IS NULL)))
         END,
         (SELECT c.currency_code FROM public.organizations o
          JOIN public.countries c ON c.code = o.country_code WHERE o.id = v_org)
  FROM public.organization_members m
  JOIN auth.users u ON u.id = m.user_id
  LEFT JOIN public.profiles p ON p.user_id = m.user_id
  WHERE m.organization_id = v_org AND m.status <> 'removed'
  ORDER BY m.role, m.created_at;
END $$;

-- ---------------------------------------------------------------------------
-- Inviting by phone.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.invite_member_by_phone(
  p_idempotency_key text, p_organization_id uuid, p_phone_e164 text,
  p_role public.business_role)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_phone text := private.normalise_phone(p_phone_e164);
  v_user  uuid;
BEGIN
  IF private.org_role(p_organization_id, v_uid) IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_phone IS NULL OR p_role IS NULL OR p_role = 'owner' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  -- GoTrue stores the number without its plus sign.
  SELECT u.id INTO v_user FROM auth.users u WHERE u.phone = ltrim(v_phone, '+');
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001',
      DETAIL = 'the person signs up with this number first';
  END IF;

  -- invite_member holds the rules and the idempotency record; its key is derived so that a
  -- retry of this call replays that one.
  PERFORM public.invite_member(p_idempotency_key || ':by_phone', p_organization_id, v_user,
                               p_role);
  RETURN v_user;
END $$;

-- ---------------------------------------------------------------------------
-- Registering a business: a number already on the platform is named, not a constraint error.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_organization(
  p_idempotency_key text, p_legal_name text, p_registration_number text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_number  text := private.normalise_identifier(p_registration_number);
  v_index   bytea;
  v_claim   jsonb;
  v_country char(2);
  v_id      uuid := gen_random_uuid();
BEGIN
  IF p_legal_name IS NULL OR btrim(p_legal_name) = ''
     OR v_number IS NULL OR length(v_number) NOT BETWEEN 3 AND 40 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_index := private.blind_index('organization_registration', v_number);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'register_organization',
    jsonb_build_object('legal_name', p_legal_name, 'blind_index', encode(v_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'organization_id')::uuid;
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- The UNIQUE constraint would say this as a bare 23505 the app cannot name.
  IF EXISTS (SELECT 1 FROM public.organizations o
             WHERE o.country_code = v_country AND o.registration_blind_index = v_index) THEN
    RAISE EXCEPTION 'ERR_ORGANIZATION_ALREADY_REGISTERED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.organizations (id, legal_name, country_code,
                                    registration_number_ciphertext, registration_blind_index,
                                    registration_masked, created_by)
  VALUES (v_id, btrim(p_legal_name), v_country,
          private.seal('organization_registration', v_number, 'organization:' || v_id),
          v_index, private.mask_tail(v_number, 4), v_uid);

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

-- What the caller has been invited to: the business's name and the role, nothing else about it.
CREATE FUNCTION public.my_organization_invitations()
RETURNS TABLE (organization_id uuid, name text, role public.business_role,
               invited_at timestamptz)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT o.id, o.legal_name, m.role, m.created_at
  FROM public.organization_members m
  JOIN public.organizations o ON o.id = m.organization_id
  WHERE m.user_id = auth.uid() AND m.status = 'invited'
  ORDER BY m.created_at DESC;
$$;

-- ---------------------------------------------------------------------------
-- Vehicles to workers.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.assign_vehicle(
  p_idempotency_key text, p_vehicle_id uuid, p_worker_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_org   uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'assign_vehicle',
    jsonb_build_object('vehicle_id', p_vehicle_id, 'worker_id', p_worker_id));
  IF v_claim IS NOT NULL THEN
    RETURN p_vehicle_id;
  END IF;

  SELECT v.organization_id INTO v_org FROM public.vehicles v WHERE v.id = p_vehicle_id FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(private.org_role(v_org, v_uid)::text, '') NOT IN ('owner', 'dispatcher') THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_worker_id IS NOT NULL
     AND private.org_role(v_org, p_worker_id) IS DISTINCT FROM 'worker' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a vehicle goes to an active worker of the same business';
  END IF;

  UPDATE public.vehicles v SET assigned_worker_id = p_worker_id, updated_at = now()
  WHERE v.id = p_vehicle_id;
  PERFORM private.audit_write('organization.assign_vehicle', 'public.vehicles',
    p_vehicle_id::text, NULL, jsonb_build_object('worker_id', p_worker_id), NULL);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('vehicle_id', p_vehicle_id));
  RETURN p_vehicle_id;
END $$;

-- ---------------------------------------------------------------------------
-- What a dispatcher can dispatch, shaped like the request rows the apps already map.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.org_assignable_jobs()
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
  v_org uuid;
BEGIN
  SELECT m.organization_id INTO v_org FROM public.organization_members m
  WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner', 'dispatcher')
  ORDER BY m.joined_at LIMIT 1;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT jsonb_build_object(
           'id', r.id, 'customer_id', r.customer_id,
           'is_custom_category', r.is_custom_category,
           'custom_category_label', r.custom_category_label,
           'description', r.description, 'urgency', r.urgency, 'status', r.status,
           'pickup_point', extensions.st_asgeojson(r.pickup_point)::jsonb,
           'pickup_label', r.pickup_label,
           'destination_point', extensions.st_asgeojson(r.destination_point)::jsonb,
           'destination_label', r.destination_label,
           'scheduled_at', r.scheduled_at, 'currency', r.currency,
           'expires_at', r.expires_at, 'created_at', r.created_at,
           'service_categories', jsonb_build_object('key', sc.key),
           'jobs', jsonb_build_object(
             'provider_id', j.provider_id, 'agreed_amount_minor', j.agreed_amount_minor,
             'currency', j.currency, 'commission_rate_bps', j.commission_rate_bps,
             'commission_minor', j.commission_minor, 'net_minor', j.net_minor,
             'estimated_gateway_fee_minor', j.estimated_gateway_fee_minor,
             'actual_gateway_fee_minor', j.actual_gateway_fee_minor, 'tip_minor', j.tip_minor))
  FROM public.jobs j
  JOIN public.requests r ON r.id = j.request_id
  LEFT JOIN public.service_categories sc ON sc.id = r.category_id
  JOIN public.organization_members m
    ON m.user_id = j.provider_id AND m.organization_id = v_org AND m.status = 'active'
  -- Payment confirmation assigns the job to the account that accepted it (`assign_job`), so a
  -- job the business holds and has not handed to a worker is one whose worker is that account.
  WHERE (j.worker_id IS NULL OR j.worker_id = j.provider_id)
    AND r.status IN ('paid_held', 'assigned')
  ORDER BY r.created_at;
END $$;

-- ---------------------------------------------------------------------------
-- availability_schedules (RLS matrix §3).
-- ---------------------------------------------------------------------------
CREATE TABLE public.availability_schedules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  -- ISO weekday: 1 is Monday.
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  start_time  time NOT NULL,
  end_time    time NOT NULL CHECK (end_time > start_time),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_id, weekday, start_time)
);
CREATE INDEX availability_schedules_provider ON public.availability_schedules (provider_id);

ALTER TABLE public.availability_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.availability_schedules FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.availability_schedules FROM anon, authenticated;
GRANT SELECT ON public.availability_schedules TO authenticated;
GRANT ALL ON public.availability_schedules TO service_role;
-- Writes go through set_availability, which replaces the week in one statement: a week saved
-- half-way is worse than either the old one or the new one.
CREATE POLICY availability_schedules_read ON public.availability_schedules FOR SELECT
  TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.organization_members me
                    JOIN public.organization_members them
                      ON them.organization_id = me.organization_id
                    WHERE me.user_id = (SELECT auth.uid()) AND me.status = 'active'
                      AND me.role IN ('owner', 'dispatcher')
                      AND them.user_id = availability_schedules.provider_id
                      AND them.status = 'active')
         OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])));

CREATE FUNCTION public.set_availability(p_idempotency_key text, p_slots jsonb)
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
  IF NOT EXISTS (SELECT 1 FROM public.provider_profiles pp WHERE pp.user_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' OR jsonb_array_length(p_slots) > 50 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'set_availability',
    jsonb_build_object('slots', p_slots));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'count')::integer;
  END IF;

  DELETE FROM public.availability_schedules a WHERE a.provider_id = v_uid;
  BEGIN
    INSERT INTO public.availability_schedules (provider_id, weekday, start_time, end_time)
    SELECT v_uid, (s ->> 'weekday')::smallint,
           make_time(((s ->> 'start_minutes')::integer) / 60,
                     ((s ->> 'start_minutes')::integer) % 60, 0),
           CASE WHEN (s ->> 'end_minutes')::integer = 1440 THEN time '23:59:59'
                ELSE make_time(((s ->> 'end_minutes')::integer) / 60,
                               ((s ->> 'end_minutes')::integer) % 60, 0) END
    FROM jsonb_array_elements(p_slots) s;
  EXCEPTION
    WHEN check_violation OR unique_violation OR invalid_text_representation
      OR not_null_violation OR datetime_field_overflow OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'each slot is a weekday 1-7 and a start before its end, in minutes of the day';
  END;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('count', v_count));
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Earnings goals.
-- ---------------------------------------------------------------------------
CREATE TABLE public.provider_earnings_goals (
  provider_id  uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  target_minor bigint NOT NULL CHECK (target_minor > 0),
  currency     char(3) NOT NULL REFERENCES public.currencies (code),
  period       text NOT NULL CHECK (period IN ('weekly', 'monthly')),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.provider_earnings_goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_earnings_goals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.provider_earnings_goals FROM anon, authenticated;
GRANT SELECT ON public.provider_earnings_goals TO authenticated;
GRANT ALL ON public.provider_earnings_goals TO service_role;
CREATE POLICY provider_earnings_goals_read_own ON public.provider_earnings_goals FOR SELECT
  TO authenticated USING (provider_id = (SELECT auth.uid()));

CREATE FUNCTION public.set_earnings_goal(
  p_idempotency_key text, p_target_minor bigint, p_period text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_currency char(3);
BEGIN
  IF p_target_minor IS NULL OR p_target_minor <= 0 OR p_period NOT IN ('weekly', 'monthly') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT c.currency_code INTO v_currency
  FROM public.provider_profiles pp
  JOIN public.profiles p ON p.user_id = pp.user_id
  JOIN public.countries c ON c.code = p.country_code
  WHERE pp.user_id = v_uid;
  IF v_currency IS NULL THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'set_earnings_goal',
    jsonb_build_object('target_minor', p_target_minor, 'period', p_period));
  IF v_claim IS NOT NULL THEN
    RETURN p_target_minor;
  END IF;

  INSERT INTO public.provider_earnings_goals (provider_id, target_minor, currency, period)
  VALUES (v_uid, p_target_minor, v_currency, p_period)
  ON CONFLICT (provider_id) DO UPDATE
  SET target_minor = excluded.target_minor, currency = excluded.currency,
      period = excluded.period, updated_at = now();
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('target_minor', p_target_minor));
  RETURN p_target_minor;
END $$;

-- Progress is what the provider netted on jobs confirmed this week or month, in their own time
-- zone, the same money the earnings screen shows.
CREATE FUNCTION public.my_earnings_goal()
RETURNS TABLE (target_minor bigint, currency char(3), period text, progress_minor bigint,
               period_start timestamptz)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_tz    text := private.user_timezone(v_uid);
  v_goal  public.provider_earnings_goals%ROWTYPE;
  v_start timestamptz;
BEGIN
  SELECT * INTO v_goal FROM public.provider_earnings_goals g WHERE g.provider_id = v_uid;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  v_start := date_trunc(CASE WHEN v_goal.period = 'weekly' THEN 'week' ELSE 'month' END,
                        now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  RETURN QUERY
  SELECT v_goal.target_minor, v_goal.currency, v_goal.period,
         (SELECT coalesce(sum(j.net_minor), 0)::bigint FROM public.jobs j
          WHERE j.confirmed_at >= v_start AND j.currency = v_goal.currency
            AND (j.worker_id = v_uid OR (j.provider_id = v_uid AND j.worker_id IS NULL))),
         v_start;
END $$;

-- ---------------------------------------------------------------------------
-- Insights.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_provider_insights(p_days integer DEFAULT 30)
RETURNS TABLE (acceptance_rate numeric, completion_rate numeric, avg_rating numeric,
               five_star_share numeric, avg_response_time_seconds integer,
               period_days integer, rating_count integer)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_days integer := least(greatest(coalesce(p_days, 30), 1), 365);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.provider_profiles pp WHERE pp.user_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  WITH decided AS (
    SELECT o.status FROM public.offers o
    WHERE o.provider_id = v_uid AND o.created_at >= now() - make_interval(days => v_days)
      AND o.status IN ('accepted', 'declined', 'expired', 'withdrawn')
  ), seen AS (
    -- Only reviews out of their blind period, and never one moderation took down.
    SELECT r.stars FROM public.ratings r
    WHERE r.ratee_id = v_uid AND r.direction = 'customer_to_provider'
      AND r.visible_at IS NOT NULL AND r.visible_at <= now()
      AND r.moderation_status <> 'rejected'
      AND r.created_at >= now() - make_interval(days => v_days)
  )
  SELECT
    CASE WHEN (SELECT count(*) FROM decided) = 0 THEN 0::numeric
         ELSE round((SELECT count(*) FILTER (WHERE status = 'accepted') FROM decided)::numeric
                    / (SELECT count(*) FROM decided), 4) END,
    round(coalesce(pp.completion_rate_bps, 0)::numeric / 10000, 4),
    round(coalesce(pp.rating_avg_milli, 0)::numeric / 1000, 2),
    CASE WHEN (SELECT count(*) FROM seen) = 0 THEN 0::numeric
         ELSE round((SELECT count(*) FILTER (WHERE stars = 5) FROM seen)::numeric
                    / (SELECT count(*) FROM seen), 4) END,
    coalesce(pp.response_time_p50_s, 0),
    v_days,
    coalesce(pp.rating_count, 0)
  FROM public.provider_profiles pp
  WHERE pp.user_id = v_uid;
END $$;

REVOKE ALL ON FUNCTION
  public.my_organization_invitations(),
  public.my_organization(),
  public.my_organization_members(),
  public.invite_member_by_phone(text, uuid, text, public.business_role),
  public.assign_vehicle(text, uuid, uuid),
  public.org_assignable_jobs(),
  public.set_availability(text, jsonb),
  public.set_earnings_goal(text, bigint, text),
  public.my_earnings_goal(),
  public.my_provider_insights(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.my_organization_invitations(),
  public.my_organization(),
  public.my_organization_members(),
  public.invite_member_by_phone(text, uuid, text, public.business_role),
  public.assign_vehicle(text, uuid, uuid),
  public.org_assignable_jobs(),
  public.set_availability(text, jsonb),
  public.set_earnings_goal(text, bigint, text),
  public.my_earnings_goal(),
  public.my_provider_insights(integer)
  TO authenticated;
