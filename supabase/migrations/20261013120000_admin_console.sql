-- The admin console's backend (audit Z.8). The web console ran on mocks because six of the reads
-- and writes its screens make had no server side at all:
--
--   * `admin_overview` — the dashboard, one row per country the caller may see. Money (GMV, held
--     funds) is NULL for a role that may not read money, because the KPI functions draw that line
--     and a dashboard that ignored it would be the way round it.
--   * `audit_search` — the matrix has always named it ("Super admin R via F") and nothing built
--     it. Reading the audit log is itself written to the audit log.
--   * `admin_staff_list` / `admin_staff_lookup` — the staff page. `admin_users` is readable by a
--     super admin, but the email and whether a second factor is enrolled live in `auth`.
--   * Staff and promo changes go through the existing config-change four eyes (RLS matrix §6:
--     "admin role grants" and "promo budgets"). Two new targets, `admin_user` and `promo_code`,
--     and nobody may propose or approve a change to their own access.
--   * `dispute_resolution_quote` — what `resolve_dispute` would post, computed by the same
--     arithmetic, so the console shows amounts and never derives them.
--   * `admin_promo_codes` — the promo list with the budget, which `promo_codes` does not grant to
--     a client column by column (knowing the budget tells a customer when to hurry).
--   * `analytics_report` learns the caller's country scope (found wiring the console): it checked
--     the role and nothing else, so a finance officer scoped to Kenya read every country's daily
--     aggregates — audit U.1's class again. A view with no country column cannot be scoped, so a
--     scoped officer is refused it: fail closed, the same rule as everywhere else.
--   * Ten read policies admit the roles the RLS matrix gives `R:scope` (Z.14). Wiring the console
--     found that a dispute officer could not read the request a dispute is about, because
--     `requests_read_own` passed the scope helper `support_agent` alone; a new checker rule (F)
--     then found nine more of the same shape. The matrix is the specification the DPIA rests on,
--     so the policies follow it, scoped by country exactly as before.

-- ---------------------------------------------------------------------------
-- The dashboard.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_overview()
RETURNS TABLE (
  country_code char(2), currency char(3), active_users integer, active_jobs integer,
  offers_per_request numeric, gmv_30d_minor bigint, held_minor bigint,
  open_disputes integer, open_sos integer)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_super boolean;
  v_money boolean;
BEGIN
  PERFORM private.require_user();
  IF NOT private.is_any_admin() THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  v_super := private.has_admin_role(ARRAY['super_admin']::public.admin_role[]);
  v_money := private.has_admin_role(ARRAY['super_admin', 'finance_officer']::public.admin_role[]);

  RETURN QUERY
  SELECT c.code, c.currency_code,
         (SELECT count(DISTINCT d.user_id)::integer
          FROM public.user_devices d
          JOIN public.profiles p ON p.user_id = d.user_id
          WHERE p.country_code = c.code AND d.last_seen_at >= now() - interval '24 hours'),
         (SELECT count(*)::integer FROM public.requests r
          WHERE r.country_code = c.code
            AND r.status IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                             'completed_by_provider')),
         (SELECT round(avg(x.n), 1)
          FROM (SELECT count(o.id) AS n
                FROM public.requests r
                LEFT JOIN public.offers o ON o.request_id = r.id
                WHERE r.country_code = c.code AND r.published_at >= now() - interval '7 days'
                GROUP BY r.id) x),
         CASE WHEN v_money THEN
           (SELECT coalesce(sum(j.agreed_amount_minor), 0)::bigint
            FROM public.jobs j JOIN public.requests r ON r.id = j.request_id
            WHERE r.country_code = c.code AND j.currency = c.currency_code
              AND j.confirmed_at >= now() - interval '30 days')
         END,
         CASE WHEN v_money THEN
           (SELECT coalesce(sum(p.job_amount_minor), 0)::bigint
            FROM public.payments p JOIN public.requests r ON r.id = p.request_id
            WHERE r.country_code = c.code AND p.currency = c.currency_code
              AND p.kind = 'job' AND p.status = 'held')
         END,
         (SELECT count(*)::integer FROM public.disputes d
          JOIN public.requests r ON r.id = d.request_id
          WHERE r.country_code = c.code AND d.status IN ('open', 'under_review')),
         (SELECT count(*)::integer FROM public.sos_incidents s
          LEFT JOIN public.requests r ON r.id = s.request_id
          LEFT JOIN public.profiles p ON p.user_id = s.raised_by
          WHERE coalesce(r.country_code, p.country_code) = c.code
            AND s.status IN ('open', 'acknowledged', 'dispatched'))
  FROM public.countries c
  WHERE c.status <> 'disabled'
    AND (v_super OR private.admin_scope_allows(c.code))
  ORDER BY c.code;
END $$;

