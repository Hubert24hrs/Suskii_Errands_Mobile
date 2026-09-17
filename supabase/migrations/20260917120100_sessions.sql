-- Active sessions (PRD SH-38: "Active sessions and devices are listed and can be signed out
-- remotely"; threat model §5). GoTrue owns auth.sessions; auth.refresh_tokens has
-- ON DELETE CASCADE on session_id (supabase/auth migration 20220811173540), so deleting a
-- session row stops it being refreshed. An access token already issued stays valid until it
-- expires (config.toml auth.jwt_expiry, 1 hour) — that window is the reason sensitive actions
-- check device integrity and, later, re-authentication rather than trusting the session alone.

-- Columns used here are GoTrue's own (migrations 20220811173540, 20221003041400,
-- 20221114143122, 20231027141322): id, user_id, created_at, updated_at, aal, not_after,
-- refreshed_at, user_agent, ip.
CREATE FUNCTION public.list_sessions()
RETURNS TABLE (
  id           uuid,
  created_at   timestamptz,
  updated_at   timestamptz,
  refreshed_at timestamptz,
  not_after    timestamptz,
  aal          text,
  user_agent   text,
  ip           text,
  is_current   boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.id,
         s.created_at,
         s.updated_at,
         s.refreshed_at AT TIME ZONE 'UTC',
         s.not_after,
         s.aal::text,
         s.user_agent,
         host(s.ip),
         s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
  FROM auth.sessions s
  WHERE s.user_id = private.require_user()
  ORDER BY coalesce(s.refreshed_at AT TIME ZONE 'UTC', s.created_at) DESC
$$;

CREATE FUNCTION public.revoke_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  DELETE FROM auth.sessions s WHERE s.id = p_session_id AND s.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_SESSION_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.audit_write('session.revoked', 'auth.sessions', p_session_id::text,
    NULL, NULL, 'user_requested');
END $$;

-- "Sign out everywhere else": keeps the caller's own session.
CREATE FUNCTION public.revoke_other_sessions()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_current uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_count   integer;
BEGIN
  DELETE FROM auth.sessions s
  WHERE s.user_id = v_uid AND (v_current IS NULL OR s.id <> v_current);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count > 0 THEN
    PERFORM private.audit_write('session.revoked_others', 'auth.sessions', v_uid::text,
      NULL, jsonb_build_object('count', v_count), 'user_requested');
  END IF;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.list_sessions(), public.revoke_session(uuid), public.revoke_other_sessions()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.list_sessions(), public.revoke_session(uuid), public.revoke_other_sessions()
  TO authenticated;
