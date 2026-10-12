-- The item float top-up (OD-04, answered 2026-10-12; money-flows 3d).
--
-- A shopping errand prepays the goods as a float. When the receipt comes to more than the float,
-- the decision is: **never charged automatically**. The provider asks for the difference, the
-- customer approves it in the app, and otherwise the difference goes to the dispute path. Until
-- now only the first half existed: `submit_float_receipt` refused a receipt above the float, and
-- the provider was left out of pocket with no way to ask.
--
-- The shape:
--
--   * **One top-up per job**, by UNIQUE. A declined request cannot be repeated, so nobody is
--     asked twice and a provider cannot wear a customer down.
--   * **Bounded**: at most `float_top_up_max_bps` of the float (100% by default). A bigger gap
--     is not a top-up; it is a dispute.
--   * **Its own payment**, of kind `float_top_up`, through the same checkout and webhook as every
--     other charge. The customer covers the gateway's fee on it with the same surcharge as the
--     float itself, so the provider is reimbursed exactly what they spent. A failed top-up payment
--     never touches the job.
--   * **Unpaid means declined**: a refusal, no answer within `float_top_up_response_hours`, or an
--     approval never paid all reimburse the provider the whole float and leave the rest to a
--     dispute, which the provider opens if they choose.
--   * **The float is not released while a top-up is open**, and no other receipt can be filed.
--   * **A cancelled job refunds a paid top-up in full**, as `cancel_job` already refunds the float
--     itself. The surcharge stays with the gateway fee it paid for.
--
-- Three functions are replaced whole, because each assumed a job had exactly one float:
-- `submit_float_receipt`, `private.release_item_float` and `private.confirm_payment`.

ALTER TABLE public.payments DROP CONSTRAINT payments_kind_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_kind_check CHECK (kind IN ('job', 'tip', 'float_top_up'));

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('float_top_up_max_bps', NULL, '10000', true),
  ('float_top_up_response_hours', NULL, '24', true)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- float_top_ups
-- ---------------------------------------------------------------------------
CREATE TABLE public.float_top_ups (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id   uuid NOT NULL UNIQUE REFERENCES public.requests (id) ON DELETE CASCADE,
  requested_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- The float as prepaid, and the receipt as spent. The top-up is the difference.
  float_minor  bigint NOT NULL CHECK (float_minor > 0),
  spent_minor  bigint NOT NULL,
  amount_minor bigint GENERATED ALWAYS AS (spent_minor - float_minor) STORED,
  currency     char(3) NOT NULL REFERENCES public.currencies (code),
  receipt_path text NOT NULL CHECK (length(receipt_path) <= 512),
  status       text NOT NULL DEFAULT 'requested'
               CHECK (status IN ('requested', 'approved', 'paid', 'declined', 'expired',
                                 'cancelled', 'refunded')),
  payment_id   uuid REFERENCES public.payments (id),
  respond_by   timestamptz NOT NULL,
  responded_at timestamptz,
  paid_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT float_top_ups_above_float CHECK (spent_minor > float_minor)
);
CREATE INDEX float_top_ups_open ON public.float_top_ups (respond_by)
  WHERE status IN ('requested', 'approved');
