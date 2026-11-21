-- Direct payment: a country can open before a payment gateway exists (owner, 2026-11-21;
-- ADR-0025). The customer confirms the hire instead of paying, and pays the provider in cash or by
-- transfer when the errand is done. The platform holds nothing, so everything in the app that
-- moves money refuses in such a country.
--
-- One place for each rule:
--   * `countries.config.client.payment_mode` is 'in_app' (also what its absence means) or
--     'direct'. It sits under `client` because the app chooses between Pay and Confirm hire on it.
--   * `jobs.direct_payment` is written once, at hire, and every later step reads it rather than
--     the country: a job keeps the terms it was agreed under if the country changes mode mid-job.
--   * `confirm_hire` is transition 32 (agreed → assigned). It shares `private.do_assign_job` with
--     the paid path, so assignment's effects — the PINs, and `assigned_at`, which opens the
--     address and the chat — cannot drift apart between the two.
--   * a direct job closes once the chat window after confirmation has passed (transition 33), so
--     the two sides can still talk about the money after the work is done.
--   * payments and disputes refuse at the table, so `start_payment`, tips, float top-ups and
--     `open_dispute` all refuse without each having to remember.
--   * shopping: `requests.item_float_minor` is the cap the customer sets on the goods. The
--     provider records what the goods cost (`record_goods_receipt`), at most the cap, before
--     marking the job done, and the customer repays that with the agreed price. These are new
--     columns rather than the in-app float's, whose hourly release sweep would otherwise trip on
--     every direct job.
--   * `country_pack_gaps` asks for payment and payout providers only in an in-app country, and
--     for an SMS provider only where phone sign-in is offered (`config.client.sign_in_methods`).
--   * Nigeria opens in direct mode with email and Google sign-in (owner, 2026-11-21). The dev seed
--     rewrites every country's config, so local and CI databases stay in-app unless a test says
--     otherwise.

ALTER TABLE public.countries
  ADD CONSTRAINT countries_payment_mode CHECK (
    config -> 'client' -> 'payment_mode' IS NULL
    OR config -> 'client' ->> 'payment_mode' IN ('in_app', 'direct')),
  ADD CONSTRAINT countries_sign_in_methods CHECK (
    config -> 'client' -> 'sign_in_methods' IS NULL
    OR (jsonb_typeof(config -> 'client' -> 'sign_in_methods') = 'array'
        AND jsonb_array_length(config -> 'client' -> 'sign_in_methods') > 0
        AND config -> 'client' -> 'sign_in_methods'
            <@ '["phone", "email", "google", "apple"]'::jsonb));

ALTER TABLE public.jobs
  ADD COLUMN direct_payment     boolean NOT NULL DEFAULT false,
  ADD COLUMN goods_spent_minor  bigint CHECK (goods_spent_minor IS NULL OR goods_spent_minor >= 0),
  ADD COLUMN goods_receipt_path text CHECK (goods_receipt_path IS NULL
                                            OR length(goods_receipt_path) <= 512),
  ADD COLUMN goods_recorded_at  timestamptz;
CREATE INDEX jobs_direct_confirmed ON public.jobs (confirmed_at) WHERE direct_payment;

CREATE FUNCTION private.country_payment_mode(p_code char(2))
RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce((SELECT c.config -> 'client' ->> 'payment_mode'
                   FROM public.countries c WHERE c.code = p_code), 'in_app');
$$;

-- ---------------------------------------------------------------------------
-- Assignment, shared by the paid path (transition 11) and the direct hire (transition 32).
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.do_assign_job(
  p_request_id uuid,
  p_from public.job_status,
  p_worker_id uuid,
  p_actor_id uuid,
  p_actor_kind public.job_actor_kind,
  p_idempotency_key text DEFAULT NULL
)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job public.jobs%ROWTYPE;
BEGIN
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

  PERFORM private.job_transition(p_request_id, p_from, 'assigned',
    coalesce(p_actor_id, p_worker_id, v_job.provider_id), p_actor_kind, NULL, p_idempotency_key);
  RETURN 'assigned'::public.job_status;
END $$;

