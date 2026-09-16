-- Operational health (infra-cicd.md §7; RB-01). The `health` Edge Function exposes
-- get_health() to uptime monitoring; scheduled checks record results in private.health_checks.
-- Thresholds live in remote_config (server-only keys) so ops can tune them without a migration.

CREATE TABLE private.health_checks (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  check_key  text        NOT NULL,
  status     text        NOT NULL CHECK (status IN ('ok', 'warn', 'fail')),
  detail     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  checked_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX health_checks_latest ON private.health_checks (check_key, id DESC);

CREATE FUNCTION private.remote_config_int(p_key text)
RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT (rc.value #>> '{}')::integer
  FROM public.remote_config rc
  WHERE rc.key = p_key AND rc.country_code IS NULL AND jsonb_typeof(rc.value) = 'number';
$$;

-- Written by scheduled jobs outside the database (the backup worker records `backup_dump` and
-- `backup_verify`). Service role and the database owner only.
CREATE FUNCTION private.record_health_check(p_key text, p_status text, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO private.health_checks (check_key, status, detail)
  VALUES (p_key, p_status, coalesce(p_detail, '{}'::jsonb))
  RETURNING id;
$$;

-- Daily: re-verify the audit hash chain and record the result. A break is also emitted as an
-- outbox event so the alerting path (RB-07) does not depend on someone reading this table.
CREATE FUNCTION private.run_audit_chain_check()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_broken bigint := private.audit_verify_chain();
  v_status text := CASE WHEN v_broken IS NULL THEN 'ok' ELSE 'fail' END;
BEGIN
  INSERT INTO private.health_checks (check_key, status, detail)
  VALUES ('audit_chain', v_status, jsonb_build_object('first_broken_id', v_broken));
  IF v_broken IS NOT NULL THEN
    PERFORM private.emit_event('ops', 'audit.log', 'ops.audit_chain_broken',
                               jsonb_build_object('first_broken_id', v_broken));
  END IF;
  RETURN v_status;
END $$;

CREATE FUNCTION private.backup_check(p_key text, p_max_age_hours integer)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_last_ok  timestamptz;
  v_last     private.health_checks%ROWTYPE;
BEGIN
  SELECT max(h.checked_at) INTO v_last_ok FROM private.health_checks h
  WHERE h.check_key = p_key AND h.status = 'ok';
  SELECT * INTO v_last FROM private.health_checks h WHERE h.check_key = p_key ORDER BY h.id DESC LIMIT 1;

  RETURN jsonb_build_object(p_key, jsonb_build_object(
    'status', CASE
      WHEN p_max_age_hours IS NULL THEN 'skipped'
      WHEN v_last_ok IS NULL OR v_last_ok < now() - make_interval(hours => p_max_age_hours) THEN 'fail'
      WHEN v_last.status <> 'ok' THEN 'warn'
      ELSE 'ok' END,
    'last_ok_at', v_last_ok,
    'last_status', v_last.status));
END $$;

CREATE FUNCTION private.health_snapshot()
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

-- Service role only: the health Edge Function calls this through PostgREST.
CREATE FUNCTION public.get_health()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.health_snapshot(); $$;

REVOKE ALL ON private.health_checks FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  private.record_health_check(text, text, jsonb),
  private.backup_check(text, integer),
  private.remote_config_int(text),
  private.run_audit_chain_check(),
  private.health_snapshot(),
  public.get_health()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_health(), private.run_audit_chain_check(),
  private.record_health_check(text, text, jsonb) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('audit-chain-check', '30 2 * * *', $cron$SELECT private.run_audit_chain_check()$cron$);
  END IF;
END $$;