CREATE INDEX float_top_ups_payment ON public.float_top_ups (payment_id);
CREATE TRIGGER float_top_ups_touch BEFORE UPDATE ON public.float_top_ups
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.float_top_ups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.float_top_ups FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.float_top_ups FROM anon, authenticated;
GRANT SELECT ON public.float_top_ups TO authenticated;
GRANT ALL ON public.float_top_ups TO service_role;
-- The two sides of the job, and the staff who already read its money and its disputes.
CREATE POLICY float_top_ups_read ON public.float_top_ups FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(request_id))
         OR (SELECT private.admin_may_read_request(request_id,
               ARRAY['support_agent', 'dispute_officer', 'finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Shared: the outcome when no top-up money arrives. The provider is reimbursed the whole float
-- against their receipt; what they spent beyond it is theirs to dispute.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.settle_unpaid_top_up(p_top_up_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_top public.float_top_ups%ROWTYPE;
BEGIN
  UPDATE public.float_top_ups t
  SET status = p_status, responded_at = coalesce(t.responded_at, now())
  WHERE t.id = p_top_up_id
  RETURNING * INTO v_top;

  UPDATE public.jobs j
  SET item_float_spent_minor = v_top.float_minor, item_float_receipt_path = v_top.receipt_path
  WHERE j.request_id = v_top.request_id AND j.item_float_approved_at IS NULL;

  PERFORM private.notify(v_top.requested_by, 'job_status',
    'notification.float.top_up.unpaid.title', 'notification.float.top_up.unpaid.body',
    jsonb_build_object('request_id', v_top.request_id, 'top_up_id', v_top.id,
                       'status', p_status, 'disputable_minor', v_top.amount_minor,
                       'currency', v_top.currency),
    '/jobs/' || v_top.request_id::text);
  PERFORM private.emit_event('payment', v_top.request_id::text, 'float.top_up_' || p_status,
    jsonb_build_object('request_id', v_top.request_id, 'top_up_id', v_top.id,
                       'amount_minor', v_top.amount_minor));
END $$;

-- ---------------------------------------------------------------------------
-- request_float_top_up — the provider, with the receipt in hand.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.request_float_top_up(
  p_idempotency_key text, p_request_id uuid, p_spent_minor bigint, p_receipt_path text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_job     public.jobs%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_max     bigint;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'request_float_top_up',
    jsonb_build_object('request_id', p_request_id, 'spent_minor', p_spent_minor));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'top_up_id')::uuid;
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (v_job.provider_id, coalesce(v_job.worker_id, v_job.provider_id)) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF v_request.status NOT IN ('in_progress', 'completed_by_provider')
     OR v_job.item_float_approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND OR v_payment.float_minor = 0 THEN
    RAISE EXCEPTION 'ERR_NO_ITEM_FLOAT' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.float_top_ups t WHERE t.request_id = p_request_id) THEN
    RAISE EXCEPTION 'ERR_FLOAT_TOP_UP_EXISTS' USING ERRCODE = 'P0001';
  END IF;
  IF p_spent_minor IS NULL OR p_spent_minor <= v_payment.float_minor THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a receipt inside the float is filed with submit_float_receipt';
  END IF;
  v_max := private.apply_bps(v_payment.float_minor,
    coalesce(private.remote_config_int('float_top_up_max_bps'), 10000));
  IF p_spent_minor - v_payment.float_minor > v_max THEN
    RAISE EXCEPTION 'ERR_FLOAT_TOP_UP_TOO_LARGE' USING ERRCODE = 'P0001',
      DETAIL = format('at most %s above the float', v_max);
  END IF;
  IF p_receipt_path IS NULL OR p_receipt_path NOT LIKE (p_request_id::text || '/%') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the receipt belongs under this job''s own folder';
  END IF;

  INSERT INTO public.float_top_ups (request_id, requested_by, float_minor, spent_minor, currency,
                                    receipt_path, respond_by)
  VALUES (p_request_id, v_uid, v_payment.float_minor, p_spent_minor, v_payment.currency,
          p_receipt_path,
          now() + make_interval(hours =>
            coalesce(private.remote_config_int('float_top_up_response_hours'), 24)))
  RETURNING id INTO v_id;

  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notification.float.top_up.requested.title', 'notification.float.top_up.requested.body',
    jsonb_build_object('request_id', p_request_id, 'top_up_id', v_id,
                       'amount_minor', p_spent_minor - v_payment.float_minor,
                       'currency', v_payment.currency),
    '/jobs/' || p_request_id::text);
  PERFORM private.emit_event('payment', p_request_id::text, 'float.top_up_requested',
    jsonb_build_object('request_id', p_request_id, 'top_up_id', v_id,
                       'amount_minor', p_spent_minor - v_payment.float_minor));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('top_up_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- respond_float_top_up — the customer. Approving returns the payment to check out; declining
-- returns NULL.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.respond_float_top_up(
  p_idempotency_key text, p_top_up_id uuid, p_approve boolean)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_top       public.float_top_ups%ROWTYPE;
  v_request   public.requests%ROWTYPE;
  v_surcharge bigint;
  v_payment   uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'respond_float_top_up',
    jsonb_build_object('top_up_id', p_top_up_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'payment_id')::uuid;
  END IF;
  IF p_approve IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_top FROM public.float_top_ups t WHERE t.id = p_top_up_id FOR UPDATE;
  IF FOUND THEN
    SELECT * INTO v_request FROM public.requests r WHERE r.id = v_top.request_id;
  END IF;
  IF NOT FOUND OR v_request.customer_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'ERR_FLOAT_TOP_UP_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- `confirmed` too: a customer can confirm the work before answering, and the float is not
  -- released (so earnings are not recognised) until the top-up is settled either way.
  IF v_top.status <> 'requested' OR v_top.respond_by <= now()
     OR v_request.status NOT IN ('in_progress', 'completed_by_provider', 'confirmed') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  IF NOT p_approve THEN
    PERFORM private.settle_unpaid_top_up(v_top.id, 'declined');
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('payment_id', NULL));
    RETURN NULL;
  END IF;

  v_surcharge := private.apply_bps(v_top.amount_minor,
    coalesce(private.remote_config_int('item_float_fee_surcharge_bps'), 300));
  INSERT INTO public.payments (request_id, payer_id, amount_minor, currency, expires_at, kind,
                               job_amount_minor, float_minor, float_surcharge_minor)
  VALUES (v_top.request_id, v_uid, v_top.amount_minor + v_surcharge, v_top.currency,
          now() + make_interval(mins =>
            coalesce(private.remote_config_int('payment_ttl_minutes'), 30)),
          'float_top_up', 0, v_top.amount_minor, v_surcharge)
  RETURNING id INTO v_payment;

  UPDATE public.float_top_ups t
  SET status = 'approved', payment_id = v_payment, responded_at = now()
  WHERE t.id = v_top.id;

  PERFORM private.emit_event('payment', v_payment::text, 'payment.requested',
    jsonb_build_object('payment_id', v_payment, 'request_id', v_top.request_id,
                       'payer_id', v_uid, 'amount_minor', v_top.amount_minor + v_surcharge,
                       'currency', v_top.currency, 'kind', 'float_top_up',
                       'country_code', v_request.country_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payment_id', v_payment));
  RETURN v_payment;
END $$;

-- ---------------------------------------------------------------------------
-- No answer, or approved and never paid. Runs every fifteen minutes.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.expire_float_top_ups(p_limit integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT t.id FROM public.float_top_ups t
    LEFT JOIN public.payments p ON p.id = t.payment_id
    WHERE (t.status = 'requested' AND t.respond_by <= now())
       OR (t.status = 'approved' AND p.status = 'failed')
    ORDER BY t.respond_by
    LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000)
    FOR UPDATE OF t SKIP LOCKED
  LOOP
    PERFORM private.settle_unpaid_top_up(v_row.id, 'expired');
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- A cancelled job. An open top-up is withdrawn; a paid one is refunded in full, because
-- `cancel_job` refunds the float it sits beside. A float already released was spent in a shop
-- and `cancel_job` refuses that case before this ever runs.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.cancel_float_top_up()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_top     public.float_top_ups%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT * INTO v_top FROM public.float_top_ups t WHERE t.request_id = NEW.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_top.status IN ('requested', 'approved') THEN
    UPDATE public.payments p
    SET status = 'failed', failed_reason_key = 'job_cancelled'
    WHERE p.id = v_top.payment_id AND p.status = 'pending';
    UPDATE public.float_top_ups t SET status = 'cancelled' WHERE t.id = v_top.id;
  ELSIF v_top.status = 'paid'
        AND NOT EXISTS (SELECT 1 FROM public.jobs j
                        WHERE j.request_id = NEW.id AND j.item_float_approved_at IS NOT NULL) THEN
    SELECT * INTO v_payment FROM public.payments p WHERE p.id = v_top.payment_id FOR UPDATE;
    PERFORM ledger.post('cancellation', v_payment.currency,
      'float_top_up_refund:' || v_payment.id::text,
      jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                           'amount_minor', v_payment.float_minor),
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                           'amount_minor', -v_payment.float_minor)),
      NEW.id, NULL);
    INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code)
    VALUES (v_payment.id, NEW.id, v_payment.float_minor, v_payment.currency, 'job_cancelled');
    UPDATE public.payments p SET status = 'refunded' WHERE p.id = v_payment.id;
    UPDATE public.float_top_ups t SET status = 'refunded' WHERE t.id = v_top.id;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER requests_cancel_float_top_up AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled')
  EXECUTE FUNCTION private.cancel_float_top_up();

