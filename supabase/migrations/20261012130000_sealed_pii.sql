-- Sealed PII: the plaintext variants CR-20260923-06 and CR-20260923-08 asked for, and the two
-- registrations audit Y.19 was waiting on.
--
-- Five functions took `*_ciphertext` and `*_blind_index` arguments "produced outside the
-- database" (ADR-0007). No client can produce them: there is no key delivery and no algorithm a
-- phone could be trusted with. So the app refused to call them, and the screens behind them
-- (trusted contacts, the ID number and police clearance steps, the business console) stopped at
-- a feature-unavailable error on a real backend.
--
-- ADR-0018 put the keys in the database, so the plaintext now arrives over TLS and is sealed
-- here, the same way access notes are:
--
--   * `private.seal(class, plaintext, row)`, one data key per class, bound to the row it lives on.
--   * A keyed blind index, `private.blind_index(class, value)`, for the lookups that need one:
--     one identity per person, one plate per vehicle, one number per contact list. Its key is the
--     class's `bidx_` key at version 1 and never rotates, because a rotated index key would stop
--     every existing row from matching. Rotating the KEK re-wraps it and leaves it unchanged.
--   * A `*_masked` display column, so a list can say which contact or vehicle a row is without
--     anybody reading the number.
--
-- The ciphertext signatures are dropped, not kept beside the new ones: nobody can call them
-- correctly, and a function that accepts "ciphertext" invites somebody to pass plaintext.
-- `add_payout_account` keeps its signature: its ciphertext is opened by the payments worker under
-- a KMS key (ADR-0007), and the holder name it takes has to come from the gateway's name check,
-- so it waits for the gateway (CR-20260923-10 c).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.blind_index(p_class text, p_value text)
RETURNS bytea
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN p_value IS NULL THEN NULL ELSE
    extensions.hmac(convert_to(p_class || '|' || p_value, 'UTF8'),
                    private.field_data_key('bidx_' || p_class, 1), 'sha256') END;
$$;

