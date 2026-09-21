-- Phase 5, part 5: the item float (spec phase 5, "Item float flow with receipt reading and refund
-- of unused amounts"; OD-04; `docs/plan/money-flows.md` postings 3a, 3b and 3c; ERD §5).
--
-- A shopping errand has two amounts in it: what the provider is paid for going, and what the
-- goods cost. **They are not the same kind of money.** The float is the customer's money passing
-- through the provider's hands to a shopkeeper, so it carries no commission, it is reimbursed
-- against a receipt, and whatever is left over goes back to the customer. Treating it as part of
-- the job price would take 12.5% of somebody's groceries.
--
-- **The customer pays the gateway's fee on the float, not the provider.** OD-04's default: the
-- charge carries a surcharge sized to the float's share of the fee. Without it the provider would
-- be reimbursed less than they spent, which is not a reimbursement.
--
-- **Four existing functions had to learn about it**, because each of them assumed a payment was
-- one amount: `start_payment`, `confirm_payment`, `recognise_earnings` and `cancel_job`. They are
-- replaced whole here rather than patched, and the arithmetic that splits a charge now lives in
-- the payment row instead of being re-derived by each of them.

ALTER TABLE public.payments
  -- What the charge is made of. `amount_minor` stays the total the customer is charged, because
  -- that is what a gateway is told; these say how it divides.
  ADD COLUMN job_amount_minor      bigint NOT NULL DEFAULT 0 CHECK (job_amount_minor >= 0),
  ADD COLUMN float_minor           bigint NOT NULL DEFAULT 0 CHECK (float_minor >= 0),
  ADD COLUMN float_surcharge_minor bigint NOT NULL DEFAULT 0 CHECK (float_surcharge_minor >= 0);
-- Nothing has run in production, but a payment written by the previous migration is all job.
UPDATE public.payments SET job_amount_minor = amount_minor WHERE job_amount_minor = 0;

ALTER TABLE public.jobs
  ADD COLUMN item_float_spent_minor   bigint CHECK (item_float_spent_minor IS NULL
                                                    OR item_float_spent_minor >= 0),
  ADD COLUMN item_float_receipt_path  text CHECK (item_float_receipt_path IS NULL
                                                  OR length(item_float_receipt_path) <= 512),
  ADD COLUMN item_float_approved_at   timestamptz;

-- ---------------------------------------------------------------------------
-- submit_float_receipt — the provider says what the goods cost and shows the receipt.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.submit_float_receipt(
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
  IF NOT FOUND OR v_uid NOT IN (v_job.provider_id, v_job.worker_id) THEN
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

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND OR v_payment.float_minor = 0 THEN
    RAISE EXCEPTION 'ERR_NO_ITEM_FLOAT' USING ERRCODE = 'P0001';
  END IF;
  -- Spending more than the customer prepaid is not something a receipt can authorise. The
  -- provider is out of pocket and it becomes a conversation, not an automatic top-up.
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
-- release_item_float — money-flows 3b. The customer approves, or the clock does.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.release_item_float(p_request_id uuid, p_actor uuid)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job     public.jobs%ROWTYPE;
  v_payment public.payments%ROWTYPE;
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
  IF v_job.item_float_spent_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'no receipt has been submitted';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_unused := v_payment.float_minor - v_job.item_float_spent_minor;

  -- 3b: the float leaves its holding account, the provider is reimbursed what they spent, and
  -- whatever is left is owed back to the customer. No commission on any of it.
  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                       'amount_minor', v_payment.float_minor));
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
                       'unused_minor', v_unused, 'approved_by', p_actor));

  RETURN ledger.post('float_released', v_payment.currency,
    'float:' || p_request_id::text, v_entries, p_request_id, p_actor);
END $$;

CREATE FUNCTION public.approve_float_receipt(p_idempotency_key text, p_request_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_tx    bigint;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'approve_float_receipt',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'transaction_id')::bigint;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.requests r
                 WHERE r.id = p_request_id AND r.customer_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_tx := private.release_item_float(p_request_id, v_uid);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('transaction_id', v_tx));
  RETURN v_tx;
END $$;

