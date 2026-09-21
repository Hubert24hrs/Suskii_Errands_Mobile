-- Phase 5, part 4: promo codes and tips (spec phase 5, "Promo codes and tips"; ERD §6;
-- `docs/plan/money-flows.md` postings 2, 4a and 4b).
--
-- **A promo never reduces provider earnings.** The spec says so and posting 4b encodes it: the
-- customer pays less, the platform books the difference as `platform_promo_expense`, and
-- commission is still taken on the full negotiated price. A discount is the platform buying the
-- customer's business, not the provider being asked to work for less.
--
-- **A tip carries no commission** (spec). The gateway's fee on the tip charge still comes out of
-- it, the same way it does on the job — the platform does not profit from a tip, and it does not
-- subsidise one either.
--
-- **Budgets are transactional.** `spent_minor` moves under a row lock inside the same transaction
-- as the redemption, because a promo budget that can be exceeded by two people clicking at once
-- is not a budget.

CREATE TYPE public.discount_kind AS ENUM ('fixed', 'percent');

CREATE TABLE public.promo_codes (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                 text NOT NULL CHECK (code ~ '^[A-Z0-9_-]{4,24}$'),
  country_code         char(2) NOT NULL REFERENCES public.countries (code),
  currency             char(3) NOT NULL REFERENCES public.currencies (code),
  discount_kind        public.discount_kind NOT NULL,
  -- Minor units for `fixed`, basis points for `percent`. One column, because a promo is one or
  -- the other and two nullable columns would let it be neither.
  discount_value       bigint NOT NULL CHECK (discount_value > 0),
  max_discount_minor   bigint CHECK (max_discount_minor IS NULL OR max_discount_minor > 0),
  budget_minor         bigint CHECK (budget_minor IS NULL OR budget_minor > 0),
  spent_minor          bigint NOT NULL DEFAULT 0 CHECK (spent_minor >= 0),
  max_uses             integer CHECK (max_uses IS NULL OR max_uses > 0),
  per_user_limit       smallint NOT NULL DEFAULT 1 CHECK (per_user_limit > 0),
  stacks_with_referral boolean NOT NULL DEFAULT false,
  starts_at            timestamptz NOT NULL DEFAULT now(),
  ends_at              timestamptz,
  active               boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (country_code, code),
  CONSTRAINT promo_percent_is_bps CHECK (
    discount_kind <> 'percent' OR discount_value BETWEEN 1 AND 10000)
);
CREATE INDEX promo_codes_live ON public.promo_codes (country_code, code) WHERE active;

ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_codes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.promo_codes FROM anon, authenticated;
GRANT ALL ON public.promo_codes TO service_role;
-- A code is meant to be typed, so knowing one exists is not a secret. The budget is: a customer
-- who could read `spent_minor` or `max_uses` would know exactly when to hurry, so those columns
-- are not granted at all.
GRANT SELECT (id, code, country_code, currency, discount_kind, discount_value,
              max_discount_minor, stacks_with_referral, starts_at, ends_at, active)
  ON public.promo_codes TO authenticated;
CREATE POLICY promo_codes_read ON public.promo_codes FOR SELECT TO authenticated
  USING (active AND starts_at <= now() AND (ends_at IS NULL OR ends_at > now()));

CREATE TABLE public.promo_redemptions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_id       uuid NOT NULL REFERENCES public.promo_codes (id) ON DELETE RESTRICT,
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  request_id     uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  discount_minor bigint NOT NULL CHECK (discount_minor > 0),
  currency       char(3) NOT NULL REFERENCES public.currencies (code),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (promo_id, request_id)
);
CREATE INDEX promo_redemptions_user ON public.promo_redemptions (promo_id, user_id);

ALTER TABLE public.promo_redemptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_redemptions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.promo_redemptions FROM anon, authenticated;
GRANT SELECT ON public.promo_redemptions TO authenticated;
GRANT ALL ON public.promo_redemptions TO service_role;
CREATE POLICY promo_redemptions_read_own ON public.promo_redemptions FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

