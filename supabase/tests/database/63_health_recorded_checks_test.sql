-- The checks scheduled jobs record are part of /health, so a failing one reaches the uptime alert.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(14);

DELETE FROM private.health_checks;

SELECT is(public.get_health() #>> '{checks,ledger_reconcile,status}', 'warn',
  'a reconciliation that never ran is a warning, not silence');
SELECT is(public.get_health() #>> '{checks,ledger_reconcile,stale}', 'true',
  'and it says why');

INSERT INTO private.health_checks (check_key, status, detail)
SELECT k, 'ok', '{}'::jsonb
FROM unnest(ARRAY['ledger_reconcile', 'partitions', 'analytics_export', 'notifications',
                  'outbox_stuck']) k;
SELECT is(public.get_health() #>> '{checks,partitions,status}', 'ok', 'a recent ok is ok');
SELECT is(public.get_health() #>> '{checks,outbox_stuck,status}', 'ok', 'for every recorded check');

-- RB-03 as rehearsed on staging: drift in a stored balance, the nightly job's own command.
CREATE TEMP TABLE rb03 AS SELECT ledger.post('payment_captured', 'USD', 'rb03-health-test-0001',
  jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending', 'amount_minor', 9710),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees', 'amount_minor', 290),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds', 'amount_minor', -10000)))
  AS tx;
UPDATE ledger.balances SET balance_minor = balance_minor + 1
WHERE account_id = (SELECT min(e.account_id::text)::uuid FROM ledger.entries e
                    WHERE e.transaction_id = (SELECT tx FROM rb03));
SELECT private.record_health_check('ledger_reconcile',
  CASE WHEN EXISTS (SELECT 1 FROM ledger.reconcile())
         OR EXISTS (SELECT 1 FROM ledger.unbalanced_transactions())
       THEN 'fail' ELSE 'ok' END,
  jsonb_build_object(
    'drifted_accounts', (SELECT count(*) FROM ledger.reconcile()),
    'unbalanced_transactions', (SELECT count(*) FROM ledger.unbalanced_transactions())));

SELECT is(public.get_health() #>> '{checks,ledger_reconcile,status}', 'fail',
  'a failed reconciliation fails the ledger check');
SELECT is(public.get_health() ->> 'status', 'fail',
  'and the whole snapshot, which is what makes /health return 503');
SELECT is(public.get_health() #>> '{checks,ledger_reconcile,detail,drifted_accounts}', '1',
  'with the count that tells on-call where to start');

-- A failure goes quiet: the job stopped, the alarm must not soften into a warning.
UPDATE private.health_checks SET checked_at = now() - interval '3 days' WHERE check_key = 'ledger_reconcile';
SELECT is(public.get_health() #>> '{checks,ledger_reconcile,status}', 'fail',
  'a stale fail is still a fail');

-- An ok goes quiet: the job stopped, which is itself worth knowing.
UPDATE private.health_checks SET checked_at = now() - interval '45 minutes' WHERE check_key = 'notifications';
SELECT is(public.get_health() #>> '{checks,notifications,status}', 'warn',
  'a ten-minute check silent for 45 minutes is stale');
UPDATE private.health_checks SET checked_at = now() - interval '20 hours' WHERE check_key = 'partitions';
SELECT is(public.get_health() #>> '{checks,partitions,status}', 'ok',
  'a daily check 20 hours old is not');
UPDATE private.health_checks SET checked_at = now() - interval '40 hours' WHERE check_key = 'partitions';
SELECT is(public.get_health() #>> '{checks,partitions,status}', 'warn',
  'and at 40 hours it is');

-- The latest row decides, so recovery clears the alarm.
SELECT private.record_health_check('ledger_reconcile', 'ok', '{"drifted_accounts": 0}');
SELECT is(public.get_health() #>> '{checks,ledger_reconcile,status}', 'ok',
  'a later clean run clears the fail');
SELECT private.record_health_check('analytics_export', 'warn', '{"stale_views": 2}');
SELECT is(public.get_health() #>> '{checks,analytics_export,status}', 'warn',
  'a recorded warning stays a warning');

SELECT ok(NOT has_function_privilege('authenticated', 'private.recorded_check(text, interval)', 'EXECUTE'),
  'clients cannot call the reader');

SELECT * FROM finish();
ROLLBACK;
