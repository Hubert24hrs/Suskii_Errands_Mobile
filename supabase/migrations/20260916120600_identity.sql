-- Identity: profiles, devices, consents, notification preferences, and the functions that
-- change server-owned fields. ERD §2; RLS matrix §2; PRD SH-01, SH-05, SH-07, SH-08, SH-16.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
CREATE TABLE public.profiles (
  user_id               uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE RESTRICT,
  display_name          text    NOT NULL DEFAULT '' CHECK (length(display_name) <= 80),
  country_code          char(2) REFERENCES public.countries (code),
  language              text    NOT NULL DEFAULT 'en' CHECK (language ~ '^[a-z]{2,3}$'),
  avatar_path           text    CHECK (avatar_path IS NULL OR length(avatar_path) <= 512),
  -- Server-owned below: no client grant exists for these columns (S-13 finding 1).
  active_mode           public.user_mode           NOT NULL DEFAULT 'customer',
  customer_verification public.verification_status NOT NULL DEFAULT 'unverified',
  provider_verification public.verification_status NOT NULL DEFAULT 'unverified',
  trust_level           public.trust_level         NOT NULL DEFAULT 'new',
  version               integer     NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX profiles_country ON public.profiles (country_code);

CREATE TRIGGER profiles_touch BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (display_name, language, avatar_path) ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;

-- Policies wrap auth.uid() and helpers in SELECT so they run once per query, not per row, and
-- keep one permissive policy per action (Supabase advisors: auth_rls_initplan,
-- multiple_permissive_policies).
CREATE POLICY profiles_read ON public.profiles FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR (SELECT private.is_any_admin()));
CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

-- The app sends the country and language chosen before sign-in (PRD SH-01) as user metadata.
-- That metadata is user-controlled, so it is validated rather than trusted.
CREATE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_country  char(2);
  v_language text;
BEGIN
  SELECT c.code INTO v_country
  FROM public.countries c
  WHERE c.code = upper(NEW.raw_user_meta_data ->> 'country_code')
    AND c.status IN ('beta', 'live');

  SELECT l INTO v_language
  FROM public.countries c, unnest(c.supported_languages) AS l
  WHERE c.code = v_country AND l = lower(NEW.raw_user_meta_data ->> 'language');

  INSERT INTO public.profiles (user_id, country_code, language)
  VALUES (NEW.id, v_country,
          coalesce(v_language,
                   (SELECT c.default_language FROM public.countries c WHERE c.code = v_country),
                   'en'));
  RETURN NEW;
END $$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.handle_new_user();

-- Language must be one the user's country supports.
CREATE FUNCTION private.profiles_validate_language()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.country_code IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.countries c
    WHERE c.code = NEW.country_code AND NEW.language = ANY (c.supported_languages)
  ) THEN
    RAISE EXCEPTION 'ERR_LANGUAGE_NOT_SUPPORTED' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER profiles_language_check BEFORE INSERT OR UPDATE OF language, country_code ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.profiles_validate_language();

-- PRD SH-08: switching to provider mode requires completed provider verification,
-- re-checked here rather than trusted from the client or the JWT.
CREATE FUNCTION public.set_active_mode(p_mode public.user_mode)
RETURNS public.user_mode
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile public.profiles%ROWTYPE;
BEGIN
  IF p_mode IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF p_mode = 'provider' AND v_profile.provider_verification <> 'verified' THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
  END IF;

  IF v_profile.active_mode IS DISTINCT FROM p_mode THEN
    UPDATE public.profiles
    SET active_mode = p_mode, version = version + 1
    WHERE user_id = v_uid;
    PERFORM private.emit_event('profile', v_uid::text, 'profile.mode_changed',
                               jsonb_build_object('from', v_profile.active_mode, 'to', p_mode));
  END IF;
  RETURN p_mode;
END $$;

-- ---------------------------------------------------------------------------
-- user_devices
-- ---------------------------------------------------------------------------
CREATE TABLE public.user_devices (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  platform                public.device_platform NOT NULL,
  -- sha256 of the client-reported fingerprint; used for self-dealing and referral checks.
  device_fingerprint_hash bytea NOT NULL,
  push_token              text,
  voip_token              text,
  app_version             text CHECK (app_version IS NULL OR app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+'),
  -- Written only by the device-integrity Edge Function (service_role).
  integrity_verdict       jsonb,
  rasp_signals            jsonb,
  created_at              timestamptz NOT NULL DEFAULT now(),
  last_seen_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, device_fingerprint_hash)
);
CREATE INDEX user_devices_fingerprint ON public.user_devices (device_fingerprint_hash);

ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_devices FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_devices FROM anon, authenticated;
GRANT SELECT (id, user_id, platform, app_version, created_at, last_seen_at) ON public.user_devices TO authenticated;
GRANT ALL ON public.user_devices TO service_role;
CREATE POLICY user_devices_read ON public.user_devices FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[])));

