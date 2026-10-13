-- KYC completeness: CR-20260923-10 (a), (b), (d) and (e).
--
-- The provider KYC screens could not finish on a real backend. The address and guarantor steps
-- had nowhere to put what the person typed, "submit for review" had no server half, and the
-- profile the screen draws from carried no timestamps, so the app rolled its own status and
-- showed the epoch for every date. Here:
--
--   (a) `submit_kyc_step` takes a `p_payload` for the three kinds that are answers rather than
--       uploads: address, guarantor and the credentials description. The payload is validated
--       per kind and **sealed** (`kyc_payload`, ADR-0018): an address and a guarantor's phone
--       number are exactly what the kyc schema exists to protect. An officer reads one through
--       `get_kyc_step_payload`, which writes `audit.kyc_access` before it returns anything, the
--       same rule as a document.
--   (b) `submit_kyc_for_review` is the server's answer to "I'm done". It refuses while a required
--       step is missing, rejected or expired (ERR_KYC_INCOMPLETE, which the catalogue has had as
--       planned since v1) and records when the person asked. It decides nothing: the officer
--       still decides every step, and RB-05's rule that nothing is approved automatically stands.
--   (d) `get_my_kyc_profile` gains per-step `submitted_at` and `reviewed_at`, the overall status
--       for the mode, and `submitted_for_review_at`.
--   (e) `provider_profiles.business_name`, client-writable. `kind` stays server-set: a provider
--       becomes `business` by registering an organisation, which is where the check lives.
--
-- (f) is declined: `update_provider_services` and `update_provider_service_areas` replace a set,
-- so a retry converges on the same state and a key would add nothing. (c) needs the gateway's
-- name check, and (g) is served by polling until a screen needs more.

SELECT private.create_field_data_key('kyc_payload');

CREATE TABLE kyc.kyc_step_payloads (
  user_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  kind               public.kyc_step_kind NOT NULL,
  payload_ciphertext bytea NOT NULL,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, kind)
);
ALTER TABLE kyc.kyc_step_payloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc.kyc_step_payloads FORCE ROW LEVEL SECURITY;
REVOKE ALL ON kyc.kyc_step_payloads FROM PUBLIC, anon, authenticated;

