-- Phase 5, part 3: cancelling a paid job, and refunds (ERD §6; `docs/plan/money-flows.md`
-- postings 5a, 5b and 5c; OD-08, OD-19; job lifecycle cancellation transitions).
--
-- `cancel_request` already handles the easy half: a request nobody has paid for. This is the
-- other half, where money is held and cancelling it costs somebody something.
--
-- **The rules here implement two Proposed defaults and nothing more.** OD-08 says the platform
-- absorbs the gateway fee except on a late customer cancellation; OD-19 says the provider is
-- compensated for a wasted trip and the platform takes commission on that compensation. Both are
-- the client's to change, both are `remote_config`, and neither is a number I invented — they
-- are in the register with those defaults, and the postings come from money-flows.
--
-- **Who cancels decides who pays.** A customer cancelling after the provider has set off pays the
-- fee; the same customer cancelling before that pays nothing. A provider cancelling pays nothing
-- and the customer is refunded in full, because a provider who abandons a job should not be able
-- to charge for it — their cancellation rate is the consequence, and the risk engine already
-- watches it.
--
-- **A refund is requested here and executed elsewhere.** The row is written and the money moved
-- out of `held_funds` into `refunds_payable` immediately, because the platform owes it from that
-- moment. `private.execute_refund` posts 5c when the gateway confirms it actually went back.

CREATE TYPE public.refund_status AS ENUM ('pending', 'succeeded', 'failed');

CREATE TABLE public.refunds (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id        uuid NOT NULL REFERENCES public.payments (id) ON DELETE RESTRICT,
  request_id        uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  amount_minor      bigint NOT NULL CHECK (amount_minor > 0),
  currency          char(3) NOT NULL REFERENCES public.currencies (code),
  reason_code       text NOT NULL CHECK (reason_code ~ '^[a-z0-9_]{3,60}$'),
  status            public.refund_status NOT NULL DEFAULT 'pending',
  gateway_reference text CHECK (gateway_reference IS NULL
                                OR length(gateway_reference) BETWEEN 1 AND 200),
  requested_by      uuid REFERENCES auth.users (id),
  approved_by       uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  settled_at        timestamptz
);
CREATE INDEX refunds_payment ON public.refunds (payment_id, created_at);
CREATE INDEX refunds_pending ON public.refunds (created_at) WHERE status = 'pending';

ALTER TABLE public.refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refunds FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.refunds FROM anon, authenticated;
GRANT SELECT ON public.refunds TO authenticated;
GRANT ALL ON public.refunds TO service_role;
-- The person owed the money can see it, and so can the desks that answer for it.
CREATE POLICY refunds_read ON public.refunds FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(refunds.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer', 'dispute_officer',
                     'support_agent']::public.admin_role[])));

-- The sum of refunds can never exceed the payment. `cancel_job` cannot breach it by
-- construction — its refund is the payment less fees — so this is the invariant standing ready
-- for the partial refunds that disputes will bring. **Whatever adds those must check first and
-- raise catchably**, because this trigger is deferred and a deferred abort cannot be caught
-- (S-14); it is the backstop, not the guard.
CREATE FUNCTION private.assert_refunds_within_payment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_paid     bigint;
  v_refunded bigint;
BEGIN
  SELECT p.amount_minor INTO v_paid FROM public.payments p WHERE p.id = NEW.payment_id;
  SELECT coalesce(sum(r.amount_minor), 0)::bigint INTO v_refunded
  FROM public.refunds r WHERE r.payment_id = NEW.payment_id AND r.status <> 'failed';

  IF v_refunded > v_paid THEN
    RAISE EXCEPTION 'ERR_REFUND_EXCEEDS_PAYMENT' USING ERRCODE = 'P0001',
      DETAIL = format('refunds total %s against a payment of %s', v_refunded, v_paid);
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER refunds_within_payment
  AFTER INSERT OR UPDATE ON public.refunds
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION private.assert_refunds_within_payment();

-- ---------------------------------------------------------------------------
-- What a cancellation costs, as a function rather than as a number scattered through the code.
-- Late is from `en_route`: the provider has set off, and that is the trip being wasted.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.cancellation_fee_minor(
  p_gross_minor bigint, p_status public.job_status, p_by_provider boolean)
RETURNS bigint
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_bps integer := coalesce(private.remote_config_int('cancellation_fee_bps'), 1000);
BEGIN
  -- A provider who abandons a job does not get to charge for it (OD-19). Their cancellation rate
  -- is the consequence, and the risk engine already watches that.
  IF p_by_provider THEN
    RETURN 0;
  END IF;
  IF p_status NOT IN ('en_route', 'arrived', 'in_progress', 'completed_by_provider') THEN
    RETURN 0;
  END IF;
  RETURN private.apply_bps(p_gross_minor, v_bps);
END $$;

-- ---------------------------------------------------------------------------
-- cancel_job — the paid half of cancellation. money-flows 5a and 5b.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.cancel_job(
  p_idempotency_key text, p_request_id uuid, p_reason_code text)
