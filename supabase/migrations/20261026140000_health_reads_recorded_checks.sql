-- Five scheduled checks have been recording into `private.health_checks` that nothing ever read.
--
-- Found rehearsing RB-03 on staging (2026-10-26): a one-unit drift planted in `ledger.balances`
-- was found by `ledger.reconcile()`, the nightly job recorded `fail` exactly as written, and
-- `get_health()` still said `ok`. The snapshot reads `audit_chain` and the backup keys by name and
-- nothing else, so `ledger_reconcile`, `partitions` (audit finding T.1's own fix), `notifications`,
-- `outbox_stuck` and `analytics_export` could fail for ever without `/health` returning 503 — which
-- is the only thing the uptime alert listens to. A check that cannot reach an alert is a log line.
--
-- Each is now read by its latest row. A row older than its job's window is stale and warns, because
-- a job that stopped running reports nothing at all; one never recorded warns for the same reason,
-- as `audit_chain` already does. A recorded `fail` stays `fail` however old it is: going quiet must
-- not turn an alarm into a warning.

CREATE FUNCTION private.recorded_check(p_key text, p_max_age interval)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_last private.health_checks%ROWTYPE;
BEGIN
  SELECT * INTO v_last FROM private.health_checks h WHERE h.check_key = p_key ORDER BY h.id DESC LIMIT 1;
  RETURN jsonb_build_object(p_key, jsonb_build_object(
    'status', CASE
      WHEN v_last.id IS NULL THEN 'warn'
      WHEN v_last.status = 'fail' THEN 'fail'
      WHEN v_last.checked_at < now() - p_max_age THEN 'warn'
      ELSE v_last.status END,
    'last_checked_at', v_last.checked_at,
    'stale', v_last.id IS NULL OR v_last.checked_at < now() - p_max_age,
    -- Counts only, by construction of every recorder: no check writes a person into its detail.
    'detail', coalesce(v_last.detail, '{}'::jsonb)));
END $$;

CREATE OR REPLACE FUNCTION private.health_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  checks        jsonb := '{}'::jsonb;
  v_outbox_max  integer := private.remote_config_int('ops.outbox_max_age_seconds');
  v_backup_max_h integer := private.remote_config_int('ops.backup_max_age_hours');
  v_oldest_s    integer;
  v_pending     bigint;
  v_ahead       integer;
  v_audit       private.health_checks%ROWTYPE;
  v_cron_failed bigint;
  v_status      text;
BEGIN
  -- Outbox backlog. Skipped until a dispatcher exists and ops sets the threshold, otherwise
  -- every environment would report failure for undelivered events nobody consumes yet.
  SELECT count(*), extract(epoch FROM now() - min(created_at))::integer
  INTO v_pending, v_oldest_s
  FROM private.outbox WHERE dispatched_at IS NULL;
  checks := checks || jsonb_build_object('outbox', jsonb_build_object(
    'status', CASE
      WHEN v_outbox_max IS NULL THEN 'skipped'
      WHEN coalesce(v_oldest_s, 0) > v_outbox_max * 3 THEN 'fail'
      WHEN coalesce(v_oldest_s, 0) > v_outbox_max THEN 'warn'
      ELSE 'ok' END,
    'pending', v_pending,
    'oldest_age_seconds', coalesce(v_oldest_s, 0)));

  -- Audit log partitions must exist ahead of time, or audit writes fail at month end.
  SELECT count(*)::integer INTO v_ahead
  FROM pg_catalog.pg_inherits i
  JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
  WHERE i.inhparent = 'audit.log'::regclass
    AND c.relname >= format('log_y%sm%s', to_char(now() + interval '1 month', 'YYYY'),
                                          to_char(now() + interval '1 month', 'MM'));
  checks := checks || jsonb_build_object('audit_partitions', jsonb_build_object(
    'status', CASE WHEN v_ahead = 0 THEN 'fail' WHEN v_ahead = 1 THEN 'warn' ELSE 'ok' END,
    'months_ahead', v_ahead));

  SELECT * INTO v_audit FROM private.health_checks
  WHERE check_key = 'audit_chain' ORDER BY id DESC LIMIT 1;
  checks := checks || jsonb_build_object('audit_chain', jsonb_build_object(
    'status', CASE
      WHEN v_audit.id IS NULL THEN 'warn'
      WHEN v_audit.status = 'fail' THEN 'fail'
      WHEN v_audit.checked_at < now() - interval '36 hours' THEN 'warn'
      ELSE 'ok' END,
    'last_checked_at', v_audit.checked_at));

  -- Backups (RB-09): the last successful dump and the last successful restore verification must
  -- be recent. Skipped until ops sets the threshold for an environment that runs the worker.
  checks := checks || private.backup_check('backup_dump', v_backup_max_h)
                   || private.backup_check('backup_verify', v_backup_max_h)
                   || private.backup_check('storage_sync', v_backup_max_h);

  -- What the scheduled jobs recorded. Windows are the job's cadence with room for one missed run:
  -- daily jobs at 36 hours, the ten-minute ones at 30 minutes.
  checks := checks || private.recorded_check('ledger_reconcile', interval '36 hours')
                   || private.recorded_check('partitions', interval '36 hours')
                   || private.recorded_check('analytics_export', interval '36 hours')
                   || private.recorded_check('notifications', interval '30 minutes')
                   || private.recorded_check('outbox_stuck', interval '30 minutes');

  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE $q$SELECT count(*) FROM cron.job_run_details
               WHERE status = 'failed' AND start_time > now() - interval '1 hour'$q$
    INTO v_cron_failed;
    checks := checks || jsonb_build_object('scheduled_jobs', jsonb_build_object(
      'status', CASE WHEN v_cron_failed > 0 THEN 'warn' ELSE 'ok' END,
      'failed_last_hour', v_cron_failed));
  END IF;

  SELECT CASE
    WHEN bool_or(value ->> 'status' = 'fail') THEN 'fail'
    WHEN bool_or(value ->> 'status' = 'warn') THEN 'warn'
    ELSE 'ok' END
  INTO v_status
  FROM jsonb_each(checks);

  RETURN jsonb_build_object('status', v_status, 'checked_at', now(), 'checks', checks);
END $$;

REVOKE ALL ON FUNCTION private.recorded_check(text, interval) FROM PUBLIC, anon, authenticated;
