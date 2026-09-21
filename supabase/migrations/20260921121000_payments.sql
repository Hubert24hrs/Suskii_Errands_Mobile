-- Phase 5, part 2: payment records and the webhook intake (ERD §6; `docs/plan/money-flows.md`
-- postings 1a–1c; job lifecycle transitions 7, 8 and 18; RLS matrix §6; spec `money_rules`).
--
-- **No gateway is called from here, and none can be.** Flutterwave and Paystack need merchant
-- accounts the client has not opened (timeline action 4). What this migration builds is the half
-- that does not depend on them: the record of a payment, the money snapshot taken when it starts,
-- the de-duplicating webhook intake, and the ledger postings each gateway answer produces. The
-- worker that actually creates a checkout and verifies a charge writes back through
-- `private.record_gateway_checkout` and `private.confirm_payment` — the same seam shape as the
-- KYC vendor and the telephony provider.
--
-- **The client never marks a payment successful.** The only path into `paid_held` is a
-- signature-verified webhook plus a server-side verify call (spec; transition 8). `start_payment`
-- creates an intent and nothing more; a client that could confirm its own payment could take a
-- job's money without paying.
--
-- **The money is snapshotted once**, when the payment starts: rate, commission and net are
-- written onto the job and never recomputed, so a country changing its commission next month
-- cannot alter a job that was already agreed.

CREATE TABLE public.payments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id        uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  payer_id          uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  gateway           text CHECK (gateway IS NULL
                                OR gateway IN ('flutterwave', 'paystack', 'stripe')),
  gateway_reference text CHECK (gateway_reference IS NULL
                                OR length(gateway_reference) BETWEEN 1 AND 200),
  method            text CHECK (method IS NULL OR length(method) <= 40),
  amount_minor      bigint NOT NULL CHECK (amount_minor > 0),
  currency          char(3) NOT NULL REFERENCES public.currencies (code),
  status            public.payment_status NOT NULL DEFAULT 'pending',
  -- The fee the gateway actually reported. Nothing estimates it into this column: an estimate
  -- that looks like a fact is how a reconciliation goes quietly wrong (ADR-0003).
  fee_minor         bigint CHECK (fee_minor IS NULL OR fee_minor >= 0),
  checkout_url      text CHECK (checkout_url IS NULL OR length(checkout_url) <= 2000),
  expires_at        timestamptz,
  confirmed_at      timestamptz,
  failed_reason_key text CHECK (failed_reason_key IS NULL OR length(failed_reason_key) <= 60),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
-- A gateway reference identifies one charge, once.
CREATE UNIQUE INDEX payments_gateway_reference ON public.payments (gateway, gateway_reference)
  WHERE gateway_reference IS NOT NULL;
-- At most one payment in flight or held per request: two held payments on one job means somebody
-- paid twice and the second refund is a support ticket nobody wants.
CREATE UNIQUE INDEX payments_one_live ON public.payments (request_id)
  WHERE status IN ('pending', 'held');
CREATE INDEX payments_request ON public.payments (request_id, created_at DESC);
CREATE INDEX payments_expiring ON public.payments (expires_at) WHERE status = 'pending';
CREATE TRIGGER payments_touch BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payments FROM anon, authenticated;
GRANT SELECT ON public.payments TO authenticated;
GRANT ALL ON public.payments TO service_role;
-- Read-only to the two people on the job (RLS matrix §6): the customer needs to see what they
-- paid and the provider what is being held for them. Nobody writes this table from a client.
CREATE POLICY payments_read_participant ON public.payments FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(payments.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- webhook_events — raw first, then processed. The spec is explicit: store the payload before
-- acting on it, de-duplicate on the gateway's own event id, and verify server-side afterwards.
-- A webhook we failed to process is a bug we can replay; one we never recorded is gone.
-- ---------------------------------------------------------------------------
CREATE TABLE public.webhook_events (
  id              bigint GENERATED ALWAYS AS IDENTITY,
  gateway         text NOT NULL CHECK (gateway IN ('flutterwave', 'paystack', 'stripe')),
  gateway_event_id text NOT NULL CHECK (length(gateway_event_id) BETWEEN 1 AND 200),
  signature_valid boolean NOT NULL,
  payload         jsonb NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz,
  error           text,
  PRIMARY KEY (id, received_at)
) PARTITION BY RANGE (received_at);
CREATE UNIQUE INDEX webhook_events_dedupe
  ON public.webhook_events (gateway, gateway_event_id, received_at);
CREATE INDEX webhook_events_unprocessed ON public.webhook_events (received_at)
  WHERE processed_at IS NULL;

ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.webhook_events FROM anon, authenticated;
GRANT ALL ON public.webhook_events TO service_role;
-- No policy for any client role: a raw gateway payload carries whatever the gateway chose to put
-- in it, which is not ours to show anybody.

SELECT private.ensure_monthly_partitions('public.webhook_events'::regclass, 3);

-- ---------------------------------------------------------------------------
-- start_payment — transition 7 (agreed → payment_pending). Creates the intent and the money
-- snapshot; the checkout itself is the worker's job.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.start_payment(
  p_idempotency_key text, p_request_id uuid, p_method text DEFAULT NULL)
