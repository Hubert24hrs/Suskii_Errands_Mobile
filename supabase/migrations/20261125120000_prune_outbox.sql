-- Outbox hygiene (Meet v5 M0-PR3): the outbox stops growing for ever.
--
-- **Nothing ever deleted an outbox row.** Every phase emits into `private.outbox`, the workers
-- mark what they take as dispatched, and the row stays. On the Free plan that is database space
-- spent on events nobody will read again, and Meet adds aggregates of its own.
--
-- **Five aggregates are written often and read by nothing.** The workers claim `user`
-- (notifications-worker), `payment` and `payout` (payments-worker) and `storage` (storage-worker).
-- Nothing claims these five, so they are never dispatched and the dispatched rule alone would
-- never reach them:
--   `request`   one row per chat message, per job transition and per offer event;
--   `ledger`    one `ledger.posted` per ledger transaction;
--   `call`      one per call state change;
--   `provider`  one per online or offline toggle, written whether or not the state changed;
--   `profile`   one per mode switch or role selection.
-- None is read back. What each announces is already in its own table (`job_events`, `messages`,
-- `offers`, `ledger.transactions`, `calls`, `provider_profiles`, `profiles`), so the outbox row
-- was only ever a notice. A worker added for any of them must take it out of this list, or it
-- loses events older than 30 days. The other unclaimed aggregates are written once per discrete
-- act (a staff decision, a verification step, a case, a registration, a consent, a meetup), not
-- per message or per toggle, and several still want a worker of their own (RB-06 found
-- `sos.escalated` alerting nobody), so they are left alone.
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
  WHERE (o.aggregate IN ('request', 'ledger', 'call', 'provider', 'profile')
         AND o.created_at < now() - interval '30 days')
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
