-- Marketplace, part 5: proofs, and the buckets the marketplace actually writes to (ERD §5 and
-- §11; RLS matrix §5 and §11; job lifecycle transition 15).
--
-- Two things this closes. `request_media` has been storing paths into a `request-media` bucket
-- that did not exist since the requests migration — a gap of my own making. And "proof
-- completeness is configuration per category, not a hardcoded list" (state machine, guards worth
-- naming) had nothing behind it: a job could be completed with no photo at all.
--
-- **On metadata.** The server records what it wants from the device explicitly — capture time and
-- point are columns — and the server timestamp is the authoritative one. The images themselves
-- are stored as uploaded: the EXIF-stripping re-encode the ERD describes is a worker that does
-- not exist yet, so until it does, the app must strip metadata **before** upload rather than
-- assume we do it. `display_path` is the column that rendition will land in.

CREATE TYPE public.proof_kind AS ENUM ('photo', 'receipt', 'signature');

-- ---------------------------------------------------------------------------
-- Buckets. Both private: nothing is served by URL alone.
--   request-media/<user_id>/<file>      what the customer attaches when composing a request
--   job-proofs/<request_id>/<file>      what the provider submits while doing the job
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('request-media', 'request-media', false),
       ('job-proofs', 'job-proofs', false)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'file_size_limit') THEN
    UPDATE storage.buckets SET file_size_limit = 10 * 1024 * 1024
    WHERE id IN ('request-media', 'job-proofs');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'allowed_mime_types') THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
    WHERE id = 'request-media';
    -- A receipt is often a PDF; a signature is an image like any other.
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
    WHERE id = 'job-proofs';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- proofs
-- ---------------------------------------------------------------------------
CREATE TABLE public.proofs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id         uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  kind               public.proof_kind NOT NULL,
  storage_path       text NOT NULL CHECK (length(storage_path) BETWEEN 3 AND 512),
  -- The EXIF-stripped rendition, when the worker that makes one exists.
  display_path       text CHECK (display_path IS NULL OR length(display_path) <= 512),
  -- Device time and position are context for a dispute, not evidence on their own: a device
  -- clock and a device GPS are both things a determined provider can lie about.
  device_captured_at timestamptz,
  device_point       extensions.geography(Point, 4326),
  -- The server's own timestamp, which is the authoritative one.
  server_received_at timestamptz NOT NULL DEFAULT now(),
  uploaded_by        uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  UNIQUE (request_id, storage_path)
);
CREATE INDEX proofs_request ON public.proofs (request_id, server_received_at DESC);

ALTER TABLE public.proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.proofs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.proofs FROM anon, authenticated;
GRANT SELECT ON public.proofs TO authenticated;
GRANT ALL ON public.proofs TO service_role;
-- Participants: the customer of the request, and the provider or worker on the job. Proofs are
-- written through `submit_proof` only, so there is no insert grant.
CREATE POLICY proofs_read_participant ON public.proofs FOR SELECT TO authenticated
  USING (uploaded_by = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = proofs.request_id AND r.customer_id = (SELECT auth.uid()))
         OR EXISTS (SELECT 1 FROM public.jobs j
                    WHERE j.request_id = proofs.request_id
                      AND (j.provider_id = (SELECT auth.uid())
                           OR j.worker_id = (SELECT auth.uid())))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Who may read which object. These run as definer because a storage policy is evaluated as the
-- calling role, and the calling role cannot see the rows that decide the answer — a provider
-- has no read on `requests` at all, which is the whole point of the feed.
-- ---------------------------------------------------------------------------
-- Both answer only about **the caller**. Taking a user id would make them a probe: anyone could
-- ask whether a given person is on a given job, which is not a question a client may ask.
CREATE FUNCTION private.may_read_request_media(p_name text)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.request_media rm
    JOIN public.jobs j ON j.request_id = rm.request_id
    WHERE rm.storage_path = p_name
      AND (j.provider_id = (SELECT auth.uid()) OR j.worker_id = (SELECT auth.uid())));