CREATE OR REPLACE FUNCTION private.assign_job(p_request_id uuid, p_worker_id uuid DEFAULT NULL)
RETURNS public.job_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_status public.job_status;
BEGIN
  SELECT r.status INTO v_status FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF v_status <> 'paid_held' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  RETURN private.do_assign_job(p_request_id, 'paid_held', p_worker_id, NULL, 'system');
END $$;

-- ---------------------------------------------------------------------------
-- confirm_hire — the customer commits to the provider in a direct-payment country. Nothing is
-- charged; the provider gets the address, the chat and the call from here, which is why only
-- the customer can make this happen (address harvesting, R-05).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.confirm_hire(p_idempotency_key text, p_request_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'confirm_hire',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_request FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status <> 'agreed' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF private.country_payment_mode(v_request.country_code) <> 'direct' THEN
    RAISE EXCEPTION 'ERR_PAYMENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.jobs j SET direct_payment = true WHERE j.request_id = p_request_id;
  PERFORM private.do_assign_job(p_request_id, 'agreed', NULL, v_uid, 'customer',
    p_idempotency_key);

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'assigned'));
  RETURN 'assigned'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- close_direct_jobs — transition 33. A direct job has no settlement to wait for; it waits only
-- for the chat window after confirmation, the same window `chat_is_open` uses.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.close_direct_jobs(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_hours integer := coalesce(private.remote_config_int('chat_window_hours_after_confirm'), 24);
  v_id    uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT r.id FROM public.requests r
    JOIN public.jobs j ON j.request_id = r.id
    WHERE j.direct_payment
      AND r.status = 'confirmed'
      AND j.confirmed_at <= now() - make_interval(hours => v_hours)
    ORDER BY j.confirmed_at
    LIMIT least(greatest(coalesce(p_limit, 500), 1), 1000)
    FOR UPDATE OF r SKIP LOCKED
  LOOP
    PERFORM private.job_transition(v_id, 'confirmed', 'closed', NULL, 'system', 'direct_payment');
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Money refuses at the table. A trigger rather than a check in each function, so the next
-- function that creates a payment refuses too without anybody remembering to make it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.refuse_payment_when_direct()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (
       SELECT 1 FROM public.requests r
       LEFT JOIN public.jobs j ON j.request_id = r.id
       WHERE r.id = NEW.request_id
         AND (coalesce(j.direct_payment, false)
              OR private.country_payment_mode(r.country_code) = 'direct')) THEN
    RAISE EXCEPTION 'ERR_DIRECT_PAYMENT_ONLY' USING ERRCODE = 'P0001',
      DETAIL = 'customers pay providers directly here; nothing is paid through the app';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER payments_refuse_direct BEFORE INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION private.refuse_payment_when_direct();

CREATE FUNCTION private.refuse_dispute_when_direct()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.jobs j
             WHERE j.request_id = NEW.request_id AND j.direct_payment) THEN
    RAISE EXCEPTION 'ERR_DIRECT_PAYMENT_ONLY' USING ERRCODE = 'P0001',
      DETAIL = 'there is no held money to decide on; a complaint goes to support';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER disputes_refuse_direct BEFORE INSERT ON public.disputes
  FOR EACH ROW EXECUTE FUNCTION private.refuse_dispute_when_direct();

