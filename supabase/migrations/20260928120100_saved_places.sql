-- Saved places and the access note (RLS matrix §2, ERD, data-flow row 8; AUDIT-2026-09-22c).
--
-- A saved place is the customer's own address book: a label, a point and a landmark note, all
-- plain, all theirs. The access note is different in kind -- a gate code, a flat number behind
-- a door, "the key is under the mat" -- and the matrix time-boxes it: the assigned provider gets
-- it **during an active job only**, through a function, and never by select.
--
-- Three decisions worth knowing before reading the code.
--
-- The note is ciphertext produced outside the database (ADR-0007), exactly like trusted
-- contacts and payout accounts, and nothing in SQL decrypts it. `reveal_access_note` hands the
-- ciphertext to a caller who is allowed it at that moment; turning it into text is the job of
-- the Edge Function that holds the key, which needs the KMS key that needs GCP billing (client
-- action 1) -- the same seam as payout decryption. The gate is here, and the gate is the part
-- that has to be right.
--
-- A request's note does not live on `requests`. That table is SELECT-granted as a whole to the
-- customer and, since V.1, to the assigned provider, so a column there would be readable by the
-- provider at any time, not only during the job. It lives in `private.request_access_notes`,
-- which no client role can reach, and is deleted when the job stops being active (data-flow row
-- 8: "deleted at job close"). A saved place keeps its own copy, because it belongs to the
-- customer and outlives any one job.
--
-- The window is `en_route`, `arrived` and `in_progress`, and not `assigned`. A scheduled job can
-- sit assigned for days, and a gate code is needed at the gate. The provider is also re-checked
-- as the current assignee on every call, so a job handed back to `paid_held` and taken by
-- somebody else (transition 26) stops answering the first provider immediately.

-- ---------------------------------------------------------------------------
-- saved_places
-- ---------------------------------------------------------------------------
CREATE TABLE public.saved_places (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users (id) ON DELETE CASCADE,
  label                  text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 60),
  point                  extensions.geography(Point, 4326) NOT NULL,
  landmark_note          text CHECK (landmark_note IS NULL OR length(landmark_note) <= 300),
  -- ADR-0007: produced outside the database and never granted to a client.
  access_note_ciphertext bytea CHECK (access_note_ciphertext IS NULL
                                      OR length(access_note_ciphertext) BETWEEN 1 AND 4096),
  -- So a screen can say "access note saved" without being able to read it.
  has_access_note        boolean GENERATED ALWAYS AS (access_note_ciphertext IS NOT NULL) STORED,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX saved_places_user ON public.saved_places (user_id, created_at);

ALTER TABLE public.saved_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_places FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.saved_places FROM anon, authenticated;
GRANT SELECT (id, user_id, label, point, landmark_note, has_access_note, created_at, updated_at)
  ON public.saved_places TO authenticated;
GRANT INSERT (user_id, label, point, landmark_note) ON public.saved_places TO authenticated;
GRANT UPDATE (label, point, landmark_note) ON public.saved_places TO authenticated;
GRANT DELETE ON public.saved_places TO authenticated;
GRANT ALL ON public.saved_places TO service_role;

-- Own rows only, for every verb. The matrix gives no staff role a read, super admin included:
-- nobody operates on somebody's address book, so nobody sees it.
CREATE POLICY saved_places_read_own ON public.saved_places FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));
CREATE POLICY saved_places_insert_own ON public.saved_places FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY saved_places_update_own ON public.saved_places FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY saved_places_delete_own ON public.saved_places FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- SECURITY DEFINER because the client inserts directly (the matrix gives I:own) and the cap is
-- read from configuration the caller has no grant on.
CREATE FUNCTION private.saved_places_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_max integer := coalesce(private.remote_config_int('saved_places_max'), 20);
BEGIN
  IF (SELECT count(*) FROM public.saved_places s WHERE s.user_id = NEW.user_id) >= v_max THEN
    RAISE EXCEPTION 'ERR_SAVED_PLACE_LIMIT' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER saved_places_limit BEFORE INSERT ON public.saved_places
  FOR EACH ROW EXECUTE FUNCTION private.saved_places_limit();

CREATE FUNCTION private.saved_places_touch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER saved_places_touch BEFORE UPDATE ON public.saved_places
  FOR EACH ROW EXECUTE FUNCTION private.saved_places_touch();

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- The app shows the cap before the user hits it, so it is client-visible.
  ('saved_places_max', NULL, '20', true)
ON CONFLICT DO NOTHING;

-- Sets, replaces or (with NULL) clears the note on one of the caller's own places. A place that
-- is not theirs and a place that does not exist answer the same, so ids cannot be probed.
CREATE FUNCTION public.set_saved_place_access_note(p_saved_place_id uuid, p_ciphertext bytea)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_saved_place_id IS NULL
     OR (p_ciphertext IS NOT NULL AND length(p_ciphertext) NOT BETWEEN 1 AND 4096) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  UPDATE public.saved_places s SET access_note_ciphertext = p_ciphertext
  WHERE s.id = p_saved_place_id AND s.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_SAVED_PLACE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN p_ciphertext IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------
