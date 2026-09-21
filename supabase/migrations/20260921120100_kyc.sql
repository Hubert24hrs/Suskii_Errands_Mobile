-- Phase 4, part 2: the KYC spine (ERD §4; RLS matrix §4; PRD SH-17, PR-02…PR-08, PR-14, AD-08,
-- AD-09; ADR-0005 names the vendor, ADR-0007 the encryption).
--
-- **No role has table privileges on `kyc`.** Everything is a function that returns an outcome and
-- a reason key. That is not decoration: the app must never receive the name on an identity record
-- (PR-02), and a reason key is all a screen needs to explain a rejection.
--
-- **The vendor is a seam.** Smile ID is OD-13 and unsigned, so no vendor call is made here. A
-- session records which vendor was asked, its job id and the outcome it returned; the Edge
-- Function that eventually talks to the vendor writes those through `private.record_vendor_check`.
-- Nothing pretends to verify anybody.
--
-- **Documents never sit in the database.** They live in `kyc-docs`, which is write-only for
-- clients: a stolen session cannot read back what it uploaded. An officer views one through a
-- short-lived signed URL, and asking for one writes `audit.kyc_access` first — in SQL, so the
-- record exists whether or not the URL is ever minted.
--
-- **One identity, one account.** `identity_documents` is unique on (country, type, blind index).
-- It is the anti-fraud control the spec asks for, and the reason ID numbers carry a blind index
-- at all: we can tell that two people submitted the same number without being able to read it.

CREATE TYPE public.kyc_decision AS ENUM ('approved', 'rejected');

CREATE TABLE kyc.verification_sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  kind          public.kyc_step_kind NOT NULL,
  vendor        text CHECK (vendor IS NULL OR length(vendor) <= 40),
  vendor_job_id text CHECK (vendor_job_id IS NULL OR length(vendor_job_id) <= 120),
  status        public.kyc_step_status NOT NULL DEFAULT 'in_progress',
  outcome       public.identity_check_outcome,
  reason_key    text CHECK (reason_key IS NULL OR length(reason_key) <= 60),
  consent_id    bigint REFERENCES public.consents (id),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '30 minutes',
  completed_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX verification_sessions_user
  ON kyc.verification_sessions (user_id, kind, created_at DESC);

CREATE TABLE kyc.kyc_steps (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  kind                 public.kyc_step_kind NOT NULL,
  status               public.kyc_step_status NOT NULL DEFAULT 'not_started',
  attempt_count        smallint NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  rejection_reason_key text CHECK (rejection_reason_key IS NULL OR length(rejection_reason_key) <= 60),
  reviewer_id          uuid REFERENCES auth.users (id),
  reviewed_at          timestamptz,
  expires_at           timestamptz,
  upload_refs          text[] NOT NULL DEFAULT '{}'::text[],
  submitted_at         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  -- One current step per kind per person; the history lives in `audit.log`.
  UNIQUE (user_id, kind)
);
CREATE INDEX kyc_steps_queue ON kyc.kyc_steps (submitted_at)
  WHERE status = 'in_review';
CREATE INDEX kyc_steps_expiry ON kyc.kyc_steps (expires_at)
  WHERE expires_at IS NOT NULL AND status = 'verified';
CREATE TRIGGER kyc_steps_touch BEFORE UPDATE ON kyc.kyc_steps
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

CREATE TABLE kyc.identity_documents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  id_type               text NOT NULL CHECK (length(id_type) BETWEEN 2 AND 40),
  id_number_ciphertext  bytea NOT NULL,
  id_number_blind_index bytea NOT NULL,
  issuing_country       char(2) NOT NULL REFERENCES public.countries (code),
  vendor_reference      text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  -- One verified identity per real person: the core anti-fraud control (ERD §4).
  UNIQUE (issuing_country, id_type, id_number_blind_index)
);
CREATE INDEX identity_documents_user ON kyc.identity_documents (user_id);