-- ---------------------------------------------------------------------------
-- record_goods_receipt — on a direct job with a goods cap, the provider says what the goods
-- cost before marking the job done, so the customer knows what to repay on delivery. Nothing
-- bought is an answer too, and needs no receipt.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.record_goods_receipt(
  p_idempotency_key text, p_request_id uuid, p_spent_minor bigint, p_storage_path text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_result  jsonb;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'record_goods_receipt',
    jsonb_build_object('request_id', p_request_id, 'spent_minor', p_spent_minor,
                       'path', p_storage_path));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF v_job.request_id IS NULL
     OR v_uid NOT IN (v_job.provider_id, coalesce(v_job.worker_id, v_job.provider_id)) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_job.direct_payment THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'a job paid in the app files its receipt with submit_float_receipt';
  END IF;
  IF v_request.item_float_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_NO_ITEM_FLOAT' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status <> 'in_progress' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF p_spent_minor IS NULL OR p_spent_minor < 0 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_spent_minor > v_request.item_float_minor THEN
    RAISE EXCEPTION 'ERR_GOODS_OVER_CAP' USING ERRCODE = 'P0001',
      DETAIL = format('the customer agreed to at most %s', v_request.item_float_minor);
  END IF;
  IF p_spent_minor > 0
     AND (p_storage_path IS NULL OR p_storage_path NOT LIKE (p_request_id::text || '/%')) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the receipt belongs under this job''s own folder';
  END IF;

  UPDATE public.jobs j
  SET goods_spent_minor = p_spent_minor,
      goods_receipt_path = CASE WHEN p_spent_minor > 0 THEN p_storage_path END,
      goods_recorded_at = now()
  WHERE j.request_id = p_request_id;

  INSERT INTO public.job_events (request_id, from_status, to_status, actor_id, actor_kind,
                                 reason_code, idempotency_key, payload)
  VALUES (p_request_id, v_request.status, v_request.status, v_uid, 'provider', 'goods_receipt',
          p_idempotency_key,
          jsonb_build_object('spent_minor', p_spent_minor, 'currency', v_request.currency));

  v_result := jsonb_build_object(
    'spent_minor', p_spent_minor,
    'cap_minor', v_request.item_float_minor,
    'agreed_minor', v_job.agreed_amount_minor,
    'total_due_minor', v_job.agreed_amount_minor + p_spent_minor,
    'currency', v_request.currency);

  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notifGoodsReceiptTitle', 'notifGoodsReceiptBody',
    jsonb_build_object('request_id', p_request_id) || v_result,
    '/requests/' || p_request_id::text);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- The provider cannot say the job is done before saying what the goods cost.
CREATE FUNCTION private.requests_require_goods_receipt()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.item_float_minor IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.jobs j
       WHERE j.request_id = NEW.id AND j.direct_payment AND j.goods_recorded_at IS NULL) THEN
    RAISE EXCEPTION 'ERR_PROOF_REQUIRED' USING ERRCODE = 'P0001', DETAIL = 'goods_receipt';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER requests_require_goods_receipt BEFORE UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status = 'completed_by_provider' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.requests_require_goods_receipt();

-- ---------------------------------------------------------------------------
-- cancel_job, replaced whole: a direct job holds no money, so cancelling it refunds nothing and
-- charges nothing. Once the provider says the work is done it is no longer cancellable: what
-- is left is paying for it, or a complaint to support. The in-app path is unchanged.
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

  IF v_job.direct_payment THEN
    IF v_request.status NOT IN ('assigned', 'en_route', 'arrived', 'in_progress') THEN
      RAISE EXCEPTION 'ERR_JOB_NOT_CANCELLABLE' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.requests r
    SET cancelled_at = now(), cancellation_reason_code = p_reason_code
    WHERE r.id = p_request_id;
    PERFORM private.job_transition(p_request_id, v_request.status, 'cancelled', v_uid,
      CASE WHEN v_provider THEN 'provider' ELSE 'customer' END::public.job_actor_kind,
      p_reason_code, p_idempotency_key, jsonb_build_object('direct_payment', true));
    PERFORM private.notify(v_request.customer_id, 'job_status',
      'notification.job.cancelled.title', 'notification.job.cancelled.body',
      jsonb_build_object('request_id', p_request_id, 'by_provider', v_provider,
                         'direct_payment', true), '/requests/' || p_request_id::text);
    PERFORM private.notify(v_job.provider_id, 'job_status',
      'notification.job.cancelled.title', 'notification.job.cancelled.body',
      jsonb_build_object('request_id', p_request_id, 'by_provider', v_provider,
                         'direct_payment', true), '/jobs/' || p_request_id::text);
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('refund_minor', 0, 'fee_minor', 0, 'currency', v_request.currency));
    RETURN QUERY SELECT 0::bigint, 0::bigint, v_request.currency;
    RETURN;
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
  -- No `RETURNING`: the id was only ever wanted for the emit, and the trigger reads it off NEW.
  VALUES (v_payment.id, p_request_id, v_refund, v_payment.currency, p_reason_code, v_uid);

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

  -- The `refund.requested` event belongs to the table now, not to this function.
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('refund_minor', v_refund, 'fee_minor', v_fee,
                       'currency', v_payment.currency));

  RETURN QUERY SELECT v_refund, v_fee, v_payment.currency;
