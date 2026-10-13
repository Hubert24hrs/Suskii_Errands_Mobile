-- The three reads the app's screens were rendering zeros for: CR-20260923-01, -03 and -05 (home).
--
--   * `create_trip_share` returns `{token, url, expires_at}`. The app had been putting the bare
--     token where a link belongs and guessing the expiry. The URL base is per environment
--     (`trip_share_base_url`), because the domain is still open (I-2): until it is set the url is
--     null and the app says so, rather than inventing a host. RB-08 sets it before go-live.
--   * `my_wallet_transactions` is a client-safe projection of the private ledger for one of the
--     user's own balances, with the withdrawals that have not reached the ledger yet, newest
--     first. Amounts are signed the way the screen reads them: money in is positive.
--     `my_pending_balance` is what will land and has not: a provider's jobs that are paid for but
--     not yet recognised (before the collection fee, which is known once the gateway settles),
--     or referral commissions still in their hold. The ledger itself stays private (ADR-0011).
--   * `provider_home_summary` is the provider home card in one call: online, standing, today's
--     earnings and completed jobs in the provider's own time zone, open requests nearby, and the
--     documents that expire within thirty days. The rest of CR-05 (availability, goals, heatmap,
--     insights, instant payout) is product scope, not a read, and stays open.

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('trip_share_base_url', NULL, 'null', false)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- CR-01: create_trip_share returns the link.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.create_trip_share(text, uuid, integer);
CREATE FUNCTION public.create_trip_share(
  p_idempotency_key text, p_request_id uuid, p_ttl_minutes integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_ttl     integer := coalesce(p_ttl_minutes,
                                private.remote_config_int('trip_share_ttl_minutes'), 60);
  v_base    text;
  v_token   text;
  v_id      uuid;
  v_expires timestamptz;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_trip_share',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    -- A replay cannot return the token: it was never stored. It returns the link's id and
    -- expiry, and a caller that lost the token asks for a new link.
    RETURN jsonb_build_object('share_id', v_claim ->> 'share_id', 'token', NULL, 'url', NULL,
                              'expires_at', v_claim ->> 'expires_at');
  END IF;

  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- 32 bytes of uuid entropy, hex: unguessable, and nothing about it identifies the job.
  v_token := replace(gen_random_uuid()::text, '-', '') ||
             replace(gen_random_uuid()::text, '-', '');
  v_ttl := least(greatest(v_ttl, 5), 1440);

  INSERT INTO public.trip_share_links (request_id, token_hash, created_by, expires_at)
  VALUES (p_request_id, sha256(convert_to(v_token, 'UTF8')), v_uid,
          now() + make_interval(mins => v_ttl))
  RETURNING id, expires_at INTO v_id, v_expires;

  SELECT rc.value #>> '{}' INTO v_base FROM public.remote_config rc
  WHERE rc.key = 'trip_share_base_url' AND rc.country_code IS NULL;

  PERFORM private.emit_event('request', p_request_id::text, 'trip.shared',
    jsonb_build_object('share_id', v_id, 'created_by', v_uid, 'ttl_minutes', v_ttl));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('share_id', v_id, 'expires_at', v_expires));
  RETURN jsonb_build_object('share_id', v_id, 'token', v_token,
                            'url', CASE WHEN v_base IS NOT NULL THEN v_base || v_token END,
                            'expires_at', v_expires);
END $$;

-- ---------------------------------------------------------------------------
-- CR-03: the wallet feed and what is pending.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_wallet_transactions(
  p_source text, p_cursor timestamptz DEFAULT NULL, p_limit integer DEFAULT 20)
