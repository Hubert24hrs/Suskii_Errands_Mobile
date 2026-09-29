-- Minimal Supabase emulation for running migrations and pgTAP tests on plain PostgreSQL
-- when the Supabase CLI local stack (Docker) is unavailable. NEVER applied to a Supabase
-- project: CI and every environment use the real stack, which already provides all of this.
--
-- What it reproduces, and why each matters for the tests:
--   * roles anon / authenticated / service_role / supabase_auth_admin
--   * auth.users, auth.identities, auth.sessions, auth.uid(), auth.role(), auth.jwt() reading
--     request.jwt.claims
--   * realtime.messages, realtime.topic() and realtime.send()
--   * the `extensions` schema
--   * Vault's create_secret and decrypted_secrets, for the field-encryption KEK (ADR-0018). The
--     shim stores secrets in the clear, which is acceptable only because it never holds real data
--   * Supabase's permissive defaults: new objects in `public` are granted to anon and
--     authenticated. Migrations must revoke them; tests would miss that without this.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT; END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA extensions, auth TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone              text UNIQUE,
  email              text UNIQUE,
  encrypted_password text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_app_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
  banned_until       timestamptz,
  deleted_at         timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- GoTrue's linked sign-in methods and second factors (auth migrations 20221003041349,
-- 20221208132122). Only the columns account erasure deletes by.
CREATE TABLE IF NOT EXISTS auth.identities (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id   text NOT NULL,
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  identity_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  provider      text NOT NULL,
  created_at    timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS auth.mfa_factors (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  factor_type text,
  created_at  timestamptz DEFAULT now()
);

-- Realtime, as the realtime service creates it: the broadcast table, the topic of the
-- connection's channel, and `send`. Without them two pgTAP files could not run here.
CREATE SCHEMA IF NOT EXISTS realtime;
GRANT USAGE ON SCHEMA realtime TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS realtime.messages (
  id          bigserial PRIMARY KEY,
  topic       text NOT NULL,
  extension   text NOT NULL DEFAULT 'broadcast',
  payload     jsonb,
  event       text,
  private     boolean DEFAULT false,
  inserted_at timestamp NOT NULL DEFAULT now()
);
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON realtime.messages TO authenticated;

CREATE OR REPLACE FUNCTION realtime.topic() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('realtime.topic', true), '')
$$;

CREATE OR REPLACE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean DEFAULT true)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO realtime.messages (payload, event, topic, private, extension)
  VALUES (payload, event, topic, private, 'broadcast');
$$;
GRANT EXECUTE ON FUNCTION realtime.topic() TO authenticated;

-- Storage, as the storage service creates it (supabase/storage migrations 0001, 0003, 0008,
-- 0013). Only what the policies touch, so the fallback can apply and test them.
CREATE SCHEMA IF NOT EXISTS storage;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  public             boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id   text REFERENCES storage.buckets (id),
  name        text,
  owner       uuid,
  owner_id    text,
  metadata    jsonb,
  path_tokens text[] GENERATED ALWAYS AS (string_to_array(name, '/')) STORED,
  created_at  timestamptz DEFAULT now()
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated, anon;
GRANT ALL ON storage.objects, storage.buckets TO service_role;
GRANT SELECT ON storage.buckets TO authenticated, anon;

-- Sessions, as GoTrue creates them (supabase/auth migrations 20220811173540, 20221003041400,
-- 20221114143122, 20231027141322). Only the columns our functions read.
DO $shim$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE n.nspname = 'auth' AND t.typname = 'aal_level') THEN
    CREATE TYPE auth.aal_level AS ENUM ('aal1', 'aal2', 'aal3');
  END IF;
END $shim$;

CREATE TABLE IF NOT EXISTS auth.sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at   timestamptz,
  updated_at   timestamptz,
  factor_id    uuid,
  aal          auth.aal_level,
  not_after    timestamptz,
  refreshed_at timestamp,
  user_agent   text,
  ip           inet,
  tag          text
);

CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
  id         bigserial PRIMARY KEY,
  session_id uuid REFERENCES auth.sessions (id) ON DELETE CASCADE,
  token      text,
  user_id    text,
  revoked    boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- Same resolution order as Supabase: legacy per-claim GUC, then the claims JSON.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  )
$$;

CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.jwt() TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

-- Vault, as supabase_vault 0.3 presents it to a migration: create_secret and the decrypted view.
-- The real extension encrypts under a root key outside the database; this stores plain text.
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.secrets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text UNIQUE,
  description text NOT NULL DEFAULT '',
  secret      text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE VIEW vault.decrypted_secrets AS
  SELECT id, name, description, secret, secret AS decrypted_secret, created_at, updated_at
  FROM vault.secrets;
CREATE OR REPLACE FUNCTION vault.create_secret(
  new_secret text, new_name text DEFAULT NULL, new_description text DEFAULT '',
  new_key_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO vault.secrets (name, description, secret)
  VALUES (new_name, coalesce(new_description, ''), new_secret)
  RETURNING id
$$;
REVOKE ALL ON SCHEMA vault FROM PUBLIC;