CREATE TABLE kyc.police_clearances (
  id                           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  country_code                 char(2) NOT NULL REFERENCES public.countries (code),
  document_name                text,
  certificate_number_ciphertext bytea NOT NULL,
  certificate_blind_index      bytea NOT NULL,
  issued_on                    date NOT NULL,
  -- OD-09 decides this where the certificate carries no statutory expiry.
  expires_on                   date NOT NULL,
  verification_channel         text CHECK (verification_channel IS NULL
                                           OR length(verification_channel) <= 40),
  decision                     public.kyc_decision,
  reviewer_id                  uuid REFERENCES auth.users (id),
  decided_at                   timestamptz,
  upload_ref                   text,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT police_clearances_dates CHECK (expires_on > issued_on)
  -- Deliberately no free-text notes column (spec): a reason key is reviewable, a note is not.
);
CREATE INDEX police_clearances_expiry ON kyc.police_clearances (expires_on)
  WHERE decision = 'approved';
CREATE INDEX police_clearances_user ON kyc.police_clearances (user_id, created_at DESC);

CREATE TABLE audit.kyc_access (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  officer_id  uuid NOT NULL REFERENCES auth.users (id),
  subject_id  uuid REFERENCES auth.users (id),
  upload_ref  text NOT NULL,
  reason_code text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kyc_access_officer ON audit.kyc_access (officer_id, created_at DESC);
CREATE INDEX kyc_access_subject ON audit.kyc_access (subject_id, created_at DESC);

REVOKE ALL ON ALL TABLES IN SCHEMA kyc FROM PUBLIC, anon, authenticated;
REVOKE ALL ON audit.kyc_access FROM PUBLIC, anon, authenticated;
-- Looking at someone's identity document is itself an event worth keeping honestly: the access
-- log is append-only for every role, like `audit.log`.
CREATE TRIGGER kyc_access_no_update_delete
  BEFORE UPDATE OR DELETE ON audit.kyc_access
  FOR EACH ROW EXECUTE FUNCTION private.audit_forbid_mutation();

-- ---------------------------------------------------------------------------
-- What a person has to complete. The required set is configuration, not schema (ERD §4), so a
-- country that asks for more does not need a migration.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.required_kyc_steps(p_country char(2), p_mode public.user_mode)
RETURNS public.kyc_step_kind[]
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_config jsonb;
  v_key    text := CASE WHEN p_mode = 'provider' THEN 'kyc_steps_provider'
                        ELSE 'kyc_steps_customer' END;
  v_steps  public.kyc_step_kind[];
BEGIN
  v_config := private.remote_config_json(v_key, p_country);
  IF v_config IS NULL OR jsonb_typeof(v_config) <> 'array' THEN
    -- The spec's own minimum: a customer proves they are a real person, a provider proves that
    -- and that they may be trusted in someone's home.
    RETURN CASE WHEN p_mode = 'provider'
      THEN ARRAY['provider_facial', 'government_id', 'id_document_capture',
                 'police_clearance']::public.kyc_step_kind[]
      ELSE ARRAY['customer_facial']::public.kyc_step_kind[] END;
  END IF;

  SELECT array_agg(value::public.kyc_step_kind ORDER BY ord) INTO v_steps
  FROM jsonb_array_elements_text(v_config) WITH ORDINALITY AS t(value, ord);
  RETURN coalesce(v_steps, '{}'::public.kyc_step_kind[]);
END $$;

-- ---------------------------------------------------------------------------
-- start_verification_session — the handle the app gives the vendor SDK. Biometric kinds need
-- explicit consent first (SH-07), checked here rather than trusted from the client.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.start_verification_session(p_kind public.kyc_step_kind)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
  v_id  uuid;
BEGIN
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
             AND c.kind = CASE WHEN p_kind = 'police_clearance' THEN 'criminal_record_check'
                               ELSE 'biometric' END
           ORDER BY c.id DESC LIMIT 1))
  RETURNING id INTO v_id;

  PERFORM private.emit_event('kyc', v_id::text, 'kyc.session_started',
    jsonb_build_object('session_id', v_id, 'user_id', v_uid, 'kind', p_kind));
  RETURN v_id;
END $$;

-- The seam the vendor integration will write through: never a client, always the Edge Function
-- that holds the vendor's key and has verified its signature.
CREATE FUNCTION private.record_vendor_check(
  p_session_id uuid,
  p_vendor text,
  p_vendor_job_id text,
  p_outcome public.identity_check_outcome,
  p_reason_key text DEFAULT NULL
)
RETURNS public.kyc_step_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_session kyc.verification_sessions%ROWTYPE;
  v_status  public.kyc_step_status;
