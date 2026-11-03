-- First-run role selection (feature 1 of the 2026-11-03 brief) and the provider status the app shows.
--
-- One account already holds both modes (`profiles.active_mode`, a verification standing per mode)
-- and switches between them with `set_active_mode`. What did not exist is the question a new
-- account is asked once, "How would you like to use Suskii Errands?", and a record that it was
-- answered so the screen is never shown twice.
--
-- Choosing "Service Provider" does not put anybody in provider mode. `set_active_mode` still
-- refuses provider mode until the provider standing is `verified`, and the job feed, offers and
-- matching all require an active provider: an unapproved provider can browse their onboarding and
-- nothing else. The choice is recorded as `signup_role` so the app can take them there.
--
-- Every account that exists when this runs is treated as having chosen already. They are using the
-- app; asking them now would be a question about something they settled by using it.

ALTER TABLE public.profiles
  ADD COLUMN role_selected_at timestamptz,
  ADD COLUMN signup_role      public.user_mode;

-- Server-owned like active_mode: no client grant (the structure test lists the writable columns).
UPDATE public.profiles SET role_selected_at = created_at WHERE role_selected_at IS NULL;

-- The six statuses of the brief, derived rather than stored: they are a reading of the provider
-- verification standing and the suspension, and a second column would drift from both.
CREATE FUNCTION private.provider_status(p_user uuid)
RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN pp.suspended_until > now() OR p.provider_verification = 'suspended' THEN 'suspended'
    WHEN p.provider_verification = 'verified' THEN 'approved'
    WHEN p.provider_verification = 'rejected' THEN 'rejected'
    WHEN p.provider_verification = 'in_review' THEN 'pending_approval'
    -- Started: documents in progress, or lapsed and needing renewal, or a provider profile saved.
    WHEN p.provider_verification IN ('pending', 'expired') OR pp.user_id IS NOT NULL
      THEN 'pending_verification'
    ELSE 'not_registered' END
  FROM public.profiles p
  LEFT JOIN public.provider_profiles pp ON pp.user_id = p.user_id
  WHERE p.user_id = p_user;
$$;
REVOKE ALL ON FUNCTION private.provider_status(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.select_initial_role(p_role public.user_mode, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_profile public.profiles%ROWTYPE;
  v_out     jsonb;
BEGIN
  IF p_role IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'select_initial_role',
    jsonb_build_object('role', p_role));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_profile FROM public.profiles p WHERE p.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- Answered once. A second answer, from a second device or a stale screen, changes nothing and
  -- is not an error: the person is simply shown where they already are.
  IF v_profile.role_selected_at IS NULL THEN
    UPDATE public.profiles
    SET role_selected_at = now(), signup_role = p_role, version = version + 1
    WHERE user_id = v_uid
    RETURNING * INTO v_profile;
    PERFORM private.emit_event('profile', v_uid::text, 'profile.role_selected',
                               jsonb_build_object('role', p_role));
  END IF;

  v_out := jsonb_build_object(
    'role_selected', true,
    'signup_role', v_profile.signup_role,
    'active_mode', v_profile.active_mode,
    'provider_status', private.provider_status(v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_out);
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.select_initial_role(public.user_mode, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.select_initial_role(public.user_mode, text) TO authenticated;

-- get_bootstrap, restated whole from 20260927120000_account_lifecycle; the three new fields are marked.
CREATE OR REPLACE FUNCTION public.get_bootstrap(
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
      'session_aal', coalesce(auth.jwt() ->> 'aal', 'aal1'),
      'deletion_scheduled_for', (SELECT d.scheduled_for FROM public.account_deletion_requests d
                                 WHERE d.user_id = v_uid AND d.status = 'scheduled'),
      -- New below (20261103120000): whether the first-run role screen is still owed, what was
      -- chosen on it, and the provider side as one of the six statuses the app shows.
      'role_selected', v_profile.role_selected_at IS NOT NULL,
      'signup_role', v_profile.signup_role,
      'provider_status', private.provider_status(v_uid)
    ) END
  );
END $$;
