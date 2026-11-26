-- Outbox hygiene (Meet v5 M0-PR3): the outbox stops growing for ever.
--
-- **Nothing ever deleted an outbox row.** Every phase emits into `private.outbox`, the workers
-- mark what they take as dispatched, and the row stays. On the Free plan that is database space
-- spent on events nobody will read again, and Meet adds aggregates of its own.
--
-- **Two aggregates have no reader at all.** The workers claim `user` (notifications-worker),
-- `payment` and `payout` (payments-worker) and `storage` (storage-worker). `ledger.posted` is
-- written once per ledger transaction and `call.*` once per call state change, and nothing claims
-- either, so they are never dispatched and the dispatched rule alone would never reach them. A
-- worker added for either must take it out of this list, or it loses events older than 30 days.
-- The other unclaimed aggregates are rare and are left alone.
--
-- **Dispatched means done.** A dispatched row of any aggregate is deleted 30 days after it was
-- dispatched, not after it was created, so a permanent failure (`fail_outbox` with no retry) stays
-- visible to an operator for a month from the day it failed. The one exception is
-- `dispute.sla_breached`, which `escalate_overdue_disputes` reads back as its record of having
-- escalated: nothing dispatches it today, and deleting it would escalate the same dispute again.

CREATE FUNCTION private.prune_outbox()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  DELETE FROM private.outbox o
  WHERE (o.aggregate IN ('ledger', 'call') AND o.created_at < now() - interval '30 days')
     OR (o.dispatched_at < now() - interval '30 days'
         AND NOT (o.aggregate = 'dispute' AND o.event_type = 'dispute.sla_breached'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION private.prune_outbox() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('outbox-prune', '47 3 * * *',
      $cron$SELECT private.prune_outbox()$cron$);
  END IF;
END $$;
