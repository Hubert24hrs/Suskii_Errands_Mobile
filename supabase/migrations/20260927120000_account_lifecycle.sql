-- Account lifecycle: self-serve deletion with a grace period, and data export requests.
-- CR-20260923-07; audit 2026-09-27 Y.9 (App Store 5.1.1(v), Google Play's account-deletion
-- policy); spec master_spec.security.privacy ("access, correction, deletion, and export").
--
-- Deletion is erasure, not a DELETE. Jobs, payments, the ledger, disputes and KYC records all
-- reference auth.users ON DELETE RESTRICT, because the law requires them to outlive the account
-- (tax and AML retention; the KYC rows keep their own retention clock). What the account owner is
-- owed is that nothing identifies them any more and nobody can sign in as them: the sweep clears
-- the name, contact details, devices, contacts and sign-in methods, and bans the login for ever.
--
-- Also here: submit_proof refuses a path with no uploaded object behind it (audit Y.5).

CREATE TYPE public.account_deletion_status AS ENUM ('scheduled', 'cancelled', 'completed');
CREATE TYPE public.data_export_status AS ENUM ('requested', 'processing', 'ready', 'failed', 'expired');

-- ---------------------------------------------------------------------------
-- account_deletion_requests
-- ---------------------------------------------------------------------------
CREATE TABLE public.account_deletion_requests (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  status         public.account_deletion_status NOT NULL DEFAULT 'scheduled',
  requested_at   timestamptz NOT NULL DEFAULT now(),
  scheduled_for  timestamptz NOT NULL,
  cancelled_at   timestamptz,
  completed_at   timestamptz,
  -- Why the sweep has not erased the account yet: an obligation still open. Cleared when it runs.
  blocked_reason text CHECK (blocked_reason IS NULL OR blocked_reason IN
                              ('active_job', 'open_dispute', 'balance_outstanding')),
  CONSTRAINT account_deletion_after_request CHECK (scheduled_for >= requested_at)
);
CREATE UNIQUE INDEX account_deletion_one_scheduled ON public.account_deletion_requests (user_id)
  WHERE status = 'scheduled';
CREATE INDEX account_deletion_due ON public.account_deletion_requests (scheduled_for)
  WHERE status = 'scheduled';

ALTER TABLE public.account_deletion_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_deletion_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_deletion_requests FROM anon, authenticated;
GRANT SELECT ON public.account_deletion_requests TO authenticated;
GRANT ALL ON public.account_deletion_requests TO service_role;
CREATE POLICY account_deletion_requests_read ON public.account_deletion_requests
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(user_id, ARRAY['support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- data_export_requests
-- ---------------------------------------------------------------------------
CREATE TABLE public.data_export_requests (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- Quoted to support and shown to the user; not a secret and not guessable into anything.
  reference      text NOT NULL UNIQUE CHECK (reference ~ '^EXP-[0-9A-F]{10}$'),
  status         public.data_export_status NOT NULL DEFAULT 'requested',
  requested_at   timestamptz NOT NULL DEFAULT now(),
  ready_at       timestamptz,
  expires_at     timestamptz,
  failure_reason text
);
CREATE UNIQUE INDEX data_export_one_open ON public.data_export_requests (user_id)
  WHERE status IN ('requested', 'processing');

ALTER TABLE public.data_export_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_export_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.data_export_requests FROM anon, authenticated;
GRANT SELECT ON public.data_export_requests TO authenticated;
GRANT ALL ON public.data_export_requests TO service_role;
CREATE POLICY data_export_requests_read ON public.data_export_requests
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(user_id, ARRAY['support_agent']::public.admin_role[])));

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- Long enough to change one's mind and for an in-flight job to settle; the stores set no
  -- minimum. Shown to the user before they confirm, so it is client-visible.
  ('account_deletion_grace_days', NULL, '30', true)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- request_account_deletion — schedules erasure and signs the account out everywhere. Signing
-- back in before the date and calling cancel_account_deletion keeps the account.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.request_account_deletion(p_idempotency_key text)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_when  timestamptz;
  v_id    uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'request_account_deletion', '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'scheduled_for')::timestamptz;
  END IF;

  -- Asking twice is not two deletions: the second answer is the first date.
  SELECT d.scheduled_for INTO v_when FROM public.account_deletion_requests d
  WHERE d.user_id = v_uid AND d.status = 'scheduled';

  IF v_when IS NULL THEN
    v_when := now() + make_interval(days =>
      greatest(1, coalesce(private.remote_config_int('account_deletion_grace_days'), 30)));
    INSERT INTO public.account_deletion_requests (user_id, scheduled_for)
    VALUES (v_uid, v_when)
    RETURNING id INTO v_id;

    PERFORM private.audit_write('account.deletion_requested', 'public.account_deletion_requests',
      v_id::text, NULL, jsonb_build_object('scheduled_for', v_when), 'user_requested');
    PERFORM private.emit_event('user', v_uid::text, 'account.deletion_requested',
      jsonb_build_object('scheduled_for', v_when));
    -- Every device, this one included: the app signs out locally on success.
    DELETE FROM auth.sessions s WHERE s.user_id = v_uid;
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('scheduled_for', v_when));
  RETURN v_when;