BEGIN
  SELECT * INTO v_session FROM kyc.verification_sessions s
  WHERE s.id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_KYC_STEP_INVALID' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE p_outcome
    WHEN 'success' THEN 'verified'::public.kyc_step_status
    WHEN 'retry'   THEN 'in_progress'::public.kyc_step_status
    ELSE 'rejected'::public.kyc_step_status END;

  UPDATE kyc.verification_sessions s
  SET vendor = p_vendor, vendor_job_id = p_vendor_job_id, outcome = p_outcome,
      reason_key = p_reason_key, status = v_status,
      completed_at = CASE WHEN p_outcome <> 'retry' THEN now() END
  WHERE s.id = p_session_id;

  -- A facial check is its own step: the vendor's answer is the decision, and no human reviews it.
  IF v_session.kind IN ('customer_facial', 'provider_facial') AND p_outcome <> 'retry' THEN
    INSERT INTO kyc.kyc_steps (user_id, kind, status, rejection_reason_key, attempt_count,
                               submitted_at, reviewed_at)
    VALUES (v_session.user_id, v_session.kind, v_status, p_reason_key, 1, now(), now())
    ON CONFLICT (user_id, kind) DO UPDATE
    SET status = excluded.status,
        rejection_reason_key = excluded.rejection_reason_key,
        attempt_count = kyc.kyc_steps.attempt_count + 1,
        reviewed_at = now();
    PERFORM private.refresh_verification(v_session.user_id);
  END IF;

  PERFORM private.emit_event('kyc', p_session_id::text, 'kyc.session_completed',
    jsonb_build_object('session_id', p_session_id, 'user_id', v_session.user_id,
                       'kind', v_session.kind, 'outcome', p_outcome, 'reason_key', p_reason_key));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- submit_kyc_step — what a person sends for a human to look at. The documents are already in
-- `kyc-docs`; this records that they are there and puts the step in the queue.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.submit_kyc_step(
  p_idempotency_key text,
  p_kind public.kyc_step_kind,
  p_upload_refs text[] DEFAULT NULL
)
RETURNS public.kyc_step_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_ref   text;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_kyc_step',
    jsonb_build_object('kind', p_kind, 'refs', p_upload_refs));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.kyc_step_status;
  END IF;

  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- Every upload must sit in the caller's own folder: `kyc-docs/<user_id>/<file>`.
  IF p_upload_refs IS NOT NULL THEN
    FOREACH v_ref IN ARRAY p_upload_refs LOOP
      IF (string_to_array(v_ref, '/'))[1] IS DISTINCT FROM v_uid::text THEN
        RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
      END IF;
    END LOOP;
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