CREATE TABLE public.tips (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id   uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  customer_id  uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  provider_id  uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  payment_id   uuid NOT NULL REFERENCES public.payments (id) ON DELETE RESTRICT,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  currency     char(3) NOT NULL REFERENCES public.currencies (code),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tips_request ON public.tips (request_id);
CREATE INDEX tips_provider ON public.tips (provider_id, created_at DESC);

ALTER TABLE public.tips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tips FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.tips FROM anon, authenticated;
GRANT SELECT ON public.tips TO authenticated;
GRANT ALL ON public.tips TO service_role;
CREATE POLICY tips_read ON public.tips FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(tips.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- A payment is now a job payment or a tip. They are the same kind of thing to a gateway and
-- want the same webhook path, so they share a table rather than duplicating one.
-- ---------------------------------------------------------------------------
ALTER TABLE public.payments
  ADD COLUMN kind text NOT NULL DEFAULT 'job' CHECK (kind IN ('job', 'tip')),
  ADD COLUMN discount_minor bigint NOT NULL DEFAULT 0 CHECK (discount_minor >= 0);

DROP INDEX public.payments_one_live;
-- Still one job payment in flight per request; a tip is a separate charge and may coexist.
CREATE UNIQUE INDEX payments_one_live ON public.payments (request_id)
  WHERE kind = 'job' AND status IN ('pending', 'held');

-- ---------------------------------------------------------------------------
-- What a code is worth on a given amount. A function, so the preview a customer sees and the
-- discount they actually get are the same arithmetic.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.promo_discount_minor(p_promo public.promo_codes, p_gross_minor bigint)
RETURNS bigint
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_discount bigint;
BEGIN
  v_discount := CASE p_promo.discount_kind
                  WHEN 'fixed' THEN p_promo.discount_value
                  ELSE private.apply_bps(p_gross_minor, p_promo.discount_value::integer)
                END;
  IF p_promo.max_discount_minor IS NOT NULL THEN
    v_discount := least(v_discount, p_promo.max_discount_minor);
  END IF;
  -- Never more than the job costs: a promo cannot make the platform owe the customer money.
  RETURN greatest(least(v_discount, p_gross_minor - 1), 0);
END $$;

-- The check every path shares. Raises rather than returning false, because every caller wants to
-- tell the customer *which* reason.
CREATE FUNCTION private.assert_promo_usable(
  p_promo public.promo_codes, p_user uuid, p_gross_minor bigint, p_currency char(3))
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT p_promo.active
     OR p_promo.starts_at > now()
     OR (p_promo.ends_at IS NOT NULL AND p_promo.ends_at <= now())
     OR p_promo.currency <> p_currency THEN
    RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001';
  END IF;
  IF p_promo.max_uses IS NOT NULL
     AND (SELECT count(*) FROM public.promo_redemptions r WHERE r.promo_id = p_promo.id)
         >= p_promo.max_uses THEN
    RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001', DETAIL = 'exhausted';
  END IF;
  IF (SELECT count(*) FROM public.promo_redemptions r
      WHERE r.promo_id = p_promo.id AND r.user_id = p_user) >= p_promo.per_user_limit THEN
    RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001', DETAIL = 'already_used';
  END IF;
  IF p_promo.budget_minor IS NOT NULL
     AND p_promo.spent_minor + private.promo_discount_minor(p_promo, p_gross_minor)
         > p_promo.budget_minor THEN
    RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001', DETAIL = 'budget_exhausted';
  END IF;
END $$;

-- What the app shows before the customer commits to anything.
CREATE FUNCTION public.preview_promo(p_code text, p_request_id uuid)
RETURNS TABLE (discount_minor bigint, currency char(3), stacks_with_referral boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_promo   public.promo_codes%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_promo FROM public.promo_codes p
  WHERE p.country_code = v_request.country_code AND p.code = upper(btrim(coalesce(p_code, '')));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROMO_INVALID' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.assert_promo_usable(v_promo, v_uid, v_job.agreed_amount_minor, v_job.currency);

  RETURN QUERY SELECT private.promo_discount_minor(v_promo, v_job.agreed_amount_minor),
                      v_job.currency, v_promo.stacks_with_referral;
END $$;

-- ---------------------------------------------------------------------------
-- start_payment, replaced whole to carry a promo code. Everything else about it is unchanged.
--
-- Dropped and recreated rather than `CREATE OR REPLACE`d: a fourth parameter is a different
-- signature, so replacing would leave two overloads, and `start_payment(key, request_id)` would
-- then be ambiguous rather than defaulting.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.start_payment(text, uuid, text);

CREATE FUNCTION public.start_payment(
  p_idempotency_key text, p_request_id uuid, p_method text DEFAULT NULL,
  p_promo_code text DEFAULT NULL)
RETURNS TABLE (payment_id uuid, amount_minor bigint, currency char(3),
               status public.payment_status)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_request  public.requests%ROWTYPE;
  v_job      public.jobs%ROWTYPE;
  v_promo    public.promo_codes%ROWTYPE;
  v_discount bigint := 0;
  v_charge   bigint;
  v_rate     integer;
  v_ttl      integer;
  v_id       uuid;
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
    -- Locked: the budget check and the spend have to be one decision, or two customers can each
    -- see room for the last discount.
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

  v_charge := v_job.agreed_amount_minor - v_discount;
  v_ttl := coalesce(private.remote_config_int('payment_ttl_minutes'), 30);
  INSERT INTO public.payments (request_id, payer_id, method, amount_minor, currency, expires_at,
                               kind, discount_minor)
  VALUES (p_request_id, v_uid, p_method, v_charge, v_job.currency,
          now() + make_interval(mins => v_ttl), 'job', v_discount)
  RETURNING id INTO v_id;

  IF v_request.status = 'agreed' THEN
    PERFORM private.job_transition(p_request_id, 'agreed', 'payment_pending', v_uid, 'customer',
      NULL, p_idempotency_key);
  END IF;

  PERFORM private.emit_event('payment', v_id::text, 'payment.requested',
    jsonb_build_object('payment_id', v_id, 'request_id', p_request_id, 'payer_id', v_uid,
                       'amount_minor', v_charge, 'currency', v_job.currency,
                       'discount_minor', v_discount, 'kind', 'job',
                       'method', p_method, 'country_code', v_request.country_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payment_id', v_id, 'amount_minor', v_charge,
                       'currency', v_job.currency, 'status', 'pending'));

  RETURN QUERY SELECT v_id, v_charge, v_job.currency, 'pending'::public.payment_status;
END $$;

-- ---------------------------------------------------------------------------
-- Tips. A separate charge, after the work, and commission-free.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.add_tip(
  p_idempotency_key text, p_request_id uuid, p_amount_minor bigint)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_ttl     integer;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'add_tip',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', p_amount_minor));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'payment_id')::uuid;
  END IF;

  IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_request FROM public.requests r
  WHERE r.id = p_request_id AND r.customer_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- A tip is for work that happened. Offering one mid-job would look like a price negotiation
  -- conducted outside the offer, which is the thing the marketplace exists to prevent.
  IF v_request.status NOT IN ('completed_by_provider', 'confirmed', 'settlement_pending',
                              'settled', 'closed') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_ttl := coalesce(private.remote_config_int('payment_ttl_minutes'), 30);
  INSERT INTO public.payments (request_id, payer_id, amount_minor, currency, expires_at, kind)
  VALUES (p_request_id, v_uid, p_amount_minor, v_job.currency,
          now() + make_interval(mins => v_ttl), 'tip')
  RETURNING id INTO v_id;

  INSERT INTO public.tips (request_id, customer_id, provider_id, payment_id, amount_minor,
                           currency)
  VALUES (p_request_id, v_uid, v_job.provider_id, v_id, p_amount_minor, v_job.currency);

  PERFORM private.emit_event('payment', v_id::text, 'payment.requested',
    jsonb_build_object('payment_id', v_id, 'request_id', p_request_id, 'payer_id', v_uid,
                       'amount_minor', p_amount_minor, 'currency', v_job.currency,
                       'kind', 'tip', 'country_code', v_request.country_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payment_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- confirm_payment, replaced whole: a tip posts money-flows 2 and moves no job state.
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
    -- Posting 2. The fee is charged and recovered in the same breath: no commission on a tip,
    -- and the platform does not subsidise one either.
    v_entries := jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                         'amount_minor', p_amount_minor - v_fee),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                         'account_type', 'provider_earnings',
                         'amount_minor', -(p_amount_minor - v_fee)));
    IF v_fee > 0 THEN
      -- Charged and recovered in the same breath, exactly as money-flows 2 sets it out. The two
      -- lines net to zero on one account; they are both here so the gross fee appears in the
      -- turnover a finance report reads, instead of vanishing into a smaller number.
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
    -- A tip changes no job state; the work was already over.
    RETURN (SELECT r.status FROM public.requests r WHERE r.id = v_payment.request_id);
  END IF;

  UPDATE public.jobs j SET actual_gateway_fee_minor = v_fee
  WHERE j.request_id = v_payment.request_id;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', p_amount_minor - v_fee),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', -p_amount_minor));
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_fee));
  END IF;
  PERFORM ledger.post('payment_captured', v_payment.currency,
    'payment:' || v_payment.id::text, v_entries, v_payment.request_id, NULL);

  PERFORM private.emit_event('payment', v_payment.id::text, 'payment.held',
    jsonb_build_object('payment_id', v_payment.id, 'request_id', v_payment.request_id,
                       'amount_minor', p_amount_minor, 'fee_minor', v_fee));
  RETURN private.mark_paid_held(v_payment.request_id);
END $$;

-- ---------------------------------------------------------------------------
-- recognise_earnings, replaced whole: posting 4b, where the platform funds the discount and the
-- provider is made whole on the price they actually negotiated.
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

  v_fee := coalesce(v_job.actual_gateway_fee_minor, 0);
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
  IF v_payment.discount_minor > 0 THEN
    -- 4b: commission was taken on the full price and the provider is paid on the full price, so
    -- the discount is the platform's own expense. A promo never reduces provider earnings (spec).
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

REVOKE ALL ON FUNCTION
  public.preview_promo(text, uuid),
  public.add_tip(text, uuid, bigint),
  public.start_payment(text, uuid, text, text),
  private.promo_discount_minor(public.promo_codes, bigint),
  private.assert_promo_usable(public.promo_codes, uuid, bigint, char)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.preview_promo(text, uuid),
  public.add_tip(text, uuid, bigint),
  public.start_payment(text, uuid, text, text)
  TO authenticated;
