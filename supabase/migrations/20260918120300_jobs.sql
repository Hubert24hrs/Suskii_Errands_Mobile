-- Marketplace, part 4: the job, its transitions and its append-only history (ERD §5 and §9;
-- RLS matrix §5; the job lifecycle state machine; spike S-10 for the transaction shape).
--
-- The five rules the state machine opens with, all enforced here:
--   * the server owns `status` — no client writes it;
--   * one transition, one transaction: lock the request row, check the guard, write the state,
--     write the event;
--   * every transition takes an idempotency key and a replay returns the first result;
--   * an illegal transition is refused with a stable code, never silently ignored;
--   * every transition writes an append-only event **and** an outbox record.
--
-- **What is deliberately missing.** Everything from `PAYMENT_PENDING` through settlement, refunds
-- and disputes is money, and money waits for OD-06 (commission rate), OD-08 (gateway fee on
-- refunds) and OD-19 (who receives a cancellation fee). The job row carries its money columns
-- unwritten, and `private.mark_paid_held()` is the seam the payment phase will call: it is not
-- reachable by any client, and until that phase exists it is how a test moves a paid job forward.
-- The money snapshot is written once, there, and never recomputed (ERD §5).

CREATE TYPE public.job_actor_kind AS ENUM ('customer', 'provider', 'worker', 'system', 'admin');
CREATE TYPE public.job_pin_kind AS ENUM ('pickup', 'delivery');

-- ---------------------------------------------------------------------------
-- jobs — one row per agreed request, created in the acceptance transaction.
-- ---------------------------------------------------------------------------
CREATE TABLE public.jobs (
  request_id                  uuid PRIMARY KEY REFERENCES public.requests (id) ON DELETE CASCADE,
  accepted_offer_id           uuid NOT NULL REFERENCES public.offers (id),
  provider_id                 uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- A business assigns a worker; for an individual provider the two are the same person.
  worker_id                   uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
  agreed_amount_minor         bigint  NOT NULL CHECK (agreed_amount_minor > 0),
  currency                    char(3) NOT NULL REFERENCES public.currencies (code),
  -- The money snapshot: written once by the payment phase, never recomputed, so a later change
  -- to a country's rate cannot alter a job that was already agreed.
  commission_rate_bps         integer CHECK (commission_rate_bps IS NULL
                                             OR commission_rate_bps BETWEEN 0 AND 10000),
  commission_minor            bigint CHECK (commission_minor IS NULL OR commission_minor >= 0),
  net_minor                   bigint CHECK (net_minor IS NULL OR net_minor >= 0),
  estimated_gateway_fee_minor bigint CHECK (estimated_gateway_fee_minor IS NULL
                                            OR estimated_gateway_fee_minor >= 0),
  actual_gateway_fee_minor    bigint CHECK (actual_gateway_fee_minor IS NULL
                                            OR actual_gateway_fee_minor >= 0),
  tip_minor                   bigint CHECK (tip_minor IS NULL OR tip_minor >= 0),
  item_float_released_minor   bigint CHECK (item_float_released_minor IS NULL
                                            OR item_float_released_minor >= 0),
  -- Proof requirements are configuration per category (state machine, "guards worth naming").
  -- Until the proofs work lands, the rule is the one the request itself states: a job with a
  -- destination is a delivery, and a delivery ends with a PIN.
  delivery_pin_required       boolean NOT NULL DEFAULT false,
  pickup_pin_verified_at      timestamptz,
  delivery_pin_verified_at    timestamptz,
  assigned_at                 timestamptz,
  en_route_at                 timestamptz,
  arrived_at                  timestamptz,
  arrived_reason_code         text CHECK (arrived_reason_code IS NULL
                                          OR length(arrived_reason_code) <= 60),
  started_at                  timestamptz,
  completed_at                timestamptz,
  confirmed_at                timestamptz,
  auto_confirmed              boolean NOT NULL DEFAULT false,
  settled_at                  timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jobs_net_is_amount_less_commission CHECK (
    commission_minor IS NULL OR net_minor IS NULL
    OR net_minor = agreed_amount_minor - commission_minor)
);
CREATE INDEX jobs_provider ON public.jobs (provider_id, created_at DESC);
CREATE INDEX jobs_worker ON public.jobs (worker_id, created_at DESC) WHERE worker_id IS NOT NULL;
CREATE INDEX jobs_auto_confirm ON public.jobs (completed_at)
  WHERE completed_at IS NOT NULL AND confirmed_at IS NULL;
