-- Structural guarantees that must hold for every migration, present and future.
-- When a new client-callable function or client-writable column is added deliberately,
-- extend the allowlists below in the same change, with the RLS matrix cell it implements.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(13);

-- Internal schemas are unreachable for client roles.
SELECT is(
  (SELECT count(*)::int FROM unnest(ARRAY['ledger', 'kyc', 'audit']) s, unnest(ARRAY['anon', 'authenticated']) r
   WHERE has_schema_privilege(r, s, 'USAGE')),
  0, 'anon and authenticated have no USAGE on ledger, kyc or audit');

-- RLS enabled and forced on every table in public (S-13 finding 5).
SELECT is(
  (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity),
  '{}'::text[], 'every public table has row level security enabled');

SELECT is(
  (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relforcerowsecurity),
  '{}'::text[], 'every public table forces row level security');

-- SECURITY DEFINER functions pin an empty search_path (CLAUDE.md non-negotiable).
SELECT is(
  (SELECT coalesce(array_agg(n.nspname || '.' || p.proname ORDER BY 1), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit')
     AND p.prosecdef
     AND NOT coalesce('search_path=""' = ANY (p.proconfig), false)),
  '{}'::text[], 'every SECURITY DEFINER function sets search_path to empty');

-- Nothing is callable by client roles unless it is on these allowlists.
SELECT is(
  (SELECT coalesce(array_agg(DISTINCT n.nspname || '.' || p.proname), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit')
     AND has_function_privilege('anon', p.oid, 'EXECUTE')
     AND n.nspname || '.' || p.proname NOT IN
       ('public.get_bootstrap', 'public.get_shared_trip')),
  '{}'::text[], 'anon can execute only allowlisted functions');

SELECT is(
  (SELECT coalesce(array_agg(DISTINCT n.nspname || '.' || p.proname), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     AND n.nspname || '.' || p.proname NOT IN (
       'public.get_bootstrap', 'public.set_active_mode', 'public.register_device',
       'public.record_consent', 'public.request_integrity_nonce',
       'public.list_sessions', 'public.revoke_session', 'public.revoke_other_sessions',
       'public.create_request', 'public.publish_request', 'public.cancel_request',
       'public.create_offer', 'public.counter_offer', 'public.accept_offer',
       'public.decline_offer', 'public.withdraw_offer',
       'public.set_online', 'public.update_provider_services',
       'public.update_provider_service_areas', 'public.heartbeat',
       'public.provider_feed',
       'public.set_job_status', 'public.verify_pin', 'public.reveal_job_pin',
       'public.confirm_completion',
       'public.submit_proof', 'public.rate_job',
       'public.send_message', 'public.mark_read',
       'public.block_user', 'public.unblock_user', 'public.favorite_provider',
       'public.report_user',
       'public.register_organization', 'public.invite_member',
       'public.accept_organization_invite', 'public.remove_member',
       'public.set_member_options', 'public.register_vehicle',
       'public.dispatch_job', 'public.claim_job',
       'private.is_org_member', 'private.org_role',
       'public.mark_notifications_read',
       'public.add_trusted_contact', 'public.remove_trusted_contact',
       'public.raise_sos', 'public.update_sos_incident',
       'public.create_trip_share', 'public.revoke_trip_share',
       'public.get_shared_trip',
       'private.chat_is_open', 'private.try_uuid', 'private.may_join_topic',
       'private.may_read_request_media', 'private.is_job_participant',
       'private.path_request_id',
       'private.has_admin_role', 'private.is_any_admin')),
  '{}'::text[], 'authenticated can execute only allowlisted functions');

-- Money is integer minor units (spec money_rules; S-14).
SELECT is(
  (SELECT coalesce(array_agg(table_schema || '.' || table_name || '.' || column_name), '{}')
   FROM information_schema.columns
   WHERE table_schema IN ('public', 'ledger', 'private')
     AND column_name LIKE '%\_minor' AND data_type <> 'bigint'),
  '{}'::text[], 'every *_minor column is bigint');

SELECT is(
  (SELECT coalesce(array_agg(table_schema || '.' || table_name || '.' || column_name), '{}')
   FROM information_schema.columns
   WHERE table_schema IN ('public', 'ledger')
     AND data_type IN ('real', 'double precision', 'numeric', 'money')),
  '{}'::text[], 'no floating point, numeric or money columns in public or ledger');

-- Table-level write privileges: clients get column grants only (S-13 finding 1).
SELECT is(
  (SELECT coalesce(array_agg(c.relname::text || ':' || priv), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
        unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND has_table_privilege('anon', c.oid, priv)),
  '{}'::text[], 'anon has no table-level write privilege on any public table');

SELECT is(
  (SELECT coalesce(array_agg(c.relname::text || ':' || priv), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
        unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND has_table_privilege('authenticated', c.oid, priv)
     AND c.relname::text || ':' || priv NOT IN ('notification_preferences:INSERT')),
  '{}'::text[], 'authenticated has table-level writes only where allowlisted');

-- Client-writable columns match the RLS matrix exactly.
SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.profiles'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.profiles'::regclass, attnum, 'UPDATE')$$,
  ARRAY['display_name', 'language', 'avatar_path'],
  'profiles: authenticated may update only display_name, language, avatar_path');

SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.notification_preferences'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.notification_preferences'::regclass, attnum, 'UPDATE')$$,
  ARRAY['enabled', 'quiet_start', 'quiet_end'],
  'notification_preferences: authenticated may update only enabled and quiet hours');

-- The audit log cannot be rewritten through any API role (RLS matrix §10).
SELECT is(
  (SELECT count(*)::int FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
          unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE has_table_privilege(r, 'audit.log', priv)),
  0, 'no API role may update, delete or truncate audit.log');

SELECT * FROM finish();
ROLLBACK;
