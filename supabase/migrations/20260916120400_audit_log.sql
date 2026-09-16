-- Append-only, hash-chained audit log (spec; ERD §12; RLS matrix §10).
--   hash = sha256(prev_hash || canonical row)
-- No role, including service_role, may UPDATE, DELETE or TRUNCATE it, and a trigger
-- refuses those statements even for the table owner. A scheduled job re-verifies the chain.

CREATE SEQUENCE audit.log_id_seq;

CREATE TABLE audit.log (
  id           bigint      NOT NULL DEFAULT nextval('audit.log_id_seq'),
  actor_id     uuid,
  actor_role   text        NOT NULL,
  action       text        NOT NULL,
  target_table text,
  target_id    text,
  before       jsonb,
  after        jsonb,
  reason_code  text,
  created_at   timestamptz NOT NULL,
  prev_hash    bytea,
  hash         bytea       NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

ALTER SEQUENCE audit.log_id_seq OWNED BY audit.log.id;
CREATE INDEX audit_log_id ON audit.log (id DESC);
CREATE INDEX audit_log_target ON audit.log (target_table, target_id);
CREATE INDEX audit_log_actor ON audit.log (actor_id, created_at DESC);

DO $$ BEGIN PERFORM private.ensure_monthly_partitions('audit.log'::regclass, 3); END $$;

-- Canonical form hashed for each row. Timestamps are hashed as epoch microseconds, not text:
-- the text form of timestamptz depends on the session TimeZone, which would make the chain
-- verify differently depending on who runs the check.
CREATE FUNCTION private.audit_row_digest(
  p_prev_hash bytea, p_id bigint, p_actor_id uuid, p_actor_role text, p_action text,
  p_target_table text, p_target_id text, p_before jsonb, p_after jsonb, p_reason_code text,
  p_created_at timestamptz
)
RETURNS bytea
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT sha256(
    coalesce(p_prev_hash, '\x'::bytea) ||
    convert_to(jsonb_build_array(
      p_id, p_actor_id, p_actor_role, p_action, p_target_table, p_target_id,
      p_before, p_after, p_reason_code,
      (extract(epoch FROM p_created_at) * 1000000)::bigint
    )::text, 'UTF8')
  );
$$;

CREATE FUNCTION private.audit_write(
  p_action text,
  p_target_table text DEFAULT NULL,
  p_target_id text DEFAULT NULL,
  p_before jsonb DEFAULT NULL,
  p_after jsonb DEFAULT NULL,
  p_reason_code text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id    bigint;
  v_prev  bytea;
  v_at    timestamptz := clock_timestamp();
  v_actor uuid := auth.uid();
  v_role  text := coalesce(auth.jwt() ->> 'role', session_user::text);
BEGIN
  -- Serialise writers so each row chains to the previous committed row. The lock is held
  -- to commit; audit writes are admin and money actions, not a hot path.
  PERFORM pg_advisory_xact_lock(hashtextextended('audit.log', 0));

  SELECT l.hash INTO v_prev FROM audit.log l ORDER BY l.id DESC LIMIT 1;
  v_id := nextval('audit.log_id_seq');

  INSERT INTO audit.log (id, actor_id, actor_role, action, target_table, target_id,
                         before, after, reason_code, created_at, prev_hash, hash)
  VALUES (v_id, v_actor, v_role, p_action, p_target_table, p_target_id,
          p_before, p_after, p_reason_code, v_at, v_prev,
          private.audit_row_digest(v_prev, v_id, v_actor, v_role, p_action, p_target_table,
                                   p_target_id, p_before, p_after, p_reason_code, v_at));
  RETURN v_id;
END $$;

-- Returns the id of the first row whose hash or back-link does not verify, or NULL if the
-- whole chain is intact.
CREATE FUNCTION private.audit_verify_chain()
RETURNS bigint
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r      audit.log%ROWTYPE;
  v_prev bytea := NULL;
BEGIN
  FOR r IN SELECT * FROM audit.log ORDER BY id LOOP
    IF r.prev_hash IS DISTINCT FROM v_prev
       OR r.hash <> private.audit_row_digest(r.prev_hash, r.id, r.actor_id, r.actor_role,
            r.action, r.target_table, r.target_id, r.before, r.after, r.reason_code, r.created_at)
    THEN
      RETURN r.id;
    END IF;
    v_prev := r.hash;
  END LOOP;
  RETURN NULL;
END $$;

CREATE FUNCTION private.audit_forbid_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'ERR_AUDIT_APPEND_ONLY' USING ERRCODE = '42501';
END $$;

CREATE TRIGGER audit_log_no_update_delete
  BEFORE UPDATE OR DELETE ON audit.log
  FOR EACH ROW EXECUTE FUNCTION private.audit_forbid_mutation();
CREATE TRIGGER audit_log_no_truncate
  BEFORE TRUNCATE ON audit.log
  FOR EACH STATEMENT EXECUTE FUNCTION private.audit_forbid_mutation();

-- Generic row-change trigger for configuration tables (countries, flags, remote config,
-- admin users). Records who changed what, before and after.
CREATE FUNCTION private.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_before jsonb := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
  v_after  jsonb := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
  v_target text  := coalesce(v_after, v_before) ->> TG_ARGV[0];
BEGIN
  PERFORM private.audit_write(lower(TG_OP), TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
                              v_target, v_before, v_after);
  RETURN coalesce(NEW, OLD);
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA audit FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE audit.log_id_seq FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION
  private.audit_row_digest(bytea, bigint, uuid, text, text, text, text, jsonb, jsonb, text, timestamptz),
  private.audit_write(text, text, text, jsonb, jsonb, text),
  private.audit_verify_chain(),
  private.audit_forbid_mutation(),
  private.audit_row_change()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.audit_write(text, text, text, jsonb, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION private.audit_verify_chain() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('audit-log-partitions', '15 0 * * *',
      $cron$SELECT private.ensure_monthly_partitions('audit.log'::regclass, 3)$cron$);
  END IF;
END $$;
