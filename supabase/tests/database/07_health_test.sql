-- Operational health snapshot and the scheduled audit chain check.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(15);

DELETE FROM private.health_checks;
DELETE FROM public.remote_config WHERE key = 'ops.outbox_max_age_seconds';

SELECT is(public.get_health() #>> '{checks,outbox,status}', 'skipped',
  'the outbox check is skipped until ops sets a threshold');
SELECT is(public.get_health() #>> '{checks,audit_chain,status}', 'warn',
  'a chain that was never verified is a warning');
SELECT is(public.get_health() #>> '{checks,audit_partitions,status}', 'ok',
  'audit partitions exist months ahead');

SELECT is(private.run_audit_chain_check(), 'ok', 'the scheduled chain check passes on an intact chain');
SELECT is(public.get_health() ->> 'status', 'ok', 'overall status is ok when every check passes');

INSERT INTO public.remote_config (key, value, client_visible) VALUES ('ops.outbox_max_age_seconds', '60', false);
INSERT INTO private.outbox (aggregate, aggregate_id, event_type, created_at)
VALUES ('test', 'x', 'test.stuck', now() - interval '10 minutes');
SELECT is(public.get_health() #>> '{checks,outbox,status}', 'fail',
  'an undispatched event older than three times the threshold fails the outbox check');

CREATE TEMP TABLE tamper_target AS SELECT private.audit_write('test.before_tamper') AS id;
ALTER TABLE audit.log DISABLE TRIGGER audit_log_no_update_delete;
UPDATE audit.log SET action = 'tampered' WHERE id = (SELECT max(id) FROM audit.log);
ALTER TABLE audit.log ENABLE TRIGGER audit_log_no_update_delete;
SELECT is(private.run_audit_chain_check(), 'fail', 'a broken chain fails the scheduled check');
SELECT ok(EXISTS (SELECT 1 FROM private.outbox WHERE event_type = 'ops.audit_chain_broken'),
  'a broken chain emits an ops event for alerting');

DELETE FROM public.remote_config WHERE key = 'ops.backup_max_age_hours';
SELECT is(public.get_health() #>> '{checks,backup_dump,status}', 'skipped',
  'backup checks are skipped until ops sets a threshold');
INSERT INTO public.remote_config (key, value, client_visible) VALUES ('ops.backup_max_age_hours', '36', false);
SELECT is(public.get_health() #>> '{checks,backup_verify,status}', 'fail',
  'with a threshold set, a backup that never verified fails');
SELECT ok(private.record_health_check('backup_dump', 'ok', '{"dump_key": "db/prod/x.dump"}') > 0,
  'the backup worker can record a result');
INSERT INTO private.health_checks (check_key, status) VALUES ('backup_verify', 'ok');
INSERT INTO private.health_checks (check_key, status) VALUES ('backup_verify', 'fail');
SELECT is(public.get_health() #>> '{checks,backup_dump,status}', 'ok', 'a recent successful dump is ok');
SELECT is(public.get_health() #>> '{checks,backup_verify,status}', 'warn',
  'a recent success followed by a failed verification is a warning');
SELECT is(public.get_health() #>> '{checks,storage_sync,status}', 'fail',
  'storage buckets that were never synced fail once the backup threshold is set');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.get_health()$$, '42501', NULL, 'clients cannot read operational health');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
