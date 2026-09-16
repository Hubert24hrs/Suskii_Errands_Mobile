-- S-13: do the spec's access-control rules actually hold on plain Postgres?
-- Emulates Supabase locally: the anon / authenticated / service_role roles, auth.uid()
-- read from request.jwt.claims, RLS default-deny, and column privileges on protected columns.
-- No Supabase needed: RLS and column privileges are core Postgres.

DROP SCHEMA IF EXISTS auth CASCADE;
DROP TABLE IF EXISTS requests, profiles CASCADE;

CREATE SCHEMA auth;

-- Supabase exposes auth.uid() from the verified JWT. Locally we read the same GUC,
-- which is exactly how Supabase sets it per request.
-- nullif() BEFORE the cast: an absent or empty claims GUC must yield NULL, not a
-- 22P02 parse error. Otherwise every unauthenticated call fails with a confusing
-- cast error instead of a clean UNAUTHENTICATED. (Found by S-13 case 14.)
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub', '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role', 'anon')
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  -- service_role bypasses RLS in Supabase; the key must never reach a client.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'verification_officer') THEN CREATE ROLE verification_officer NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role, verification_officer;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO anon, authenticated, service_role, verification_officer;

CREATE TABLE profiles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL UNIQUE,
    display_name text NOT NULL,
    -- Server-owned columns. A client must never write these.
    trust_level  smallint NOT NULL DEFAULT 0,
    verified_at  timestamptz
);

CREATE TABLE requests (
    id                 bigserial PRIMARY KEY,
    customer_id        uuid NOT NULL,
    title              text NOT NULL,
    -- Server-owned: status is a state machine, money is computed server-side.
    status             text NOT NULL DEFAULT 'DRAFT',
    agreed_amount_minor bigint,
    currency           text NOT NULL DEFAULT 'NGN'
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE requests ENABLE ROW LEVEL SECURITY;
-- Force RLS so even a table owner is subject to it (catches SECURITY DEFINER mistakes).
ALTER TABLE profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE requests FORCE ROW LEVEL SECURITY;

-- Default deny: no policy for anon at all.
CREATE POLICY profiles_select_own ON profiles FOR SELECT TO authenticated
    USING (user_id = auth.uid());
CREATE POLICY profiles_update_own ON profiles FOR UPDATE TO authenticated
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE POLICY requests_select_own ON requests FOR SELECT TO authenticated
    USING (customer_id = auth.uid());
CREATE POLICY requests_insert_own ON requests FOR INSERT TO authenticated
    WITH CHECK (customer_id = auth.uid());
-- Deliberately NO update policy: status changes go through a function.

-- Verification Officers read profiles for review, but never write them.
CREATE POLICY profiles_select_officer ON profiles FOR SELECT TO verification_officer USING (true);

-- Table privileges, then column privileges: RLS alone does not stop a client
-- writing a protected column on a row it legitimately owns.
GRANT SELECT, INSERT ON profiles TO authenticated;
GRANT UPDATE (display_name) ON profiles TO authenticated;      -- and nothing else
GRANT SELECT, INSERT ON requests TO authenticated;
GRANT UPDATE (title) ON requests TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT SELECT ON profiles TO verification_officer;
-- BYPASSRLS skips policies but NOT table privileges, so service_role still needs grants.
GRANT SELECT, INSERT, UPDATE, DELETE ON profiles, requests TO service_role;

-- The only sanctioned way to move a request forward.
CREATE OR REPLACE FUNCTION publish_request(p_request bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_owner uuid; v_status text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED' USING ERRCODE = '28000';
    END IF;

    SELECT customer_id, status INTO v_owner, v_status
      FROM public.requests WHERE id = p_request FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    IF v_owner <> auth.uid() THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501'; END IF;
    IF v_status <> 'DRAFT' THEN RAISE EXCEPTION 'ILLEGAL_TRANSITION' USING ERRCODE = 'P0001'; END IF;

    UPDATE public.requests SET status = 'PUBLISHED' WHERE id = p_request;
    RETURN 'PUBLISHED';
END $$;

REVOKE ALL ON FUNCTION publish_request(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION publish_request(bigint) TO authenticated;