-- request_access_notes -- the note for one job, private, deleted when the job stops being active.
-- ---------------------------------------------------------------------------
CREATE TABLE private.request_access_notes (
  request_id            uuid PRIMARY KEY REFERENCES public.requests (id) ON DELETE CASCADE,
  ciphertext            bytea NOT NULL CHECK (length(ciphertext) BETWEEN 1 AND 4096),
  -- Provenance only: the copy is taken at the moment of choosing, so editing or deleting the
  -- place later does not change what this job's provider is told.
  source_saved_place_id uuid REFERENCES public.saved_places (id) ON DELETE SET NULL,
  updated_at            timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON private.request_access_notes FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.request_access_notes TO service_role;

-- The statuses in which a request may still carry a note. After these the job is over, one way
-- or another, and the note goes.
CREATE FUNCTION private.access_note_may_exist(p_status public.job_status)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_status IN ('draft', 'published', 'offers_received', 'negotiating', 'agreed',
                      'payment_pending', 'paid_held', 'assigned', 'en_route', 'arrived',
                      'in_progress');
$$;

-- The customer attaches a note to their own request: either fresh ciphertext, or a copy of the
-- one on a saved place of theirs. Both NULL clears it. Allowed until the job stops being active,
-- so "the gate code changed" can still reach a provider who is on the way.
CREATE FUNCTION public.set_request_access_note(
  p_request_id uuid, p_ciphertext bytea DEFAULT NULL, p_saved_place_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_status public.job_status;
  v_cipher bytea := p_ciphertext;
BEGIN
  IF p_request_id IS NULL OR (p_ciphertext IS NOT NULL AND p_saved_place_id IS NOT NULL)
     OR (p_ciphertext IS NOT NULL AND length(p_ciphertext) NOT BETWEEN 1 AND 4096) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.access_note_may_exist(v_status) THEN
    RAISE EXCEPTION 'ERR_ACCESS_NOTE_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  IF p_saved_place_id IS NOT NULL THEN
    SELECT s.access_note_ciphertext INTO v_cipher FROM public.saved_places s
    WHERE s.id = p_saved_place_id AND s.user_id = v_uid;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ERR_SAVED_PLACE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_cipher IS NULL THEN
    DELETE FROM private.request_access_notes n WHERE n.request_id = p_request_id;
    RETURN false;
  END IF;

  INSERT INTO private.request_access_notes (request_id, ciphertext, source_saved_place_id)
  VALUES (p_request_id, v_cipher, p_saved_place_id)
  ON CONFLICT (request_id) DO UPDATE
    SET ciphertext = EXCLUDED.ciphertext,
        source_saved_place_id = EXCLUDED.source_saved_place_id,
        updated_at = now();
  RETURN true;
END $$;

-- The customer's own view: whether their request carries a note. Never the note itself -- the
-- customer wrote it and has no need to have it handed back.
CREATE FUNCTION public.request_has_access_note(p_request_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = p_request_id AND r.customer_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  RETURN EXISTS (SELECT 1 FROM private.request_access_notes n WHERE n.request_id = p_request_id);
END $$;

-- The one way a provider learns the note. Every successful reveal is audited before it returns,
-- because "who read the gate code, and when" is the question a burglary complaint asks.
--
-- Returns NULL when the job is in its window and the customer left no note: an absent note is
-- an answer, not an error. Somebody who is not the current assignee gets ERR_JOB_NOT_FOUND, the
-- same code a job that does not exist gives, so a request id cannot be probed.
CREATE FUNCTION public.reveal_access_note(p_request_id uuid)
RETURNS bytea
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_status public.job_status;
  v_cipher bytea;
BEGIN
  SELECT r.status INTO v_status
  FROM public.requests r
  JOIN public.jobs j ON j.request_id = r.id
  WHERE r.id = p_request_id
    AND j.assigned_at IS NOT NULL
    AND (j.provider_id = v_uid OR j.worker_id = v_uid);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('en_route', 'arrived', 'in_progress') THEN
    RAISE EXCEPTION 'ERR_ACCESS_NOTE_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  SELECT n.ciphertext INTO v_cipher FROM private.request_access_notes n
  WHERE n.request_id = p_request_id;
  IF v_cipher IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM private.audit_write('access_note.revealed', 'public.requests', p_request_id::text,
    NULL, jsonb_build_object('status', v_status));
  RETURN v_cipher;
END $$;

-- Data-flow row 8: deleted at job close. A trigger, so every path that ends a job -- completion,
-- cancellation from either side, a dispute, expiry -- takes the note with it without any of
-- them having to remember.
CREATE FUNCTION private.drop_request_access_note()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.request_access_notes n WHERE n.request_id = NEW.id;
  RETURN NULL;
END $$;

CREATE TRIGGER requests_drop_access_note AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status
        AND NOT private.access_note_may_exist(NEW.status))
  EXECUTE FUNCTION private.drop_request_access_note();

-- ---------------------------------------------------------------------------
-- Account erasure: the address book goes with the account. `auth.users` is kept as a tombstone
-- rather than deleted, so ON DELETE CASCADE never fires and the erasure has to say so itself.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.erase_account(p_user uuid)
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
  DELETE FROM public.saved_places WHERE user_id = p_user;
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

  -- The user's folder in `avatars` (one folder per user, named by id).
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'avatars', 'prefix', p_user::text || '/'));

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;

REVOKE ALL ON FUNCTION
  private.saved_places_limit(),
  private.saved_places_touch(),
  private.access_note_may_exist(public.job_status),
  private.drop_request_access_note(),
  public.set_saved_place_access_note(uuid, bytea),
  public.set_request_access_note(uuid, bytea, uuid),
  public.request_has_access_note(uuid),
  public.reveal_access_note(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.set_saved_place_access_note(uuid, bytea),
  public.set_request_access_note(uuid, bytea, uuid),
  public.request_has_access_note(uuid),
  public.reveal_access_note(uuid)
  TO authenticated;