RETURNS TABLE (payment_id uuid, amount_minor bigint, currency char(3),
               status public.payment_status)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_rate    integer;
  v_ttl     integer;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'start_payment',
    jsonb_build_object('request_id', p_request_id, 'method', p_method));
  IF v_claim IS NOT NULL THEN
    RETURN QUERY SELECT (v_claim ->> 'payment_id')::uuid,
                        (v_claim ->> 'amount_minor')::bigint,
                        (v_claim ->> 'currency')::char(3),
                        (v_claim ->> 'status')::public.payment_status;
    RETURN;
  END IF;

  SELECT * INTO v_request FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status NOT IN ('agreed', 'payment_pending') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- An unexpired intent is reused rather than duplicated: a customer who backgrounded the
  -- checkout and came back should land on the same charge, not a second one.
  SELECT p.id INTO v_id FROM public.payments p
  WHERE p.request_id = p_request_id AND p.status IN ('pending', 'held');
  IF FOUND THEN
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('payment_id', v_id, 'amount_minor', v_job.agreed_amount_minor,
                         'currency', v_job.currency,
                         'status', (SELECT p.status FROM public.payments p WHERE p.id = v_id)));
    RETURN QUERY SELECT v_id, v_job.agreed_amount_minor, v_job.currency,
                        (SELECT p.status FROM public.payments p WHERE p.id = v_id);
    RETURN;
  END IF;

  -- The snapshot. Written once; a later change to a country's rate cannot reach a job that was
  -- already agreed (spec money_rules; ERD §5).
  IF v_job.commission_rate_bps IS NULL THEN
    v_rate := coalesce(
      private.remote_config_int('commission_rate_bps_' || lower(v_request.country_code)),
      private.remote_config_int('commission_rate_bps'),
      1250);
    UPDATE public.jobs j
    SET commission_rate_bps = v_rate,
        commission_minor = private.apply_bps(j.agreed_amount_minor, v_rate),
        net_minor = j.agreed_amount_minor - private.apply_bps(j.agreed_amount_minor, v_rate)
    WHERE j.request_id = p_request_id;
  END IF;

  v_ttl := coalesce(private.remote_config_int('payment_ttl_minutes'), 30);
  INSERT INTO public.payments (request_id, payer_id, method, amount_minor, currency, expires_at)
  VALUES (p_request_id, v_uid, p_method, v_job.agreed_amount_minor, v_job.currency,
          now() + make_interval(mins => v_ttl))
  RETURNING id INTO v_id;

  IF v_request.status = 'agreed' THEN
    PERFORM private.job_transition(p_request_id, 'agreed', 'payment_pending', v_uid, 'customer',
      NULL, p_idempotency_key);
  END IF;

  -- The worker that owns the gateway credentials picks this up, creates the hosted checkout and
  -- writes the reference back. Nothing exists to pick it up yet, which is why `checkout_url`
  -- stays NULL and the app has nothing to open (client action 4).
  PERFORM private.emit_event('payment', v_id::text, 'payment.requested',
    jsonb_build_object('payment_id', v_id, 'request_id', p_request_id, 'payer_id', v_uid,
                       'amount_minor', v_job.agreed_amount_minor, 'currency', v_job.currency,
                       'method', p_method, 'country_code', v_request.country_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payment_id', v_id, 'amount_minor', v_job.agreed_amount_minor,
                       'currency', v_job.currency, 'status', 'pending'));

  RETURN QUERY SELECT v_id, v_job.agreed_amount_minor, v_job.currency,
                      'pending'::public.payment_status;
END $$;