-- ---------------------------------------------------------------------------
-- audit_search: the audit log, newest first, a page at a time.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.audit_search(
  p_before_id bigint DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_actor_id uuid DEFAULT NULL,
  p_action_prefix text DEFAULT NULL,
  p_target_id text DEFAULT NULL)
RETURNS TABLE (
  id bigint, actor_id uuid, actor_name text, actor_role text, action text,
  target_table text, target_id text, reason_code text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_action_prefix IS NOT NULL AND p_action_prefix !~ '^[a-z0-9_.]{1,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  PERFORM private.audit_write('audit.search', 'audit.log', NULL, NULL,
    jsonb_strip_nulls(jsonb_build_object('before_id', p_before_id, 'actor_id', p_actor_id,
      'action_prefix', p_action_prefix, 'target_id', p_target_id)), NULL);

  -- Display name, not contact details: the trail says who acted, not how to reach them.
  RETURN QUERY
  SELECT l.id, l.actor_id, coalesce(p.display_name, u.email::text), l.actor_role, l.action,
         l.target_table, l.target_id, l.reason_code, l.created_at
  FROM audit.log l
  LEFT JOIN public.profiles p ON p.user_id = l.actor_id
  LEFT JOIN auth.users u ON u.id = l.actor_id
  WHERE (p_before_id IS NULL OR l.id < p_before_id)
    AND (p_actor_id IS NULL OR l.actor_id = p_actor_id)
    AND (p_action_prefix IS NULL OR l.action LIKE p_action_prefix || '%')
    AND (p_target_id IS NULL OR l.target_id = p_target_id)
  ORDER BY l.id DESC
  LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END $$;

-- ---------------------------------------------------------------------------
-- Staff.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_staff_list()
RETURNS TABLE (
  user_id uuid, email text, display_name text, roles public.admin_role[],
  country_scope char(2)[], mfa_enrolled boolean, created_at timestamptz,
  disabled_at timestamptz, last_sign_in_at timestamptz)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- Enrolment is read from the factor itself rather than `mfa_enrolled_at`, which nothing sets:
  -- every admin function requires aal2, so a staff member without a verified factor can sign in
  -- and do nothing at all.
  RETURN QUERY
  SELECT a.user_id, u.email::text, p.display_name, a.roles, a.country_scope,
         EXISTS (SELECT 1 FROM auth.mfa_factors f
                 WHERE f.user_id = a.user_id AND f.status = 'verified'),
         a.created_at, a.disabled_at, u.last_sign_in_at
  FROM public.admin_users a
  JOIN auth.users u ON u.id = a.user_id
  LEFT JOIN public.profiles p ON p.user_id = a.user_id
  ORDER BY a.created_at;
END $$;

-- Finds the account a new staff member signed up with, by exact email. Exact, so it confirms an
-- address the caller already has rather than discovering one.
CREATE FUNCTION public.admin_staff_lookup(p_email text)
RETURNS TABLE (user_id uuid, email text, display_name text, is_staff boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  PERFORM private.audit_write('admin.staff_lookup', 'auth.users', NULL, NULL,
    jsonb_build_object('domain', split_part(v_email, '@', 2)), NULL);
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = v_email) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY
  SELECT u.id, u.email::text, p.display_name,
         EXISTS (SELECT 1 FROM public.admin_users a WHERE a.user_id = u.id)
  FROM auth.users u
  LEFT JOIN public.profiles p ON p.user_id = u.id
  WHERE lower(u.email) = v_email;
END $$;

-- ---------------------------------------------------------------------------
-- Two new config-change targets. Levels stay one (proposer plus one reviewer) through the
-- existing `config_change_levels`, whose `<> 'country'` arm already covers both.
-- ---------------------------------------------------------------------------
ALTER TABLE public.config_changes DROP CONSTRAINT config_changes_target;
ALTER TABLE public.config_changes ADD CONSTRAINT config_changes_target
  CHECK (target IN ('country', 'feature_flag', 'remote_config', 'referral_campaign',
                    'admin_user', 'promo_code'));

-- What a proposal may name, per target. A key it does not list is refused at proposal time,
-- rather than discovered by a reviewer or, worse, silently ignored by the apply.
CREATE FUNCTION private.config_proposal_problem(
  p_target text, p_target_key text, p_proposed jsonb, p_country_code char(2), p_uid uuid)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_key     text;
  v_role    text;
  v_currency char(3);
  v_exists  boolean;
