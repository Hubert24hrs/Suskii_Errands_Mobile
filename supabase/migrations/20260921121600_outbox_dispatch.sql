-- Phase 5, part 8: claiming outbox events, so a worker can act on them exactly once.
--
-- `private.outbox` has been written to since Phase 2 and read by nobody: every phase emits into
-- it and `dispatched_at` has never been set, because there was no worker. The payment and payout
-- seams are the first things that actually need to *take* an event and call somebody, so this is
-- where claiming has to exist.
--
-- **`FOR UPDATE SKIP LOCKED`, not a flag.** Two workers polling the same table will otherwise
-- both read the same row, both call the gateway and both charge somebody. Skip-locked is the
-- standard queue pattern and it is the reason the claim marks the row inside the same statement
-- that selects it.
--
-- **A failed dispatch is retried, with a ceiling.** An event that has failed too many times stops
-- being retried and starts being a health check: a worker that retries a poisoned event for ever
-- looks exactly like a worker that is working.

ALTER TABLE private.outbox
  ADD COLUMN attempts   smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  ADD COLUMN claimed_at timestamptz,
  ADD COLUMN last_error text;

-- Undispatched, unclaimed, or claimed long enough ago that the worker holding it is gone.
DROP INDEX private.outbox_undispatched;
CREATE INDEX outbox_claimable ON private.outbox (aggregate, id)
  WHERE dispatched_at IS NULL;

CREATE FUNCTION private.claim_outbox(
  p_aggregates text[], p_limit integer DEFAULT 50, p_max_attempts smallint DEFAULT 8,
  p_stale_after interval DEFAULT interval '5 minutes')
RETURNS TABLE (id bigint, aggregate text, aggregate_id text, event_type text, payload jsonb,
               attempts smallint)
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  WITH claimed AS (
    SELECT o.id
    FROM private.outbox o
    WHERE o.dispatched_at IS NULL
      AND o.aggregate = ANY (p_aggregates)
      AND o.attempts < p_max_attempts
      -- Either never claimed, or claimed by a worker that has since died.
      AND (o.claimed_at IS NULL OR o.claimed_at < now() - p_stale_after)
    ORDER BY o.id
    LIMIT least(greatest(coalesce(p_limit, 50), 1), 500)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE private.outbox o
  SET claimed_at = now(), attempts = o.attempts + 1
  FROM claimed c
  WHERE o.id = c.id
  RETURNING o.id, o.aggregate, o.aggregate_id, o.event_type, o.payload, o.attempts;
END $$;

CREATE FUNCTION private.complete_outbox(p_id bigint)
RETURNS boolean
LANGUAGE sql
SET search_path = ''
AS $$
  UPDATE private.outbox o SET dispatched_at = now(), last_error = NULL
  WHERE o.id = p_id AND o.dispatched_at IS NULL
  RETURNING true;
$$;

-- Releasing is not failing: a worker that could not reach the gateway should hand the event back
-- without burning an attempt it never really made.
CREATE FUNCTION private.fail_outbox(p_id bigint, p_reason_key text, p_retry boolean DEFAULT true)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE private.outbox o
  SET claimed_at = NULL,
      last_error = left(coalesce(p_reason_key, 'ERR_INTERNAL'), 200),
      -- A permanent failure is marked dispatched so it stops being retried; it is still in the
      -- table with its error, which is what an operator needs to see.
      dispatched_at = CASE WHEN p_retry THEN NULL ELSE now() END
  WHERE o.id = p_id;
  RETURN FOUND;
END $$;

-- Events nobody could dispatch. Counted rather than raised: a queue that is quietly stuck is the
-- failure mode, and `health` already reports the backlog.
CREATE FUNCTION private.outbox_stuck_count(p_max_attempts smallint DEFAULT 8)
RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT count(*)::integer FROM private.outbox o
  WHERE o.dispatched_at IS NULL AND o.attempts >= p_max_attempts;
$$;

REVOKE ALL ON FUNCTION
  private.claim_outbox(text[], integer, smallint, interval),
  private.complete_outbox(bigint),
  private.fail_outbox(bigint, text, boolean),
  private.outbox_stuck_count(smallint)
  FROM PUBLIC, anon, authenticated;
-- The payments worker runs with the service role, which is the only thing that may take an event.
GRANT EXECUTE ON FUNCTION
  private.claim_outbox(text[], integer, smallint, interval),
  private.complete_outbox(bigint),
  private.fail_outbox(bigint, text, boolean),
  private.outbox_stuck_count(smallint)
  TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('outbox-stuck-check', '*/10 * * * *',
      $cron$SELECT private.record_health_check('outbox_stuck',
              CASE WHEN private.outbox_stuck_count() > 0 THEN 'fail' ELSE 'ok' END,
              jsonb_build_object('stuck', private.outbox_stuck_count()))$cron$);
  END IF;
END $$;