CREATE FUNCTION public.register_device(
  p_platform public.device_platform,
  p_fingerprint text,
  p_app_version text DEFAULT NULL,
  p_push_token text DEFAULT NULL,
  p_voip_token text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
  v_id  uuid;
BEGIN
  IF p_platform IS NULL OR p_fingerprint IS NULL OR length(p_fingerprint) NOT BETWEEN 16 AND 512 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- VoIP push tokens exist only on iOS (PushKit); refusing them elsewhere keeps call
  -- routing honest (spec: VoIP push only for calls).
  IF p_voip_token IS NOT NULL AND p_platform <> 'ios' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_devices AS d
    (user_id, platform, device_fingerprint_hash, app_version, push_token, voip_token)
  VALUES (v_uid, p_platform, sha256(convert_to(p_fingerprint, 'UTF8')), p_app_version,
          p_push_token, p_voip_token)
  ON CONFLICT (user_id, device_fingerprint_hash) DO UPDATE
    SET app_version  = coalesce(EXCLUDED.app_version, d.app_version),
        push_token   = coalesce(EXCLUDED.push_token, d.push_token),
        voip_token   = coalesce(EXCLUDED.voip_token, d.voip_token),
        last_seen_at = now()
  RETURNING d.id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- consents — append-only. A withdrawal is a new row with granted = false.
-- ---------------------------------------------------------------------------
CREATE TABLE public.consents (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id           uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  kind              public.consent_kind NOT NULL,
  granted           boolean NOT NULL,
  legal_document_id uuid REFERENCES public.legal_documents (id),
  device_id         uuid REFERENCES public.user_devices (id),
  country_code      char(2) REFERENCES public.countries (code),
  recorded_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX consents_latest ON public.consents (user_id, kind, id DESC);

ALTER TABLE public.consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consents FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.consents FROM anon, authenticated;
GRANT SELECT ON public.consents TO authenticated;
GRANT SELECT, INSERT ON public.consents TO service_role;
CREATE POLICY consents_read ON public.consents FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[])));

CREATE TRIGGER consents_append_only
  BEFORE UPDATE OR DELETE ON public.consents
  FOR EACH ROW EXECUTE FUNCTION private.audit_forbid_mutation();

CREATE FUNCTION private.has_consent(p_user uuid, p_kind public.consent_kind)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce((
    SELECT c.granted FROM public.consents c
    WHERE c.user_id = p_user AND c.kind = p_kind
    ORDER BY c.id DESC LIMIT 1
  ), false);
$$;

-- PRD SH-07. Idempotent by key so a retried tap cannot record two rows.
CREATE FUNCTION public.record_consent(
  p_kind public.consent_kind,
  p_granted boolean,
  p_idempotency_key text,
  p_legal_document_id uuid DEFAULT NULL,
  p_device_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_request jsonb := jsonb_build_object('kind', p_kind, 'granted', p_granted,
                       'legal_document_id', p_legal_document_id, 'device_id', p_device_id);
  v_replay  jsonb;
  v_row     public.consents%ROWTYPE;
  v_result  jsonb;
BEGIN
  IF p_kind IS NULL OR p_granted IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_replay := private.idempotency_claim(v_uid, p_idempotency_key, 'record_consent', v_request);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF p_device_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_devices d WHERE d.id = p_device_id AND d.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.consents (user_id, kind, granted, legal_document_id, device_id, country_code)
  VALUES (v_uid, p_kind, p_granted, p_legal_document_id, p_device_id,
          (SELECT p.country_code FROM public.profiles p WHERE p.user_id = v_uid))
  RETURNING * INTO v_row;

  PERFORM private.emit_event('consent', v_uid::text,
    CASE WHEN p_granted THEN 'consent.granted' ELSE 'consent.withdrawn' END,
    jsonb_build_object('kind', p_kind, 'consent_id', v_row.id));

  v_result := jsonb_build_object('id', v_row.id, 'kind', v_row.kind, 'granted', v_row.granted,
                                 'recorded_at', v_row.recorded_at);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- ---------------------------------------------------------------------------
-- notification_preferences
-- ---------------------------------------------------------------------------
CREATE TABLE public.notification_preferences (
  user_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  channel     text NOT NULL CHECK (channel IN ('push', 'sms', 'email', 'in_app', 'whatsapp')),
  category    text NOT NULL CHECK (category IN ('transactional', 'marketing')),
  enabled     boolean NOT NULL DEFAULT true,
  quiet_start time,
  quiet_end   time,
  PRIMARY KEY (user_id, channel, category),
  CONSTRAINT notification_preferences_quiet_pair CHECK ((quiet_start IS NULL) = (quiet_end IS NULL))
);

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_preferences FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_preferences FROM anon, authenticated;
GRANT SELECT, INSERT ON public.notification_preferences TO authenticated;
GRANT UPDATE (enabled, quiet_start, quiet_end) ON public.notification_preferences TO authenticated;
GRANT ALL ON public.notification_preferences TO service_role;
CREATE POLICY notification_preferences_read ON public.notification_preferences FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[])));
CREATE POLICY notification_preferences_insert_own ON public.notification_preferences FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY notification_preferences_update_own ON public.notification_preferences FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- Function privileges: nothing is callable unless granted here.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  private.handle_new_user(),
  private.profiles_validate_language(),
  private.has_consent(uuid, public.consent_kind),
  public.set_active_mode(public.user_mode),
  public.register_device(public.device_platform, text, text, text, text),
  public.record_consent(public.consent_kind, boolean, text, uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.set_active_mode(public.user_mode),
  public.register_device(public.device_platform, text, text, text, text),
  public.record_consent(public.consent_kind, boolean, text, uuid, uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_consent(uuid, public.consent_kind) TO service_role;
