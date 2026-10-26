-- Push dispatch: dead tokens cleared, stale pushes dropped, workers invoked only when configured.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(12);

INSERT INTO auth.users (id, phone) VALUES ('dddddddd-6262-4262-8262-eeeeeeeeeeee', '2348000006262');
INSERT INTO public.user_devices (id, user_id, platform, device_fingerprint_hash, push_token)
VALUES ('dddddddd-6262-4262-8262-000000000001', 'dddddddd-6262-4262-8262-eeeeeeeeeeee', 'android',
        sha256('push-dispatch-test-device'::bytea), 'fcm-token-1');

-- ---------------------------------------------------------------------------
-- Dead tokens.
-- ---------------------------------------------------------------------------
SELECT ok(has_function_privilege('service_role', 'public.dispatch_clear_push_token(uuid)', 'EXECUTE'),
  'the worker may clear a dead token');
SELECT ok(NOT has_function_privilege('authenticated', 'public.dispatch_clear_push_token(uuid)', 'EXECUTE'),
  'a client may not clear anybody''s token');
SELECT is(public.dispatch_clear_push_token('dddddddd-6262-4262-8262-000000000001'), true,
  'a dead token is cleared');
SELECT is((SELECT push_token FROM public.user_devices WHERE id = 'dddddddd-6262-4262-8262-000000000001'), NULL,
  'and the device keeps no token to retry');
SELECT is(public.dispatch_clear_push_token('dddddddd-6262-4262-8262-000000000001'), NULL,
  'clearing it twice changes nothing');

-- ---------------------------------------------------------------------------
-- Stale pushes.
-- ---------------------------------------------------------------------------
INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload, created_at) VALUES
  ('user', 'dddddddd-6262-4262-8262-eeeeeeeeeeee', 'notification.created', '{"notification_id": 1}', now() - interval '3 hours'),
  ('user', 'dddddddd-6262-4262-8262-eeeeeeeeeeee', 'notification.created', '{"notification_id": 2}', now() - interval '5 minutes'),
  ('user', 'dddddddd-6262-4262-8262-eeeeeeeeeeee', 'user.mode_changed', '{}', now() - interval '3 hours');

SELECT is(private.expire_stale_notification_events(), 1, 'one stale push is expired');
SELECT is((SELECT last_error FROM private.outbox WHERE payload ->> 'notification_id' = '1'),
  'ERR_NOTIFICATION_STALE', 'and says why');
SELECT is((SELECT dispatched_at FROM private.outbox WHERE payload ->> 'notification_id' = '2'), NULL,
  'a recent one is still sent');
SELECT is((SELECT count(*)::integer FROM private.outbox
           WHERE event_type = 'user.mode_changed' AND aggregate_id = 'dddddddd-6262-4262-8262-eeeeeeeeeeee'
             AND dispatched_at IS NULL), 1,
  'and an event that is not a notification is not this function''s business');

-- ---------------------------------------------------------------------------
-- Invoking a worker.
-- ---------------------------------------------------------------------------
DELETE FROM vault.secrets WHERE name IN ('edge_functions_url', 'worker_api_key');
SELECT is(private.invoke_edge_worker('notifications-worker'), NULL,
  'an environment without the URL and key in Vault invokes nothing, quietly');
SELECT throws_ok($$SELECT private.invoke_edge_worker('anything-else')$$, '22023', 'ERR_INVALID_ARGUMENT',
  'the worker key is only ever posted to our own workers');
SELECT ok(NOT has_function_privilege('authenticated', 'private.invoke_edge_worker(text)', 'EXECUTE'),
  'a client may not make the database call a worker');

SELECT * FROM finish();
ROLLBACK;
