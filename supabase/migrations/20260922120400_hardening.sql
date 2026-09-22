-- Phase 9, part 1: what the audit of 2026-09-22 found (`docs/audit/AUDIT-2026-09-22.md`).
--
-- Five defects, four of them in money and two of them the kind that stay invisible until the day
-- they are not. Each fix is below, in the order of the findings.

-- ---------------------------------------------------------------------------
-- T.1 - `webhook_events` partitions were created once and never again.
--
-- Every other partitioned table has a pg_cron job keeping its partitions ahead: `audit.log`,
-- `job_events`, `messages`, `notifications`. `webhook_events` was given three months at
-- migration time and no job, so roughly three months after a deploy the first gateway webhook to
-- arrive would find no partition, `ingest_webhook` would raise, the Edge Function would answer
-- 500, and **every payment would stop being confirmed** - while every other check stayed green.
--
-- Two fixes, because the missing job is only the symptom. The job itself, and a check that looks
-- at every partitioned table rather than at `audit.log` alone, so that the next one somebody
-- forgets is found by a machine rather than by an audit.
-- ---------------------------------------------------------------------------
SELECT private.ensure_monthly_partitions('public.webhook_events'::regclass, 3);

CREATE FUNCTION private.partition_health()
RETURNS TABLE (parent text, months_ahead integer)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT n.nspname || '.' || c.relname,
         (SELECT count(*)::integer
          FROM pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class p ON p.oid = i.inhrelid
          WHERE i.inhparent = c.oid
            -- Partitions are named `<parent>_yYYYYmMM`, so the name sorts by date.
            AND p.relname >= format('%s_y%sm%s', c.relname,
                                    to_char(now() + interval '1 month', 'YYYY'),
                                    to_char(now() + interval '1 month', 'MM')))
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'p' AND n.nspname IN ('public', 'private', 'audit')
  ORDER BY 1;
$$;

CREATE FUNCTION private.record_partition_health()
RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_bad    integer;
  v_thin   integer;
  v_status text;
BEGIN
  SELECT count(*) FILTER (WHERE ph.months_ahead = 0),
         count(*) FILTER (WHERE ph.months_ahead = 1)
  INTO v_bad, v_thin
  FROM private.partition_health() ph;
  v_status := CASE WHEN v_bad > 0 THEN 'fail' WHEN v_thin > 0 THEN 'warn' ELSE 'ok' END;
  PERFORM private.record_health_check('partitions', v_status,
    jsonb_build_object('no_next_month', v_bad, 'one_month_only', v_thin,
                       'tables', (SELECT jsonb_object_agg(ph2.parent, ph2.months_ahead)
                                  FROM private.partition_health() ph2)));
  RETURN v_status;
END $$;

REVOKE ALL ON FUNCTION private.partition_health(), private.record_partition_health()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.partition_health() TO service_role;

-- ---------------------------------------------------------------------------
-- T.2 - a refund was created and nobody was ever asked to pay it.
--
-- `execute_refund` and `fail_refund` have been the gateway seam since Phase 5 part 3, and the
-- event that reaches them was emitted by exactly one of the three functions that create a
-- refund: `cancel_job`. `resolve_dispute` and `release_item_float` created the row and said
-- nothing, so a customer owed money by a dispute or by unspent groceries was never going to be
-- paid. Worse, the worker claims the `payment` aggregate, so the one event that *was* emitted
-- fell through its `default` branch and was **marked complete** - the demand was consumed and
-- discarded.
--
-- The emit becomes a trigger on the table, so creating a refund row is what asks for it and no
-- future author has to remember. `cancel_job` is replaced to drop the manual emit it no longer
-- needs, which is also what stops the gateway being asked twice.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.refunds_request_execution()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  PERFORM private.emit_event('payment', NEW.id::text, 'refund.requested',
    jsonb_build_object('refund_id', NEW.id, 'payment_id', NEW.payment_id,
                       'request_id', NEW.request_id, 'amount_minor', NEW.amount_minor,
                       'currency', NEW.currency, 'reason_code', NEW.reason_code));
  RETURN NULL;
END $$;

REVOKE ALL ON FUNCTION private.refunds_request_execution() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER refunds_request_execution
  AFTER INSERT ON public.refunds
  FOR EACH ROW WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION private.refunds_request_execution();

-- `cancel_job`, replaced whole: one emit fewer, because the trigger above now does it for every
-- refund rather than for the one this function happened to remember.
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

  -- The `refund.requested` event belongs to the table now, not to this function.
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('refund_minor', v_refund, 'fee_minor', v_fee,
                       'currency', v_payment.currency));

  RETURN QUERY SELECT v_refund, v_fee, v_payment.currency;
END $$;