-- A receipt nobody looked at. The same shape as job auto-confirmation: silence is not approval,
-- but it cannot hold the provider's own money for ever either.
CREATE FUNCTION private.auto_approve_float_receipts(p_limit integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_hours integer := coalesce(private.remote_config_int('float_auto_approve_hours'), 24);
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT j.request_id FROM public.jobs j
    JOIN public.requests r ON r.id = j.request_id
    WHERE j.item_float_spent_minor IS NOT NULL
      AND j.item_float_approved_at IS NULL
      AND r.status IN ('completed_by_provider', 'confirmed')
      AND j.completed_at IS NOT NULL
      AND j.completed_at < now() - make_interval(hours => v_hours)
    ORDER BY j.completed_at
    LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000)
  LOOP
    BEGIN
      PERFORM private.release_item_float(v_row.request_id, NULL);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      PERFORM private.emit_event('payment', v_row.request_id::text, 'float.auto_release_failed',
        jsonb_build_object('request_id', v_row.request_id,
                           'reason_key', CASE WHEN SQLERRM ~ '^ERR_[A-Z_]+$'
                                              THEN SQLERRM ELSE 'ERR_INTERNAL' END));
    END;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- start_payment, replaced whole: a charge is now job + float + the fee surcharge on the float.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_payment(
  p_idempotency_key text, p_request_id uuid, p_method text DEFAULT NULL,
  p_promo_code text DEFAULT NULL)
RETURNS TABLE (payment_id uuid, amount_minor bigint, currency char(3),
               status public.payment_status)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_request   public.requests%ROWTYPE;
  v_job       public.jobs%ROWTYPE;
  v_promo     public.promo_codes%ROWTYPE;
  v_discount  bigint := 0;
  v_float     bigint := 0;
  v_surcharge bigint := 0;
  v_jobamount bigint;
  v_charge    bigint;
  v_rate      integer;
  v_ttl       integer;
  v_id        uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'start_payment',
    jsonb_build_object('request_id', p_request_id, 'method', p_method, 'promo', p_promo_code));
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

  SELECT p.id INTO v_id FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status IN ('pending', 'held');
  IF FOUND THEN
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('payment_id', v_id,
                         'amount_minor', (SELECT p.amount_minor FROM public.payments p
                                          WHERE p.id = v_id),
                         'currency', v_job.currency,
                         'status', (SELECT p.status FROM public.payments p WHERE p.id = v_id)));
    RETURN QUERY SELECT v_id, (SELECT p.amount_minor FROM public.payments p WHERE p.id = v_id),
                        v_job.currency,
                        (SELECT p.status FROM public.payments p WHERE p.id = v_id);
    RETURN;
  END IF;

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
    SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  END IF;

  IF nullif(btrim(coalesce(p_promo_code, '')), '') IS NOT NULL THEN
    SELECT * INTO v_promo FROM public.promo_codes p
    WHERE p.country_code = v_request.country_code AND p.code = upper(btrim(p_promo_code))
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001';
    END IF;
    PERFORM private.assert_promo_usable(v_promo, v_uid, v_job.agreed_amount_minor, v_job.currency);
    v_discount := private.promo_discount_minor(v_promo, v_job.agreed_amount_minor);

    INSERT INTO public.promo_redemptions (promo_id, user_id, request_id, discount_minor, currency)
    VALUES (v_promo.id, v_uid, p_request_id, v_discount, v_job.currency);
    UPDATE public.promo_codes p SET spent_minor = p.spent_minor + v_discount
    WHERE p.id = v_promo.id;
  END IF;

  -- OD-04: the goods money is prepaid as its own line, and the customer covers the gateway's fee
  -- on it so the provider is reimbursed exactly what they spend. The rate is an estimate — the
  -- only one in the money path, and it is config rather than a literal for that reason.
  v_float := coalesce(v_request.item_float_minor, 0);
  IF v_float > 0 THEN
    v_surcharge := private.apply_bps(v_float,
      coalesce(private.remote_config_int('item_float_fee_surcharge_bps'), 300));
  END IF;

  v_jobamount := v_job.agreed_amount_minor - v_discount;
  v_charge := v_jobamount + v_float + v_surcharge;
  v_ttl := coalesce(private.remote_config_int('payment_ttl_minutes'), 30);
  INSERT INTO public.payments (request_id, payer_id, method, amount_minor, currency, expires_at,
                               kind, discount_minor, job_amount_minor, float_minor,
                               float_surcharge_minor)
  VALUES (p_request_id, v_uid, p_method, v_charge, v_job.currency,
          now() + make_interval(mins => v_ttl), 'job', v_discount, v_jobamount, v_float,
          v_surcharge)
  RETURNING id INTO v_id;

  IF v_request.status = 'agreed' THEN
    PERFORM private.job_transition(p_request_id, 'agreed', 'payment_pending', v_uid, 'customer',
      NULL, p_idempotency_key);
  END IF;

  PERFORM private.emit_event('payment', v_id::text, 'payment.requested',
    jsonb_build_object('payment_id', v_id, 'request_id', p_request_id, 'payer_id', v_uid,
                       'amount_minor', v_charge, 'currency', v_job.currency,
                       'discount_minor', v_discount, 'float_minor', v_float,
                       'float_surcharge_minor', v_surcharge, 'kind', 'job',
                       'method', p_method, 'country_code', v_request.country_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payment_id', v_id, 'amount_minor', v_charge,
                       'currency', v_job.currency, 'status', 'pending'));

  RETURN QUERY SELECT v_id, v_charge, v_job.currency, 'pending'::public.payment_status;
