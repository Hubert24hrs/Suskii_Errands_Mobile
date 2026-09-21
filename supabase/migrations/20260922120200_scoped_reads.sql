-- Audit finding **S.1, second half** (`docs/audit/AUDIT-2026-09-21.md`): `job_events` and the
-- storage read scopes still grant by role where the RLS matrix grants by case.
--
-- The first half closed in Phase 8's first slice and Phase 5 part 6: conversations, messages and
-- calls are scoped by `private.support_ticket_scope` and `private.dispute_scope`. What the
-- finding left open, in its own words: "`job_events` gives support `R:scope` in the matrix and is
-- not yet scoped the same way… Storage read scopes for `chat-media` and `request-media` name
-- 'support/dispute scope' and are unenforced for the same reason." Both mechanisms now exist, so
-- this is wiring.
--
-- **Super admin keeps the unscoped read**, because the matrix gives it one (§9, §Storage): the
-- role that can do anything is not made safer by pretending otherwise, and its every read is
-- already an `aal2` session against a named account in `audit.log`. Support and dispute officers
-- lose theirs, which is the control the DPIA relies on.
--
-- **The `receipts` bucket is created here**, because it was named in the matrix and never built.
-- `submit_float_receipt` has been validating a `<request_id>/…` path since Phase 5 part 5 and
-- storing it on the job with no bucket behind it and no policy over it — a receipt is a
-- purchase record with a shop, a time and an amount on it, and it should not have been the one
-- artefact in the system with nowhere to live.

-- ---------------------------------------------------------------------------
-- job_events: a transition history is the job's own record, and a support agent reads it when a
-- ticket names the job — not because they are a support agent.
-- ---------------------------------------------------------------------------
DROP POLICY job_events_read_participant ON public.job_events;
CREATE POLICY job_events_read_participant ON public.job_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = job_events.request_id
                   AND (r.customer_id = (SELECT auth.uid())
                        OR EXISTS (SELECT 1 FROM public.jobs j
                                   WHERE j.request_id = r.id
                                     AND (j.provider_id = (SELECT auth.uid())
                                          OR j.worker_id = (SELECT auth.uid())))))
         OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
         OR (SELECT private.support_ticket_scope(job_events.request_id))
         OR (SELECT private.dispute_scope(job_events.request_id)));

-- ---------------------------------------------------------------------------
-- Storage. Each of these replaces a policy that named participants only, so the staff clause is
-- additive: nobody who could read a file before loses access to it.
-- ---------------------------------------------------------------------------

-- chat-media — matrix: participants | support/dispute scope.
DROP POLICY chat_media_participant_read ON storage.objects;
CREATE POLICY chat_media_participant_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'chat-media'
         AND ((SELECT private.is_job_participant(private.path_request_id(name)))
              OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
              OR (SELECT private.support_ticket_scope(private.path_request_id(name)))
              OR (SELECT private.dispute_scope(private.path_request_id(name)))));

-- request-media — matrix: participants + matched providers | support/dispute scope. The folder
-- is the uploader's, not the job's, so the scope has to be reached through `request_media`.
CREATE FUNCTION private.staff_may_read_request_media(p_name text)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.request_media rm
    WHERE rm.storage_path = p_name
      AND (private.support_ticket_scope(rm.request_id)
           OR private.dispute_scope(rm.request_id)));
$$;

DROP POLICY request_media_own_folder_read ON storage.objects;
CREATE POLICY request_media_own_folder_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'request-media'
         AND ((string_to_array(name, '/'))[1] = (SELECT auth.uid())::text
              OR (SELECT private.may_read_request_media(name))
              OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
              OR (SELECT private.staff_may_read_request_media(name))));

-- job-proofs — matrix: participants (EXIF-stripped rendition) | **dispute scope only**. A proof
-- photo carries a location and a timestamp; it is evidence in an argument about money, not
-- context for a support conversation.
DROP POLICY job_proofs_participant_read ON storage.objects;
CREATE POLICY job_proofs_participant_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-proofs'
         AND ((SELECT private.is_job_participant(private.path_request_id(name)))
              OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
              OR (SELECT private.dispute_scope(private.path_request_id(name)))));

-- ---------------------------------------------------------------------------
-- receipts — matrix: assigned provider uploads on item-float jobs | participants read |
-- finance and dispute scope. One folder per request, as with proofs, and no delete policy: a
-- receipt that could be removed is not one.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public) VALUES ('receipts', 'receipts', false)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'file_size_limit') THEN
    UPDATE storage.buckets SET file_size_limit = 10 * 1024 * 1024 WHERE id = 'receipts';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'allowed_mime_types') THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
    WHERE id = 'receipts';
  END IF;
END $$;

CREATE POLICY receipts_participant_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'receipts'
         AND ((SELECT private.is_job_participant(private.path_request_id(name)))
              OR (SELECT private.has_admin_role(
                    ARRAY['super_admin', 'finance_officer']::public.admin_role[]))
              OR (SELECT private.dispute_scope(private.path_request_id(name)))));

-- Only the provider on the job, and only while there is a float to account for. A receipt on a
-- job that never had one is somebody uploading a document to a place it does not belong.
CREATE POLICY receipts_provider_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'receipts'
              AND EXISTS (SELECT 1 FROM public.jobs j
                          JOIN public.payments p ON p.request_id = j.request_id
                                                AND p.kind = 'job'
                          WHERE j.request_id = private.path_request_id(name)
                            AND p.float_minor > 0
                            AND (j.provider_id = (SELECT auth.uid())
                                 OR j.worker_id = (SELECT auth.uid()))));

REVOKE ALL ON FUNCTION private.staff_may_read_request_media(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.staff_may_read_request_media(text) TO authenticated;