END $$;

-- ---------------------------------------------------------------------------
-- country_pack_gaps, replaced whole. A direct-payment country needs no payment or payout
-- provider, and a country that offers no phone sign-in needs no SMS provider. Everything else
-- is unchanged, including the refusal of a console-only payment route in an in-app country.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.country_pack_gaps(p_code char(2))
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(array_agg(gap ORDER BY gap), '{}'::text[])
  FROM (
    SELECT 'cities' AS gap WHERE NOT EXISTS (
      SELECT 1 FROM public.cities c WHERE c.country_code = p_code)
    UNION ALL
    SELECT 'legal.terms' WHERE NOT EXISTS (
      SELECT 1 FROM public.legal_documents d
      WHERE d.country_code = p_code AND d.type = 'terms'
        AND d.published_at IS NOT NULL AND d.published_at <= now())
    UNION ALL
    SELECT 'legal.privacy' WHERE NOT EXISTS (
      SELECT 1 FROM public.legal_documents d
      WHERE d.country_code = p_code AND d.type = 'privacy'
        AND d.published_at IS NOT NULL AND d.published_at <= now())
    UNION ALL
    SELECT 'config.client.accepted_id_types' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND jsonb_array_length(coalesce(c.config -> 'client' -> 'accepted_id_types',
                                        '[]'::jsonb)) > 0)
    UNION ALL
    SELECT 'config.server.sms_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND (NOT coalesce(c.config -> 'client' -> 'sign_in_methods' ? 'phone', true)
             OR jsonb_array_length(coalesce(c.config -> 'server' -> 'sms_providers',
                                            '[]'::jsonb)) > 0))
    UNION ALL
    SELECT 'config.server.payment_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND (c.config -> 'client' ->> 'payment_mode' = 'direct'
             OR jsonb_array_length(coalesce(c.config -> 'server' -> 'payment_providers',
                                            '[]'::jsonb)) > 0))
    UNION ALL
    SELECT 'config.server.payout_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND (c.config -> 'client' ->> 'payment_mode' = 'direct'
             OR jsonb_array_length(coalesce(c.config -> 'server' -> 'payout_providers',
                                            '[]'::jsonb)) > 0))
    UNION ALL
    -- A live country whose only payment provider is the development one would report a customer
    -- paid when nobody did. The Edge Function refuses it too; refusing it here means nobody has
    -- to find out that way.
    SELECT 'config.server.payment_providers.console_only' WHERE EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND coalesce(c.config -> 'client' ->> 'payment_mode', 'in_app') <> 'direct'
        AND coalesce(c.config -> 'server' -> 'payment_providers', '[]'::jsonb) = '["console"]'::jsonb)
  ) gaps;
$$;

-- ---------------------------------------------------------------------------
-- Nigeria opens in direct mode, signing in by email and Google (owner, 2026-11-21). Only where
-- nobody has chosen a mode yet, so a later approved change is never undone by a replay.
-- ---------------------------------------------------------------------------
UPDATE public.countries c
SET config = jsonb_set(c.config, '{client}',
               coalesce(c.config -> 'client', '{}'::jsonb)
               || '{"payment_mode": "direct", "sign_in_methods": ["email", "google"]}'::jsonb)
WHERE c.code = 'NG'
  AND NOT coalesce(c.config -> 'client' ? 'payment_mode', false);

REVOKE ALL ON FUNCTION
  public.confirm_hire(text, uuid),
  public.record_goods_receipt(text, uuid, bigint, text),
  private.country_payment_mode(char),
  private.do_assign_job(uuid, public.job_status, uuid, uuid, public.job_actor_kind, text),
  private.close_direct_jobs(integer),
  private.refuse_payment_when_direct(),
  private.refuse_dispute_when_direct(),
  private.requests_require_goods_receipt()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.confirm_hire(text, uuid),
  public.record_goods_receipt(text, uuid, bigint, text)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('direct-jobs-close', '23 * * * *',
      $cron$SELECT private.close_direct_jobs()$cron$);
  END IF;
END $$;
