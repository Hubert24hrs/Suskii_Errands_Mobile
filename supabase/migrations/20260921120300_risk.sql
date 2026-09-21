-- Phase 4, part 4: the risk engine and fraud cases (spec, "Rule-based risk engine (velocity,
-- device reuse, GPS spoofing, collusion, cancellation abuse, chargebacks)"; ERD §7 `fraud_flags`;
-- threat model T/S rows 37, 38 and 159).
--
-- **Rules, not a model.** Every rule here is arithmetic over rows that already exist, with its
-- thresholds in `remote_config`. A person whose account is questioned is entitled to be told what
-- tripped it, and "the model said so" is not that.
--
-- **Nothing here bans, suspends, holds money or refuses a job.** The engine raises a flag and a
-- human decides. That is deliberate and it is the expensive choice: a false positive costs a
-- reviewer five minutes, while an automatic suspension costs somebody their week's income for a
-- coincidence of device fingerprints. Confirming a flag records the finding — the action that
-- follows is a separate, explicit, audited decision by a person with the authority to make it.
--
-- **The flags are not readable by the people they are about.** This is the one place in the
-- schema where that is right: a subject who can read their own score can tune their behaviour
-- until it stops firing, which is exactly what the rules exist to catch.
--
-- Chargebacks are named in the spec's rule list and are not here: a chargeback arrives from a
-- payment gateway, and there is no gateway until Phase 5. `payment_chargeback` is left as a rule
-- key the money work fills in, not as a rule that silently never fires.

CREATE TYPE public.fraud_flag_status AS ENUM ('open', 'cleared', 'confirmed');

CREATE TABLE public.fraud_flags (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_kind  text NOT NULL CHECK (subject_kind IN ('user', 'pair', 'device', 'request')),
  -- Text, because a subject is a user id, a request id, a hex device hash or a pair of user ids:
  -- a uuid column would force three of the four into a shape they are not.
  subject_id    text NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 200),
  rule_key      text NOT NULL CHECK (rule_key ~ '^[a-z0-9_]{3,60}$'),
  -- 0–100. Not money, not a probability: an ordering for the queue.
  score         smallint NOT NULL CHECK (score BETWEEN 0 AND 100),
  status        public.fraud_flag_status NOT NULL DEFAULT 'open',
  details       jsonb NOT NULL DEFAULT '{}'::jsonb,
  reviewer_id   uuid REFERENCES auth.users (id),
  reviewed_at   timestamptz,
  resolution_note text CHECK (resolution_note IS NULL OR length(resolution_note) <= 1000),
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- One open flag per subject per rule. A sweep that runs every hour must not turn one suspicious
-- pattern into twenty-four queue items.
CREATE UNIQUE INDEX fraud_flags_open_once
  ON public.fraud_flags (subject_kind, subject_id, rule_key) WHERE status = 'open';
CREATE INDEX fraud_flags_queue ON public.fraud_flags (score DESC, created_at)
  WHERE status = 'open';
CREATE INDEX fraud_flags_subject ON public.fraud_flags (subject_kind, subject_id);