-- ---------------------------------------------------------------------------
-- T.3 - a chargeback before settlement reversed postings that were never made.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.record_chargeback(
  p_payment_id uuid, p_chargeback_fee_minor bigint, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment    public.payments%ROWTYPE;
  v_job        public.jobs%ROWTYPE;
  v_fee        bigint := greatest(coalesce(p_chargeback_fee_minor, 0), 0);
  v_net        bigint;
  v_entries    jsonb;
  v_recognised boolean;
BEGIN
  SELECT * INTO v_payment FROM public.payments p WHERE p.id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_payment.request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_payment.float_minor > 0 THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'a chargeback on a job with an item float needs a person';
  END IF;
  -- Refunded already, and now charged back as well: the customer has been paid twice, and which
  -- of the two to unwind is not arithmetic. Refused rather than guessed at, exactly as the item
  -- float is.
  IF EXISTS (SELECT 1 FROM public.refunds r
             WHERE r.payment_id = p_payment_id AND r.status <> 'failed') THEN
    RAISE EXCEPTION 'ERR_CHARGEBACK_NEEDS_REVIEW' USING ERRCODE = 'P0001',
      DETAIL = 'this payment has already been refunded';
  END IF;

  -- **Which posting this is depends on whether there is anything to reverse.** money-flows 7 is
  -- written for a chargeback *after payout*; a customer can equally dispute with their bank on
  -- the first day, while the money is still held. Reversing commission, provider earnings and
  -- the referral then invents three debts out of postings that were never made - in particular
  -- it leaves the provider owing the platform 84.60 for money they never saw, and leaves
  -- `held_funds` saying the platform still owes a customer who has already been paid by their
  -- bank. The ledger is asked the question, because it is the only thing that knows the answer.
  v_recognised := EXISTS (SELECT 1 FROM ledger.transactions t
                          WHERE t.request_id = v_payment.request_id
                            AND t.kind = 'earnings_recognised');

  IF NOT v_recognised THEN
    -- The hold is released because the money is gone; the gateway takes the charge and its own
    -- fee; and the collection fee recorded at 1a simply stays a platform expense, because there
    -- was no settlement to recover it from and there never will be.
    v_entries := jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                         'amount_minor', v_payment.job_amount_minor),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', -(v_payment.job_amount_minor + v_fee)));
    IF v_fee > 0 THEN
      v_entries := v_entries || jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'chargeback_losses',
                           'amount_minor', v_fee));
    END IF;
    -- Anticipated commissions are closed out even though none was posted, or they would mature
    -- against a job the platform was never paid for.
    v_entries := v_entries || private.reverse_referrals(v_payment.request_id,
                                                        coalesce(p_reason_key, 'chargeback'));

    UPDATE public.payments p SET status = 'refunded' WHERE p.id = p_payment_id;
    PERFORM private.raise_fraud_flag('user', v_payment.payer_id::text, 'payment_chargeback',
      80::smallint, jsonb_build_object('payment_id', p_payment_id, 'reason_key', p_reason_key));
    PERFORM private.emit_event('payment', p_payment_id::text, 'payment.charged_back',
      jsonb_build_object('payment_id', p_payment_id, 'request_id', v_payment.request_id,
                         'fee_minor', v_fee, 'reason_key', p_reason_key, 'settled', false));
    RETURN ledger.post('chargeback', v_payment.currency, 'chargeback:' || p_payment_id::text,
      v_entries, v_payment.request_id, NULL);
  END IF;

  v_net := v_job.net_minor - coalesce(v_job.actual_gateway_fee_minor, 0);

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', v_net),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', -(v_payment.job_amount_minor + v_fee)));
  IF coalesce(v_job.actual_gateway_fee_minor, 0) > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_job.actual_gateway_fee_minor));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', -v_payment.discount_minor));
  END IF;
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'chargeback_losses',
                         'amount_minor', v_fee));
  END IF;
  v_entries := v_entries || private.reverse_referrals(v_payment.request_id,
                                                      coalesce(p_reason_key, 'chargeback'));

  UPDATE public.payments p SET status = 'refunded' WHERE p.id = p_payment_id;
  PERFORM private.raise_fraud_flag('user', v_payment.payer_id::text, 'payment_chargeback',
    80::smallint, jsonb_build_object('payment_id', p_payment_id, 'reason_key', p_reason_key));
  PERFORM private.emit_event('payment', p_payment_id::text, 'payment.charged_back',
    jsonb_build_object('payment_id', p_payment_id, 'request_id', v_payment.request_id,
                       'fee_minor', v_fee, 'reason_key', p_reason_key));

  RETURN ledger.post('chargeback', v_payment.currency, 'chargeback:' || p_payment_id::text,
    v_entries, v_payment.request_id, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- T.4 - `stacks_with_referral` was configuration that nothing read.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.accrue_referrals(
  p_request_id uuid, p_net_minor bigint, p_currency char(3))
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_entries  jsonb := '[]'::jsonb;
  v_hold     integer := coalesce(private.remote_config_int('referral.hold_hours'), 72);
  v_maxrefs  integer := coalesce(private.remote_config_int('referral.max_referrers_per_job'), 2);
  v_maxearn  integer := coalesce(private.remote_config_int('referral.max_earned_minor'), 0);
  v_country  char(2);
  v_row      record;
  v_rate     integer;
  v_campaign uuid;
  v_amount   bigint;
  v_earned   bigint;
  v_used     integer := 0;
BEGIN
  -- A job refunded down to nothing shares nothing. Rather than returning here, the cap is set to
  -- zero so the loop exits at once and the cleanup at the end still runs: leaving a commission
  -- `pending` against a job that paid nobody is how it matures three days later.
  IF p_net_minor IS NULL OR p_net_minor <= 0 THEN
    v_maxrefs := 0;
  END IF;
  -- **The promo decides too.** `promo_codes.stacks_with_referral` defaults to false, so until now
  -- the stated rule for every promo was "does not stack" and every promo stacked anyway. A job
  -- redeemed against a non-stacking promo pays no referral, and the anticipated rows are closed
  -- out by the cleanup at the end rather than left to mature.
  IF EXISTS (SELECT 1 FROM public.promo_redemptions pr
             JOIN public.promo_codes pc ON pc.id = pr.promo_id
             WHERE pr.request_id = p_request_id AND NOT pc.stacks_with_referral) THEN
    v_maxrefs := 0;
  END IF;
  SELECT r.country_code INTO v_country FROM public.requests r WHERE r.id = p_request_id;

  FOR v_row IN
    -- Both sides of the job, each with their own referrer, and **one row per referrer**: somebody
    -- who introduced the customer and the provider earns one commission, not two. The UNIQUE on
    -- (request_id, referrer_id) already says so; without `DISTINCT ON` the loop would post twice
    -- against a row that can only hold one amount. Ordered so the result does not depend on
    -- physical row order when the per-job cap bites.
    SELECT * FROM (
      SELECT DISTINCT ON (ref.referrer_id)
             ref.id AS referral_id, ref.referrer_id, ref.referee_id,
             side.role AS referee_role, ref.attributed_at
      FROM (SELECT r.customer_id AS uid, 'customer'::text AS role FROM public.requests r
            WHERE r.id = p_request_id
            UNION ALL
            SELECT j.provider_id, 'provider'::text FROM public.jobs j
            WHERE j.request_id = p_request_id AND j.provider_id IS NOT NULL) side
      JOIN public.referrals ref ON ref.referee_id = side.uid
      WHERE ref.blocked_at IS NULL
        AND (ref.expires_at IS NULL OR ref.expires_at > now())
        -- A referrer who is also on this job would be paying themselves a finder's fee for their
        -- own work, which is the collusion case the risk engine already watches for.
        AND ref.referrer_id IS DISTINCT FROM (SELECT r2.customer_id FROM public.requests r2
                                              WHERE r2.id = p_request_id)
        AND ref.referrer_id IS DISTINCT FROM (SELECT j2.provider_id FROM public.jobs j2
                                              WHERE j2.request_id = p_request_id)
        -- Already posted, so there is nothing to post. Without this, a second call — a dispute
        -- resolved on a job whose earnings had somehow been recognised — would pay twice.
        AND NOT EXISTS (SELECT 1 FROM public.referral_commissions rc2
                        WHERE rc2.request_id = p_request_id
                          AND rc2.referrer_id = ref.referrer_id
                          AND rc2.status IN ('holding', 'available', 'reversed'))
      ORDER BY ref.referrer_id, side.role, ref.attributed_at
    ) picked
    ORDER BY picked.referee_role, picked.attributed_at
  LOOP
    EXIT WHEN v_used >= greatest(v_maxrefs, 0);

    SELECT rr.rate_bps, rr.campaign_id INTO v_rate, v_campaign
    FROM private.referral_rate(v_country, p_currency) rr;
    IF v_rate IS NULL OR v_rate = 0 THEN
      CONTINUE;
    END IF;

    v_amount := private.apply_bps(p_net_minor, v_rate);

    -- OD-02's amount cap, counted across this referral's whole history.
    IF v_maxearn > 0 THEN
      v_earned := private.referral_earned_minor(v_row.referral_id);
      v_amount := least(v_amount, greatest(v_maxearn - v_earned, 0));
    END IF;

    -- A campaign cannot overspend its budget. Checked before the write and raised catchably,
    -- because the CHECK that guarantees it is a constraint and an aborted transaction here would
    -- take the whole settlement with it (S-14's lesson, applied to a cheaper constraint).
    IF v_campaign IS NOT NULL THEN
      DECLARE
        v_left bigint;
      BEGIN
        SELECT c.budget_minor - c.spent_minor INTO v_left
        FROM public.referral_campaigns c WHERE c.id = v_campaign FOR UPDATE;
        v_amount := least(v_amount, greatest(coalesce(v_left, 0), 0));
        IF v_amount > 0 THEN
          UPDATE public.referral_campaigns c SET spent_minor = c.spent_minor + v_amount
          WHERE c.id = v_campaign;
        END IF;
      END;
    END IF;

    IF v_amount <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO public.referral_commissions (
      referral_id, referrer_id, referee_id, request_id, referee_role,
      base_minor, rate_bps, amount_minor, currency, campaign_id, status,
      available_at, posted_at)
    VALUES (v_row.referral_id, v_row.referrer_id, v_row.referee_id, p_request_id,
            v_row.referee_role, p_net_minor, v_rate, v_amount, p_currency, v_campaign,
            'holding', now() + make_interval(hours => v_hold), now())
    ON CONFLICT (request_id, referrer_id) DO UPDATE SET
      base_minor = excluded.base_minor,
      rate_bps = excluded.rate_bps,
      amount_minor = excluded.amount_minor,
      campaign_id = excluded.campaign_id,
      status = 'holding',
      available_at = excluded.available_at,
      posted_at = excluded.posted_at;

    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_referral_expense',
                         'amount_minor', v_amount),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_row.referrer_id,
                         'account_type', 'referral_earnings', 'amount_minor', -v_amount));

    PERFORM private.notify(v_row.referrer_id, 'system',
      'notification.referral.earned.title', 'notification.referral.earned.body',
      jsonb_build_object('request_id', p_request_id, 'amount_minor', v_amount,
                         'currency', p_currency), '/referrals');
    PERFORM private.emit_event('referral', v_row.referral_id::text, 'referral.commission_earned',
      jsonb_build_object('referral_id', v_row.referral_id, 'request_id', p_request_id,
                         'referrer_id', v_row.referrer_id, 'amount_minor', v_amount,
                         'currency', p_currency, 'campaign_id', v_campaign));
    v_used := v_used + 1;
  END LOOP;

  -- Anything still anticipated is now decided against: a referral that expired between the job
  -- and its settlement, one past OD-02's cap, one beyond the per-job ceiling, or a job refunded
  -- down to nothing. Left `pending` it would mature later against money nobody was paid.
  UPDATE public.referral_commissions rc
  SET status = 'reversed', reversed_reason_key = 'not_eligible_at_settlement'
  WHERE rc.request_id = p_request_id AND rc.status IN ('pending', 'earned');

  RETURN v_entries;