-- The worker's write-back once it has a checkout.
CREATE FUNCTION private.record_gateway_checkout(
  p_payment_id uuid, p_gateway text, p_gateway_reference text, p_checkout_url text)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.payments p
  SET gateway = p_gateway, gateway_reference = p_gateway_reference,
      checkout_url = p_checkout_url
  WHERE p.id = p_payment_id AND p.status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.broadcast('request:' || (SELECT p.request_id::text FROM public.payments p
                                           WHERE p.id = p_payment_id) || ':customer',
    'payment.checkout_ready', jsonb_build_object('payment_id', p_payment_id));
  RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- The webhook intake. Raw first, de-duplicated on the gateway's event id; returns NULL when the
-- event has been seen before, which is the whole point.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.ingest_webhook(
  p_gateway text, p_event_id text, p_signature_valid boolean, p_payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- The unique index has to carry `received_at`, because a partitioned table's unique index must
  -- include the partition key — so it cannot catch a retry that crosses a month boundary. The
  -- explicit check does, and the index remains the backstop against two concurrent copies of the
  -- same event in the same month.
  IF EXISTS (SELECT 1 FROM public.webhook_events w
             WHERE w.gateway = p_gateway AND w.gateway_event_id = p_event_id) THEN
    RETURN NULL;   -- already seen; the gateway is retrying, not telling us something new
  END IF;

  INSERT INTO public.webhook_events (gateway, gateway_event_id, signature_valid, payload)
  VALUES (p_gateway, p_event_id, p_signature_valid, p_payload)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN NULL;
  END IF;
  -- An invalid signature is stored and not acted on. Discarding it would lose the evidence that
  -- somebody is posting forged events at us.
  IF NOT p_signature_valid THEN
    UPDATE public.webhook_events w SET processed_at = now(), error = 'ERR_INVALID_PAYLOAD'
    WHERE w.id = v_id;
    PERFORM private.emit_event('payment', v_id::text, 'webhook.signature_invalid',
      jsonb_build_object('gateway', p_gateway, 'event_id', p_event_id));
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- confirm_payment — money-flows 1a, plus transition 8. The only way into `paid_held`.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.confirm_payment(
  p_gateway text, p_gateway_reference text, p_amount_minor bigint, p_fee_minor bigint)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_fee     bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.gateway = p_gateway AND p.gateway_reference = p_gateway_reference FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- A replayed webhook is not an error. The gateway retries by design, and the job is already
  -- where it should be.
  IF v_payment.status = 'held' THEN
    RETURN (SELECT r.status FROM public.requests r WHERE r.id = v_payment.request_id);
  END IF;
  IF v_payment.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- The amount is the gateway's, checked against ours. A charge for the wrong amount is not a
  -- payment for this job.
  IF p_amount_minor <> v_payment.amount_minor THEN
    RAISE EXCEPTION 'ERR_PAYMENT_FAILED' USING ERRCODE = 'P0001',
      DETAIL = format('gateway reported %s, expected %s', p_amount_minor,
                      v_payment.amount_minor);
  END IF;

  v_fee := greatest(coalesce(p_fee_minor, 0), 0);
  UPDATE public.payments p
  SET status = 'held', fee_minor = v_fee, confirmed_at = now()
  WHERE p.id = v_payment.id;
  UPDATE public.jobs j SET actual_gateway_fee_minor = v_fee
  WHERE j.request_id = v_payment.request_id;

  -- 1a: the customer's money becomes a liability; the gateway keeps its fee.
  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', p_amount_minor - v_fee),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', -p_amount_minor));
  -- A zero fee would be an entry of zero, which the ledger refuses; a gateway that charged
  -- nothing gets no fee line rather than a fabricated one.
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_fee));
  END IF;
  PERFORM ledger.post('payment_captured', v_payment.currency,
    'payment:' || v_payment.id::text, v_entries, v_payment.request_id, NULL);

  PERFORM private.emit_event('payment', v_payment.id::text, 'payment.held',
    jsonb_build_object('payment_id', v_payment.id, 'request_id', v_payment.request_id,
                       'amount_minor', p_amount_minor, 'fee_minor', p_fee_minor));
  RETURN private.mark_paid_held(v_payment.request_id);
END $$;