CREATE TRIGGER jobs_touch BEFORE UPDATE ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.jobs FROM anon, authenticated;
GRANT SELECT ON public.jobs TO authenticated;
GRANT ALL ON public.jobs TO service_role;
-- Participants only: the customer of the request, the provider, and the assigned worker. There
-- are no secrets in this table — the PINs live in `private.job_pins`, which nobody selects.
CREATE POLICY jobs_read_participant ON public.jobs FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR worker_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = jobs.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- job_events — one row per transition, append-only, partitioned monthly (ERD §9). This is the
-- audit trail the state machine requires: who moved the job, from where to where, and why.
-- ---------------------------------------------------------------------------
CREATE TABLE public.job_events (
  id              bigint GENERATED ALWAYS AS IDENTITY,
  request_id      uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  from_status     public.job_status,
  to_status       public.job_status NOT NULL,
  actor_id        uuid,
  actor_kind      public.job_actor_kind NOT NULL,
  reason_code     text CHECK (reason_code IS NULL OR length(reason_code) <= 60),
  idempotency_key text,
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE INDEX job_events_request ON public.job_events (request_id, id DESC);

ALTER TABLE public.job_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.job_events FROM anon, authenticated;
GRANT SELECT ON public.job_events TO authenticated;
GRANT ALL ON public.job_events TO service_role;
CREATE POLICY job_events_read_participant ON public.job_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = job_events.request_id
                   AND (r.customer_id = (SELECT auth.uid())
                        OR EXISTS (SELECT 1 FROM public.jobs j
                                   WHERE j.request_id = r.id
                                     AND (j.provider_id = (SELECT auth.uid())
                                          OR j.worker_id = (SELECT auth.uid())))))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- The history cannot be rewritten, by anyone, through any path.
CREATE TRIGGER job_events_no_update_delete
  BEFORE UPDATE OR DELETE ON public.job_events
  FOR EACH ROW EXECUTE FUNCTION private.audit_forbid_mutation();

-- Partitions of a public table need row security of their own: reaching one directly bypasses
-- the parent's policies, and with RLS forced and no policy a direct read returns nothing.
CREATE OR REPLACE FUNCTION private.ensure_monthly_partitions(p_parent regclass, p_months_ahead int DEFAULT 3)
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
      EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', parent_schema, part_name);
      EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', parent_schema, part_name);
      created := created + 1;
    END IF;
  END LOOP;
  RETURN created;
END $$;

SELECT private.ensure_monthly_partitions('public.job_events'::regclass, 3);

-- ---------------------------------------------------------------------------
-- job_pins — hashed, salted, attempt-limited, and in `private` so that no grant, policy or
-- `SELECT *` can ever return one. The plaintext exists only in the reply to the customer who
-- asked for it (ERD §5: shown once).
-- ---------------------------------------------------------------------------
CREATE TABLE private.job_pins (
  request_id    uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  kind          public.job_pin_kind NOT NULL,
  pin_hash      bytea NOT NULL,
  pin_salt      text  NOT NULL,
  attempts      smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  verified_at   timestamptz,
  rotated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, kind)
);
REVOKE ALL ON private.job_pins FROM PUBLIC, anon, authenticated;

-- A PIN a person reads aloud: six digits, drawn from the same source as a v4 uuid rather than
-- from `random()`, which is seeded and predictable.
CREATE FUNCTION private.new_pin()
RETURNS text
LANGUAGE sql
SET search_path = ''
AS $$
  SELECT lpad((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint
               % 1000000)::text, 6, '0');
$$;

CREATE FUNCTION private.pin_digest(p_pin text, p_salt text)
RETURNS bytea
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')) $$;

