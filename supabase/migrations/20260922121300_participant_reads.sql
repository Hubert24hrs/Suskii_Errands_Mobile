-- The Participant column of the RLS matrix, which was never implemented on the marketplace
-- tables (`docs/audit/AUDIT-2026-09-22c.md`, finding V.1).
--
-- Section 5 of the matrix has seven columns, and one of them is **Participant**. `requests`
-- carries `R:part` in it and `request_media` carries `R:part` too. Neither policy has ever had
-- a participant clause: `requests` is customer-or-scoped-support, `request_media` is customer
-- alone. The Provider column says a provider meets the market via `provider_feed` and "via feed
-- card", and both of those are true -- but they describe the provider *before* they are
-- assigned. After assignment nothing widened.
--
-- So an assigned provider could read `jobs` (their money and their timestamps) and
-- `get_job_summary` (a status and a category key) and could not read the description, the
-- pickup or destination label, the landmark notes, the urgency, or the customer's photos.
-- A provider who accepted a delivery could not see the address.
--
-- This is the same class as U.1 and U.3 in the two 2026-09-22 passes: the matrix names an
-- access, one part of it was never built, and nothing noticed because no screen had asked yet.
-- Kimi's M8.6 is the screen that asks.
--
-- Three limbs, and a fourth found while fixing them:
--   a) an **assigned** provider reads the request. Gated on `jobs.assigned_at`, not on the
--      current status -- see the helper.
--   b) a **matched** provider reads the request's media, which is the feed card the matrix
--      already promises. `provider_feed` returns `media_paths` and no policy let a bidding
--      provider fetch a single one of them.
--   c) `request_media` gains the staff scope every other media surface got in S.1.
--   d) `job_events` was **already broken for providers** and would have stayed broken after
--      (a): its provider clause is nested inside a subquery on `public.requests`, and a
--      policy's subqueries are themselves RLS-filtered, so the clause could only ever be true
--      for somebody who could already read the request. Every other marketplace policy puts
--      the provider clause on the table's own columns, which is why this is the only one.

-- ---------------------------------------------------------------------------
-- Helpers. Both are SECURITY DEFINER so that the read inside them is not filtered by the
-- policy that calls them -- a policy's subquery runs with the caller's permissions, so a raw
-- EXISTS over `public.jobs` inside a policy on `public.requests` would be evaluated against
-- `jobs_read_participant`, which itself reads `public.requests`.
-- ---------------------------------------------------------------------------

-- The gate is `assigned_at`, not `requests.status`, for two reasons.
--
-- It only ever becomes non-NULL in the `paid_held` -> `assigned` transition, which refuses to
-- run from any other status, so it means "this job was funded" and not merely "somebody
-- accepted an offer". A provider cannot collect exact addresses by bidding, accepting and
-- walking away before the customer pays -- threat model R-05, off-platform deals, the highest
-- business risk on that table.
--
-- And it is monotonic. A status test would have to enumerate the states that count, and
-- `cancelled` is reachable from both sides of payment: a job cancelled before funding would
-- match a naive `status <> 'agreed'` test and hand over the address on the way out. Once set,
-- `assigned_at` stays set, so a provider keeps the record of a job they actually did -- which
-- they need for their own history, for a rating and for a dispute.
CREATE FUNCTION private.is_assigned_job_provider(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.jobs j
                 WHERE j.request_id = p_request_id
                   AND j.assigned_at IS NOT NULL
                   AND (j.provider_id = (SELECT auth.uid())
                        OR j.worker_id = (SELECT auth.uid())));
$$;

-- "Matched", in the sense the matrix's feed-card note means: this provider has opened a
-- negotiation on this request. It is the narrowest defensible reading -- a provider who has not
-- engaged learns nothing, and one who has is looking at a card they were already shown.
CREATE FUNCTION private.is_matched_provider(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.offer_threads t
                 WHERE t.request_id = p_request_id
                   AND t.provider_id = (SELECT auth.uid()));
$$;

REVOKE ALL ON FUNCTION
  private.is_assigned_job_provider(uuid),
  private.is_matched_provider(uuid)
  FROM PUBLIC, anon, authenticated;
-- The policies below call these as the invoking role.
GRANT EXECUTE ON FUNCTION
  private.is_assigned_job_provider(uuid),
  private.is_matched_provider(uuid)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- requests -- the Participant column, at last. The customer clause stays a direct column test:
-- it is the common case and it is an index lookup.
-- ---------------------------------------------------------------------------
DROP POLICY requests_read_own ON public.requests;
CREATE POLICY requests_read_own ON public.requests FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.is_assigned_job_provider(requests.id))
         OR (SELECT private.admin_may_read_country(requests.country_code,
               ARRAY['support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- request_media -- participants, the matched provider's feed card, and the staff scope the
-- storage objects got in S.1 while the rows describing them did not.
-- ---------------------------------------------------------------------------
DROP POLICY request_media_read_own ON public.request_media;
CREATE POLICY request_media_read_own ON public.request_media FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(request_media.request_id))
         OR (SELECT private.is_matched_provider(request_media.request_id))
         OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
         OR (SELECT private.support_ticket_scope(request_media.request_id))
         OR (SELECT private.dispute_scope(request_media.request_id)));

-- The object behind the row. A matched provider is handed `media_paths` by `provider_feed` and
-- until now could not fetch one of them, so the feed card has been rendering broken images for
-- as long as there has been a feed.
CREATE OR REPLACE FUNCTION private.may_read_request_media(p_name text)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.request_media rm
    WHERE rm.storage_path = p_name
      AND (EXISTS (SELECT 1 FROM public.jobs j
                   WHERE j.request_id = rm.request_id
                     AND (j.provider_id = (SELECT auth.uid())
                          OR j.worker_id = (SELECT auth.uid())))
           OR EXISTS (SELECT 1 FROM public.offer_threads t
                      WHERE t.request_id = rm.request_id
                        AND t.provider_id = (SELECT auth.uid()))));
$$;

-- ---------------------------------------------------------------------------
-- job_events -- the provider clause moves out of the `requests` subquery and into the helper
-- that every other participant surface already uses. No funding gate here: a transition
-- history carries statuses and reason codes, not an address, and a provider who is negotiating
-- should be able to see that the request was cancelled underneath them.
-- ---------------------------------------------------------------------------
DROP POLICY job_events_read_participant ON public.job_events;
CREATE POLICY job_events_read_participant ON public.job_events FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(job_events.request_id))
         OR (SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]))
         OR (SELECT private.support_ticket_scope(job_events.request_id))
         OR (SELECT private.dispute_scope(job_events.request_id)));