RETURNS TABLE (refund_minor bigint, fee_minor bigint, currency char(3))
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_request  public.requests%ROWTYPE;
  v_job      public.jobs%ROWTYPE;
  v_payment  public.payments%ROWTYPE;
  v_provider boolean;
  v_fee      bigint;
  v_gwfee    bigint;
  v_refund   bigint;
  v_comm     bigint;
  v_entries  jsonb;
  v_refund_id uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'cancel_job',
    jsonb_build_object('request_id', p_request_id, 'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN QUERY SELECT (v_claim ->> 'refund_minor')::bigint,
                        (v_claim ->> 'fee_minor')::bigint,
                        (v_claim ->> 'currency')::char(3);
    RETURN;
  END IF;
  IF p_reason_code IS NULL OR p_reason_code !~ '^[a-z0-9_]{3,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_provider := v_uid IN (v_job.provider_id, v_job.worker_id);
  IF NOT v_provider AND v_request.customer_id <> v_uid THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- Once the customer has confirmed the work, cancelling is not the remedy; a dispute is.
  IF v_request.status NOT IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                              'completed_by_provider') THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_CANCELLABLE' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.status = 'held' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_fee := private.cancellation_fee_minor(v_payment.amount_minor, v_request.status, v_provider);
  -- OD-08: the platform absorbs the collection fee, except on a late customer cancellation,
  -- where it comes out of what the customer gets back.
  v_gwfee := CASE WHEN v_fee > 0 THEN coalesce(v_job.actual_gateway_fee_minor, 0) ELSE 0 END;
  v_refund := v_payment.amount_minor - v_fee - v_gwfee;
  IF v_refund <= 0 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the fee would consume the whole payment';
  END IF;

  -- 5a and 5b differ only in which lines are non-zero, so they are one posting built up.
  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.amount_minor),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                       'amount_minor', -v_refund));
  IF v_fee > 0 THEN
    -- OD-19: the platform takes its commission on the compensation, and the provider keeps the
    -- rest for the trip they actually made.
    v_comm := private.apply_bps(v_fee, coalesce(v_job.commission_rate_bps, 1250));
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', -v_comm),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                         'account_type', 'provider_earnings', 'amount_minor', -(v_fee - v_comm)));
  END IF;
  IF v_gwfee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', -v_gwfee));
  END IF;

  PERFORM ledger.post('cancellation', v_payment.currency,
    'cancel:' || p_request_id::text, v_entries, p_request_id, v_uid);

  INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code,
                              requested_by)
  VALUES (v_payment.id, p_request_id, v_refund, v_payment.currency, p_reason_code, v_uid)
  RETURNING id INTO v_refund_id;

  UPDATE public.payments p SET status = 'refunded' WHERE p.id = v_payment.id;
  PERFORM private.job_transition(p_request_id, v_request.status, 'cancelled', v_uid,
    CASE WHEN v_provider THEN 'provider' ELSE 'customer' END::public.job_actor_kind,
    p_reason_code, p_idempotency_key,
    jsonb_build_object('refund_minor', v_refund, 'fee_minor', v_fee));

  -- Both sides are told, because both are affected and neither should learn it from a screen
  -- that happened to refresh.
  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notification.job.cancelled.title', 'notification.job.cancelled.body',
    jsonb_build_object('request_id', p_request_id, 'refund_minor', v_refund,
                       'fee_minor', v_fee, 'currency', v_payment.currency,
                       'by_provider', v_provider), '/requests/' || p_request_id::text);
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.job.cancelled.title', 'notification.job.cancelled.body',
    jsonb_build_object('request_id', p_request_id, 'compensation_minor', v_fee - coalesce(v_comm, 0),
                       'currency', v_payment.currency, 'by_provider', v_provider),
    '/jobs/' || p_request_id::text);

  PERFORM private.emit_event('payment', v_refund_id::text, 'refund.requested',
    jsonb_build_object('refund_id', v_refund_id, 'payment_id', v_payment.id,
                       'request_id', p_request_id, 'amount_minor', v_refund,
                       'currency', v_payment.currency, 'reason_code', p_reason_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('refund_minor', v_refund, 'fee_minor', v_fee,
                       'currency', v_payment.currency));

  RETURN QUERY SELECT v_refund, v_fee, v_payment.currency;
END $$;

-- ---------------------------------------------------------------------------
-- execute_refund — money-flows 5c, when the gateway confirms the money actually went back.
-- Until then the platform owes it, which is what `refunds_payable` says.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.execute_refund(p_refund_id uuid, p_gateway_reference text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_refund public.refunds%ROWTYPE;
BEGIN
  SELECT * INTO v_refund FROM public.refunds r WHERE r.id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REFUND_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_refund.status = 'succeeded' THEN
    RETURN NULL;   -- the gateway is retrying; the money has already moved
  END IF;
  IF v_refund.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.refunds r
  SET status = 'succeeded', gateway_reference = p_gateway_reference, settled_at = now()
  WHERE r.id = p_refund_id;

  PERFORM private.emit_event('payment', p_refund_id::text, 'refund.succeeded',
    jsonb_build_object('refund_id', p_refund_id, 'request_id', v_refund.request_id,
                       'amount_minor', v_refund.amount_minor));

  RETURN ledger.post('refund', v_refund.currency, 'refund:' || p_refund_id::text,
    jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                         'amount_minor', v_refund.amount_minor),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', -v_refund.amount_minor)),
    v_refund.request_id, NULL);
END $$;

CREATE FUNCTION private.fail_refund(p_refund_id uuid, p_reason_key text)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- The ledger is untouched: the platform still owes the money, which is the truthful position
  -- until it actually reaches the customer. A failed refund is an ops problem, not an accounting
  -- one.
  UPDATE public.refunds r SET status = 'failed' WHERE r.id = p_refund_id AND r.status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REFUND_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.emit_event('payment', p_refund_id::text, 'refund.failed',
    jsonb_build_object('refund_id', p_refund_id, 'reason_key', p_reason_key));
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION
  public.cancel_job(text, uuid, text),
  private.cancellation_fee_minor(bigint, public.job_status, boolean),
  private.assert_refunds_within_payment(),
  private.execute_refund(uuid, text),
  private.fail_refund(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_job(text, uuid, text) TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- OD-19's proposed default: 10% of the job, charged only on a late customer cancellation, and
  -- paid to the provider less commission. The client's to change; it is config, not code.
  ('cancellation_fee_bps', NULL, '1000', true)
ON CONFLICT DO NOTHING;