RETURNS TABLE (
  id              text,
  kind            text,
  status          text,
  amount_minor    bigint,
  currency        char(3),
  reference_id    uuid,
  description_key text,
  created_at      timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
BEGIN
  IF p_source IS NULL
     OR p_source NOT IN ('provider_earnings', 'referral_earnings', 'customer_wallet') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT f.id, f.kind, f.status, f.amount_minor, f.currency, f.reference_id, f.description_key,
         f.created_at
  FROM (
    -- Posted movements. The user's accounts are liabilities, so a credit to them is money owed
    -- to the user: negate the entry, as `my_balances` does.
    SELECT 'ledger:' || e.id AS id,
           CASE
             WHEN t.kind = 'earnings_recognised' AND p_source = 'referral_earnings' THEN 'referral'
             WHEN t.kind = 'earnings_recognised' THEN 'credit'
             WHEN t.kind = 'tip_captured' THEN 'tip'
             WHEN t.kind = 'float_released' THEN 'item_float'
             WHEN t.kind = 'payout_paid' THEN 'payout'
             WHEN t.kind = 'refund' AND -e.amount_minor > 0 THEN 'refund'
             WHEN -e.amount_minor > 0 THEN 'credit'
             ELSE 'debit' END AS kind,
           'completed' AS status,
           -e.amount_minor AS amount_minor,
           e.currency,
           t.request_id AS reference_id,
           CASE
             WHEN t.kind = 'earnings_recognised' AND p_source = 'referral_earnings' THEN 'txnReferral'
             WHEN t.kind = 'earnings_recognised' THEN 'txnJobEarnings'
             WHEN t.kind = 'tip_captured' THEN 'txnTip'
             WHEN t.kind = 'float_released' THEN 'txnFloatReimbursed'
             WHEN t.kind = 'payout_paid' AND p_source = 'referral_earnings' THEN 'txnReferralWithdrawal'
             WHEN t.kind = 'payout_paid' THEN 'txnWithdrawal'
             WHEN t.kind = 'chargeback' THEN 'txnChargeback'
             ELSE 'txnAdjustment' END AS description_key,
           t.created_at
    FROM ledger.entries e
    JOIN ledger.accounts a ON a.id = e.account_id
    JOIN ledger.transactions t ON t.id = e.transaction_id
    WHERE a.owner_kind = 'user' AND a.owner_id = v_uid
      AND a.account_type = p_source::ledger.account_type
    UNION ALL
    -- Withdrawals that have not reached the ledger: asked for, waiting on approval, in flight, or
    -- refused. A paid one is already above as `payout_paid`.
    SELECT 'withdrawal:' || w.id,
           'payout',
           CASE WHEN w.status IN ('rejected', 'failed') THEN 'failed' ELSE 'pending' END,
           -w.amount_minor,
           w.currency,
           w.id,
           CASE WHEN w.status = 'awaiting_approval' THEN 'txnWithdrawalAwaitingApproval'
                WHEN p_source = 'referral_earnings' THEN 'txnReferralWithdrawal'
                ELSE 'txnWithdrawal' END,
           w.created_at
    FROM public.withdrawals w
    WHERE w.user_id = v_uid AND w.source_account = p_source AND w.status <> 'paid'
  ) f
  WHERE p_cursor IS NULL OR f.created_at < p_cursor
  ORDER BY f.created_at DESC, f.id DESC
  LIMIT v_limit;
END $$;

CREATE FUNCTION public.my_pending_balance(p_source text, p_currency char(3))
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_source IS NULL OR p_currency IS NULL
     OR p_source NOT IN ('provider_earnings', 'referral_earnings', 'customer_wallet') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  IF p_source = 'provider_earnings' THEN
    -- Funded and not yet recognised: what `recognise_earnings` will post once the dispute window
    -- closes, less the collection fee where the gateway has told us what it was.
    RETURN coalesce((
      SELECT sum(j.net_minor - coalesce(j.actual_gateway_fee_minor, 0))::bigint
      FROM public.jobs j
      JOIN public.requests r ON r.id = j.request_id
      WHERE j.provider_id = v_uid AND j.currency = p_currency AND j.net_minor IS NOT NULL
        AND r.status IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                         'completed_by_provider', 'confirmed', 'settlement_pending', 'disputed')
        AND NOT EXISTS (SELECT 1 FROM ledger.transactions t
                        WHERE t.request_id = j.request_id AND t.kind = 'earnings_recognised')),
      0);
  ELSIF p_source = 'referral_earnings' THEN
    RETURN coalesce((
      SELECT sum(rc.amount_minor)::bigint FROM public.referral_commissions rc
      WHERE rc.referrer_id = v_uid AND rc.currency = p_currency
        AND rc.status IN ('pending', 'earned', 'holding')), 0);
  END IF;
  RETURN 0;
