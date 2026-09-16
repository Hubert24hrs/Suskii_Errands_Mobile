-- Platform internals: caller identity, idempotency keys, the transactional outbox and
-- monthly partition management. Nothing here is exposed to clients.

-- Error convention for every client-callable function:
--   28000 ERR_UNAUTHENTICATED   no valid JWT (S-13 finding 2: never a 22P02 cast error)
--   42501 ERR_*                 authenticated but not allowed
--   P0001 ERR_*                 business rule refused (the message is the stable code)
--   22023 ERR_*                 invalid argument
CREATE FUNCTION private.require_user()
RETURNS uuid
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'ERR_UNAUTHENTICATED' USING ERRCODE = '28000';
  END IF;
  RETURN uid;
END $$;

CREATE FUNCTION private.jwt_aal()
RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$ SELECT auth.jwt() ->> 'aal' $$;

-- ---------------------------------------------------------------------------
-- Idempotency (S-10): insert the key first; a conflict means a replay.
-- ---------------------------------------------------------------------------
CREATE TABLE private.idempotency_keys (
  user_id      uuid        NOT NULL,
  key          text        NOT NULL CHECK (length(key) BETWEEN 16 AND 128),
  operation    text        NOT NULL,
  request_hash bytea       NOT NULL,
  response     jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (user_id, key)
);
CREATE INDEX idempotency_keys_expires_at ON private.idempotency_keys (expires_at);

-- Returns NULL when the caller should perform the operation, or the stored response
-- when this key already completed. A concurrent duplicate blocks on the primary key
-- until the first transaction commits, then sees its response; if the first rolls back,
-- the duplicate proceeds as the first. Reusing a key for a different operation or a
-- different payload is refused rather than replayed.
CREATE FUNCTION private.idempotency_claim(
  p_user uuid, p_key text, p_operation text, p_request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  h        bytea := sha256(convert_to(coalesce(p_request, 'null'::jsonb)::text, 'UTF8'));
  existing private.idempotency_keys%ROWTYPE;
BEGIN
  IF p_key IS NULL OR length(p_key) NOT BETWEEN 16 AND 128 THEN
    RAISE EXCEPTION 'ERR_IDEMPOTENCY_KEY_INVALID' USING ERRCODE = '22023';
  END IF;

  INSERT INTO private.idempotency_keys (user_id, key, operation, request_hash)
  VALUES (p_user, p_key, p_operation, h)
  ON CONFLICT (user_id, key) DO NOTHING;
  IF FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO existing FROM private.idempotency_keys k
  WHERE k.user_id = p_user AND k.key = p_key;

  IF existing.operation <> p_operation OR existing.request_hash <> h THEN
    RAISE EXCEPTION 'ERR_IDEMPOTENCY_KEY_REUSED' USING ERRCODE = 'P0001';
  END IF;
  IF existing.response IS NULL THEN
    -- Only reachable if a caller claimed a key without completing it in the same transaction.
    RAISE EXCEPTION 'ERR_IDEMPOTENCY_IN_PROGRESS' USING ERRCODE = 'P0001';
  END IF;
  RETURN existing.response;
END $$;

CREATE FUNCTION private.idempotency_complete(p_user uuid, p_key text, p_response jsonb)
RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  UPDATE private.idempotency_keys
  SET response = coalesce(p_response, 'null'::jsonb)
  WHERE user_id = p_user AND key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Transactional outbox: written in the same transaction as the change it describes.
-- A dispatcher (Phase 3/6) moves rows to Supabase Queues for notifications, analytics,
-- AI follow-up, referral commission and settlement.
-- ---------------------------------------------------------------------------
CREATE TABLE private.outbox (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  aggregate     text        NOT NULL,
  aggregate_id  text        NOT NULL,
  event_type    text        NOT NULL,
  payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  dispatched_at timestamptz
);
CREATE INDEX outbox_undispatched ON private.outbox (id) WHERE dispatched_at IS NULL;

CREATE FUNCTION private.emit_event(
  p_aggregate text, p_aggregate_id text, p_event_type text, p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload)
  VALUES (p_aggregate, p_aggregate_id, p_event_type, coalesce(p_payload, '{}'::jsonb))
  RETURNING id;
$$;

-- ---------------------------------------------------------------------------
-- Monthly range partitions, created ahead of time. Used instead of pg_partman so the
-- same migrations run everywhere; scheduled daily by pg_cron where it exists.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.ensure_monthly_partitions(p_parent regclass, p_months_ahead int DEFAULT 3)
RETURNS int
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  parent_schema text;
  parent_name   text;
  month_start   date := date_trunc('month', now())::date;
  from_d        date;
  to_d          date;
  part_name     text;
  created       int := 0;
BEGIN
  SELECT n.nspname, c.relname INTO parent_schema, parent_name
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = p_parent;

  FOR i IN 0..p_months_ahead LOOP
    from_d := (month_start + make_interval(months => i))::date;
    to_d   := (from_d + interval '1 month')::date;
    part_name := format('%s_y%sm%s', parent_name, to_char(from_d, 'YYYY'), to_char(from_d, 'MM'));
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = parent_schema AND c.relname = part_name
    ) THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
        parent_schema, part_name, parent_schema, parent_name, from_d, to_d);
      created := created + 1;
    END IF;
  END LOOP;
  RETURN created;
END $$;

CREATE FUNCTION private.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  private.idempotency_claim(uuid, text, text, jsonb),
  private.idempotency_complete(uuid, text, jsonb),
  private.emit_event(text, text, text, jsonb),
  private.ensure_monthly_partitions(regclass, int)
FROM PUBLIC;
REVOKE ALL ON FUNCTION private.require_user(), private.jwt_aal(), private.touch_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.require_user(), private.jwt_aal() TO service_role;