BEGIN
  IF p_target = 'admin_user' THEN
    IF private.try_uuid(p_target_key) IS NULL
       OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = private.try_uuid(p_target_key)) THEN
      RETURN 'a staff change names an existing account';
    END IF;
    IF private.try_uuid(p_target_key) = p_uid THEN
      RETURN 'nobody changes their own access';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_proposed) LOOP
      IF v_key NOT IN ('roles', 'country_scope', 'active') THEN
        RETURN format('%s is not a staff field', v_key);
      END IF;
    END LOOP;
    IF p_proposed ? 'roles' THEN
      IF jsonb_typeof(p_proposed -> 'roles') <> 'array'
         OR jsonb_array_length(p_proposed -> 'roles') = 0 THEN
        RETURN 'roles is a non-empty list';
      END IF;
      FOR v_role IN SELECT jsonb_array_elements_text(p_proposed -> 'roles') LOOP
        IF NOT v_role = ANY (enum_range(NULL::public.admin_role)::text[]) THEN
          RETURN format('%s is not a role', v_role);
        END IF;
      END LOOP;
    ELSIF NOT EXISTS (SELECT 1 FROM public.admin_users a
                      WHERE a.user_id = private.try_uuid(p_target_key)) THEN
      RETURN 'a new staff member needs at least one role';
    END IF;
    IF p_proposed ? 'country_scope' AND jsonb_typeof(p_proposed -> 'country_scope') <> 'null' THEN
      IF jsonb_typeof(p_proposed -> 'country_scope') <> 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_proposed -> 'country_scope') s
                    WHERE s !~ '^[A-Z]{2}$') THEN
        RETURN 'country_scope is null or a list of ISO codes';
      END IF;
    END IF;
    IF p_proposed ? 'active' AND jsonb_typeof(p_proposed -> 'active') <> 'boolean' THEN
      RETURN 'active is true or false';
    END IF;
    RETURN NULL;
  END IF;

  IF p_target = 'promo_code' THEN
    v_exists := p_target_key <> 'new';
    IF v_exists AND NOT EXISTS (SELECT 1 FROM public.promo_codes pc
                                WHERE pc.id = private.try_uuid(p_target_key)) THEN
      RETURN 'a promo change names an existing id or the word new';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_proposed) LOOP
      -- A live promo's terms do not change under the customers who have already seen them; its
      -- budget, end, cap and on/off switch may.
      IF v_exists AND v_key NOT IN ('active', 'budget_minor', 'ends_at', 'max_uses',
                                    'max_discount_minor') THEN
        RETURN format('%s cannot change on an existing promo', v_key);
      END IF;
      IF NOT v_exists AND v_key NOT IN ('code', 'currency', 'discount_kind', 'discount_value',
          'max_discount_minor', 'budget_minor', 'max_uses', 'per_user_limit',
          'stacks_with_referral', 'starts_at', 'ends_at', 'active') THEN
        RETURN format('%s is not a promo field', v_key);
      END IF;
    END LOOP;
    IF NOT v_exists THEN
      IF p_country_code IS NULL THEN
        RETURN 'a promo belongs to a country';
      END IF;
      SELECT c.currency_code INTO v_currency FROM public.countries c WHERE c.code = p_country_code;
      IF NOT FOUND THEN
        RETURN 'unknown country';
      END IF;
      IF coalesce(p_proposed ->> 'code', '') !~ '^[A-Z0-9_-]{4,24}$' THEN
        RETURN 'code is 4 to 24 capitals, digits, dash or underscore';
      END IF;
      IF coalesce(p_proposed ->> 'currency', v_currency) <> v_currency THEN
        RETURN 'a promo is in its country''s currency';
      END IF;
      IF coalesce(p_proposed ->> 'discount_kind', '') NOT IN ('percent', 'fixed') THEN
        RETURN 'discount_kind is percent or fixed';
      END IF;
      IF jsonb_typeof(p_proposed -> 'discount_value') <> 'number'
         OR (p_proposed ->> 'discount_value')::numeric <= 0
         OR (p_proposed ->> 'discount_kind' = 'percent'
             AND (p_proposed ->> 'discount_value')::numeric > 10000) THEN
        RETURN 'discount_value is positive; basis points for percent';
      END IF;
      IF EXISTS (SELECT 1 FROM public.promo_codes pc
                 WHERE pc.country_code = p_country_code AND pc.code = p_proposed ->> 'code') THEN
        RETURN 'that code already exists in this country';
      END IF;
    END IF;
    FOR v_key IN SELECT unnest(ARRAY['budget_minor', 'max_uses', 'max_discount_minor',
                                     'per_user_limit']) LOOP
      IF p_proposed ? v_key AND jsonb_typeof(p_proposed -> v_key) <> 'null'
         AND (jsonb_typeof(p_proposed -> v_key) <> 'number'
              OR (p_proposed ->> v_key)::numeric <= 0
              OR (p_proposed ->> v_key)::numeric <> trunc((p_proposed ->> v_key)::numeric)) THEN
        RETURN format('%s is a positive whole number', v_key);
      END IF;
    END LOOP;
    IF p_proposed ? 'ends_at' AND jsonb_typeof(p_proposed -> 'ends_at') = 'string'
       AND (p_proposed ->> 'ends_at')::timestamptz
           <= coalesce((p_proposed ->> 'starts_at')::timestamptz, now()) THEN
      RETURN 'a promo ends after it starts';
    END IF;
    RETURN NULL;
  END IF;

  RETURN NULL;
