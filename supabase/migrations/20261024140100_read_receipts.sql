-- Read receipts work (audit 2026-10-24, AA.9). Both apps draw "Read" under a message once the
-- other side's marker passes it, and the RLS matrix gives `message_reads` `R:part`; the policy
-- gave own-only, recorded as the waiver `part:message_reads` ("decide whether read receipts
-- ship"). They ship, so participants may read each other's marker, as the matrix says. Writes
-- still go only through `mark_read()`, and staff scopes are not widened: a marker is a time,
-- not content, and nothing in support or disputes needs it.

DROP POLICY message_reads_read_own ON public.message_reads;
CREATE POLICY message_reads_read_participant ON public.message_reads FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR EXISTS (SELECT 1 FROM public.conversations c
             WHERE c.id = message_reads.conversation_id
               AND (SELECT private.is_job_participant(c.request_id)))
);