$$;

CREATE FUNCTION private.is_job_participant(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = p_request_id AND r.customer_id = (SELECT auth.uid()))
      OR EXISTS (SELECT 1 FROM public.jobs j
                 WHERE j.request_id = p_request_id
                   AND (j.provider_id = (SELECT auth.uid())
                        OR j.worker_id = (SELECT auth.uid())));
$$;

-- The first path segment as a uuid, or NULL when it is not one. A cast would raise inside a
-- policy on any object whose name happens not to start with a uuid.
CREATE FUNCTION private.path_request_id(p_name text)
RETURNS uuid
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN (string_to_array(p_name, '/'))[1] ~
         '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    THEN ((string_to_array(p_name, '/'))[1])::uuid
  END;
$$;

-- request-media: the customer owns their folder, as with avatars. The provider who is actually
-- doing the job can read the photos attached to it, and nobody else can — a provider still
-- deciding whether to bid cannot.
CREATE POLICY request_media_own_folder_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'request-media'
         AND ((string_to_array(name, '/'))[1] = (SELECT auth.uid())::text
              OR (SELECT private.may_read_request_media(name))));

CREATE POLICY request_media_own_folder_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'request-media'
              AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

CREATE POLICY request_media_own_folder_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'request-media'
         AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

-- job-proofs: one folder per request, readable by that job's participants and writable by the
-- provider doing the work. There is no delete policy: a proof that could be removed is not one.
CREATE POLICY job_proofs_participant_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-proofs'
         AND (SELECT private.is_job_participant(private.path_request_id(name))));

CREATE POLICY job_proofs_provider_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-proofs'
              AND EXISTS (SELECT 1 FROM public.jobs j
                          WHERE j.request_id = private.path_request_id(name)
                            AND (j.provider_id = (SELECT auth.uid())
                                 OR j.worker_id = (SELECT auth.uid()))));

-- ---------------------------------------------------------------------------
-- submit_proof — the provider records what they did (transition 15's evidence).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.submit_proof(
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

-- ---------------------------------------------------------------------------
-- Proof completeness, from the category rather than from a list in a function. A category's
-- `proof_requirements` is a count per kind, `{"photo": 1, "receipt": 1}`; a kind that is absent
-- or zero is not required. The check is a trigger, so it holds on every path into
-- `completed_by_provider`, including ones written after this migration.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.requests_require_proofs()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_required jsonb;
  v_kind     text;
  v_needed   integer;
BEGIN
  SELECT sc.proof_requirements INTO v_required
  FROM public.service_categories sc WHERE sc.id = NEW.category_id;

  FOR v_kind, v_needed IN
    SELECT key, value::integer FROM jsonb_each_text(coalesce(v_required, '{}'::jsonb))
    WHERE value ~ '^[0-9]+$'
  LOOP
    IF v_needed > 0 AND (
         SELECT count(*) FROM public.proofs p
         WHERE p.request_id = NEW.id AND p.kind::text = v_kind) < v_needed THEN
      RAISE EXCEPTION 'ERR_PROOF_REQUIRED' USING ERRCODE = 'P0001',
        DETAIL = format('%s: %s required', v_kind, v_needed);
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

CREATE TRIGGER requests_require_proofs BEFORE UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status = 'completed_by_provider' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.requests_require_proofs();

REVOKE ALL ON FUNCTION
  public.submit_proof(text, uuid, public.proof_kind, text, timestamptz,
                      double precision, double precision),
  private.may_read_request_media(text),
  private.is_job_participant(uuid),
  private.path_request_id(text),
  private.requests_require_proofs()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.submit_proof(text, uuid, public.proof_kind, text, timestamptz,
                      double precision, double precision)
  TO authenticated;
-- The storage policies call these as the invoking role, so `authenticated` needs execute on the
-- two that answer "may this person see this object".
GRANT EXECUTE ON FUNCTION
  private.may_read_request_media(text),
  private.is_job_participant(uuid),
  private.path_request_id(text)
  TO authenticated;
