-- Idempotency keys (S-10), the outbox, its pruning and partition management.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(25);

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

-- Pruning. Every row is backdated against the transaction's now(), and tagged so the assertions
-- read only these rows.
INSERT INTO private.outbox (aggregate, aggregate_id, event_type, created_at, dispatched_at) VALUES
  ('ledger',   'prune-old-ledger',   'ledger.posted',        now() - interval '31 days', NULL),
  ('call',     'prune-old-call',     'call.ended',           now() - interval '31 days', NULL),
  ('request',  'prune-old-request',  'chat.message',         now() - interval '31 days', NULL),
  ('provider', 'prune-old-provider', 'provider.online',      now() - interval '31 days', NULL),
  ('profile',  'prune-old-profile',  'profile.mode_changed', now() - interval '31 days', NULL),
  ('ledger',   'prune-new-ledger',   'ledger.posted',        now() - interval '29 days', NULL),
  ('payment',  'prune-old-payment',  'refund.requested',     now() - interval '90 days', NULL),
  ('user',     'prune-done-user',    'notification.created', now() - interval '40 days', now() - interval '31 days'),
  ('user',     'prune-late-user',    'notification.created', now() - interval '40 days', now() - interval '10 days'),
  ('dispute',  'prune-sla-dispute',  'dispute.sla_breached', now() - interval '90 days', now() - interval '60 days');

SELECT is(private.prune_outbox(), 6, 'prune_outbox deletes the six rows it should and reports them');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-ledger'),
  'an unclaimed ledger row older than 30 days is pruned: nothing will ever dispatch it');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-call'),
  'and so is an unclaimed call row');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-request'),
  'and an unclaimed request row, one per chat message and job transition');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-provider'),
  'and an unclaimed provider row, one per online toggle');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-profile'),
  'and an unclaimed profile row, one per mode switch');
SELECT ok(EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-new-ledger'),
  'an unclaimed row younger than 30 days is kept');
SELECT ok(EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-old-payment'),
  'an undispatched row of a claimed aggregate is kept however old: a worker may still take it');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-done-user'),
  'a row dispatched more than 30 days ago is pruned');
SELECT ok(EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-late-user'),
  'the 30 days run from dispatch, not creation, so a late failure stays visible for a month');
SELECT ok(EXISTS (SELECT 1 FROM private.outbox WHERE aggregate_id = 'prune-sla-dispute'),
  'a dispute''s SLA marker is kept, because escalate_overdue_disputes reads it to escalate once');

-- results_eq runs its query dynamically, so a database without pg_cron never parses cron.job.
SELECT CASE WHEN to_regclass('cron.job') IS NULL THEN skip('pg_cron is not installed here', 1)
  ELSE results_eq(
    $$SELECT schedule, command FROM cron.job WHERE jobname = 'outbox-prune'$$,
    $$VALUES ('47 3 * * *'::text, 'SELECT private.prune_outbox()'::text)$$,
    'outbox-prune runs prune_outbox daily at 03:47')
  END;

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT private.prune_outbox()$$, '42501', NULL,
  'authenticated cannot prune the outbox');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