ALTER TABLE public.fraud_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fraud_flags FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.fraud_flags FROM anon, authenticated;
GRANT SELECT ON public.fraud_flags TO authenticated;
GRANT ALL ON public.fraud_flags TO service_role;
-- Reviewers only. The subject of a flag is not among them.
CREATE POLICY fraud_flags_read ON public.fraud_flags FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(
            ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- raise_fraud_flag — the single door in. Returns NULL when the same rule is already open on the
-- same subject, which is what makes every rule below safe to run on a schedule.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.raise_fraud_flag(
  p_subject_kind text, p_subject_id text, p_rule_key text, p_score smallint,
  p_details jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.fraud_flags (subject_kind, subject_id, rule_key, score, details)
  VALUES (p_subject_kind, p_subject_id, p_rule_key,
          least(greatest(coalesce(p_score, 50), 0), 100)::smallint,
          coalesce(p_details, '{}'::jsonb))
  ON CONFLICT (subject_kind, subject_id, rule_key) WHERE status = 'open' DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    PERFORM private.emit_event('risk', v_id::text, 'risk.flag_raised',
      jsonb_build_object('flag_id', v_id, 'subject_kind', p_subject_kind,
                         'subject_id', p_subject_id, 'rule_key', p_rule_key,
                         'score', p_score));
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Immediate signals: things the database already knows the moment they happen.
-- ---------------------------------------------------------------------------

-- GPS spoofing (threat model row 38). The client reports it, so the client can lie about it —
-- which is why this raises a flag rather than refusing the ping. A provider who has learned to
-- hide the flag still has to produce a PIN and a photo at the door.
CREATE FUNCTION private.risk_mock_location()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.is_mock THEN
    PERFORM private.raise_fraud_flag('user', NEW.provider_id::text, 'mock_location', 70::smallint,
      jsonb_build_object('reported_at', NEW.updated_at));
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER provider_live_location_risk
  AFTER INSERT OR UPDATE OF is_mock ON public.provider_live_location
  FOR EACH ROW WHEN (NEW.is_mock)
  EXECUTE FUNCTION private.risk_mock_location();

-- A device that fails integrity (threat model row 37). The verdict is written by the
-- device-integrity Edge Function with the service role, and only a failing one is interesting:
-- `unevaluated` means we had no credentials, not that the device lied.
CREATE FUNCTION private.risk_device_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF coalesce(NEW.integrity_verdict ->> 'status', '') = 'fail' THEN
    PERFORM private.raise_fraud_flag('user', NEW.user_id::text, 'device_integrity_failed',
      60::smallint,
      jsonb_build_object('device_id', NEW.id, 'platform', NEW.platform,
                         'reasons', NEW.integrity_verdict -> 'reasons'));
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER user_devices_risk
  AFTER INSERT OR UPDATE OF integrity_verdict ON public.user_devices
  FOR EACH ROW EXECUTE FUNCTION private.risk_device_integrity();

-- Self-dealing across two accounts on one handset: the customer and the provider on a job share
-- a device fingerprint. `ERR_SELF_DEALING_BLOCKED` already refuses one account bidding on its own
-- request; this is the same fraud wearing a second account, and it can only be seen after the
-- fact, so it is a flag and not a refusal.
CREATE FUNCTION private.risk_job_self_dealing()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
  v_shared   integer;
BEGIN
  SELECT r.customer_id INTO v_customer FROM public.requests r WHERE r.id = NEW.request_id;
  IF v_customer IS NULL OR v_customer = NEW.provider_id THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::integer INTO v_shared
  FROM public.user_devices a
  JOIN public.user_devices b
    ON b.device_fingerprint_hash = a.device_fingerprint_hash AND b.user_id = NEW.provider_id
  WHERE a.user_id = v_customer;

  IF v_shared > 0 THEN
    PERFORM private.raise_fraud_flag('request', NEW.request_id::text, 'self_dealing_device',
      90::smallint,
      jsonb_build_object('customer_id', v_customer, 'provider_id', NEW.provider_id,
                         'shared_devices', v_shared));
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER jobs_risk_self_dealing AFTER INSERT ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION private.risk_job_self_dealing();

-- ---------------------------------------------------------------------------
-- The sweep. Patterns that only exist over a window, run on a schedule rather than in the path
-- of anybody's request: none of this is worth adding a millisecond to publishing an errand.
-- ---------------------------------------------------------------------------

-- One handset, many accounts (threat model row 159). Two accounts on a shared phone is ordinary
-- in the markets we are opening into; the threshold is config, and it starts at four.
CREATE FUNCTION private.risk_device_reuse()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_max   integer := coalesce(private.remote_config_int('risk_device_reuse_max'), 3);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT d.device_fingerprint_hash AS fp, count(DISTINCT d.user_id)::integer AS users
    FROM public.user_devices d
    GROUP BY d.device_fingerprint_hash
    HAVING count(DISTINCT d.user_id) > v_max
  LOOP
    IF private.raise_fraud_flag('device', encode(v_row.fp, 'hex'), 'device_reuse', 55::smallint,
         jsonb_build_object('accounts', v_row.users, 'threshold', v_max)) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

-- A pair that only ever works with each other. Two people who get on well is a favourite; two
-- accounts that have transacted eight times in a month and almost never with anybody else is a
-- commission or referral wash, and the second half of that test is what keeps a loyal customer
-- out of the queue.
CREATE FUNCTION private.risk_collusive_pairs()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_min   integer := coalesce(private.remote_config_int('risk_pair_jobs_30d'), 8);
  v_share integer := coalesce(private.remote_config_int('risk_pair_share_pct'), 80);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    WITH recent AS (
      SELECT r.customer_id, j.provider_id
      FROM public.jobs j
      JOIN public.requests r ON r.id = j.request_id
      WHERE j.created_at > now() - interval '30 days'
    ),
    pair AS (
      SELECT customer_id, provider_id, count(*)::integer AS jobs
      FROM recent GROUP BY customer_id, provider_id
    )
    SELECT p.customer_id, p.provider_id, p.jobs,
           (SELECT count(*)::integer FROM recent x WHERE x.customer_id = p.customer_id) AS cust_jobs,
           (SELECT count(*)::integer FROM recent y WHERE y.provider_id = p.provider_id) AS prov_jobs
    FROM pair p
    WHERE p.jobs >= v_min
  LOOP
    IF v_row.jobs * 100 >= v_row.cust_jobs * v_share
       AND v_row.jobs * 100 >= v_row.prov_jobs * v_share THEN
      IF private.raise_fraud_flag('pair',
           v_row.customer_id::text || ':' || v_row.provider_id::text,
           'collusive_pair', 75::smallint,
           jsonb_build_object('jobs_30d', v_row.jobs, 'customer_jobs', v_row.cust_jobs,
                              'provider_jobs', v_row.prov_jobs)) IS NOT NULL THEN
        v_count := v_count + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

-- Velocity, on both sides. A customer posting thirty requests in an hour is not running errands;
-- a provider making two hundred offers in an hour is not reading them.
CREATE FUNCTION private.risk_velocity()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_req   integer := coalesce(private.remote_config_int('risk_requests_per_hour'), 10);
  v_off   integer := coalesce(private.remote_config_int('risk_offers_per_hour'), 40);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT r.customer_id AS subject, count(*)::integer AS n
    FROM public.requests r
    WHERE r.created_at > now() - interval '1 hour'
    GROUP BY r.customer_id HAVING count(*) > v_req
  LOOP
    IF private.raise_fraud_flag('user', v_row.subject::text, 'request_velocity', 50::smallint,
         jsonb_build_object('requests_1h', v_row.n, 'threshold', v_req)) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  FOR v_row IN
    SELECT o.provider_id AS subject, count(*)::integer AS n
    FROM public.offers o
    WHERE o.created_at > now() - interval '1 hour'
    GROUP BY o.provider_id HAVING count(*) > v_off
  LOOP
    IF private.raise_fraud_flag('user', v_row.subject::text, 'offer_velocity', 45::smallint,
         jsonb_build_object('offers_1h', v_row.n, 'threshold', v_off)) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

-- Cancellation abuse. The rate is already maintained on the provider profile by the reputation
-- job; what this adds is the volume floor underneath it.
CREATE FUNCTION private.risk_cancellations()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_bps   integer := coalesce(private.remote_config_int('risk_cancellation_rate_bps'), 3000);
  v_min   integer := coalesce(private.remote_config_int('risk_min_jobs_for_rate'), 10);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT pp.user_id, pp.cancellation_rate_bps,
           (SELECT count(*)::integer FROM public.jobs j WHERE j.provider_id = pp.user_id) AS jobs
    FROM public.provider_profiles pp
    WHERE pp.cancellation_rate_bps >= v_bps
  LOOP
    -- The rate alone says nothing until there is enough history behind it: one cancellation out
    -- of one job is 100%.
    IF v_row.jobs >= v_min
       AND private.raise_fraud_flag('user', v_row.user_id::text, 'cancellation_abuse',
             40::smallint,
             jsonb_build_object('cancellation_rate_bps', v_row.cancellation_rate_bps,
                                'jobs', v_row.jobs, 'threshold_bps', v_bps)) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;

CREATE FUNCTION private.run_risk_rules()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RETURN private.risk_device_reuse()
       + private.risk_collusive_pairs()
       + private.risk_velocity()
       + private.risk_cancellations();
END $$;

-- ---------------------------------------------------------------------------
-- The queue and the decision.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.fraud_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.fraud_flags
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.fraud_flags f WHERE f.status = 'open'
  ORDER BY f.score DESC, f.created_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

-- Confirming a flag records a finding. It does not suspend, ban, withhold money or close an
-- account: whoever does that does it explicitly, with their name on it, under the four-eyes rule
-- that already governs those actions. A note is required either way, because "confirmed" with no
-- reasoning is not a record anybody can defend six months later.
CREATE FUNCTION public.review_fraud_flag(
  p_idempotency_key text, p_flag_id uuid, p_confirmed boolean, p_note text)
RETURNS public.fraud_flag_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_flag   public.fraud_flags%ROWTYPE;
  v_status public.fraud_flag_status;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a review needs a note';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'review_fraud_flag',
    jsonb_build_object('flag_id', p_flag_id, 'confirmed', p_confirmed));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.fraud_flag_status;
  END IF;

  SELECT * INTO v_flag FROM public.fraud_flags f WHERE f.id = p_flag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_FRAUD_FLAG_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_flag.status <> 'open' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE WHEN p_confirmed THEN 'confirmed' ELSE 'cleared'
              END::public.fraud_flag_status;
  UPDATE public.fraud_flags f
  SET status = v_status, reviewer_id = v_uid, reviewed_at = now(),
      resolution_note = btrim(p_note)
  WHERE f.id = p_flag_id;

  PERFORM private.audit_write('risk.review_flag', 'public.fraud_flags', p_flag_id::text,
    jsonb_build_object('status', v_flag.status, 'rule_key', v_flag.rule_key),
    jsonb_build_object('status', v_status), NULL);
  PERFORM private.emit_event('risk', p_flag_id::text, 'risk.flag_reviewed',
    jsonb_build_object('flag_id', p_flag_id, 'status', v_status, 'rule_key', v_flag.rule_key,
                       'subject_kind', v_flag.subject_kind, 'subject_id', v_flag.subject_id,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

REVOKE ALL ON FUNCTION
  public.fraud_queue(integer),
  public.review_fraud_flag(text, uuid, boolean, text),
  private.raise_fraud_flag(text, text, text, smallint, jsonb),
  private.risk_mock_location(),
  private.risk_device_integrity(),
  private.risk_job_self_dealing(),
  private.risk_device_reuse(),
  private.risk_collusive_pairs(),
  private.risk_velocity(),
  private.risk_cancellations(),
  private.run_risk_rules()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.fraud_queue(integer),
  public.review_fraud_flag(text, uuid, boolean, text)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('risk_device_reuse_max', NULL, '3', false),
  ('risk_pair_jobs_30d', NULL, '8', false),
  ('risk_pair_share_pct', NULL, '80', false),
  ('risk_requests_per_hour', NULL, '10', false),
  ('risk_offers_per_hour', NULL, '40', false),
  ('risk_cancellation_rate_bps', NULL, '3000', false),
  ('risk_min_jobs_for_rate', NULL, '10', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('risk-rules', '7 * * * *',
      $cron$SELECT private.run_risk_rules()$cron$);
  END IF;
END $$;