-- ---------------------------------------------------------------------------
-- submit_float_receipt, replaced whole: no second receipt while a top-up is open or paid.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_float_receipt(
  p_idempotency_key text, p_request_id uuid, p_spent_minor bigint, p_storage_path text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_float_receipt',
    jsonb_build_object('request_id', p_request_id, 'spent_minor', p_spent_minor));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'spent_minor')::bigint;
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  -- coalesce: `x NOT IN (a, NULL)` is NULL, not true, and would let anybody through. Assignment
  -- always sets worker_id today, so this was not reachable; it should not depend on that.
  IF NOT FOUND OR v_uid NOT IN (v_job.provider_id, coalesce(v_job.worker_id, v_job.provider_id)) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id;
  IF v_request.status NOT IN ('in_progress', 'completed_by_provider') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.item_float_approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'the float has already been released';
  END IF;
  IF EXISTS (SELECT 1 FROM public.float_top_ups t
             WHERE t.request_id = p_request_id AND t.status IN ('requested', 'approved', 'paid')) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'the receipt is the one the top-up was asked against';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND OR v_payment.float_minor = 0 THEN
    RAISE EXCEPTION 'ERR_NO_ITEM_FLOAT' USING ERRCODE = 'P0001';
  END IF;
  -- Spending more than the customer prepaid is not something a receipt can authorise: that is
  -- request_float_top_up, which the customer has to approve.
  IF p_spent_minor IS NULL OR p_spent_minor < 0 OR p_spent_minor > v_payment.float_minor THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'spent must be between zero and the float that was prepaid';
  END IF;
  IF p_storage_path IS NULL OR p_storage_path NOT LIKE (p_request_id::text || '/%') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the receipt belongs under this job''s own folder';
  END IF;

  UPDATE public.jobs j
  SET item_float_spent_minor = p_spent_minor, item_float_receipt_path = p_storage_path
  WHERE j.request_id = p_request_id;

  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notification.float.receipt.title', 'notification.float.receipt.body',
    jsonb_build_object('request_id', p_request_id, 'spent_minor', p_spent_minor,
                       'float_minor', v_payment.float_minor, 'currency', v_payment.currency),
    '/jobs/' || p_request_id::text);
  PERFORM private.emit_event('payment', p_request_id::text, 'float.receipt_submitted',
    jsonb_build_object('request_id', p_request_id, 'spent_minor', p_spent_minor,
                       'storage_path', p_storage_path));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('spent_minor', p_spent_minor));
  RETURN p_spent_minor;