END $$;

-- ---------------------------------------------------------------------------
-- T.5 - the analytics export health check called a never-run exporter stale.
--
-- Nothing exports yet: the worker that would is the same one waiting on GCP billing. A warning
-- every day from the fourth after deploy, about something nobody has switched on, is how a
-- health check stops being read. A view that has never run is not stale, it is not started; a
-- view that ran and then stopped is what this check is for.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.export_health(p_max_lag_days integer DEFAULT 3)
RETURNS TABLE (view_name text, exported_through date, lag_days integer, last_error text)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT e.view_name, e.exported_through,
         (current_date - coalesce(e.exported_through, current_date - 90))::integer,
         e.last_error
  FROM analytics.exports e
  WHERE e.enabled
    AND e.last_run_at IS NOT NULL
    AND (e.last_error IS NOT NULL
         OR coalesce(e.exported_through, date '1970-01-01')
            < current_date - greatest(coalesce(p_max_lag_days, 3), 1))
  ORDER BY e.view_name;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('webhook-event-partitions', '17 3 * * *',
      $cron$SELECT private.ensure_monthly_partitions('public.webhook_events'::regclass)$cron$);
    PERFORM cron.schedule('partition-health', '19 3 * * *',
      $cron$SELECT private.record_partition_health()$cron$);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- T.2, the other half: the seam the worker needs to answer a `refund.requested` event through.
-- Two more `gateway_*` wrappers, granted to `service_role` alone, exactly as thin as the rest.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.gateway_execute_refund(p_refund_id uuid, p_gateway_reference text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.execute_refund(p_refund_id, p_gateway_reference); $$;

CREATE FUNCTION public.gateway_fail_refund(p_refund_id uuid, p_reason_key text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.fail_refund(p_refund_id, p_reason_key); $$;

REVOKE ALL ON FUNCTION
  public.gateway_execute_refund(uuid, text),
  public.gateway_fail_refund(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.gateway_execute_refund(uuid, text),
  public.gateway_fail_refund(uuid, text)
  TO service_role;