EXCEPTION
  WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
    RETURN 'a date or number did not parse';
END $$;

CREATE OR REPLACE FUNCTION private.apply_config_change(p_change public.config_changes)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_gaps  text[];
  v_user  uuid;
  v_roles public.admin_role[];
  v_scope char(2)[];
BEGIN
  IF p_change.target = 'admin_user' THEN
    v_user := p_change.target_key::uuid;
    IF p_change.proposed ? 'roles' THEN
      v_roles := ARRAY(SELECT jsonb_array_elements_text(p_change.proposed -> 'roles'))
                   ::public.admin_role[];
    END IF;
    IF jsonb_typeof(p_change.proposed -> 'country_scope') = 'array' THEN
      v_scope := ARRAY(SELECT jsonb_array_elements_text(p_change.proposed -> 'country_scope'))
                   ::char(2)[];
    END IF;
    -- An existing row is updated field by field; a new one is inserted. Not one upsert, because
    -- the insert half would be checked for NOT NULL roles even when the row already exists.
    UPDATE public.admin_users a SET
      roles = coalesce(v_roles, a.roles),
      country_scope = CASE WHEN p_change.proposed ? 'country_scope' THEN v_scope
                           ELSE a.country_scope END,
      disabled_at = CASE
        WHEN NOT p_change.proposed ? 'active' THEN a.disabled_at
        WHEN (p_change.proposed ->> 'active')::boolean THEN NULL
        ELSE coalesce(a.disabled_at, now()) END
    WHERE a.user_id = v_user;
    IF NOT FOUND THEN
      INSERT INTO public.admin_users (user_id, roles, country_scope, disabled_at)
      VALUES (v_user, v_roles, v_scope,
              CASE WHEN (p_change.proposed ->> 'active')::boolean IS FALSE THEN now() END);
    END IF;
    -- Disabling is immediate: every admin function re-reads `admin_users`, and the sessions go
    -- too, so a token minted before the change does not outlive it.
    IF (p_change.proposed ->> 'active')::boolean IS FALSE THEN
      DELETE FROM auth.sessions s WHERE s.user_id = v_user;
    END IF;
    RETURN;
  END IF;

  IF p_change.target = 'promo_code' THEN
    INSERT INTO public.promo_codes (id, code, country_code, currency, discount_kind,
                                    discount_value, max_discount_minor, budget_minor, max_uses,
                                    per_user_limit, stacks_with_referral, starts_at, ends_at,
                                    active)
    VALUES (coalesce(nullif(p_change.target_key, 'new')::uuid, gen_random_uuid()),
            p_change.proposed ->> 'code',
            p_change.country_code,
            coalesce((p_change.proposed ->> 'currency')::char(3),
                     (SELECT c.currency_code FROM public.countries c
                      WHERE c.code = p_change.country_code)),
            (p_change.proposed ->> 'discount_kind')::public.discount_kind,
            (p_change.proposed ->> 'discount_value')::bigint,
            (p_change.proposed ->> 'max_discount_minor')::bigint,
            (p_change.proposed ->> 'budget_minor')::bigint,
            (p_change.proposed ->> 'max_uses')::integer,
            coalesce((p_change.proposed ->> 'per_user_limit')::smallint, 1::smallint),
            coalesce((p_change.proposed ->> 'stacks_with_referral')::boolean, false),
            coalesce((p_change.proposed ->> 'starts_at')::timestamptz, now()),
            (p_change.proposed ->> 'ends_at')::timestamptz,
            coalesce((p_change.proposed ->> 'active')::boolean, true))
    ON CONFLICT (id) DO UPDATE SET
      active = coalesce((p_change.proposed ->> 'active')::boolean, promo_codes.active),
      -- Never below what has been spent; the table's CHECK and `spent_minor` have the last word.
      budget_minor = CASE WHEN p_change.proposed ? 'budget_minor'
                          THEN (p_change.proposed ->> 'budget_minor')::bigint
                          ELSE promo_codes.budget_minor END,
      ends_at = CASE WHEN p_change.proposed ? 'ends_at'
                     THEN (p_change.proposed ->> 'ends_at')::timestamptz
                     ELSE promo_codes.ends_at END,
      max_uses = CASE WHEN p_change.proposed ? 'max_uses'
                      THEN (p_change.proposed ->> 'max_uses')::integer
                      ELSE promo_codes.max_uses END,
      max_discount_minor = CASE WHEN p_change.proposed ? 'max_discount_minor'
                                THEN (p_change.proposed ->> 'max_discount_minor')::bigint
                                ELSE promo_codes.max_discount_minor END;
    RETURN;
  END IF;

  IF p_change.target = 'referral_campaign' THEN
    INSERT INTO public.referral_campaigns (id, country_code, name, rate_bps, currency,
                                           budget_minor, starts_at, ends_at, active, created_by)
    VALUES (coalesce(nullif(p_change.target_key, 'new')::uuid, gen_random_uuid()),
            p_change.country_code,
            p_change.proposed ->> 'name',
            (p_change.proposed ->> 'rate_bps')::integer,
            (p_change.proposed ->> 'currency')::char(3),
            (p_change.proposed ->> 'budget_minor')::bigint,
            (p_change.proposed ->> 'starts_at')::timestamptz,
            (p_change.proposed ->> 'ends_at')::timestamptz,
            coalesce((p_change.proposed ->> 'active')::boolean, true),
            p_change.requested_by)
    ON CONFLICT (id) DO UPDATE SET
      name = coalesce(p_change.proposed ->> 'name', referral_campaigns.name),
      rate_bps = coalesce((p_change.proposed ->> 'rate_bps')::integer,
                          referral_campaigns.rate_bps),
      budget_minor = coalesce((p_change.proposed ->> 'budget_minor')::bigint,
                              referral_campaigns.budget_minor),
      ends_at = coalesce((p_change.proposed ->> 'ends_at')::timestamptz,
                         referral_campaigns.ends_at),
      active = coalesce((p_change.proposed ->> 'active')::boolean, referral_campaigns.active);
    RETURN;
  END IF;

  IF p_change.target = 'country' THEN
    IF p_change.proposed ->> 'status' = 'live' THEN
      v_gaps := private.country_pack_gaps(p_change.target_key::char(2));
      IF cardinality(v_gaps) > 0 THEN
        RAISE EXCEPTION 'ERR_COUNTRY_PACK_INCOMPLETE' USING ERRCODE = 'P0001',
          DETAIL = array_to_string(v_gaps, ', ');
      END IF;
    END IF;
    UPDATE public.countries c SET
      status = coalesce((p_change.proposed ->> 'status')::public.country_status, c.status),
      commission_rate_bps = coalesce((p_change.proposed ->> 'commission_rate_bps')::integer,
                                     c.commission_rate_bps),
      referral_rate_bps = coalesce((p_change.proposed ->> 'referral_rate_bps')::integer,
                                   c.referral_rate_bps),
      config = jsonb_build_object(
        'client', coalesce(p_change.proposed -> 'config' -> 'client', c.config -> 'client'),
        'server', coalesce(p_change.proposed -> 'config' -> 'server', c.config -> 'server')),
      version = c.version + 1,
      approved_by = p_change.requested_by,
      approved_at = now()
    WHERE c.code = p_change.target_key::char(2);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
    END IF;

  ELSIF p_change.target = 'feature_flag' THEN
    INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible,
                                      payload)
    VALUES (p_change.target_key, p_change.country_code,
            coalesce((p_change.proposed ->> 'enabled')::boolean, false),
            coalesce((p_change.proposed ->> 'rollout_pct')::smallint, 100::smallint),
            coalesce((p_change.proposed ->> 'client_visible')::boolean, true),
            coalesce(p_change.proposed -> 'payload', '{}'::jsonb))
    ON CONFLICT (key, country_code) DO UPDATE SET
      enabled = coalesce((p_change.proposed ->> 'enabled')::boolean, feature_flags.enabled),
      rollout_pct = coalesce((p_change.proposed ->> 'rollout_pct')::smallint,
                             feature_flags.rollout_pct),
      client_visible = coalesce((p_change.proposed ->> 'client_visible')::boolean,
                                feature_flags.client_visible),
      payload = coalesce(p_change.proposed -> 'payload', feature_flags.payload);

  ELSIF p_change.target = 'remote_config' THEN
    IF NOT (p_change.proposed ? 'value') THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a remote_config change must name a value';
    END IF;
    INSERT INTO public.remote_config (key, country_code, value, client_visible)
    VALUES (p_change.target_key, p_change.country_code,
            p_change.proposed -> 'value',
            coalesce((p_change.proposed ->> 'client_visible')::boolean, false))
    ON CONFLICT (key, country_code) DO UPDATE SET
      value = p_change.proposed -> 'value',
      client_visible = coalesce((p_change.proposed ->> 'client_visible')::boolean,
                                remote_config.client_visible);

  ELSE
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = format('no apply path for target %s', p_change.target);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.propose_config_change(
  p_idempotency_key text,
  p_target text,
  p_target_key text,
  p_proposed jsonb,
  p_country_code char(2) DEFAULT NULL,
  p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_previous jsonb;
  v_levels   smallint;
  v_problem  text;
  v_country  char(2);
  v_id       uuid;
BEGIN
  IF NOT private.has_admin_role(
       CASE WHEN p_target = 'referral_campaign'
            THEN ARRAY['super_admin', 'finance_officer']::public.admin_role[]
            ELSE ARRAY['super_admin']::public.admin_role[] END) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- Step-up (Z.11): private.require_recent_mfa is defined in 20261013120200.
  PERFORM private.require_recent_mfa();

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'propose_config_change',
    jsonb_build_object('target', p_target, 'target_key', p_target_key,
                       'country_code', p_country_code, 'proposed', p_proposed));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'change_id')::uuid;
  END IF;

  IF p_target NOT IN ('country', 'feature_flag', 'remote_config', 'referral_campaign',
                      'admin_user', 'promo_code')
     OR p_proposed IS NULL OR jsonb_typeof(p_proposed) <> 'object'
     OR p_proposed = '{}'::jsonb THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_target = 'country' AND p_target_key !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a country change is keyed by its ISO code';
  END IF;
  IF p_target = 'referral_campaign' THEN
    IF p_country_code IS NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a campaign belongs to a country';
    END IF;
    IF p_target_key <> 'new' AND private.try_uuid(p_target_key) IS NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a campaign change names an existing id or the word new';
    END IF;
  ELSIF p_target IN ('admin_user', 'promo_code') THEN
    v_problem := private.config_proposal_problem(p_target, p_target_key, p_proposed,
                                                 p_country_code, v_uid);
    IF v_problem IS NOT NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = v_problem;
    END IF;
  ELSIF p_target <> 'country' AND p_target_key !~ '^[a-z0-9_.]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a flag or config key is lowercase, digits, underscore and dot';
  END IF;

  v_previous := CASE p_target
    WHEN 'country' THEN
      (SELECT to_jsonb(c) - 'updated_at' FROM public.countries c
       WHERE c.code = p_target_key::char(2))
    WHEN 'feature_flag' THEN
      (SELECT to_jsonb(f) - 'updated_at' - 'id' FROM public.feature_flags f
       WHERE f.key = p_target_key AND f.country_code IS NOT DISTINCT FROM p_country_code)
    WHEN 'referral_campaign' THEN
      (SELECT to_jsonb(rc) - 'created_at' FROM public.referral_campaigns rc
       WHERE rc.id = private.try_uuid(p_target_key))
    WHEN 'admin_user' THEN
      (SELECT jsonb_build_object('roles', to_jsonb(a.roles),
                                 'country_scope', to_jsonb(a.country_scope),
                                 'active', a.disabled_at IS NULL)
       FROM public.admin_users a WHERE a.user_id = private.try_uuid(p_target_key))
    WHEN 'promo_code' THEN
      (SELECT to_jsonb(pc) - 'created_at' - 'spent_minor' FROM public.promo_codes pc
       WHERE pc.id = private.try_uuid(p_target_key))
    ELSE
      (SELECT to_jsonb(r) - 'updated_at' - 'id' FROM public.remote_config r
       WHERE r.key = p_target_key AND r.country_code IS NOT DISTINCT FROM p_country_code)
  END;

  -- An existing promo carries its own country, so a proposal cannot file it under another one.
  v_country := CASE
    WHEN p_target = 'country' THEN p_target_key::char(2)
    WHEN p_target = 'promo_code' AND p_target_key <> 'new' THEN
      (SELECT pc.country_code FROM public.promo_codes pc
       WHERE pc.id = private.try_uuid(p_target_key))
    ELSE p_country_code END;

  v_levels := private.config_change_levels(p_target, p_proposed, v_previous);

  INSERT INTO public.config_changes (target, target_key, country_code, proposed, previous, note,
                                     approvals_required, requested_by)
  VALUES (p_target, p_target_key, v_country,
          p_proposed, v_previous, nullif(btrim(coalesce(p_note, '')), ''), v_levels, v_uid)
  RETURNING id INTO v_id;

  INSERT INTO public.approvals (subject_kind, subject_id, action, payload, requested_by, level)
  SELECT 'config_change', v_id::text, p_target || '.apply',
         jsonb_build_object('target_key', p_target_key, 'country_code', v_country),
         v_uid, lvl
  FROM generate_series(1, v_levels) lvl;

  PERFORM private.audit_write('config.propose', 'public.config_changes', v_id::text,
    v_previous, p_proposed, NULL);
  PERFORM private.emit_event('config', v_id::text, 'config.change_proposed',
    jsonb_build_object('change_id', v_id, 'target', p_target, 'target_key', p_target_key,
                       'approvals_required', v_levels));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('change_id', v_id));
  RETURN v_id;
