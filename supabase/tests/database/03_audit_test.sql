-- Hash-chained, append-only audit log.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

CREATE TEMP TABLE written AS
  SELECT private.audit_write('test.first', 'public.example', '1', NULL, '{"a": 1}') AS id;
INSERT INTO written SELECT private.audit_write('test.second', 'public.example', '1', '{"a": 1}', '{"a": 2}');

SELECT is((SELECT count(*)::int FROM audit.log l JOIN written w ON w.id = l.id), 2,
  'audit_write appends rows');

SELECT is(
  (SELECT l2.prev_hash FROM audit.log l2 WHERE l2.id = (SELECT max(id) FROM written)),
  (SELECT l1.hash FROM audit.log l1 WHERE l1.id = (SELECT min(id) FROM written)),
  'each row links to the hash of the previous row');

SELECT is(private.audit_verify_chain(), NULL, 'the chain verifies');

INSERT INTO public.feature_flags (key, enabled) VALUES ('test.audited_flag', true);
SELECT ok(
  (SELECT l.after ->> 'key' = 'test.audited_flag' AND l.action = 'insert'
   FROM audit.log l WHERE l.target_table = 'public.feature_flags' AND l.target_id = 'test.audited_flag'),
  'changes to configuration tables are audited automatically');

SELECT throws_ok($$UPDATE audit.log SET action = 'forged'$$, '42501', 'ERR_AUDIT_APPEND_ONLY',
  'even the owner cannot update audit rows');
SELECT throws_ok($$DELETE FROM audit.log$$, '42501', 'ERR_AUDIT_APPEND_ONLY',
  'even the owner cannot delete audit rows');
SELECT throws_ok($$TRUNCATE audit.log$$, '42501', 'ERR_AUDIT_APPEND_ONLY',
  'even the owner cannot truncate the audit log');

SET LOCAL ROLE service_role;
SELECT throws_ok($$UPDATE audit.log SET action = 'forged'$$, '42501', NULL,
  'service_role has no UPDATE privilege on the audit log');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM audit.log$$, '42501', NULL, 'authenticated cannot read the audit log');
SELECT throws_ok($$SELECT private.audit_write('forged')$$, '42501', NULL,
  'authenticated cannot write audit rows directly');
RESET ROLE;

-- Tampering detection: bypass the guard trigger as the owner, alter a row, and the verifier
-- must name that row.
ALTER TABLE audit.log DISABLE TRIGGER audit_log_no_update_delete;
UPDATE audit.log SET after = '{"a": 999}' WHERE id = (SELECT max(id) FROM written);
ALTER TABLE audit.log ENABLE TRIGGER audit_log_no_update_delete;
SELECT is(private.audit_verify_chain(), (SELECT max(id) FROM written),
  'a tampered row is detected by the chain verifier');

SELECT ok(
  has_function_privilege('service_role', 'private.audit_verify_chain()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'private.audit_verify_chain()', 'EXECUTE'),
  'only service_role may run the chain verifier');

SELECT * FROM finish();
ROLLBACK;