END $$;

CREATE FUNCTION public.cancel_account_deletion(p_idempotency_key text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_id    uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'cancel_account_deletion', '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'cancelled')::boolean;
  END IF;

  UPDATE public.account_deletion_requests d
  SET status = 'cancelled', cancelled_at = now()
  WHERE d.user_id = v_uid AND d.status = 'scheduled'
  RETURNING d.id INTO v_id;

  IF v_id IS NOT NULL THEN
    PERFORM private.audit_write('account.deletion_cancelled', 'public.account_deletion_requests',
      v_id::text, NULL, NULL, 'user_requested');
    PERFORM private.emit_event('user', v_uid::text, 'account.deletion_cancelled', '{}'::jsonb);
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('cancelled', v_id IS NOT NULL));
  RETURN v_id IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------
-- request_data_export — records the request and hands it to the fulfilment path. While one is
-- open, asking again returns the same reference rather than queueing a second.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.request_data_export(p_idempotency_key text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_ref   text;
  v_id    uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'request_data_export', '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN v_claim ->> 'reference';
  END IF;

  SELECT e.reference INTO v_ref FROM public.data_export_requests e
  WHERE e.user_id = v_uid AND e.status IN ('requested', 'processing');

  IF v_ref IS NULL THEN
    v_ref := 'EXP-' || upper(substr(encode(extensions.gen_random_bytes(5), 'hex'), 1, 10));
    INSERT INTO public.data_export_requests (user_id, reference)
    VALUES (v_uid, v_ref)
    RETURNING id INTO v_id;
    PERFORM private.audit_write('account.export_requested', 'public.data_export_requests',
      v_id::text, NULL, jsonb_build_object('reference', v_ref), 'user_requested');
    PERFORM private.emit_event('user', v_uid::text, 'account.export_requested',
      jsonb_build_object('export_id', v_id, 'reference', v_ref));
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('reference', v_ref));
  RETURN v_ref;
END $$;

-- The personal data an export contains, in one document. The fulfilment worker (or a support
-- agent within the statutory window, RB-07) uploads it for the user; it is never returned to a
-- client directly, because a function that answers "everything about user X" is only safe behind
-- service_role. Ciphertext columns are left out: the export is what we know, not what we store.
CREATE FUNCTION private.collect_personal_data(p_user uuid)
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

-- ---------------------------------------------------------------------------
-- The erasure sweep. Hourly; a request becomes due at `scheduled_for` and waits while the
-- account still has an obligation, because erasing a provider mid-job or a user who is owed
-- money would strand someone. Support sees `blocked_reason` and resolves it with the user.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.account_deletion_blocker(p_user uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.status = 'disputed'
                   AND (r.customer_id = p_user
                        OR EXISTS (SELECT 1 FROM public.jobs j WHERE j.request_id = r.id
                                   AND (j.provider_id = p_user OR j.worker_id = p_user))))
      THEN 'open_dispute'
    WHEN EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.status NOT IN ('draft', 'settled', 'closed', 'cancelled', 'expired',
                                        'refunded', 'disputed')
                   AND (r.customer_id = p_user
                        OR EXISTS (SELECT 1 FROM public.jobs j WHERE j.request_id = r.id
                                   AND (j.provider_id = p_user OR j.worker_id = p_user))))
      THEN 'active_job'
    WHEN EXISTS (SELECT 1 FROM ledger.accounts a JOIN ledger.balances b ON b.account_id = a.id
                 WHERE a.owner_kind = 'user' AND a.owner_id = p_user
                   AND a.account_type IN ('customer_wallet', 'provider_earnings', 'referral_earnings')
                   AND b.balance_minor <> 0)
      THEN 'balance_outstanding'
  END;
$$;