END $$;

-- The reviewer half of "nobody changes their own access": a proposal to widen somebody's roles
-- must not be signed by that somebody.
CREATE OR REPLACE FUNCTION public.review_config_change(
  p_idempotency_key text, p_change_id uuid, p_approve boolean,
  p_reason_key text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_change  public.config_changes%ROWTYPE;
  v_pending uuid;
  v_left    integer;
  v_status  text;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- Step-up (Z.11): private.require_recent_mfa is defined in 20261013120200.
  PERFORM private.require_recent_mfa();

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'review_config_change',
    jsonb_build_object('change_id', p_change_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim ->> 'status';
  END IF;

  SELECT * INTO v_change FROM public.config_changes c WHERE c.id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CONFIG_CHANGE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_change.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF v_change.requested_by = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you proposed this one';
  END IF;
  IF v_change.target = 'admin_user' AND private.try_uuid(v_change.target_key) = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'this change is to your own access';
  END IF;
  IF EXISTS (SELECT 1 FROM public.approvals a
             WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
               AND a.approved_by = v_uid) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you have already signed this one';
  END IF;

  SELECT a.id INTO v_pending FROM public.approvals a
  WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
    AND a.status = 'pending'
  ORDER BY a.level LIMIT 1;
  IF v_pending IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.approvals a
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
      approved_by = v_uid, decided_at = now()
  WHERE a.id = v_pending;

  IF NOT p_approve THEN
    v_status := 'rejected';
    UPDATE public.approvals a SET status = 'cancelled', decided_at = now()
    WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
      AND a.status = 'pending';
    UPDATE public.config_changes c
    SET status = 'rejected', decided_at = now(), reason_key = p_reason_key
    WHERE c.id = p_change_id;
  ELSE
    SELECT count(*)::integer INTO v_left FROM public.approvals a
    WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
      AND a.status = 'pending';
    IF v_left > 0 THEN
      v_status := 'pending';
    ELSE
      v_status := 'applied';
      PERFORM private.apply_config_change(v_change);
      UPDATE public.config_changes c
      SET status = 'applied', decided_at = now(), applied_at = now(), reason_key = p_reason_key
      WHERE c.id = p_change_id;
    END IF;
  END IF;

  PERFORM private.audit_write('config.review', 'public.config_changes', p_change_id::text,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', v_status, 'approve', p_approve), p_reason_key);
  PERFORM private.emit_event('config', p_change_id::text, 'config.change_' || v_status,
    jsonb_build_object('change_id', p_change_id, 'target', v_change.target,
                       'target_key', v_change.target_key, 'status', v_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- What a resolution would post, by the arithmetic `resolve_dispute` uses. The refund is a share
-- of what is held for the job, in basis points, so the console sends a choice and never an
-- amount it worked out itself.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.dispute_resolution_quote(p_dispute_id uuid, p_refund_bps integer)
RETURNS TABLE (
  currency char(3), held_minor bigint, refund_minor bigint, commission_minor bigint,
  gateway_fee_minor bigint, provider_minor bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_dispute  public.disputes%ROWTYPE;
  v_job      public.jobs%ROWTYPE;
  v_payment  public.payments%ROWTYPE;
  v_refund   bigint;
  v_refunded bigint;
  v_kept     bigint;
  v_comm     bigint;
  v_fee      bigint;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_refund_bps IS NULL OR p_refund_bps < 0 OR p_refund_bps > 10000 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_dispute FROM public.disputes d WHERE d.id = p_dispute_id;
  IF NOT FOUND OR NOT private.admin_may_read_request(v_dispute.request_id,
       ARRAY['dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_DISPUTE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_dispute.status NOT IN ('open', 'under_review') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_dispute.request_id;
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = v_dispute.request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_refund := private.apply_bps(v_payment.job_amount_minor, p_refund_bps);
  SELECT coalesce(sum(r.amount_minor), 0)::bigint INTO v_refunded
  FROM public.refunds r WHERE r.payment_id = v_payment.id AND r.status <> 'failed';
  IF v_refunded + v_refund > v_payment.amount_minor THEN
    RAISE EXCEPTION 'ERR_REFUND_EXCEEDS_PAYMENT' USING ERRCODE = 'P0001';
  END IF;

  v_kept := v_payment.job_amount_minor - v_refund;
  v_comm := private.apply_bps(v_kept, coalesce(v_job.commission_rate_bps, 1250));
  v_fee  := coalesce(v_job.actual_gateway_fee_minor, 0);

  RETURN QUERY SELECT v_payment.currency, v_payment.job_amount_minor, v_refund, v_comm, v_fee,
                      v_kept - v_comm - v_fee;
END $$;

-- ---------------------------------------------------------------------------
-- Promos as the console sees them: with the budget, what is spent and how often used.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_promo_codes(p_country char(2) DEFAULT NULL)
RETURNS TABLE (
  id uuid, code text, country_code char(2), currency char(3),
  discount_kind public.discount_kind, discount_value bigint, max_discount_minor bigint,
  budget_minor bigint, spent_minor bigint, max_uses integer, uses integer,
  per_user_limit smallint, stacks_with_referral boolean, starts_at timestamptz,
  ends_at timestamptz, active boolean, created_at timestamptz)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'finance_officer', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT pc.id, pc.code, pc.country_code, pc.currency, pc.discount_kind, pc.discount_value,
         pc.max_discount_minor, pc.budget_minor, pc.spent_minor, pc.max_uses,
         (SELECT count(*)::integer FROM public.promo_redemptions pr WHERE pr.promo_id = pc.id),
         pc.per_user_limit, pc.stacks_with_referral, pc.starts_at, pc.ends_at, pc.active,
         pc.created_at
  FROM public.promo_codes pc
  WHERE (p_country IS NULL OR pc.country_code = p_country)
    AND private.admin_may_read_country(pc.country_code,
          ARRAY['finance_officer', 'support_agent']::public.admin_role[])
  ORDER BY pc.created_at DESC;
END $$;

-- ---------------------------------------------------------------------------
-- analytics_report, scoped.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.analytics_report(
  p_view text, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_limit integer DEFAULT 400)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_from  date := coalesce(p_from, current_date - 30);
  v_to    date := coalesce(p_to, current_date);
  v_scope char(2)[] := private.kpi_guard(
    ARRAY['super_admin', 'finance_officer']::public.admin_role[], NULL);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM analytics.exports e WHERE e.view_name = p_view AND e.enabled) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = format('%s is not an analytics view', p_view);
  END IF;
  IF v_to < v_from THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the window ends before it starts';
  END IF;

  IF v_scope IS NULL THEN
    RETURN QUERY EXECUTE format(
      'SELECT to_jsonb(v) FROM analytics.%I v WHERE v.day BETWEEN $1 AND $2 '
      || 'ORDER BY v.day DESC LIMIT $3', p_view)
    USING v_from, v_to, least(greatest(coalesce(p_limit, 400), 1), 5000);
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns c
                 WHERE c.table_schema = 'analytics' AND c.table_name = p_view
                   AND c.column_name = 'country_code') THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'this view has no country, so a country-scoped officer cannot read it';
  END IF;
  RETURN QUERY EXECUTE format(
    'SELECT to_jsonb(v) FROM analytics.%I v WHERE v.day BETWEEN $1 AND $2 '
    || 'AND v.country_code = ANY ($4) ORDER BY v.day DESC LIMIT $3', p_view)
  USING v_from, v_to, least(greatest(coalesce(p_limit, 400), 1), 5000), v_scope;
END $$;

-- ---------------------------------------------------------------------------
-- Z.14: the roles the matrix gives R:scope, admitted by the same country-scoped helpers.
-- ---------------------------------------------------------------------------
DROP POLICY requests_read_own ON public.requests;
CREATE POLICY requests_read_own ON public.requests FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.is_assigned_job_provider(requests.id))
         OR (SELECT private.admin_may_read_country(requests.country_code,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY offer_threads_read ON public.offer_threads;
CREATE POLICY offer_threads_read ON public.offer_threads FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offer_threads.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.admin_may_read_request(offer_threads.request_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY offers_read ON public.offers;
CREATE POLICY offers_read ON public.offers FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offers.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.admin_may_read_request(offers.request_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY payments_read_participant ON public.payments;
CREATE POLICY payments_read_participant ON public.payments FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(payments.request_id))
         OR (SELECT private.admin_may_read_request(payments.request_id,
               ARRAY['finance_officer', 'dispute_officer', 'support_agent']::public.admin_role[])));

DROP POLICY payouts_read_own ON public.payouts;
CREATE POLICY payouts_read_own ON public.payouts FOR SELECT TO authenticated
  USING (beneficiary_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(payouts.beneficiary_id,
               ARRAY['finance_officer', 'support_agent']::public.admin_role[])));

DROP POLICY withdrawals_read_own ON public.withdrawals;
CREATE POLICY withdrawals_read_own ON public.withdrawals FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(withdrawals.user_id,
               ARRAY['finance_officer', 'support_agent']::public.admin_role[])));

DROP POLICY tips_read ON public.tips;
CREATE POLICY tips_read ON public.tips FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(tips.request_id))
         OR (SELECT private.admin_may_read_request(tips.request_id,
               ARRAY['finance_officer', 'support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY promo_redemptions_read_own ON public.promo_redemptions;
CREATE POLICY promo_redemptions_read_own ON public.promo_redemptions FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_request(promo_redemptions.request_id,
               ARRAY['finance_officer', 'support_agent']::public.admin_role[])));

DROP POLICY referral_commissions_read_own ON public.referral_commissions;
CREATE POLICY referral_commissions_read_own ON public.referral_commissions FOR SELECT
  TO authenticated
  USING (referrer_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_request(referral_commissions.request_id,
               ARRAY['finance_officer', 'support_agent']::public.admin_role[])));

REVOKE ALL ON FUNCTION
  public.admin_overview(),
  public.audit_search(bigint, integer, uuid, text, text),
  public.admin_staff_list(),
  public.admin_staff_lookup(text),
  private.config_proposal_problem(text, text, jsonb, char, uuid),
  public.dispute_resolution_quote(uuid, integer),
  public.admin_promo_codes(char)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.admin_overview(),
  public.audit_search(bigint, integer, uuid, text, text),
  public.admin_staff_list(),
  public.admin_staff_lookup(text),
  public.dispute_resolution_quote(uuid, integer),
  public.admin_promo_codes(char)
  TO authenticated;