-- money-flows 1b, from the gateway's settlement report.
CREATE FUNCTION private.record_gateway_settlement(
  p_payment_id uuid, p_settled_minor bigint)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT * INTO v_payment FROM public.payments p WHERE p.id = p_payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  RETURN ledger.post('gateway_settled', v_payment.currency,
    'settlement:' || p_payment_id::text,
    jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', p_settled_minor),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                         'amount_minor', -p_settled_minor)),
    v_payment.request_id, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- recognise_earnings — money-flows 1c, and transition 18 (confirmed → settlement_pending).
-- Runs after the dispute window, not at confirmation: money released before the window closes is
-- money that has to be clawed back from somebody who has already spent it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.recognise_earnings(p_request_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job     public.jobs%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_fee     bigint;
  v_net     bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.commission_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'the money was never snapshotted on this job';
  END IF;

  v_fee := coalesce(v_job.actual_gateway_fee_minor, 0);
  -- The provider bears the collection fee (ADR-0003), so their earnings are net minus it.
  v_net := v_job.net_minor - v_fee;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.amount_minor),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', -v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', -v_net));
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', -v_fee));
  END IF;

  PERFORM private.job_transition(p_request_id, 'confirmed', 'settlement_pending', NULL, 'system');
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.earnings.released.title', 'notification.earnings.released.body',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', v_net,
                       'currency', v_job.currency), '/earnings');

  RETURN ledger.post('earnings_recognised', v_job.currency,
    'earnings:' || p_request_id::text, v_entries, p_request_id, NULL);
END $$;

-- The sweep. A job confirmed longer ago than the dispute window, with nothing open against it.
CREATE FUNCTION private.recognise_due_earnings(p_limit integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_hours integer := coalesce(private.remote_config_int('settlement_hold_hours'), 24);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT j.request_id FROM public.jobs j
    JOIN public.requests r ON r.id = j.request_id
    WHERE r.status = 'confirmed'
      AND j.confirmed_at IS NOT NULL
      AND j.confirmed_at < now() - make_interval(hours => v_hours)
    ORDER BY j.confirmed_at
    LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000)
  LOOP
    BEGIN
      PERFORM private.recognise_earnings(v_row.request_id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- One job that cannot settle must not stop the rest. It stays `confirmed` and is picked up
      -- again next run; a job stuck for days is what the health check is for.
      PERFORM private.emit_event('payment', v_row.request_id::text, 'earnings.recognise_failed',
        jsonb_build_object('request_id', v_row.request_id,
                           'reason_key', CASE WHEN SQLERRM ~ '^ERR_[A-Z_]+$'
                                              THEN SQLERRM ELSE 'ERR_INTERNAL' END));
    END;
  END LOOP;
  RETURN v_count;
END $$;

-- A payment nobody completed. The request goes back to `agreed` so the customer can try again
-- rather than losing the job they negotiated.
CREATE FUNCTION private.expire_payments()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    UPDATE public.payments p
    SET status = 'failed', failed_reason_key = 'payment_ttl_expired'
    WHERE p.status = 'pending' AND p.expires_at IS NOT NULL AND p.expires_at < now()
    RETURNING p.id, p.request_id, p.payer_id
  LOOP
    IF EXISTS (SELECT 1 FROM public.requests r
               WHERE r.id = v_row.request_id AND r.status = 'payment_pending') THEN
      PERFORM private.job_transition(v_row.request_id, 'payment_pending', 'agreed', NULL,
        'system', 'payment_ttl_expired');
    END IF;
    PERFORM private.notify(v_row.payer_id, 'system',
      'notification.payment.expired.title', 'notification.payment.expired.body',
      jsonb_build_object('request_id', v_row.request_id), '/requests/' || v_row.request_id::text);
    PERFORM private.emit_event('payment', v_row.id::text, 'payment.expired',
      jsonb_build_object('payment_id', v_row.id, 'request_id', v_row.request_id));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.start_payment(text, uuid, text),
  private.record_gateway_checkout(uuid, text, text, text),
  private.ingest_webhook(text, text, boolean, jsonb),
  private.confirm_payment(text, text, bigint, bigint),
  private.record_gateway_settlement(uuid, bigint),
  private.recognise_earnings(uuid),
  private.recognise_due_earnings(integer),
  private.expire_payments()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_payment(text, uuid, text) TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- 12.5%: the spec's worked example ($100 → $87.50) resolves OD-06's "typo", and the Nigeria
  -- pack already carries `commission_rate: "0.125"` as a verified client decision.
  ('commission_rate_bps', NULL, '1250', false),
  ('payment_ttl_minutes', NULL, '30', true),
  ('settlement_hold_hours', NULL, '24', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('payment-ttl', '*/5 * * * *',
      $cron$SELECT private.expire_payments()$cron$);
    PERFORM cron.schedule('recognise-earnings', '23 * * * *',
      $cron$SELECT private.recognise_due_earnings()$cron$);
  END IF;
END $$;