END $$;

-- ---------------------------------------------------------------------------
-- release_item_float, replaced whole: the float is the job payment's plus a paid top-up's
-- (money-flows 3b and 3d). Not while a top-up is still open.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.release_item_float(p_request_id uuid, p_actor uuid)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job     public.jobs%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_topup   bigint;
  v_total   bigint;
  v_unused  bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.item_float_approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.float_top_ups t
             WHERE t.request_id = p_request_id AND t.status IN ('requested', 'approved')) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'a top-up is waiting for the customer';
  END IF;
  IF v_job.item_float_spent_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'no receipt has been submitted';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(sum(p.float_minor), 0) INTO v_topup FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'float_top_up' AND p.status = 'held';
  v_total := v_payment.float_minor + v_topup;
  v_unused := v_total - v_job.item_float_spent_minor;
  -- A paid top-up means the receipt was the whole float plus the top-up, so anything unused is
  -- the job payment's own float and is refunded against it.
  IF v_unused < 0 OR v_unused > v_payment.float_minor THEN
    RAISE EXCEPTION 'ERR_INVALID_AMOUNT' USING ERRCODE = 'P0001',
      DETAIL = format('spent %s against a float of %s', v_job.item_float_spent_minor, v_total);
  END IF;

  -- 3b and 3d: the float leaves its holding account, the provider is reimbursed what they spent,
  -- and whatever is left is owed back to the customer. No commission on any of it.
  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                       'amount_minor', v_total));
  IF v_job.item_float_spent_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                         'account_type', 'provider_earnings',
                         'amount_minor', -v_job.item_float_spent_minor));
  END IF;
  IF v_unused > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                         'amount_minor', -v_unused));
    INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code,
                                requested_by)
    VALUES (v_payment.id, p_request_id, v_unused, v_payment.currency, 'item_float_unused',
            p_actor);
  END IF;

  UPDATE public.jobs j
  SET item_float_approved_at = now(), item_float_released_minor = v_job.item_float_spent_minor
  WHERE j.request_id = p_request_id;

  PERFORM private.emit_event('payment', p_request_id::text, 'float.released',
    jsonb_build_object('request_id', p_request_id,
                       'spent_minor', v_job.item_float_spent_minor,
                       'topped_up_minor', v_topup,
                       'unused_minor', v_unused, 'approved_by', p_actor));

  RETURN ledger.post('float_released', v_payment.currency,
    'float:' || p_request_id::text, v_entries, p_request_id, p_actor);
