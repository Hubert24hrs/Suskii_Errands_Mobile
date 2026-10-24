-- Two owner decisions of 2026-10-24.
--
-- 1. Verification is for service providers only. A customer publishes a request without verifying
--    their identity. The guard is not deleted: it becomes `customer_verification_required`
--    (remote config, per country, default false), so a country that needs it back is a
--    configuration change rather than a migration. Providers are unaffected: every provider path
--    still goes through `private.is_active_provider`, which requires `provider_verification`.
--
-- 2. Sign in with Google and Apple creates the account through `signInWithIdToken`, which carries
--    no sign-up metadata, so `private.handle_new_user` leaves `profiles.country_code` NULL. A
--    profile without a country cannot publish, be matched or be paid. `set_initial_country` lets
--    the person choose it once, while it is still NULL; after that the country is as fixed as it
--    is for an OTP sign-up, because the country decides currency, rules and the ledger.

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('customer_verification_required', NULL, 'false', true);

CREATE OR REPLACE FUNCTION private.do_publish_request(p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
  v_country public.country_status;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status <> 'draft' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(private.remote_config_json('customer_verification_required',
                                         v_request.country_code) = 'true'::jsonb, false)
     AND NOT EXISTS (SELECT 1 FROM public.profiles p
                     WHERE p.user_id = v_request.customer_id
                       AND p.customer_verification = 'verified') THEN
    RAISE EXCEPTION 'ERR_VERIFICATION_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.status INTO v_country FROM public.countries c WHERE c.code = v_request.country_code;
  IF v_country NOT IN ('live', 'beta') THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.requests r
  SET status = 'published',
      published_at = now(),
      expires_at = now() + interval '24 hours',
      version = r.version + 1
  WHERE r.id = p_request_id;

  PERFORM private.emit_event('request', p_request_id::text, 'request.published',
    jsonb_build_object('category_id', v_request.category_id, 'city_id', v_request.city_id,
                       'country_code', v_request.country_code, 'urgency', v_request.urgency,
                       'scheduled_at', v_request.scheduled_at));
  RETURN 'published'::public.job_status;
END $$;

CREATE FUNCTION public.set_initial_country(p_country_code text, p_language text DEFAULT NULL)
RETURNS char(2)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_profile  public.profiles%ROWTYPE;
  v_country  char(2);
  v_language text;
BEGIN
  SELECT * INTO v_profile FROM public.profiles p WHERE p.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.code INTO v_country FROM public.countries c
  WHERE c.code = upper(btrim(p_country_code)) AND c.status IN ('beta', 'live');
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  -- Idempotent for the same answer, so a retry after a dropped response is not an error.
  IF v_profile.country_code IS NOT NULL THEN
    IF v_profile.country_code = v_country THEN
      RETURN v_country;
    END IF;
    RAISE EXCEPTION 'ERR_COUNTRY_ALREADY_SET' USING ERRCODE = 'P0001';
  END IF;

  SELECT l INTO v_language
  FROM public.countries c, unnest(c.supported_languages) AS l
  WHERE c.code = v_country AND l = lower(p_language);

  UPDATE public.profiles p
  SET country_code = v_country,
      language = coalesce(v_language,
                          (SELECT c.default_language FROM public.countries c
                           WHERE c.code = v_country),
                          'en'),
      version = p.version + 1
  WHERE p.user_id = v_uid;

  PERFORM private.audit_write('profile.set_initial_country', 'public.profiles', v_uid::text,
    NULL, jsonb_build_object('country_code', v_country), NULL);
  RETURN v_country;
END $$;

REVOKE ALL ON FUNCTION public.set_initial_country(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_initial_country(text, text) TO authenticated;