CREATE TABLE kyc.kyc_reviews (
  user_id      uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  submitted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE kyc.kyc_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc.kyc_reviews FORCE ROW LEVEL SECURITY;
REVOKE ALL ON kyc.kyc_reviews FROM PUBLIC, anon, authenticated;

ALTER TABLE public.provider_profiles
  ADD COLUMN business_name text CHECK (business_name IS NULL
                                       OR length(btrim(business_name)) BETWEEN 2 AND 120);
GRANT UPDATE (business_name) ON public.provider_profiles TO authenticated;

-- ---------------------------------------------------------------------------
-- What a payload may contain, per kind. Unknown keys are refused: a free-form bag sealed into the
-- kyc schema is a place for anything to end up.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.kyc_payload_clean(p_kind public.kyc_step_kind, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_allowed  text[];
  v_required text[];
  v_limits   jsonb;
  v_key      text;
  v_value    text;
  v_clean    jsonb := '{}'::jsonb;
BEGIN
  CASE p_kind
    WHEN 'address' THEN
      v_allowed  := ARRAY['line1', 'line2', 'city', 'state', 'landmark'];
      v_required := ARRAY['line1', 'city', 'state'];
      v_limits   := '{"line1": 200, "line2": 200, "city": 100, "state": 100, "landmark": 300}';
    WHEN 'guarantor' THEN
      v_allowed  := ARRAY['name', 'phone_e164', 'relationship'];
      v_required := ARRAY['name', 'phone_e164', 'relationship'];
      v_limits   := '{"name": 120, "phone_e164": 20, "relationship": 40}';
    WHEN 'credentials' THEN
      v_allowed  := ARRAY['description'];
      v_required := ARRAY['description'];
      v_limits   := '{"description": 1000}';
    ELSE
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END CASE;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    IF NOT (v_key = ANY (v_allowed)) OR jsonb_typeof(p_payload -> v_key) NOT IN ('string', 'null')
    THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
    END IF;
    v_value := nullif(btrim(p_payload ->> v_key), '');
    IF v_value IS NOT NULL THEN
      IF length(v_value) > (v_limits ->> v_key)::integer THEN
        RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
      END IF;
      IF v_key = 'phone_e164' THEN
        v_value := private.normalise_phone(v_value);
        IF v_value IS NULL THEN
          RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
        END IF;
      END IF;
      v_clean := v_clean || jsonb_build_object(v_key, v_value);
    END IF;
  END LOOP;
  FOREACH v_key IN ARRAY v_required LOOP
    IF NOT v_clean ? v_key THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  RETURN v_clean;
END $$;

-- ---------------------------------------------------------------------------
-- (a) submit_kyc_step with a payload. Replaced whole; the three-argument call still works.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.submit_kyc_step(text, public.kyc_step_kind, text[]);
CREATE FUNCTION public.submit_kyc_step(
  p_idempotency_key text,
  p_kind public.kyc_step_kind,
  p_upload_refs text[] DEFAULT NULL,
  p_payload jsonb DEFAULT NULL
)
RETURNS public.kyc_step_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_ref     text;
  v_payload jsonb;
BEGIN
  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- The answer steps need their answer; the others never take one.
  IF p_kind IN ('address', 'guarantor', 'credentials') THEN
    IF p_payload IS NOT NULL OR p_kind <> 'credentials' THEN
      v_payload := private.kyc_payload_clean(p_kind, p_payload);
    END IF;
  ELSIF p_payload IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_kyc_step',
    jsonb_build_object('kind', p_kind, 'refs', p_upload_refs,
                       'payload', CASE WHEN v_payload IS NOT NULL
                                       THEN md5(v_payload::text) END));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.kyc_step_status;
  END IF;

  -- Every upload must sit in the caller's own folder: `kyc-docs/<user_id>/<file>`.
  IF p_upload_refs IS NOT NULL THEN
    FOREACH v_ref IN ARRAY p_upload_refs LOOP
      IF (string_to_array(v_ref, '/'))[1] IS DISTINCT FROM v_uid::text THEN
        RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  END IF;

  IF v_payload IS NOT NULL THEN
    INSERT INTO kyc.kyc_step_payloads (user_id, kind, payload_ciphertext)
    VALUES (v_uid, p_kind,
            private.seal('kyc_payload', v_payload::text, 'kyc_payload:' || v_uid || ':' || p_kind))
    ON CONFLICT (user_id, kind) DO UPDATE
    SET payload_ciphertext = excluded.payload_ciphertext, updated_at = now();
  END IF;

  INSERT INTO kyc.kyc_steps (user_id, kind, status, upload_refs, attempt_count, submitted_at)
  VALUES (v_uid, p_kind, 'in_review', coalesce(p_upload_refs, '{}'::text[]), 1, now())
  ON CONFLICT (user_id, kind) DO UPDATE
  SET status = 'in_review',
      upload_refs = coalesce(excluded.upload_refs, kyc.kyc_steps.upload_refs),
      attempt_count = kyc.kyc_steps.attempt_count + 1,
      rejection_reason_key = NULL,
      reviewer_id = NULL,
      reviewed_at = NULL,
      submitted_at = now();

  PERFORM private.emit_event('kyc', v_uid::text, 'kyc.step_submitted',
    jsonb_build_object('user_id', v_uid, 'kind', p_kind));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'in_review'));
  RETURN 'in_review'::public.kyc_step_status;
END $$;