END $$;

-- ---------------------------------------------------------------------------
-- confirm_payment, replaced whole: a top-up books into the float and moves no job state.
-- The job and tip branches are as 20260921121300 left them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.confirm_payment(
  p_gateway text, p_gateway_reference text, p_amount_minor bigint, p_fee_minor bigint)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_top     public.float_top_ups%ROWTYPE;
  v_fee     bigint;
  v_jobfee  bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.gateway = p_gateway AND p.gateway_reference = p_gateway_reference FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_payment.status = 'held' THEN
    RETURN (SELECT r.status FROM public.requests r WHERE r.id = v_payment.request_id);
  END IF;
  IF v_payment.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_minor <> v_payment.amount_minor THEN
    RAISE EXCEPTION 'ERR_PAYMENT_FAILED' USING ERRCODE = 'P0001',
      DETAIL = format('gateway reported %s, expected %s', p_amount_minor,
                      v_payment.amount_minor);
  END IF;

  v_fee := greatest(coalesce(p_fee_minor, 0), 0);
  UPDATE public.payments p
  SET status = 'held', fee_minor = v_fee, confirmed_at = now()
  WHERE p.id = v_payment.id;

  IF v_payment.kind = 'tip' THEN
    SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_payment.request_id;
    v_entries := jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                         'amount_minor', p_amount_minor - v_fee),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                         'account_type', 'provider_earnings',
                         'amount_minor', -(p_amount_minor - v_fee)));
    IF v_fee > 0 THEN
      v_entries := v_entries || jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                           'amount_minor', v_fee),
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                           'amount_minor', -v_fee));
    END IF;
    PERFORM ledger.post('tip_captured', v_payment.currency,
      'tip:' || v_payment.id::text, v_entries, v_payment.request_id, NULL);

    PERFORM private.notify(v_job.provider_id, 'job_status',
      'notification.tip.received.title', 'notification.tip.received.body',
      jsonb_build_object('request_id', v_payment.request_id,
                         'amount_minor', p_amount_minor - v_fee,
                         'currency', v_payment.currency), '/earnings');
    PERFORM private.emit_event('payment', v_payment.id::text, 'tip.captured',
      jsonb_build_object('payment_id', v_payment.id, 'request_id', v_payment.request_id,
                         'amount_minor', p_amount_minor));
    RETURN (SELECT r.status FROM public.requests r WHERE r.id = v_payment.request_id);
  END IF;

  -- The surcharge covers the float's share of the fee, as on the job payment (3a).
  v_jobfee := v_fee - v_payment.float_surcharge_minor;

  IF v_payment.kind = 'float_top_up' THEN
    v_entries := jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                         'amount_minor', p_amount_minor - v_fee),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                         'amount_minor', -v_payment.float_minor));
    IF v_jobfee <> 0 THEN
      v_entries := v_entries || jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                           'amount_minor', v_jobfee));
    END IF;
    PERFORM ledger.post('payment_captured', v_payment.currency,
      'float_top_up:' || v_payment.id::text, v_entries, v_payment.request_id, NULL);

    UPDATE public.float_top_ups t SET status = 'paid', paid_at = now()
    WHERE t.payment_id = v_payment.id AND t.status = 'approved'
    RETURNING * INTO v_top;
    IF NOT FOUND THEN
      -- Withdrawn while the customer was paying. The capture rolls back with this exception and
      -- the money is a reconciliation item (RB-03), exactly as a late job payment is.
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
        DETAIL = 'the top-up is no longer waiting for this payment';
    END IF;
    -- The receipt the top-up was asked against becomes the job's receipt.
    UPDATE public.jobs j
    SET item_float_spent_minor = v_top.spent_minor, item_float_receipt_path = v_top.receipt_path
    WHERE j.request_id = v_payment.request_id;

    PERFORM private.notify(v_top.requested_by, 'job_status',
      'notification.float.top_up.paid.title', 'notification.float.top_up.paid.body',
      jsonb_build_object('request_id', v_payment.request_id, 'top_up_id', v_top.id,
                         'amount_minor', v_payment.float_minor,
                         'currency', v_payment.currency),
      '/jobs/' || v_payment.request_id::text);
    PERFORM private.emit_event('payment', v_payment.id::text, 'float.top_up_paid',
      jsonb_build_object('payment_id', v_payment.id, 'request_id', v_payment.request_id,
                         'top_up_id', v_top.id, 'amount_minor', p_amount_minor));
    RETURN (SELECT r.status FROM public.requests r WHERE r.id = v_payment.request_id);
  END IF;

  UPDATE public.jobs j SET actual_gateway_fee_minor = greatest(v_jobfee, 0)
  WHERE j.request_id = v_payment.request_id;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', p_amount_minor - v_fee),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', -v_payment.job_amount_minor));
  IF v_payment.float_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                         'amount_minor', -v_payment.float_minor));
  END IF;
  IF v_jobfee <> 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_jobfee));
  END IF;
  PERFORM ledger.post('payment_captured', v_payment.currency,
    'payment:' || v_payment.id::text, v_entries, v_payment.request_id, NULL);

  PERFORM private.emit_event('payment', v_payment.id::text, 'payment.held',
    jsonb_build_object('payment_id', v_payment.id, 'request_id', v_payment.request_id,
                       'amount_minor', p_amount_minor, 'fee_minor', v_fee,
                       'float_minor', v_payment.float_minor));
  RETURN private.mark_paid_held(v_payment.request_id);
END $$;

REVOKE ALL ON FUNCTION
  private.settle_unpaid_top_up(uuid, text),
  private.expire_float_top_ups(integer),
  private.cancel_float_top_up(),
  public.request_float_top_up(text, uuid, bigint, text),
  public.respond_float_top_up(text, uuid, boolean)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.request_float_top_up(text, uuid, bigint, text),
  public.respond_float_top_up(text, uuid, boolean)
TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('float-top-up-expiry', '11,26,41,56 * * * *',
      $cron$SELECT private.expire_float_top_ups()$cron$);
  END IF;
END $$;
