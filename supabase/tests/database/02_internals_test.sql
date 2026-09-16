-- Idempotency keys (S-10), the outbox and partition management.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

SELECT is(
  private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', 'op_a', '{"x": 1}'),
  NULL, 'first claim of a key returns NULL: perform the operation');

SELECT throws_ok(
  $$SELECT private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', 'op_a', '{"x": 1}')$$,
  'P0001', 'ERR_IDEMPOTENCY_IN_PROGRESS', 'a claimed but uncompleted key is not replayed as success');

SELECT lives_ok(
  $$SELECT private.idempotency_complete('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', '{"result": 42}')$$,
  'completing a key stores its response');

SELECT is(
  private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', 'op_a', '{"x": 1}'),
  '{"result": 42}'::jsonb, 'a replay returns the stored response');

SELECT throws_ok(
  $$SELECT private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', 'op_a', '{"x": 2}')$$,
  'P0001', 'ERR_IDEMPOTENCY_KEY_REUSED', 'the same key with a different payload is refused');

SELECT throws_ok(
  $$SELECT private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'key-aaaaaaaaaaaaaaaa', 'op_b', '{"x": 1}')$$,
  'P0001', 'ERR_IDEMPOTENCY_KEY_REUSED', 'the same key for a different operation is refused');

SELECT throws_ok(
  $$SELECT private.idempotency_claim('00000000-0000-4000-8000-000000000001', 'short', 'op_a', '{}')$$,
  '22023', 'ERR_IDEMPOTENCY_KEY_INVALID', 'keys shorter than 16 characters are refused');

SELECT is(
  private.idempotency_claim('00000000-0000-4000-8000-000000000002', 'key-aaaaaaaaaaaaaaaa', 'op_a', '{"x": 1}'),
  NULL, 'keys are scoped per user');

CREATE TEMP TABLE emitted AS SELECT private.emit_event('test', 'abc', 'test.happened', '{"k": "v"}') AS id;
SELECT ok(
  (SELECT o.dispatched_at IS NULL AND o.payload = '{"k": "v"}' FROM private.outbox o JOIN emitted e ON e.id = o.id),
  'emit_event writes an undispatched outbox row');

SELECT is(private.ensure_monthly_partitions('audit.log'::regclass, 3), 0,
  'ensure_monthly_partitions is idempotent');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM private.outbox$$, '42501', NULL, 'authenticated cannot read the outbox');
SELECT throws_ok($$SELECT private.emit_event('a', 'b', 'c', '{}')$$, '42501', NULL,
  'authenticated cannot emit events directly');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