END $$;

-- ---------------------------------------------------------------------------
-- confirm_payment, replaced whole: posting 3a splits the charge into held funds and float, and
-- only the part of the fee the surcharge did not cover is a fee to recover.
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

  -- The surcharge the customer paid covers the float's share of the fee, so only the remainder
  -- is a cost to recover from the provider. It can go negative if the surcharge over-collected,
  -- and that is left visible rather than clamped: a rate that is consistently too high should be
  -- corrected in config, not hidden by arithmetic.
  v_jobfee := v_fee - v_payment.float_surcharge_minor;
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

-- ---------------------------------------------------------------------------
-- recognise_earnings, replaced whole: it releases the job's hold, which is no longer the whole
-- charge. money-flows 3c.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.recognise_earnings(p_request_id uuid)
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
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.commission_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'the money was never snapshotted on this job';
  END IF;
  -- A float still waiting on a receipt is somebody's money sitting in the wrong place. Settling
  -- the job around it would leave `item_float` holding a balance nobody is watching.
  IF v_payment.float_minor > 0 AND v_job.item_float_approved_at IS NULL THEN
    RAISE EXCEPTION 'ERR_ITEM_FLOAT_PENDING' USING ERRCODE = 'P0001';
  END IF;

  v_fee := coalesce(v_job.actual_gateway_fee_minor, 0);
  v_net := v_job.net_minor - v_fee;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.job_amount_minor),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', -v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', -v_net));
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', -v_fee));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', v_payment.discount_minor));
  END IF;

  PERFORM private.job_transition(p_request_id, 'confirmed', 'settlement_pending', NULL, 'system');
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.earnings.released.title', 'notification.earnings.released.body',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', v_net,
                       'currency', v_job.currency), '/earnings');

  RETURN ledger.post('earnings_recognised', v_job.currency,
    'earnings:' || p_request_id::text, v_entries, p_request_id, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- cancel_job, replaced whole: an unspent float goes back to the customer untouched by any fee,
-- because it was never the platform's or the provider's money.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_job(
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
  IF v_request.status NOT IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                              'completed_by_provider') THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_CANCELLABLE' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- A float already released is money the provider has spent in a shop. Unwinding that is a
  -- dispute, not a cancellation.
  IF v_job.item_float_approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_CANCELLABLE' USING ERRCODE = 'P0001',
      DETAIL = 'the item float has already been released';
  END IF;

  -- The fee is on the job price, never on the goods money.
  v_fee := private.cancellation_fee_minor(v_payment.job_amount_minor, v_request.status,
                                          v_provider);
  v_gwfee := CASE WHEN v_fee > 0 THEN coalesce(v_job.actual_gateway_fee_minor, 0) ELSE 0 END;
  v_refund := v_payment.job_amount_minor + v_payment.float_minor - v_fee - v_gwfee;
  IF v_refund <= 0 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the fee would consume the whole payment';
  END IF;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.job_amount_minor),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                       'amount_minor', -v_refund));
  IF v_payment.float_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'item_float',
                         'amount_minor', v_payment.float_minor));
  END IF;
  IF v_fee > 0 THEN
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

  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notification.job.cancelled.title', 'notification.job.cancelled.body',
    jsonb_build_object('request_id', p_request_id, 'refund_minor', v_refund,
                       'fee_minor', v_fee, 'currency', v_payment.currency,
                       'by_provider', v_provider), '/requests/' || p_request_id::text);
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.job.cancelled.title', 'notification.job.cancelled.body',
    jsonb_build_object('request_id', p_request_id,
                       'compensation_minor', v_fee - coalesce(v_comm, 0),
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

REVOKE ALL ON FUNCTION
  public.submit_float_receipt(text, uuid, bigint, text),
  public.approve_float_receipt(text, uuid),
  private.release_item_float(uuid, uuid),
  private.auto_approve_float_receipts(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.submit_float_receipt(text, uuid, bigint, text),
  public.approve_float_receipt(text, uuid)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- The float's share of the gateway's fee, which the customer pays so the provider is reimbursed
  -- exactly what they spend (OD-04). An estimate, and the only one in the money path.
  ('item_float_fee_surcharge_bps', NULL, '300', true),
  ('float_auto_approve_hours', NULL, '24', true)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('float-auto-approve', '37 * * * *',
      $cron$SELECT private.auto_approve_float_receipts()$cron$);
  END IF;
END $$;