CREATE FUNCTION public.submit_identity_document(
  p_idempotency_key text,
  p_id_type text,
  p_id_number_ciphertext bytea,
  p_id_number_blind_index bytea
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_country char(2);
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_identity_document',
    jsonb_build_object('id_type', p_id_type,
                       'blind_index', encode(p_id_number_blind_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'document_id')::uuid;
  END IF;

  IF p_id_type IS NULL OR p_id_number_ciphertext IS NULL OR p_id_number_blind_index IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- One identity, one account. The blind index tells us two submissions match without letting
  -- anything here read either number.
  IF EXISTS (SELECT 1 FROM kyc.identity_documents d
             WHERE d.issuing_country = v_country AND d.id_type = p_id_type
               AND d.id_number_blind_index = p_id_number_blind_index
               AND d.user_id <> v_uid) THEN
    RAISE EXCEPTION 'ERR_IDENTITY_ALREADY_REGISTERED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO kyc.identity_documents (user_id, id_type, id_number_ciphertext,
                                      id_number_blind_index, issuing_country)
  VALUES (v_uid, p_id_type, p_id_number_ciphertext, p_id_number_blind_index, v_country)
  ON CONFLICT (issuing_country, id_type, id_number_blind_index) DO UPDATE
  SET id_number_ciphertext = excluded.id_number_ciphertext
  RETURNING id INTO v_id;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('document_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.submit_police_clearance(
  p_idempotency_key text,
  p_certificate_ciphertext bytea,
  p_certificate_blind_index bytea,
  p_issued_on date,
  p_expires_on date,
  p_upload_ref text DEFAULT NULL,
  p_document_name text DEFAULT NULL
)
RETURNS public.kyc_step_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_country  char(2);
  v_max_age  integer := coalesce(private.remote_config_int('police_clearance_max_age_months'), 6);
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_police_clearance',
    jsonb_build_object('blind_index', encode(p_certificate_blind_index, 'hex'),
                       'issued_on', p_issued_on));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.kyc_step_status;
  END IF;

  IF p_certificate_ciphertext IS NULL OR p_certificate_blind_index IS NULL
     OR p_issued_on IS NULL OR p_expires_on IS NULL OR p_expires_on <= p_issued_on THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF NOT private.has_consent(v_uid, 'criminal_record_check') THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  -- OD-09's proposed default: a certificate older than six months is not evidence of anything
  -- current. The window is config so counsel can change it per country without a migration.
  IF p_issued_on < (now() - make_interval(months => v_max_age))::date THEN
    RAISE EXCEPTION 'ERR_KYC_STEP_INVALID' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;

  INSERT INTO kyc.police_clearances (user_id, country_code, document_name,
                                     certificate_number_ciphertext, certificate_blind_index,
                                     issued_on, expires_on, upload_ref)
  VALUES (v_uid, v_country, p_document_name, p_certificate_ciphertext, p_certificate_blind_index,
          p_issued_on, p_expires_on, p_upload_ref);

  INSERT INTO kyc.kyc_steps (user_id, kind, status, upload_refs, attempt_count, submitted_at,
                             expires_at)
  VALUES (v_uid, 'police_clearance', 'in_review',
          CASE WHEN p_upload_ref IS NULL THEN '{}'::text[] ELSE ARRAY[p_upload_ref] END,
          1, now(), p_expires_on::timestamptz)
  ON CONFLICT (user_id, kind) DO UPDATE
  SET status = 'in_review', attempt_count = kyc.kyc_steps.attempt_count + 1,
      upload_refs = excluded.upload_refs, expires_at = excluded.expires_at,
      rejection_reason_key = NULL, reviewer_id = NULL, reviewed_at = NULL, submitted_at = now();

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'in_review'));
  RETURN 'in_review'::public.kyc_step_status;
END $$;