CREATE FUNCTION private.erase_account(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = '', avatar_path = NULL, timezone = NULL
  WHERE user_id = p_user;

  DELETE FROM public.trusted_contacts WHERE user_id = p_user;
  DELETE FROM public.favorites WHERE customer_id = p_user OR provider_id = p_user;
  -- Device rows are referenced by consents, which are the record of what was agreed; the
  -- addresses a push could still reach are what identify the handset, so those go.
  UPDATE public.user_devices SET push_token = NULL, voip_token = NULL WHERE user_id = p_user;
  UPDATE public.provider_profiles SET online = false WHERE user_id = p_user;

  DELETE FROM auth.sessions WHERE user_id = p_user;
  DELETE FROM auth.identities WHERE user_id = p_user;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user;
  UPDATE auth.users
  SET phone = NULL, email = NULL, encrypted_password = NULL,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = 'infinity', deleted_at = now()
  WHERE id = p_user;

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;

CREATE FUNCTION private.process_account_deletions(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req     record;
  v_blocker text;
  v_done    integer := 0;
BEGIN
  FOR v_req IN
    SELECT d.id, d.user_id, d.blocked_reason
    FROM public.account_deletion_requests d
    WHERE d.status = 'scheduled' AND d.scheduled_for <= now()
    ORDER BY d.scheduled_for
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_blocker := private.account_deletion_blocker(v_req.user_id);
    IF v_blocker IS NOT NULL THEN
      IF v_req.blocked_reason IS DISTINCT FROM v_blocker THEN
        UPDATE public.account_deletion_requests SET blocked_reason = v_blocker WHERE id = v_req.id;
        PERFORM private.emit_event('user', v_req.user_id::text, 'account.deletion_blocked',
          jsonb_build_object('reason', v_blocker));
      END IF;
      CONTINUE;
    END IF;

    PERFORM private.erase_account(v_req.user_id);
    UPDATE public.account_deletion_requests
    SET status = 'completed', completed_at = now(), blocked_reason = NULL
    WHERE id = v_req.id;
    v_done := v_done + 1;
  END LOOP;
  RETURN v_done;
END $$;

-- ---------------------------------------------------------------------------
-- get_bootstrap learns the pending deletion, so the app can offer to keep the account on the
-- first screen after signing back in. Same signature; one key added under `user`.
-- ---------------------------------------------------------------------------
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
                                 WHERE d.user_id = v_uid AND d.status = 'scheduled')
    ) END
  );
END $$;

-- ---------------------------------------------------------------------------
-- submit_proof: a path is evidence only if something was uploaded to it (audit Y.5). The app
-- uploads first and files the proof second; a path with no object is refused, so the category's
-- proof requirement can no longer be met by a string.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_proof(
  p_idempotency_key text,
  p_request_id uuid,
  p_kind public.proof_kind,
  p_storage_path text,
  p_device_captured_at timestamptz DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_status public.job_status;
  v_job    public.jobs%ROWTYPE;
  v_id     uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_proof',
    jsonb_build_object('request_id', p_request_id, 'kind', p_kind, 'path', p_storage_path));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'proof_id')::uuid;
  END IF;

  IF p_storage_path IS NULL OR private.path_request_id(p_storage_path) IS DISTINCT FROM p_request_id THEN
    -- The folder is the request id, so a proof cannot be filed against someone else's job.
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_uid <> v_job.provider_id AND v_uid <> coalesce(v_job.worker_id, v_job.provider_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id;
  IF v_status NOT IN ('in_progress', 'completed_by_provider') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM storage.objects o
                 WHERE o.bucket_id = 'job-proofs' AND o.name = p_storage_path) THEN
    RAISE EXCEPTION 'ERR_UPLOAD_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.proofs (request_id, kind, storage_path, device_captured_at, device_point,
                             uploaded_by)
  VALUES (p_request_id, p_kind, p_storage_path, p_device_captured_at,
          CASE WHEN p_lat IS NULL OR p_lng IS NULL THEN NULL
               ELSE extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography END,
          v_uid)
  RETURNING id INTO v_id;

  INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                 reason_code, idempotency_key, payload)
  VALUES (p_request_id, v_status, v_status, v_uid, 'provider', 'proof_submitted',
          p_idempotency_key, jsonb_build_object('proof_id', v_id, 'kind', p_kind));
  PERFORM private.emit_event('request', p_request_id::text, 'job.proof_submitted',
    jsonb_build_object('proof_id', v_id, 'kind', p_kind, 'provider_id', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('proof_id', v_id));
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION
  public.request_account_deletion(text),
  public.cancel_account_deletion(text),
  public.request_data_export(text),
  private.collect_personal_data(uuid),
  private.account_deletion_blocker(uuid),
  private.erase_account(uuid),
  private.process_account_deletions(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.request_account_deletion(text),
  public.cancel_account_deletion(text),
  public.request_data_export(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION
  private.collect_personal_data(uuid),
  private.process_account_deletions(integer)
  TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('account-deletions', '41 * * * *',
      $cron$SELECT private.process_account_deletions()$cron$);
  END IF;
END $$;