-- What a person types for the same document differs in spaces, dashes and case; the index must
-- not.
CREATE FUNCTION private.normalise_identifier(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT nullif(upper(regexp_replace(coalesce(p_value, ''), '[[:space:]./-]', '', 'g')), '');
$$;

CREATE FUNCTION private.normalise_phone(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN n ~ '^\+[1-9][0-9]{6,14}$' THEN n END
  FROM (SELECT regexp_replace(coalesce(p_value, ''), '[[:space:]()-]', '', 'g') AS n) x;
$$;

CREATE FUNCTION private.mask_tail(p_value text, p_keep integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT repeat('•', greatest(length(p_value) - p_keep, 0)) || right(p_value, p_keep);
$$;

-- `+2348031234567` → `+234••••••4567`: the country and the last four, which is what somebody
-- needs to recognise their own contact.
CREATE FUNCTION private.mask_phone(p_e164 text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN length(p_e164) <= 8 THEN private.mask_tail(p_e164, 2)
              ELSE left(p_e164, 4) || repeat('•', length(p_e164) - 8) || right(p_e164, 4) END;
$$;

SELECT private.create_field_data_key(c)
FROM unnest(ARRAY['trusted_contact_phone', 'identity_number', 'police_certificate',
                  'organization_registration', 'vehicle_plate',
                  'bidx_trusted_contact_phone', 'bidx_identity_number', 'bidx_police_certificate',
                  'bidx_organization_registration', 'bidx_vehicle_plate']) AS c;

ALTER TABLE public.trusted_contacts ADD COLUMN phone_masked text;
ALTER TABLE public.organizations ADD COLUMN registration_masked text;
ALTER TABLE public.vehicles ADD COLUMN plate_masked text;

COMMENT ON COLUMN public.trusted_contacts.phone_ciphertext IS
  'Sealed with the trusted_contact_phone key, context trusted_contact:<id> (ADR-0018).';
COMMENT ON COLUMN public.organizations.registration_number_ciphertext IS
  'Sealed with the organization_registration key, context organization:<id> (ADR-0018).';
COMMENT ON COLUMN public.vehicles.plate_ciphertext IS
  'Sealed with the vehicle_plate key, context vehicle:<id> (ADR-0018).';

-- ---------------------------------------------------------------------------
-- add_trusted_contact (CR-20260923-06)
-- ---------------------------------------------------------------------------
DROP FUNCTION public.add_trusted_contact(text, text, bytea, bytea, text);
CREATE FUNCTION public.add_trusted_contact(
  p_idempotency_key text, p_name text, p_phone_e164 text, p_relationship_key text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_phone text := private.normalise_phone(p_phone_e164);
  v_index bytea;
  v_claim jsonb;
  v_id    uuid := gen_random_uuid();
BEGIN
  IF p_name IS NULL OR btrim(p_name) = '' OR v_phone IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_index := private.blind_index('trusted_contact_phone', v_phone);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'add_trusted_contact',
    jsonb_build_object('blind_index', encode(v_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'contact_id')::uuid;
  END IF;

  INSERT INTO public.trusted_contacts (id, user_id, name, phone_ciphertext, phone_blind_index,
                                       phone_masked, relationship_key)
  VALUES (v_id, v_uid, btrim(p_name),
          private.seal('trusted_contact_phone', v_phone, 'trusted_contact:' || v_id),
          v_index, private.mask_phone(v_phone), p_relationship_key);

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('contact_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- submit_identity_document and submit_police_clearance (CR-20260923-08)
-- ---------------------------------------------------------------------------
DROP FUNCTION public.submit_identity_document(text, text, bytea, bytea);
CREATE FUNCTION public.submit_identity_document(
  p_idempotency_key text, p_id_type text, p_id_number text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_number  text := private.normalise_identifier(p_id_number);
  v_index   bytea;
  v_claim   jsonb;
  v_country char(2);
  v_owner   uuid;
  v_id      uuid;
BEGIN
  IF p_id_type IS NULL OR length(p_id_type) NOT BETWEEN 2 AND 40
     OR v_number IS NULL OR length(v_number) NOT BETWEEN 4 AND 40 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_index := private.blind_index('identity_number', v_number);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_identity_document',
    jsonb_build_object('id_type', p_id_type, 'blind_index', encode(v_index, 'hex')));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'document_id')::uuid;
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- One identity, one account. The index tells us two submissions match without anything here
  -- reading either number.
  SELECT d.id, d.user_id INTO v_id, v_owner FROM kyc.identity_documents d
  WHERE d.issuing_country = v_country AND d.id_type = p_id_type
    AND d.id_number_blind_index = v_index;
  IF v_owner IS NOT NULL AND v_owner <> v_uid THEN
    RAISE EXCEPTION 'ERR_IDENTITY_ALREADY_REGISTERED' USING ERRCODE = 'P0001';
  END IF;

  IF v_id IS NULL THEN
    v_id := gen_random_uuid();
    INSERT INTO kyc.identity_documents (id, user_id, id_type, id_number_ciphertext,
                                        id_number_blind_index, issuing_country)
    VALUES (v_id, v_uid, p_id_type,
            private.seal('identity_number', v_number, 'identity_document:' || v_id),
            v_index, v_country);
  ELSE
    -- The same person sending the same number again re-seals it under the current key version.
    UPDATE kyc.identity_documents d
    SET id_number_ciphertext = private.seal('identity_number', v_number,
                                            'identity_document:' || v_id)
    WHERE d.id = v_id;
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('document_id', v_id));
  RETURN v_id;
END $$;

DROP FUNCTION public.submit_police_clearance(text, bytea, bytea, date, date, text, text);
CREATE FUNCTION public.submit_police_clearance(
  p_idempotency_key text,
  p_certificate_number text,
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
  v_uid     uuid := private.require_user();
  v_number  text := private.normalise_identifier(p_certificate_number);
  v_index   bytea;
  v_claim   jsonb;
  v_country char(2);
  v_max_age integer := coalesce(private.remote_config_int('police_clearance_max_age_months'), 6);
  v_id      uuid := gen_random_uuid();
BEGIN
  IF v_number IS NULL OR length(v_number) NOT BETWEEN 3 AND 60
     OR p_issued_on IS NULL OR p_expires_on IS NULL OR p_expires_on <= p_issued_on THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- The upload, when there is one, must sit in the caller's own kyc-docs folder.
  IF p_upload_ref IS NOT NULL
     AND (string_to_array(p_upload_ref, '/'))[1] IS DISTINCT FROM v_uid::text THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_index := private.blind_index('police_certificate', v_number);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_police_clearance',
    jsonb_build_object('blind_index', encode(v_index, 'hex'), 'issued_on', p_issued_on));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.kyc_step_status;
  END IF;

  IF NOT private.has_consent(v_uid, 'criminal_record_check') THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  -- OD-09's default: a certificate older than six months is not evidence of anything current.
  IF p_issued_on < (now() - make_interval(months => v_max_age))::date THEN
    RAISE EXCEPTION 'ERR_KYC_STEP_INVALID' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;

  INSERT INTO kyc.police_clearances (id, user_id, country_code, document_name,
                                     certificate_number_ciphertext, certificate_blind_index,
                                     issued_on, expires_on, upload_ref)
  VALUES (v_id, v_uid, v_country, p_document_name,
          private.seal('police_certificate', v_number, 'police_clearance:' || v_id), v_index,
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
-- register_organization and register_vehicle (audit Y.19)
-- ---------------------------------------------------------------------------
DROP FUNCTION public.register_organization(text, text, bytea, bytea);
CREATE FUNCTION public.register_organization(
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

DROP FUNCTION public.register_vehicle(text, public.vehicle_type, bytea, bytea, uuid, uuid, date);
CREATE FUNCTION public.register_vehicle(
  p_idempotency_key text,
  p_type public.vehicle_type,
  p_plate text,
  p_organization_id uuid DEFAULT NULL,
  p_assigned_worker_id uuid DEFAULT NULL,
  p_documents_expire_on date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_plate text := private.normalise_identifier(p_plate);
  v_index bytea;
  v_claim jsonb;
  v_id    uuid := gen_random_uuid();
BEGIN
  IF p_type IS NULL OR v_plate IS NULL OR length(v_plate) NOT BETWEEN 2 AND 15 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_index := private.blind_index('vehicle_plate', v_plate);

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'register_vehicle',
    jsonb_build_object('type', p_type, 'blind_index', encode(v_index, 'hex'),
                       'organization_id', p_organization_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'vehicle_id')::uuid;
  END IF;

  IF p_organization_id IS NOT NULL
     AND coalesce(private.org_role(p_organization_id, v_uid)::text, '')
         NOT IN ('owner', 'dispatcher') THEN
    RAISE EXCEPTION 'ERR_ORG_ROLE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.vehicles (id, organization_id, owner_user_id, type, plate_ciphertext,
                               plate_blind_index, plate_masked, assigned_worker_id,
                               documents_expire_on)
  VALUES (v_id, p_organization_id,
          CASE WHEN p_organization_id IS NULL THEN v_uid END,
          p_type, private.seal('vehicle_plate', v_plate, 'vehicle:' || v_id), v_index,
          private.mask_tail(v_plate, 3), p_assigned_worker_id, p_documents_expire_on);

  -- An individual provider's own vehicle is the one their profile advertises.
  IF p_organization_id IS NULL THEN
    PERFORM private.ensure_provider_profile(v_uid);
    UPDATE public.provider_profiles pp SET vehicle_type = p_type WHERE pp.user_id = v_uid;
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('vehicle_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- The export now carries trusted contacts, opened for their owner: a right-of-access answer that
-- leaves out the people someone named as their emergency contacts is not complete.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.collect_personal_data(p_user uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'generated_at', now(),
    'account', (SELECT jsonb_build_object('id', u.id, 'phone', u.phone, 'email', u.email,
                                          'created_at', u.created_at)
                FROM auth.users u WHERE u.id = p_user),
    'profile', (SELECT to_jsonb(p) - 'version' FROM public.profiles p WHERE p.user_id = p_user),
    'consents', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'granted', c.granted,
                                                              'recorded_at', c.recorded_at)
                                           ORDER BY c.id), '[]'::jsonb)
                 FROM public.consents c WHERE c.user_id = p_user),
    'devices', (SELECT coalesce(jsonb_agg(jsonb_build_object('platform', d.platform,
                                                             'app_version', d.app_version,
                                                             'created_at', d.created_at,
                                                             'last_seen_at', d.last_seen_at)
                                          ORDER BY d.created_at), '[]'::jsonb)
                FROM public.user_devices d WHERE d.user_id = p_user),
    'saved_places', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                       'label', sp.label,
                                       'lat', extensions.ST_Y(sp.point::extensions.geometry),
                                       'lng', extensions.ST_X(sp.point::extensions.geometry),
                                       'landmark_note', sp.landmark_note,
                                       'access_note', private.open('access_note',
                                          sp.access_note_ciphertext, 'saved_place:' || sp.id),
                                       'created_at', sp.created_at)
                                     ORDER BY sp.created_at), '[]'::jsonb)
                     FROM public.saved_places sp WHERE sp.user_id = p_user),
    'trusted_contacts', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                           'name', tc.name,
                                           -- Rows written before this migration carried bytes
                                           -- nothing can open; they export masked or empty.
                                           'phone', CASE WHEN tc.phone_masked IS NOT NULL THEN
                                             private.open('trusted_contact_phone',
                                               tc.phone_ciphertext, 'trusted_contact:' || tc.id)
                                           END,
                                           'relationship_key', tc.relationship_key,
                                           'created_at', tc.created_at)
                                         ORDER BY tc.created_at), '[]'::jsonb)
                         FROM public.trusted_contacts tc WHERE tc.user_id = p_user),
    'requests', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status,
                                                              'created_at', r.created_at)
                                           ORDER BY r.created_at), '[]'::jsonb)
                 FROM public.requests r WHERE r.customer_id = p_user),
    'jobs_as_provider', (SELECT coalesce(jsonb_agg(jsonb_build_object('request_id', j.request_id,
                                                                      'assigned_at', j.assigned_at)
                                                   ORDER BY j.assigned_at), '[]'::jsonb)
                         FROM public.jobs j WHERE j.provider_id = p_user OR j.worker_id = p_user),
    'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', pm.id, 'status', pm.status,
                                                              'amount_minor', pm.amount_minor,
                                                              'currency', pm.currency,
                                                              'created_at', pm.created_at)
                                           ORDER BY pm.created_at), '[]'::jsonb)
                 FROM public.payments pm WHERE pm.payer_id = p_user),
    'ratings_given', (SELECT coalesce(jsonb_agg(jsonb_build_object('request_id', rt.request_id,
                                                                   'stars', rt.stars,
                                                                   'comment', rt.comment)), '[]'::jsonb)
                      FROM public.ratings rt WHERE rt.rater_id = p_user),
    'support_tickets', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'category', t.category,
                                                                     'status', t.status,
                                                                     'created_at', t.created_at)
                                                  ORDER BY t.created_at), '[]'::jsonb)
                        FROM public.support_tickets t WHERE t.user_id = p_user)
  );
$$;

REVOKE ALL ON FUNCTION
  private.blind_index(text, text),
  private.normalise_identifier(text),
  private.normalise_phone(text),
  private.mask_tail(text, integer),
  private.mask_phone(text),
  public.add_trusted_contact(text, text, text, text),
  public.submit_identity_document(text, text, text),
  public.submit_police_clearance(text, text, date, date, text, text),
  public.register_organization(text, text, text),
  public.register_vehicle(text, public.vehicle_type, text, uuid, uuid, date)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.add_trusted_contact(text, text, text, text),
  public.submit_identity_document(text, text, text),
  public.submit_police_clearance(text, text, date, date, text, text),
  public.register_organization(text, text, text),
  public.register_vehicle(text, public.vehicle_type, text, uuid, uuid, date)
TO authenticated;