-- An officer reads a payload the way they open a document: the access is written down first.
CREATE FUNCTION public.get_kyc_step_payload(p_step_id uuid, p_reason_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_step    kyc.kyc_steps%ROWTYPE;
  v_country char(2);
  v_blob    bytea;
BEGIN
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_step FROM kyc.kyc_steps s WHERE s.id = p_step_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_KYC_STEP_INVALID' USING ERRCODE = 'P0001';
  END IF;
  IF v_step.user_id = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- The officer's country scope, as on the queue (RLS matrix §4).
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_step.user_id;
  IF NOT (SELECT a.country_scope IS NULL OR v_country = ANY (a.country_scope)
          FROM public.admin_users a WHERE a.user_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  SELECT pl.payload_ciphertext INTO v_blob FROM kyc.kyc_step_payloads pl
  WHERE pl.user_id = v_step.user_id AND pl.kind = v_step.kind;
  IF v_blob IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO audit.kyc_access (officer_id, subject_id, upload_ref, reason_code)
  VALUES (v_uid, v_step.user_id, 'payload:' || v_step.kind, p_reason_code);
  PERFORM private.audit_write('kyc.payload_access', 'kyc.kyc_step_payloads',
    v_step.user_id || ':' || v_step.kind, NULL,
    jsonb_build_object('subject_id', v_step.user_id), p_reason_code);
  RETURN private.open('kyc_payload', v_blob,
                      'kyc_payload:' || v_step.user_id || ':' || v_step.kind)::jsonb;
END $$;

-- ---------------------------------------------------------------------------
-- (b) "I'm done": refused while anything required is missing; decides nothing.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.submit_kyc_for_review(p_idempotency_key text)
RETURNS public.verification_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_country char(2);
  v_missing public.kyc_step_kind[];
  v_status  public.verification_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_kyc_for_review',
    '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.verification_status;
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- `in_progress` counts as submitted: it is a vendor check running, not a gap the person left.
  SELECT array_agg(r.kind ORDER BY r.ord) INTO v_missing
  FROM unnest(private.required_kyc_steps(v_country, 'provider')) WITH ORDINALITY AS r(kind, ord)
  LEFT JOIN kyc.kyc_steps s ON s.user_id = v_uid AND s.kind = r.kind
  WHERE coalesce(s.status, 'not_started') NOT IN ('in_progress', 'in_review', 'verified');
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_KYC_INCOMPLETE' USING ERRCODE = 'P0001',
      DETAIL = array_to_string(v_missing, ',');
  END IF;

  INSERT INTO kyc.kyc_reviews (user_id, submitted_at) VALUES (v_uid, now())
  ON CONFLICT (user_id) DO UPDATE SET submitted_at = now();

  PERFORM private.refresh_verification(v_uid);
  SELECT p.provider_verification INTO v_status FROM public.profiles p WHERE p.user_id = v_uid;

  PERFORM private.emit_event('kyc', v_uid::text, 'kyc.submitted_for_review',
    jsonb_build_object('user_id', v_uid, 'country_code', v_country));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- (d) The profile with its dates. Every row carries the overall status and when the person last
-- asked for review, so one call draws the whole screen.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.get_my_kyc_profile();
CREATE FUNCTION public.get_my_kyc_profile()
RETURNS TABLE (
  kind                    public.kyc_step_kind,
  status                  public.kyc_step_status,
  rejection_reason_key    text,
  attempt_count           smallint,
  expires_at              timestamptz,
  required                boolean,
  submitted_at            timestamptz,
  reviewed_at             timestamptz,
  overall_status          public.verification_status,
  submitted_for_review_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_country   char(2);
  v_mode      public.user_mode;
  v_required  public.kyc_step_kind[];
  v_overall   public.verification_status;
  v_submitted timestamptz;
BEGIN
  SELECT p.country_code, p.active_mode,
         CASE WHEN p.active_mode = 'provider' THEN p.provider_verification
              ELSE p.customer_verification END
  INTO v_country, v_mode, v_overall
  FROM public.profiles p WHERE p.user_id = v_uid;
  v_required := private.required_kyc_steps(v_country, coalesce(v_mode, 'customer'));
  SELECT r.submitted_at INTO v_submitted FROM kyc.kyc_reviews r WHERE r.user_id = v_uid;

  RETURN QUERY
  SELECT r.kind,
         coalesce(s.status, 'not_started'::public.kyc_step_status),
         s.rejection_reason_key,
         coalesce(s.attempt_count, 0::smallint),
         s.expires_at,
         true,
         s.submitted_at,
         s.reviewed_at,
         v_overall,
         v_submitted
  FROM unnest(v_required) AS r(kind)
  LEFT JOIN kyc.kyc_steps s ON s.user_id = v_uid AND s.kind = r.kind
  UNION ALL
  -- Steps they have done that their current mode does not require: a customer who has started
  -- provider onboarding should still see where it got to.
  SELECT s.kind, s.status, s.rejection_reason_key, s.attempt_count, s.expires_at, false,
         s.submitted_at, s.reviewed_at, v_overall, v_submitted
  FROM kyc.kyc_steps s
  WHERE s.user_id = v_uid AND NOT (s.kind = ANY (v_required));
END $$;

REVOKE ALL ON FUNCTION
  private.kyc_payload_clean(public.kyc_step_kind, jsonb),
  public.submit_kyc_step(text, public.kyc_step_kind, text[], jsonb),
  public.get_kyc_step_payload(uuid, text),
  public.submit_kyc_for_review(text),
  public.get_my_kyc_profile()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.submit_kyc_step(text, public.kyc_step_kind, text[], jsonb),
  public.get_kyc_step_payload(uuid, text),
  public.submit_kyc_for_review(text),
  public.get_my_kyc_profile()
TO authenticated;