END $$;

-- ---------------------------------------------------------------------------
-- CR-05: the provider home card.
-- ---------------------------------------------------------------------------
-- `provider_feed` refuses a provider who is not active yet or has no known location. The home
-- card is where exactly those providers land, so for them the count is zero rather than an error.
CREATE FUNCTION private.nearby_open_request_count()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RETURN (SELECT count(*)::integer FROM public.provider_feed(100) f WHERE NOT f.already_offered);
EXCEPTION WHEN SQLSTATE 'P0001' THEN
  RETURN 0;
END $$;

CREATE FUNCTION public.provider_home_summary()
RETURNS TABLE (
  online                boolean,
  verification_status   public.verification_status,
  today_earnings_minor  bigint,
  currency              char(3),
  completed_today       integer,
  nearby_open_requests  integer,
  document_warnings     jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_tz       text := private.user_timezone(v_uid);
  v_today    date;
  v_currency char(3);
BEGIN
  v_today := (now() AT TIME ZONE v_tz)::date;
  SELECT c.currency_code INTO v_currency
  FROM public.profiles p JOIN public.countries c ON c.code = p.country_code
  WHERE p.user_id = v_uid;

  RETURN QUERY
  SELECT coalesce(pp.online, false),
         coalesce(p.provider_verification, 'unverified'::public.verification_status),
         coalesce((SELECT sum(j.net_minor - coalesce(j.actual_gateway_fee_minor, 0))::bigint
                   FROM public.jobs j
                   WHERE j.provider_id = v_uid AND j.currency = v_currency
                     AND j.completed_at IS NOT NULL
                     AND (j.completed_at AT TIME ZONE v_tz)::date = v_today), 0),
         v_currency,
         (SELECT count(*)::integer FROM public.jobs j
          WHERE (j.provider_id = v_uid OR j.worker_id = v_uid) AND j.completed_at IS NOT NULL
            AND (j.completed_at AT TIME ZONE v_tz)::date = v_today),
         private.nearby_open_request_count(),
         coalesce((SELECT jsonb_agg(w.warning ORDER BY w.days_left) FROM (
             SELECT jsonb_build_object(
                      'document_type_key',
                      'doc' || replace(initcap(replace(s.kind::text, '_', ' ')), ' ', ''),
                      'days_remaining', greatest((s.expires_at AT TIME ZONE v_tz)::date - v_today, 0)
                    ) AS warning,
                    (s.expires_at AT TIME ZONE v_tz)::date - v_today AS days_left
             FROM kyc.kyc_steps s
             WHERE s.user_id = v_uid AND s.expires_at IS NOT NULL
               AND s.status IN ('verified', 'expired')
               AND (s.expires_at AT TIME ZONE v_tz)::date - v_today <= 30
             UNION ALL
             SELECT jsonb_build_object('document_type_key', 'docVehicleDocuments',
                                       'days_remaining', greatest(v.documents_expire_on - v_today, 0)),
                    v.documents_expire_on - v_today
             FROM public.vehicles v
             WHERE (v.owner_user_id = v_uid OR v.assigned_worker_id = v_uid)
               AND v.documents_expire_on IS NOT NULL
               AND v.documents_expire_on - v_today <= 30) w), '[]'::jsonb)
  FROM public.profiles p
  LEFT JOIN public.provider_profiles pp ON pp.user_id = p.user_id
  WHERE p.user_id = v_uid;
END $$;

REVOKE ALL ON FUNCTION
  private.nearby_open_request_count(),
  public.create_trip_share(text, uuid, integer),
  public.my_wallet_transactions(text, timestamptz, integer),
  public.my_pending_balance(text, char),
  public.provider_home_summary()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.create_trip_share(text, uuid, integer),
  public.my_wallet_transactions(text, timestamptz, integer),
  public.my_pending_balance(text, char),
  public.provider_home_summary()
TO authenticated;
