-- Supabase Auth hooks and the cold-start bootstrap function.
-- Hook wiring lives in supabase/config.toml ([auth.hook.*]); payload shapes follow the
-- Supabase Auth hooks documentation and are re-checked on a real project in spike S-02.

-- ---------------------------------------------------------------------------
-- Custom Access Token Hook: adds active_mode and admin_roles claims.
-- Claims are hints for routing and UI; every sensitive check re-reads the database
-- (private.has_admin_role requires aal2 and a live admin_users row).
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user   uuid  := (event ->> 'user_id')::uuid;
  v_claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  v_mode   public.user_mode;
  v_roles  public.admin_role[];
BEGIN
  SELECT p.active_mode INTO v_mode FROM public.profiles p WHERE p.user_id = v_user;
  SELECT a.roles INTO v_roles FROM public.admin_users a
  WHERE a.user_id = v_user AND a.disabled_at IS NULL;

  v_claims := jsonb_set(v_claims, '{active_mode}', coalesce(to_jsonb(v_mode), to_jsonb('customer'::text)));
  IF v_roles IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{admin_roles}', to_jsonb(v_roles));
  ELSE
    v_claims := v_claims - 'admin_roles';
  END IF;

  RETURN jsonb_set(event, '{claims}', v_claims);
END $$;

-- ---------------------------------------------------------------------------
-- Before User Created Hook: refuses phone sign-ups whose calling code does not belong to a
-- live or beta country, before any OTP SMS is paid for (R-31 SMS pumping; PRD SH-02).
-- Email-only sign-ups are not affected.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.before_user_created_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_phone text := regexp_replace(coalesce(event -> 'user' ->> 'phone', ''), '[^0-9]', '', 'g');
BEGIN
  IF v_phone = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.countries c
    WHERE c.status IN ('beta', 'live') AND v_phone LIKE c.calling_code || '%'
  ) THEN
    RETURN '{}'::jsonb;
  END IF;

  RETURN jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'ERR_COUNTRY_NOT_SUPPORTED'
  ));
END $$;

REVOKE ALL ON FUNCTION private.custom_access_token_hook(jsonb), private.before_user_created_hook(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION private.custom_access_token_hook(jsonb), private.before_user_created_hook(jsonb)
  TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- get_bootstrap(): everything the app shell needs on cold start (Kimi's AppBootstrap).
-- Callable before sign-in (country picker, forced update) and after.
-- PRE-CONTRACT: the response shape is finalised in contracts v1 (Stage B).
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.flag_on_for(p_key text, p_rollout_pct smallint, p_user uuid)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  -- Stable bucketing: the same user lands in the same bucket for a flag across sessions
  -- and releases. Anonymous callers get only fully rolled-out flags.
  SELECT CASE
    WHEN p_rollout_pct >= 100 THEN true
    WHEN p_rollout_pct <= 0 OR p_user IS NULL THEN false
    ELSE (get_byte(sha256(convert_to(p_key || ':' || p_user::text, 'UTF8')), 0) * 100 / 256) < p_rollout_pct
  END;
$$;

CREATE FUNCTION public.get_bootstrap(
  p_country_code char(2) DEFAULT NULL,
  p_platform public.device_platform DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_profile  public.profiles%ROWTYPE;
  v_country  public.countries%ROWTYPE;
  v_code     char(2);
  v_flags    jsonb;
  v_config   jsonb;
  v_min_ver  text;
BEGIN
  IF v_uid IS NOT NULL THEN
    SELECT * INTO v_profile FROM public.profiles p WHERE p.user_id = v_uid;
  END IF;

  v_code := coalesce(v_profile.country_code, upper(p_country_code));
  SELECT * INTO v_country FROM public.countries c
  WHERE c.code = v_code AND c.status IN ('beta', 'live');

  -- Country rows override global rows for the same key.
  SELECT coalesce(jsonb_object_agg(f.key, private.flag_on_for(f.key, f.rollout_pct, v_uid) AND f.enabled), '{}'::jsonb)
  INTO v_flags
  FROM (
    SELECT DISTINCT ON (ff.key) ff.key, ff.enabled, ff.rollout_pct
    FROM public.feature_flags ff
    WHERE ff.client_visible
      AND (ff.country_code IS NULL OR ff.country_code = v_country.code)
    ORDER BY ff.key, ff.country_code NULLS LAST
  ) f;

  SELECT coalesce(jsonb_object_agg(r.key, r.value), '{}'::jsonb)
  INTO v_config
  FROM (
    SELECT DISTINCT ON (rc.key) rc.key, rc.value
    FROM public.remote_config rc
    WHERE rc.client_visible
      AND (rc.country_code IS NULL OR rc.country_code = v_country.code)
    ORDER BY rc.key, rc.country_code NULLS LAST
  ) r;

  v_min_ver := coalesce(v_config -> 'min_supported_app_version' ->> p_platform::text, '0.0.0');

  RETURN jsonb_build_object(
    'server_time', to_jsonb(now()),
    'min_supported_app_version', v_min_ver,
    'countries', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code', c.code, 'name', c.name, 'status', c.status,
               'currency', c.currency_code, 'calling_code', c.calling_code,
               'default_language', c.default_language,
               'supported_languages', to_jsonb(c.supported_languages)
             ) ORDER BY c.name), '[]'::jsonb)
      FROM public.countries c WHERE c.status IN ('beta', 'live')
    ),
    'country_pack', CASE WHEN v_country.code IS NULL THEN NULL ELSE jsonb_build_object(
      'code', v_country.code,
      'status', v_country.status,
      'currency', jsonb_build_object('code', v_country.currency_code,
                                     'exponent', private.currency_exponent(v_country.currency_code)),
      'calling_code', v_country.calling_code,
      'default_language', v_country.default_language,
      'supported_languages', to_jsonb(v_country.supported_languages),
      'commission_rate_bps', v_country.commission_rate_bps,
      'version', v_country.version,
      'client', v_country.config -> 'client'
    ) END,
    'feature_flags', v_flags,
    'remote_config', v_config - 'min_supported_app_version',
    'user', CASE WHEN v_profile.user_id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_profile.user_id,
      'display_name', v_profile.display_name,
      'country_code', v_profile.country_code,
      'language', v_profile.language,
      'active_mode', v_profile.active_mode,
      'customer_verification', v_profile.customer_verification,
      'provider_verification', v_profile.provider_verification,
      'trust_level', v_profile.trust_level,
      -- Assurance level of this session. Whether the user has *enrolled* a factor
      -- (review 2.16, `mfa_enrolled`) reads auth.mfa_factors and is added with contracts v1.
      'session_aal', coalesce(auth.jwt() ->> 'aal', 'aal1')
    ) END
  );
END $$;

REVOKE ALL ON FUNCTION private.flag_on_for(text, smallint, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_bootstrap(char, public.device_platform) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_bootstrap(char, public.device_platform) TO anon, authenticated;