-- Issues or rotates a PIN and returns the plaintext to its one caller. Nothing stores it.
CREATE FUNCTION private.issue_pin(p_request_id uuid, p_kind public.job_pin_kind)
RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_pin  text := private.new_pin();
  v_salt text := replace(gen_random_uuid()::text, '-', '');
BEGIN
  INSERT INTO private.job_pins (request_id, kind, pin_hash, pin_salt)
  VALUES (p_request_id, p_kind, private.pin_digest(v_pin, v_salt), v_salt)
  ON CONFLICT (request_id, kind) DO UPDATE
  SET pin_hash = excluded.pin_hash, pin_salt = excluded.pin_salt,
      attempts = 0, verified_at = NULL, rotated_at = now();
  RETURN v_pin;
END $$;

-- ---------------------------------------------------------------------------
-- The transition helper: one place that writes the status, the event and the outbox record, so
-- no future transition can write two of the three and forget the other.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.job_transition(
  p_request_id uuid,
  p_from public.job_status,
  p_to public.job_status,
  p_actor_id uuid,
  p_actor_kind public.job_actor_kind,
  p_reason_code text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.requests r SET status = p_to, version = r.version + 1 WHERE r.id = p_request_id;

  INSERT INTO public.job_events
    (request_id, from_status, to_status, actor_id, actor_kind, reason_code, idempotency_key, payload)
  VALUES (p_request_id, p_from, p_to, p_actor_id, p_actor_kind, p_reason_code, p_idempotency_key,
          coalesce(p_payload, '{}'::jsonb));

  PERFORM private.emit_event('request', p_request_id::text, 'job.' || p_to::text,
    jsonb_build_object('from_status', p_from, 'to_status', p_to, 'actor_id', p_actor_id,
                       'actor_kind', p_actor_kind, 'reason_code', p_reason_code)
    || coalesce(p_payload, '{}'::jsonb));
END $$;

-- ---------------------------------------------------------------------------
-- The job row is created when an offer is accepted — by trigger rather than inside
-- `accept_offer`, so that any future path to `accepted` creates it too. The state machine's
-- side effects for transition 6 are "accept, expire siblings, snapshot, create payment intent";
-- the snapshot and the intent belong to the payment phase.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.offers_create_job()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_request public.requests%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM public.requests r WHERE r.id = NEW.request_id;

  INSERT INTO public.jobs (request_id, accepted_offer_id, provider_id, worker_id,
                           agreed_amount_minor, currency, delivery_pin_required)
  VALUES (NEW.request_id, NEW.id, NEW.provider_id, NEW.provider_id,
          NEW.amount_minor, NEW.currency, v_request.destination_label IS NOT NULL)
  ON CONFLICT (request_id) DO NOTHING;

  INSERT INTO public.job_events
    (request_id, from_status, to_status, actor_id, actor_kind, payload)
  VALUES (NEW.request_id, v_request.status, 'agreed', NEW.provider_id, 'system',
          jsonb_build_object('offer_id', NEW.id, 'amount_minor', NEW.amount_minor,
                             'currency', NEW.currency));
  RETURN NEW;
END $$;

CREATE TRIGGER offers_create_job AFTER UPDATE OF status ON public.offers
  FOR EACH ROW
  WHEN (NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.offers_create_job();

-- ---------------------------------------------------------------------------
-- The payment seam. `mark_paid_held` is the only way into the working states, and only a
-- signature-verified webhook plus a server-side verify call may call it (state machine, guard
-- "payment truth"). No client grant exists, and none should: this is the most abusable
-- transition in the product.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.mark_paid_held(p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_status public.job_status;
BEGIN
  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('agreed', 'payment_pending') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.job_transition(p_request_id, v_status, 'paid_held', NULL, 'system');
  -- An individual provider is already known, so assignment follows immediately. A business job
  -- waits for a dispatcher to name a worker, which arrives with the fleet work.
  RETURN private.assign_job(p_request_id);
END $$;

CREATE FUNCTION private.assign_job(p_request_id uuid, p_worker_id uuid DEFAULT NULL)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job    public.jobs%ROWTYPE;
  v_status public.job_status;
BEGIN
  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF v_status <> 'paid_held' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.require_active_provider(coalesce(p_worker_id, v_job.provider_id));

  UPDATE public.jobs j
  SET worker_id = coalesce(p_worker_id, j.worker_id, j.provider_id), assigned_at = now()
  WHERE j.request_id = p_request_id;

  -- The PINs exist from assignment, so the customer can be given one the moment they ask.
  PERFORM private.issue_pin(p_request_id, 'pickup');
  IF v_job.delivery_pin_required THEN
    PERFORM private.issue_pin(p_request_id, 'delivery');
  END IF;

  PERFORM private.job_transition(p_request_id, 'paid_held', 'assigned',
    coalesce(p_worker_id, v_job.provider_id), 'system');
  RETURN 'assigned'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- reveal_job_pin — the customer asks for the PIN they read to the provider. Every reveal
-- rotates it, so a PIN that was seen once and then shown on a screenshot is already dead.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.reveal_job_pin(p_request_id uuid, p_kind public.job_pin_kind DEFAULT 'pickup')
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_status public.job_status;
  v_pin    text;
BEGIN
  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('assigned', 'en_route', 'arrived', 'in_progress') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind = 'delivery'
     AND NOT EXISTS (SELECT 1 FROM public.jobs j
                     WHERE j.request_id = p_request_id AND j.delivery_pin_required) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_pin := private.issue_pin(p_request_id, p_kind);
  INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                 reason_code, payload)
  VALUES (p_request_id, v_status, v_status, v_uid, 'customer', 'pin_revealed',
          jsonb_build_object('kind', p_kind));
  RETURN v_pin;
END $$;

-- ---------------------------------------------------------------------------
-- verify_pin — the provider types what the customer read out. Attempt-limited, and the pickup
-- PIN is what starts the work (transition 14).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.verify_pin(
  p_idempotency_key text,
  p_request_id uuid,
  p_pin text,
  p_kind public.job_pin_kind DEFAULT 'pickup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_status    public.job_status;
  v_job       public.jobs%ROWTYPE;
  v_pin_row   private.job_pins%ROWTYPE;
  v_max_tries integer := coalesce(private.remote_config_int('job_pin_max_attempts'), 5);
  v_result    jsonb;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'verify_pin',
    jsonb_build_object('request_id', p_request_id, 'kind', p_kind));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_uid <> v_job.provider_id
     AND v_uid <> coalesce(v_job.worker_id, v_job.provider_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF (p_kind = 'pickup' AND v_status <> 'arrived')
     OR (p_kind = 'delivery' AND v_status <> 'in_progress') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_pin_row FROM private.job_pins p
  WHERE p.request_id = p_request_id AND p.kind = p_kind FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_pin_row.attempts >= v_max_tries THEN
    RAISE EXCEPTION 'ERR_PIN_ATTEMPTS_EXCEEDED' USING ERRCODE = 'P0001';
  END IF;

  -- A wrong PIN **returns** rather than raising. Raising would roll the transaction back, and
  -- the attempt counter with it, so an attempt limit enforced by an exception is not a limit at
  -- all. The failure is the answer, and the same key replays it rather than spending an attempt.
  IF private.pin_digest(coalesce(p_pin, ''), v_pin_row.pin_salt) <> v_pin_row.pin_hash THEN
    UPDATE private.job_pins p SET attempts = p.attempts + 1
    WHERE p.request_id = p_request_id AND p.kind = p_kind
    RETURNING p.attempts INTO v_pin_row.attempts;
    v_result := jsonb_build_object('verified', false, 'status', v_status,
                                   'attempts_remaining', greatest(v_max_tries - v_pin_row.attempts, 0));
    INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                   reason_code, idempotency_key, payload)
    VALUES (p_request_id, v_status, v_status, v_uid, 'provider', 'pin_rejected',
            p_idempotency_key, jsonb_build_object('kind', p_kind));
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
    RETURN v_result;
  END IF;

  UPDATE private.job_pins p SET verified_at = now(), attempts = 0
  WHERE p.request_id = p_request_id AND p.kind = p_kind;

  IF p_kind = 'pickup' THEN
    UPDATE public.jobs j SET pickup_pin_verified_at = now(), started_at = now()
    WHERE j.request_id = p_request_id;
    PERFORM private.job_transition(p_request_id, v_status, 'in_progress', v_uid, 'provider',
      'pickup_pin_verified', p_idempotency_key);
    v_result := jsonb_build_object('verified', true, 'status', 'in_progress',
                                   'attempts_remaining', v_max_tries);
  ELSE
    UPDATE public.jobs j SET delivery_pin_verified_at = now() WHERE j.request_id = p_request_id;
    INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                   reason_code, idempotency_key)
    VALUES (p_request_id, v_status, v_status, v_uid, 'provider', 'delivery_pin_verified',
            p_idempotency_key);
    v_result := jsonb_build_object('verified', true, 'status', v_status,
                                   'attempts_remaining', v_max_tries);
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- ---------------------------------------------------------------------------
-- set_job_status — the provider's own transitions: 12, 13 and 15. `in_progress` is not here;
-- it is reached by verifying the pickup PIN, which is the point of having one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.set_job_status(
  p_idempotency_key text,
  p_request_id uuid,
  p_target public.job_status,
  p_reason_code text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_status   public.job_status;
  v_job      public.jobs%ROWTYPE;
  v_request  public.requests%ROWTYPE;
  v_geofence integer := coalesce(private.remote_config_int('job_arrival_geofence_m'), 150);
  v_point    extensions.geography(Point, 4326);
  v_near     boolean := false;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'set_job_status',
    jsonb_build_object('request_id', p_request_id, 'target', p_target));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  v_status := v_request.status;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_uid <> v_job.provider_id
     AND v_uid <> coalesce(v_job.worker_id, v_job.provider_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF p_target = 'en_route' THEN
    IF v_status <> 'assigned' THEN
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.jobs j SET en_route_at = now() WHERE j.request_id = p_request_id;

  ELSIF p_target = 'arrived' THEN
    IF v_status <> 'en_route' THEN
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    -- Inside the geofence, or manual with a reason the dispute file can read later.
    IF p_lat IS NOT NULL AND p_lng IS NOT NULL AND v_request.pickup_point IS NOT NULL THEN
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
      v_near := extensions.ST_DWithin(v_request.pickup_point, v_point, v_geofence);
    END IF;
    IF NOT v_near AND p_reason_code IS NULL THEN
      RAISE EXCEPTION 'ERR_NOT_AT_PICKUP' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.jobs j
    SET arrived_at = now(), arrived_reason_code = CASE WHEN v_near THEN NULL ELSE p_reason_code END
    WHERE j.request_id = p_request_id;

  ELSIF p_target = 'completed_by_provider' THEN
    IF v_status <> 'in_progress' THEN
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    -- Proof completeness is configuration per category (state machine); the part that exists
    -- today is the delivery PIN, and a delivery is not complete without it.
    IF v_job.delivery_pin_required AND v_job.delivery_pin_verified_at IS NULL THEN
      RAISE EXCEPTION 'ERR_PROOF_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.jobs j SET completed_at = now() WHERE j.request_id = p_request_id;

  ELSE
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.job_transition(p_request_id, v_status, p_target, v_uid, 'provider',
    p_reason_code, p_idempotency_key,
    CASE WHEN p_target = 'arrived' THEN jsonb_build_object('inside_geofence', v_near)
         ELSE '{}'::jsonb END);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', p_target));
  RETURN p_target;
END $$;

-- ---------------------------------------------------------------------------
-- confirm_completion — the customer says the work is done (transition 16). The dispute window
-- and everything downstream of it is money, and waits.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.confirm_completion(p_idempotency_key text, p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_status public.job_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'confirm_completion',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status <> 'completed_by_provider' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.jobs j SET confirmed_at = now() WHERE j.request_id = p_request_id;
  PERFORM private.job_transition(p_request_id, v_status, 'confirmed', v_uid, 'customer',
    NULL, p_idempotency_key);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'confirmed'));
  RETURN 'confirmed'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- auto_confirm_jobs — transition 17, and the spec is strict about it: the window elapsing is not
-- enough on its own. A job auto-confirms only when the PIN it needed was verified. Proof
-- completeness joins this guard when the proofs table exists.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.auto_confirm_jobs(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_window integer := coalesce(private.remote_config_int('job_auto_confirm_hours'), 24);
  v_ids    uuid[];
  v_id     uuid;
  v_count  integer := 0;
BEGIN
  SELECT coalesce(array_agg(due.request_id), '{}'::uuid[]) INTO v_ids FROM (
    SELECT j.request_id
    FROM public.jobs j
    JOIN public.requests r ON r.id = j.request_id
    WHERE r.status = 'completed_by_provider'
      AND j.completed_at <= now() - make_interval(hours => v_window)
      AND j.pickup_pin_verified_at IS NOT NULL
      AND (NOT j.delivery_pin_required OR j.delivery_pin_verified_at IS NOT NULL)
    ORDER BY j.completed_at
    LIMIT p_limit
  ) due;

  FOREACH v_id IN ARRAY v_ids LOOP
    UPDATE public.jobs j SET confirmed_at = now(), auto_confirmed = true
    WHERE j.request_id = v_id;
    PERFORM private.job_transition(v_id, 'completed_by_provider', 'confirmed', NULL, 'system',
      'auto_confirmed');
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Cancelling before anyone has paid is free (transition 23), and `agreed` is still before
-- payment. After `paid_held` there are fees and refunds, which wait for OD-08 and OD-19 — this
-- function keeps refusing those states.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_request(
  p_request_id uuid, p_idempotency_key text, p_reason_code text DEFAULT NULL)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_status public.job_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'cancel_request',
    jsonb_build_object('request_id', p_request_id, 'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT r.status INTO v_status FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('draft', 'published', 'offers_received', 'negotiating', 'agreed') THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_CANCELLABLE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.requests r
  SET status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason_code = p_reason_code,
      expires_at = NULL,
      version = r.version + 1
  WHERE r.id = p_request_id;

  -- A draft that was never published has no job history worth keeping; anything further along
  -- does, including the cancellation itself.
  IF v_status <> 'draft' THEN
    INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                   reason_code, idempotency_key)
    VALUES (p_request_id, v_status, 'cancelled', v_uid, 'customer', p_reason_code,
            p_idempotency_key);
  END IF;

  PERFORM private.emit_event('request', p_request_id::text, 'request.cancelled',
    jsonb_build_object('from_status', v_status, 'reason', p_reason_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'cancelled'));
  RETURN 'cancelled'::public.job_status;
END $$;

REVOKE ALL ON FUNCTION
  public.set_job_status(text, uuid, public.job_status, text, double precision, double precision),
  public.verify_pin(text, uuid, text, public.job_pin_kind),
  public.reveal_job_pin(uuid, public.job_pin_kind),
  public.confirm_completion(text, uuid),
  private.job_transition(uuid, public.job_status, public.job_status, uuid,
                         public.job_actor_kind, text, text, jsonb),
  private.mark_paid_held(uuid),
  private.assign_job(uuid, uuid),
  private.auto_confirm_jobs(integer),
  private.new_pin(),
  private.pin_digest(text, text),
  private.issue_pin(uuid, public.job_pin_kind),
  private.offers_create_job()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.set_job_status(text, uuid, public.job_status, text, double precision, double precision),
  public.verify_pin(text, uuid, text, public.job_pin_kind),
  public.reveal_job_pin(uuid, public.job_pin_kind),
  public.confirm_completion(text, uuid)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('jobs-auto-confirm', '*/10 * * * *',
      $cron$SELECT private.auto_confirm_jobs()$cron$);
    PERFORM cron.schedule('job-events-partitions', '17 3 * * *',
      $cron$SELECT private.ensure_monthly_partitions('public.job_events'::regclass)$cron$);
  END IF;
END $$;