-- ---------------------------------------------------------------------------
-- What the person sees: their own outcomes and reason keys, never a document and never a name.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_my_kyc_profile()
RETURNS TABLE (
  kind                 public.kyc_step_kind,
  status               public.kyc_step_status,
  rejection_reason_key text,
  attempt_count        smallint,
  expires_at           timestamptz,
  required             boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_country  char(2);
  v_mode     public.user_mode;
  v_required public.kyc_step_kind[];
BEGIN
  SELECT p.country_code, p.active_mode INTO v_country, v_mode
  FROM public.profiles p WHERE p.user_id = v_uid;
  v_required := private.required_kyc_steps(v_country, coalesce(v_mode, 'customer'));

  RETURN QUERY
  SELECT r.kind,
         coalesce(s.status, 'not_started'::public.kyc_step_status),
         s.rejection_reason_key,
         coalesce(s.attempt_count, 0::smallint),
         s.expires_at,
         true
  FROM unnest(v_required) AS r(kind)
  LEFT JOIN kyc.kyc_steps s ON s.user_id = v_uid AND s.kind = r.kind
  UNION ALL
  -- Steps they have done that their current mode does not require — a customer who has started
  -- provider onboarding should still see where it got to.
  SELECT s.kind, s.status, s.rejection_reason_key, s.attempt_count, s.expires_at, false
  FROM kyc.kyc_steps s
  WHERE s.user_id = v_uid AND NOT (s.kind = ANY (v_required));
END $$;

-- ---------------------------------------------------------------------------
-- The Verification Officer's three calls.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kyc_review_queue(p_limit integer DEFAULT 50)
RETURNS TABLE (
  step_id       uuid,
  user_id       uuid,
  kind          public.kyc_step_kind,
  attempt_count smallint,
  upload_refs   text[],
  submitted_at  timestamptz,
  country_code  char(2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT s.id, s.user_id, s.kind, s.attempt_count, s.upload_refs, s.submitted_at, p.country_code
  FROM kyc.kyc_steps s
  JOIN public.profiles p ON p.user_id = s.user_id
  WHERE s.status = 'in_review'
    -- An officer works their own countries only, where a scope is set (RLS matrix §4).
    AND (SELECT a.country_scope IS NULL OR p.country_code = ANY (a.country_scope)
         FROM public.admin_users a WHERE a.user_id = v_uid)
    -- Nobody reviews themselves.
    AND s.user_id <> v_uid
  ORDER BY s.submitted_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE FUNCTION public.decide_kyc_step(
  p_idempotency_key text,
  p_step_id uuid,
  p_decision public.kyc_decision,
  p_reason_key text DEFAULT NULL
)
RETURNS public.kyc_step_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_step   kyc.kyc_steps%ROWTYPE;
  v_status public.kyc_step_status;
BEGIN
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'decide_kyc_step',
    jsonb_build_object('step_id', p_step_id, 'decision', p_decision));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.kyc_step_status;
  END IF;

  SELECT * INTO v_step FROM kyc.kyc_steps s WHERE s.id = p_step_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_KYC_STEP_INVALID' USING ERRCODE = 'P0001';
  END IF;
  -- An officer cannot decide their own KYC. The matrix names this as a required deny test, and
  -- it is the one review that nobody else would notice.
  IF v_step.user_id = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF v_step.status <> 'in_review' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF p_decision = 'rejected' AND (p_reason_key IS NULL OR btrim(p_reason_key) = '') THEN
    -- A rejection the person cannot act on is a rejection that will come back tomorrow.
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_status := CASE WHEN p_decision = 'approved' THEN 'verified'::public.kyc_step_status
                   ELSE 'rejected'::public.kyc_step_status END;

  UPDATE kyc.kyc_steps s
  SET status = v_status, reviewer_id = v_uid, reviewed_at = now(),
      rejection_reason_key = CASE WHEN p_decision = 'rejected' THEN p_reason_key END
  WHERE s.id = p_step_id;

  IF v_step.kind = 'police_clearance' THEN
    UPDATE kyc.police_clearances c
    SET decision = p_decision, reviewer_id = v_uid, decided_at = now()
    WHERE c.user_id = v_step.user_id AND c.decision IS NULL;
  END IF;

  -- A decision on someone's identity is exactly the kind of act the hash-chained log is for.
  PERFORM private.audit_write('kyc.decide_step', 'kyc.kyc_steps', p_step_id::text,
    jsonb_build_object('status', v_step.status),
    jsonb_build_object('status', v_status, 'reviewer_id', v_uid),
    p_reason_key);
  PERFORM private.refresh_verification(v_step.user_id);
  PERFORM private.notify(v_step.user_id, 'system',
    CASE WHEN p_decision = 'approved' THEN 'notifKycApprovedTitle' ELSE 'notifKycRejectedTitle' END,
    CASE WHEN p_decision = 'approved' THEN 'notifKycApprovedBody' ELSE 'notifKycRejectedBody' END,
    jsonb_build_object('kind', v_step.kind, 'reason_key', p_reason_key), '/verify');
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- Asking to see a document is itself recorded, here, before any URL exists. The Edge Function
-- that mints the signed URL calls this first and refuses to sign if it raises.
CREATE FUNCTION public.request_document_access(p_upload_ref text, p_reason_code text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_subject uuid;
BEGIN
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_upload_ref IS NULL OR p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_subject := private.try_uuid((string_to_array(p_upload_ref, '/'))[1]);
  IF v_subject IS NULL OR v_subject = v_uid THEN
    -- The folder is the subject's user id, and an officer may not fetch their own documents
    -- through the review path.
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  INSERT INTO audit.kyc_access (officer_id, subject_id, upload_ref, reason_code)
  VALUES (v_uid, v_subject, p_upload_ref, p_reason_code);
  PERFORM private.audit_write('kyc.document_access', 'storage.objects', p_upload_ref,
    NULL, jsonb_build_object('subject_id', v_subject), p_reason_code);
  RETURN p_upload_ref;
END $$;

-- Status only, no documents: what support and ops are allowed to know (RLS matrix §4).
CREATE FUNCTION public.verification_summary(p_user_id uuid)
RETURNS TABLE (
  kind       public.kyc_step_kind,
  status     public.kyc_step_status,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['verification_officer', 'support_agent', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT s.kind, s.status, s.expires_at FROM kyc.kyc_steps s WHERE s.user_id = p_user_id;
END $$;

-- ---------------------------------------------------------------------------
-- The verification state the rest of the system reads. `profiles.customer_verification` and
-- `provider_verification` are derived from the steps, never set by hand, so "verified" always
-- means the same thing.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.refresh_verification(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
  v_mode    public.user_mode;
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = p_user;

  FOREACH v_mode IN ARRAY ARRAY['customer', 'provider']::public.user_mode[] LOOP
    UPDATE public.profiles p
    SET customer_verification = CASE WHEN v_mode = 'customer' THEN v_new.value
                                     ELSE p.customer_verification END,
        provider_verification = CASE WHEN v_mode = 'provider' THEN v_new.value
                                     ELSE p.provider_verification END
    FROM (
      SELECT CASE
        -- Any required step expired: the whole standing lapses, which is what stops new work.
        WHEN bool_or(coalesce(s.status, 'not_started') = 'expired') THEN 'expired'
        WHEN bool_and(coalesce(s.status, 'not_started') = 'verified') THEN 'verified'
        WHEN bool_or(coalesce(s.status, 'not_started') = 'rejected') THEN 'rejected'
        WHEN bool_or(coalesce(s.status, 'not_started') = 'in_review') THEN 'in_review'
        WHEN bool_or(coalesce(s.status, 'not_started') <> 'not_started') THEN 'pending'
        ELSE 'unverified' END::public.verification_status AS value
      FROM unnest(private.required_kyc_steps(v_country, v_mode)) AS r(kind)
      LEFT JOIN kyc.kyc_steps s ON s.user_id = p_user AND s.kind = r.kind
    ) AS v_new
    WHERE p.user_id = p_user;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- PR-14: reminders at 30, 14 and 3 days, and the standing that lapses on the day itself. An
-- in-progress job is untouched — the provider finishes what they started; what stops is taking
-- anything new, because `is_active_provider` reads the verification this writes.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.expire_kyc_documents()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_row   record;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT s.id, s.user_id, s.kind,
           (s.expires_at::date - current_date) AS days_left
    FROM kyc.kyc_steps s
    WHERE s.status = 'verified' AND s.expires_at IS NOT NULL
      AND s.expires_at::date - current_date IN (30, 14, 3)
  LOOP
    PERFORM private.notify(v_row.user_id, 'system', 'notifDocumentExpiringTitle',
      'notifDocumentExpiringBody',
      jsonb_build_object('kind', v_row.kind, 'days_left', v_row.days_left), '/provider/documents');
  END LOOP;

  FOR v_row IN
    SELECT s.id, s.user_id, s.kind FROM kyc.kyc_steps s
    WHERE s.status = 'verified' AND s.expires_at IS NOT NULL AND s.expires_at <= now()
  LOOP
    UPDATE kyc.kyc_steps s SET status = 'expired' WHERE s.id = v_row.id;
    PERFORM private.refresh_verification(v_row.user_id);
    PERFORM private.notify(v_row.user_id, 'system', 'notifDocumentExpiredTitle',
      'notifDocumentExpiredBody', jsonb_build_object('kind', v_row.kind), '/provider/documents');
    PERFORM private.emit_event('kyc', v_row.user_id::text, 'kyc.document_expired',
      jsonb_build_object('user_id', v_row.user_id, 'kind', v_row.kind));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.start_verification_session(public.kyc_step_kind),
  public.submit_kyc_step(text, public.kyc_step_kind, text[]),
  public.submit_identity_document(text, text, bytea, bytea),
  public.submit_police_clearance(text, bytea, bytea, date, date, text, text),
  public.get_my_kyc_profile(),
  public.kyc_review_queue(integer),
  public.decide_kyc_step(text, uuid, public.kyc_decision, text),
  public.request_document_access(text, text),
  public.verification_summary(uuid),
  private.required_kyc_steps(char, public.user_mode),
  private.record_vendor_check(uuid, text, text, public.identity_check_outcome, text),
  private.refresh_verification(uuid),
  private.expire_kyc_documents()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.start_verification_session(public.kyc_step_kind),
  public.submit_kyc_step(text, public.kyc_step_kind, text[]),
  public.submit_identity_document(text, text, bytea, bytea),
  public.submit_police_clearance(text, bytea, bytea, date, date, text, text),
  public.get_my_kyc_profile(),
  public.kyc_review_queue(integer),
  public.decide_kyc_step(text, uuid, public.kyc_decision, text),
  public.request_document_access(text, text),
  public.verification_summary(uuid)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('kyc-expiry', '41 2 * * *',
      $cron$SELECT private.expire_kyc_documents()$cron$);
  END IF;
END $$;
