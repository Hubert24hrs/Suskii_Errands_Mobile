-- Foundation: extensions, schemas and default privileges.
-- ERD conventions: `public` is exposed through the Data API with RLS on every table;
-- `private`, `ledger`, `kyc` and `audit` are never exposed and are reached only through
-- vetted SECURITY DEFINER functions.

CREATE SCHEMA IF NOT EXISTS extensions;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS postgis  WITH SCHEMA extensions;

-- Platform extensions that exist on Supabase but not on a plain PostgreSQL build.
-- Guarded so the local fallback runner can still apply migrations; availability on the
-- chosen Supabase plan is confirmed by spike S-02.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pgmq') THEN
    CREATE EXTENSION IF NOT EXISTS pgmq;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS private;
CREATE SCHEMA IF NOT EXISTS ledger;
CREATE SCHEMA IF NOT EXISTS kyc;
CREATE SCHEMA IF NOT EXISTS audit;

REVOKE ALL ON SCHEMA private, ledger, kyc, audit FROM PUBLIC;
REVOKE ALL ON SCHEMA private, ledger, kyc, audit FROM anon, authenticated;

-- RLS policies call helper functions in `private`, which requires USAGE on the schema.
-- USAGE alone exposes nothing: no table in `private` is granted to these roles, and the
-- schema is not in the API's exposed list.
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

-- Supabase grants every new object in `public` to anon and authenticated by default.
-- Reverse that for objects created by migrations, so each table and function states
-- its own grants explicitly (S-13 finding 1: column grants are the control).
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
-- Functions are also executable by PUBLIC by default. That default cannot be revoked per
-- schema, and revoking it globally would break extension functions installed later, so every
-- migration revokes PUBLIC on each function it creates and a structural pgTAP test
-- (00_structure_test.sql) fails on any function callable by anon or authenticated that is not
-- on the allowlist.
