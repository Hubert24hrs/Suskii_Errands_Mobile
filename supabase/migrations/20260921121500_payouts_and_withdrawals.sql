-- Phase 5, part 7: payout accounts, payouts and withdrawals (spec phase 5, "Double-entry ledger,
-- wallets, holds, settlements, provider payouts (bank + mobile money)" and "Finance approvals
-- (single and four-eyes)"; ERD §6 and §7; `docs/plan/money-flows.md` postings 1d, 7, 8 and 9;
-- country packs `payments.*`; OD-10).
--
-- **Everything except the transfer itself.** Creating a bank transfer is an HTTP call to
-- Flutterwave or Paystack with merchant credentials nobody has (timeline action 4). The record of
-- where money is going, the approvals it needs, the state machine it moves through and the
-- postings each outcome produces do not need any of that, and they are what takes the longest to
-- get right. `private.create_payout` emits the instruction; `private.record_payout_result` takes
-- the answer back. That is the whole seam.
--
-- **A payout is asynchronous and can reverse hours later** (REPORT §3.1), which is why it has an
-- explicit state machine rather than a boolean. A reversal is posting 8, and the platform absorbs
-- the transfer fee on a failed transfer because the provider did nothing wrong.
--
-- **Account details never arrive in plain text.** Ciphertext and a keyed blind index, produced
-- outside the database (ADR-0007), the same as trusted contacts and identity documents. The blind
-- index is what lets the risk engine notice one bank account behind six providers without anybody
-- reading a single account number.

CREATE TYPE public.payout_rail AS ENUM ('bank', 'mobile_money');
CREATE TYPE public.payout_status AS ENUM
  ('requested', 'submitted', 'pending', 'succeeded', 'failed', 'reversed');
CREATE TYPE public.withdrawal_status AS ENUM
  ('requested', 'awaiting_approval', 'approved', 'rejected', 'processing', 'paid', 'failed');

CREATE TABLE public.payout_accounts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  country_code        char(2) NOT NULL REFERENCES public.countries (code),
  rail                public.payout_rail NOT NULL,
  -- ADR-0007. Nothing in SQL reads either of these.
  account_ciphertext  bytea NOT NULL,
  account_blind_index bytea NOT NULL,
  -- Not secret: a sort code identifies an institution, not a person.
  institution_code    text NOT NULL CHECK (length(institution_code) BETWEEN 2 AND 20),
  holder_name         text NOT NULL CHECK (length(btrim(holder_name)) BETWEEN 2 AND 120),
  -- Set by the vendor's name-enquiry response, never by the client.
  verified_at         timestamptz,
  is_default          boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, account_blind_index)
);
CREATE UNIQUE INDEX payout_accounts_one_default ON public.payout_accounts (user_id)
  WHERE is_default;
-- Not unique across users on purpose: two people may genuinely share an account, and refusing
-- that would strand somebody with no way to be paid. The risk engine is told instead.
CREATE INDEX payout_accounts_blind ON public.payout_accounts (account_blind_index);

ALTER TABLE public.payout_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payout_accounts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payout_accounts FROM anon, authenticated;
GRANT SELECT (id, user_id, country_code, rail, institution_code, holder_name, verified_at,
              is_default, created_at) ON public.payout_accounts TO authenticated;
GRANT ALL ON public.payout_accounts TO service_role;
-- The ciphertext is not granted to anybody. A user reads which accounts they registered and what
-- the bank said the name was; they do not read back their own account number, because a stolen
-- session should not be able to either.
CREATE POLICY payout_accounts_read_own ON public.payout_accounts FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

CREATE TABLE public.payouts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beneficiary_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  payout_account_id uuid NOT NULL REFERENCES public.payout_accounts (id) ON DELETE RESTRICT,
  -- A payout settles a job, or a withdrawal, never both.
  request_id        uuid REFERENCES public.requests (id),
  withdrawal_id     uuid,
  -- Text rather than `ledger.account_type`: this column is read by clients, and the ledger's own
  -- types belong to a schema no client role may reach into.
  source_account    text NOT NULL CHECK (source_account IN
                      ('provider_earnings', 'referral_earnings')),
  amount_minor      bigint NOT NULL CHECK (amount_minor > 0),
  fee_minor         bigint NOT NULL DEFAULT 0 CHECK (fee_minor >= 0),
  currency          char(3) NOT NULL REFERENCES public.currencies (code),
  status            public.payout_status NOT NULL DEFAULT 'requested',
  gateway           text CHECK (gateway IS NULL
                                OR gateway IN ('flutterwave', 'paystack', 'stripe')),
  gateway_reference text CHECK (gateway_reference IS NULL
                                OR length(gateway_reference) BETWEEN 1 AND 200),
  failure_reason_key text CHECK (failure_reason_key IS NULL
                                 OR length(failure_reason_key) <= 60),
  created_at        timestamptz NOT NULL DEFAULT now(),
  settled_at        timestamptz,
  CONSTRAINT payouts_one_source CHECK (num_nonnulls(request_id, withdrawal_id) = 1)
);
CREATE UNIQUE INDEX payouts_gateway_reference ON public.payouts (gateway, gateway_reference)
  WHERE gateway_reference IS NOT NULL;
CREATE INDEX payouts_beneficiary ON public.payouts (beneficiary_id, created_at DESC);
CREATE INDEX payouts_open ON public.payouts (created_at)
  WHERE status IN ('requested', 'submitted', 'pending');

ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payouts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payouts FROM anon, authenticated;
GRANT SELECT ON public.payouts TO authenticated;
GRANT ALL ON public.payouts TO service_role;
CREATE POLICY payouts_read_own ON public.payouts FOR SELECT TO authenticated
  USING (beneficiary_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

CREATE TABLE public.withdrawals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  source_account     text NOT NULL CHECK (
                       source_account IN ('provider_earnings', 'referral_earnings')),
  payout_account_id  uuid NOT NULL REFERENCES public.payout_accounts (id) ON DELETE RESTRICT,
  amount_minor       bigint NOT NULL CHECK (amount_minor > 0),
  currency           char(3) NOT NULL REFERENCES public.currencies (code),
  status             public.withdrawal_status NOT NULL DEFAULT 'requested',
  -- 0, 1 or 2, from the country pack's thresholds. Recorded on the row so a later change to the
  -- thresholds cannot retroactively make a paid withdrawal look under-approved.
  approvals_required smallint NOT NULL DEFAULT 0 CHECK (approvals_required BETWEEN 0 AND 2),
  rejection_reason_key text CHECK (rejection_reason_key IS NULL
                                   OR length(rejection_reason_key) <= 60),
  created_at         timestamptz NOT NULL DEFAULT now(),
  decided_at         timestamptz,
  paid_at            timestamptz
);
CREATE INDEX withdrawals_user ON public.withdrawals (user_id, created_at DESC);
CREATE INDEX withdrawals_queue ON public.withdrawals (created_at)
  WHERE status IN ('requested', 'awaiting_approval', 'approved');

ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.withdrawals FROM anon, authenticated;
GRANT SELECT ON public.withdrawals TO authenticated;
GRANT ALL ON public.withdrawals TO service_role;
CREATE POLICY withdrawals_read_own ON public.withdrawals FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

ALTER TABLE public.payouts
  ADD CONSTRAINT payouts_withdrawal_fk FOREIGN KEY (withdrawal_id)
    REFERENCES public.withdrawals (id);

-- ---------------------------------------------------------------------------
-- What somebody actually has. Derived from the ledger, negated: these are liabilities in the
-- books, and a credit balance is money owed to them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.available_minor(
  p_user uuid, p_account ledger.account_type, p_currency char(3))
RETURNS bigint
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce((SELECT -b.balance_minor FROM ledger.balances b
                   JOIN ledger.accounts a ON a.id = b.account_id
                   WHERE a.owner_kind = 'user' AND a.owner_id = p_user
                     AND a.account_type = p_account AND a.currency = p_currency), 0)
       - coalesce((SELECT sum(w.amount_minor)::bigint FROM public.withdrawals w
                   WHERE w.user_id = p_user AND w.source_account = p_account
                     AND w.currency = p_currency
                     AND w.status IN ('requested', 'awaiting_approval', 'approved',
                                      'processing')), 0);
$$;

CREATE FUNCTION public.available_balance(p_source text, p_currency char(3))
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  IF p_source NOT IN ('provider_earnings', 'referral_earnings', 'customer_wallet') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  RETURN private.available_minor(v_uid, p_source::ledger.account_type, p_currency);
END $$;

-- ---------------------------------------------------------------------------
-- Registering where money should go.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.add_payout_account(
  p_idempotency_key text, p_rail public.payout_rail, p_institution_code text,
  p_holder_name text, p_account_ciphertext bytea, p_account_blind_index bytea,
  p_make_default boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_country char(2);
  v_shared  integer;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'add_payout_account',
    jsonb_build_object('rail', p_rail, 'institution_code', p_institution_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'payout_account_id')::uuid;
  END IF;

  IF p_account_ciphertext IS NULL OR length(p_account_ciphertext) = 0
     OR p_account_blind_index IS NULL OR length(p_account_blind_index) <> 32 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'ciphertext and a 32-byte blind index, both produced outside the database';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  -- One account behind several people is not refused — two people may genuinely share one, and
  -- refusing would strand somebody with no way to be paid. It is flagged, which is the risk
  -- engine's whole posture (OD-25).
  SELECT count(DISTINCT pa.user_id)::integer INTO v_shared FROM public.payout_accounts pa
  WHERE pa.account_blind_index = p_account_blind_index AND pa.user_id <> v_uid;

  INSERT INTO public.payout_accounts (user_id, country_code, rail, account_ciphertext,
                                      account_blind_index, institution_code, holder_name)
  VALUES (v_uid, v_country, p_rail, p_account_ciphertext, p_account_blind_index,
          p_institution_code, btrim(p_holder_name))
  RETURNING id INTO v_id;

  IF p_make_default OR NOT EXISTS (SELECT 1 FROM public.payout_accounts pa
                                   WHERE pa.user_id = v_uid AND pa.is_default) THEN
    UPDATE public.payout_accounts pa SET is_default = (pa.id = v_id) WHERE pa.user_id = v_uid;
  END IF;

  IF v_shared > 0 THEN
    PERFORM private.raise_fraud_flag('user', v_uid::text, 'payout_account_reuse', 65::smallint,
      jsonb_build_object('other_accounts', v_shared, 'payout_account_id', v_id));
  END IF;

  -- The vendor's name enquiry confirms the account exists and whose it is. Nothing verifies it
  -- here, so `verified_at` stays NULL and no payout can use it yet.
  PERFORM private.emit_event('payout', v_id::text, 'payout_account.registered',
    jsonb_build_object('payout_account_id', v_id, 'user_id', v_uid, 'rail', p_rail,
                       'institution_code', p_institution_code, 'country_code', v_country));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('payout_account_id', v_id));
  RETURN v_id;
END $$;

-- The name-enquiry answer, written back by the worker that made the call.
CREATE FUNCTION private.record_payout_account_verification(
  p_payout_account_id uuid, p_verified boolean, p_holder_name text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.payout_accounts pa
  SET verified_at = CASE WHEN p_verified THEN now() ELSE NULL END,
      holder_name = coalesce(nullif(btrim(coalesce(p_holder_name, '')), ''), pa.holder_name)
  WHERE pa.id = p_payout_account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYOUT_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.emit_event('payout', p_payout_account_id::text,
    'payout_account.verification_recorded',
    jsonb_build_object('payout_account_id', p_payout_account_id, 'verified', p_verified));
  RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- Payouts. `create_payout` writes the instruction and emits it; nothing here calls a bank.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.create_payout(
  p_beneficiary uuid, p_source ledger.account_type, p_amount_minor bigint, p_currency char(3),
  p_request_id uuid DEFAULT NULL, p_withdrawal_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_account uuid;
  v_id      uuid;
BEGIN
  SELECT pa.id INTO v_account FROM public.payout_accounts pa
  WHERE pa.user_id = p_beneficiary AND pa.verified_at IS NOT NULL
  ORDER BY pa.is_default DESC, pa.created_at
  LIMIT 1;
  IF v_account IS NULL THEN
    -- Not an assertion that they have no account: an unverified one is not somewhere money may
    -- be sent, and saying so is what stops a typo becoming a stranger's windfall.
    RAISE EXCEPTION 'ERR_PAYOUT_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001',
      DETAIL = 'no verified payout account';
  END IF;

  INSERT INTO public.payouts (beneficiary_id, payout_account_id, request_id, withdrawal_id,
                              source_account, amount_minor, currency)
  VALUES (p_beneficiary, v_account, p_request_id, p_withdrawal_id, p_source, p_amount_minor,
          p_currency)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('payout', v_id::text, 'payout.requested',
    jsonb_build_object('payout_id', v_id, 'beneficiary_id', p_beneficiary,
                       'payout_account_id', v_account, 'amount_minor', p_amount_minor,
                       'currency', p_currency, 'source_account', p_source));
  RETURN v_id;
END $$;

-- money-flows 1d and 9 on success, 8 on a reversal. The gateway's answer, whenever it comes.
CREATE FUNCTION private.record_payout_result(
  p_payout_id uuid, p_status public.payout_status, p_gateway text DEFAULT NULL,
  p_gateway_reference text DEFAULT NULL, p_fee_minor bigint DEFAULT 0,
  p_reason_key text DEFAULT NULL)
RETURNS public.payout_status
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payout  public.payouts%ROWTYPE;
  v_fee     bigint := greatest(coalesce(p_fee_minor, 0), 0);
  v_entries jsonb;
BEGIN
  SELECT * INTO v_payout FROM public.payouts p WHERE p.id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYOUT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_payout.status = p_status THEN
    RETURN p_status;   -- the gateway is retrying; nothing new has happened
  END IF;

  IF p_status IN ('submitted', 'pending') THEN
    UPDATE public.payouts p SET status = p_status, gateway = coalesce(p_gateway, p.gateway),
      gateway_reference = coalesce(p_gateway_reference, p.gateway_reference)
    WHERE p.id = p_payout_id;
    RETURN p_status;
  END IF;

  IF p_status = 'succeeded' THEN
    IF v_payout.status = 'succeeded' THEN
      RETURN 'succeeded'::public.payout_status;
    END IF;
    UPDATE public.payouts p
    SET status = 'succeeded', fee_minor = v_fee, settled_at = now(),
        gateway = coalesce(p_gateway, p.gateway),
        gateway_reference = coalesce(p_gateway_reference, p.gateway_reference)
    WHERE p.id = p_payout_id;

    -- The beneficiary's balance is cleared by the whole amount; what reaches their bank is that
    -- less the transfer fee. Who bears it is OD-10: the provider on their own earnings, the
    -- platform on a referral payout, which is usually small enough that the fee would eat it.
    v_entries := jsonb_build_array(
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_payout.beneficiary_id,
                         'account_type', v_payout.source_account,
                         'amount_minor', v_payout.amount_minor));
    IF v_payout.source_account = 'referral_earnings' THEN
      -- Posting 9: the referrer receives the whole amount and the platform pays the fee on top,
      -- because a referral payout is usually small enough that the fee would eat it (OD-10).
      v_entries := v_entries || jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                           'amount_minor', -v_payout.amount_minor));
      IF v_fee > 0 THEN
        v_entries := v_entries || jsonb_build_array(
          jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                             'amount_minor', v_fee),
          jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                             'amount_minor', -v_fee));
      END IF;
    ELSE
      -- Posting 1d: the provider's balance clears in full and the fee comes out of what reaches
      -- their bank, so the platform's cash moves by the amount and no more.
      v_entries := v_entries || jsonb_build_array(
        jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                           'amount_minor', -(v_payout.amount_minor - v_fee)));
      IF v_fee > 0 THEN
        v_entries := v_entries || jsonb_build_array(
          jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                             'amount_minor', -v_fee));
      END IF;
    END IF;

    PERFORM ledger.post('payout_paid', v_payout.currency, 'payout:' || p_payout_id::text,
      v_entries, v_payout.request_id, NULL);

    IF v_payout.withdrawal_id IS NOT NULL THEN
      UPDATE public.withdrawals w SET status = 'paid', paid_at = now()
      WHERE w.id = v_payout.withdrawal_id;
    END IF;
    IF v_payout.request_id IS NOT NULL THEN
      PERFORM private.job_transition(v_payout.request_id, 'settlement_pending', 'settled',
        NULL, 'system', 'payout_succeeded');
    END IF;

    PERFORM private.notify(v_payout.beneficiary_id, 'system',
      'notification.payout.paid.title', 'notification.payout.paid.body',
      jsonb_build_object('payout_id', p_payout_id,
                         'amount_minor', v_payout.amount_minor - v_fee,
                         'currency', v_payout.currency), '/earnings');
    PERFORM private.emit_event('payout', p_payout_id::text, 'payout.succeeded',
      jsonb_build_object('payout_id', p_payout_id, 'amount_minor', v_payout.amount_minor,
                         'fee_minor', v_fee));
    RETURN 'succeeded'::public.payout_status;
  END IF;

  IF p_status = 'failed' THEN
    UPDATE public.payouts p
    SET status = 'failed', failure_reason_key = p_reason_key, settled_at = now()
    WHERE p.id = p_payout_id;
    -- Nothing is posted: the money never left, so the beneficiary is still owed it and the books
    -- already say so.
    IF v_payout.withdrawal_id IS NOT NULL THEN
      UPDATE public.withdrawals w SET status = 'failed' WHERE w.id = v_payout.withdrawal_id;
    END IF;
    PERFORM private.emit_event('payout', p_payout_id::text, 'payout.failed',
      jsonb_build_object('payout_id', p_payout_id, 'reason_key', p_reason_key));
    RETURN 'failed'::public.payout_status;
  END IF;

  -- Reversed: posting 8. The bank sent it back hours later. The beneficiary's balance is
  -- restored in full and the platform eats the transfer fee, because they did nothing wrong.
  IF v_payout.status <> 'succeeded' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'only a succeeded payout can reverse';
  END IF;
  UPDATE public.payouts p
  SET status = 'reversed', failure_reason_key = p_reason_key WHERE p.id = p_payout_id;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', v_payout.amount_minor - v_payout.fee_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_payout.beneficiary_id,
                       'account_type', v_payout.source_account,
                       'amount_minor', -v_payout.amount_minor));
  IF v_payout.fee_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_payout.fee_minor));
  END IF;
  PERFORM ledger.post('payout_paid', v_payout.currency, 'payout-reversal:' || p_payout_id::text,
    v_entries, v_payout.request_id, NULL);

  IF v_payout.withdrawal_id IS NOT NULL THEN
    UPDATE public.withdrawals w SET status = 'failed' WHERE w.id = v_payout.withdrawal_id;
  END IF;
  PERFORM private.notify(v_payout.beneficiary_id, 'system',
    'notification.payout.reversed.title', 'notification.payout.reversed.body',
    jsonb_build_object('payout_id', p_payout_id, 'amount_minor', v_payout.amount_minor,
                       'currency', v_payout.currency, 'reason_key', p_reason_key), '/earnings');
  PERFORM private.emit_event('payout', p_payout_id::text, 'payout.reversed',
    jsonb_build_object('payout_id', p_payout_id, 'reason_key', p_reason_key));
  RETURN 'reversed'::public.payout_status;
END $$;

-- The settlement worker's entry point: a job whose earnings were recognised and whose provider
-- has somewhere to be paid.
CREATE FUNCTION private.pay_out_settled_jobs(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT j.request_id, j.provider_id, j.currency,
           private.available_minor(j.provider_id, 'provider_earnings', j.currency) AS owed
    FROM public.jobs j
    JOIN public.requests r ON r.id = j.request_id
    WHERE r.status = 'settlement_pending'
      AND NOT EXISTS (SELECT 1 FROM public.payouts p
                      WHERE p.request_id = j.request_id
                        AND p.status IN ('requested', 'submitted', 'pending', 'succeeded'))
    ORDER BY j.confirmed_at
    LIMIT least(greatest(coalesce(p_limit, 100), 1), 500)
  LOOP
    BEGIN
      IF v_row.owed > 0 THEN
        PERFORM private.create_payout(v_row.provider_id, 'provider_earnings', v_row.owed,
          v_row.currency, v_row.request_id, NULL);
        v_count := v_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- A provider with no verified account is the common case, and it is not an error worth
      -- stopping the batch for. They are told once and the job waits.
      PERFORM private.emit_event('payout', v_row.request_id::text, 'payout.deferred',
        jsonb_build_object('request_id', v_row.request_id,
                           'reason_key', CASE WHEN SQLERRM ~ '^ERR_[A-Z_]+$'
                                              THEN SQLERRM ELSE 'ERR_INTERNAL' END));
    END;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Withdrawals, and the approvals the country pack asks for.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.request_withdrawal(
  p_idempotency_key text, p_source text, p_amount_minor bigint, p_payout_account_id uuid)
RETURNS public.withdrawal_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_account   public.payout_accounts%ROWTYPE;
  v_currency  char(3);
  v_available bigint;
  v_min       integer;
  v_one       integer;
  v_two       integer;
  v_required  smallint;
  v_status    public.withdrawal_status;
  v_id        uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'request_withdrawal',
    jsonb_build_object('source', p_source, 'amount_minor', p_amount_minor,
                       'payout_account_id', p_payout_account_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.withdrawal_status;
  END IF;

  IF p_source NOT IN ('provider_earnings', 'referral_earnings')
     OR p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_account FROM public.payout_accounts pa
  WHERE pa.id = p_payout_account_id AND pa.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYOUT_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_account.verified_at IS NULL THEN
    RAISE EXCEPTION 'ERR_PAYOUT_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001',
      DETAIL = 'the account has not been verified with the bank yet';
  END IF;

  SELECT c.currency_code INTO v_currency FROM public.countries c
  WHERE c.code = v_account.country_code;

  v_min := coalesce(private.remote_config_int('min_withdrawal_minor'), 100000);
  IF p_amount_minor < v_min THEN
    RAISE EXCEPTION 'ERR_WITHDRAWAL_BELOW_MINIMUM' USING ERRCODE = 'P0001',
      DETAIL = format('minimum is %s', v_min);
  END IF;

  -- Available, not earned: money already committed to a withdrawal in flight is not available
  -- again, which is what stops the same balance being withdrawn twice.
  v_available := private.available_minor(v_uid, p_source::ledger.account_type, v_currency);
  IF p_amount_minor > v_available THEN
    RAISE EXCEPTION 'ERR_INSUFFICIENT_BALANCE' USING ERRCODE = 'P0001',
      DETAIL = format('available %s', v_available);
  END IF;

  v_one := coalesce(private.remote_config_int('withdrawal_single_approver_minor'), 50000000);
  v_two := coalesce(private.remote_config_int('withdrawal_second_approver_minor'), 200000000);
  v_required := CASE WHEN p_amount_minor >= v_two THEN 2
                     WHEN p_amount_minor >= v_one THEN 1
                     ELSE 0 END::smallint;
  v_status := CASE WHEN v_required = 0 THEN 'approved' ELSE 'awaiting_approval' END
                ::public.withdrawal_status;

  INSERT INTO public.withdrawals (user_id, source_account, payout_account_id, amount_minor,
                                  currency, status, approvals_required)
  VALUES (v_uid, p_source, p_payout_account_id, p_amount_minor, v_currency,
          v_status, v_required)
  RETURNING id INTO v_id;

  IF v_required > 0 THEN
    INSERT INTO public.approvals (subject_kind, subject_id, action, payload, requested_by, level)
    SELECT 'withdrawal', v_id::text, 'withdrawal.approve',
           jsonb_build_object('amount_minor', p_amount_minor, 'currency', v_currency),
           v_uid, lvl
    FROM generate_series(1, v_required) lvl;
  END IF;

  PERFORM private.emit_event('withdrawal', v_id::text, 'withdrawal.requested',
    jsonb_build_object('withdrawal_id', v_id, 'user_id', v_uid, 'amount_minor', p_amount_minor,
                       'currency', v_currency, 'source_account', p_source,
                       'approvals_required', v_required, 'status', v_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status, 'withdrawal_id', v_id));
  RETURN v_status;
END $$;

CREATE FUNCTION public.approve_withdrawal(
  p_idempotency_key text, p_withdrawal_id uuid, p_approve boolean,
  p_reason_key text DEFAULT NULL)
RETURNS public.withdrawal_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_w        public.withdrawals%ROWTYPE;
  v_pending  uuid;
  v_left     integer;
  v_status   public.withdrawal_status;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'finance_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'approve_withdrawal',
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.withdrawal_status;
  END IF;

  SELECT * INTO v_w FROM public.withdrawals w WHERE w.id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_WITHDRAWAL_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_w.status <> 'awaiting_approval' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- Four eyes. The table's own CHECK refuses `approved_by = requested_by`; this refuses the same
  -- approver twice, which the CHECK cannot see.
  IF EXISTS (SELECT 1 FROM public.approvals a
             WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
               AND a.approved_by = v_uid) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you have already signed this one';
  END IF;

  SELECT a.id INTO v_pending FROM public.approvals a
  WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
    AND a.status = 'pending'
  ORDER BY a.level LIMIT 1;
  IF v_pending IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.approvals a
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
      approved_by = v_uid, decided_at = now()
  WHERE a.id = v_pending;

  IF NOT p_approve THEN
    v_status := 'rejected';
    UPDATE public.withdrawals w
    SET status = 'rejected', rejection_reason_key = p_reason_key, decided_at = now()
    WHERE w.id = p_withdrawal_id;
    UPDATE public.approvals a SET status = 'cancelled', decided_at = now()
    WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
      AND a.status = 'pending';
    PERFORM private.notify(v_w.user_id, 'system',
      'notification.withdrawal.rejected.title', 'notification.withdrawal.rejected.body',
      jsonb_build_object('withdrawal_id', p_withdrawal_id, 'reason_key', p_reason_key),
      '/earnings');
  ELSE
    SELECT count(*)::integer INTO v_left FROM public.approvals a
    WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
      AND a.status = 'pending';
    v_status := CASE WHEN v_left = 0 THEN 'approved' ELSE 'awaiting_approval' END
                  ::public.withdrawal_status;
    IF v_left = 0 THEN
      UPDATE public.withdrawals w SET status = 'approved', decided_at = now()
      WHERE w.id = p_withdrawal_id;
    END IF;
  END IF;

  PERFORM private.audit_write('withdrawal.approve', 'public.withdrawals',
    p_withdrawal_id::text, jsonb_build_object('status', v_w.status),
    jsonb_build_object('status', v_status, 'approved', p_approve), p_reason_key);
  PERFORM private.emit_event('withdrawal', p_withdrawal_id::text,
    CASE WHEN p_approve THEN 'withdrawal.approved' ELSE 'withdrawal.rejected' END,
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'by', v_uid, 'status', v_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- Approved withdrawals become payout instructions. Separate from approval so a batch failure
-- cannot un-approve anything.
CREATE FUNCTION private.dispatch_approved_withdrawals(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT w.* FROM public.withdrawals w
    WHERE w.status = 'approved'
      AND NOT EXISTS (SELECT 1 FROM public.payouts p WHERE p.withdrawal_id = w.id
                        AND p.status <> 'failed')
    ORDER BY w.created_at
    LIMIT least(greatest(coalesce(p_limit, 100), 1), 500)
  LOOP
    BEGIN
      PERFORM private.create_payout(v_row.user_id,
        v_row.source_account::ledger.account_type, v_row.amount_minor,
        v_row.currency, NULL, v_row.id);
      UPDATE public.withdrawals w SET status = 'processing' WHERE w.id = v_row.id;
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      PERFORM private.emit_event('withdrawal', v_row.id::text, 'withdrawal.dispatch_failed',
        jsonb_build_object('withdrawal_id', v_row.id,
                           'reason_key', CASE WHEN SQLERRM ~ '^ERR_[A-Z_]+$'
                                              THEN SQLERRM ELSE 'ERR_INTERNAL' END));
    END;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Chargebacks — money-flows 7. The gateway takes the charge back, plus its own fee, after the
-- provider has already been paid. Everything is reversed and the provider's balance may go
-- negative, which is the truthful position: they owe it back.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.record_chargeback(
  p_payment_id uuid, p_chargeback_fee_minor bigint, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_fee     bigint := greatest(coalesce(p_chargeback_fee_minor, 0), 0);
  v_net     bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_payment FROM public.payments p WHERE p.id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_payment.request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- A charged-back shopping errand is an ops case, not arithmetic: the goods money may already
  -- be in a shopkeeper's till. Refused rather than guessed at.
  IF v_payment.float_minor > 0 THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'a chargeback on a job with an item float needs a person';
  END IF;

  v_net := v_job.net_minor - coalesce(v_job.actual_gateway_fee_minor, 0);

  -- Everything 1c did, undone, against `job_amount_minor` — the part of the charge that was the
  -- job. The provider's balance may go negative, which is the truthful position: they owe it.
  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', v_net),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', -(v_payment.job_amount_minor + v_fee)));
  IF coalesce(v_job.actual_gateway_fee_minor, 0) > 0 THEN
    -- The original collection fee is lost again, and this time nobody recovers it.
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_job.actual_gateway_fee_minor));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    -- The platform funded a discount on a job it is now being charged back for; that expense is
    -- reversed with everything else.
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', -v_payment.discount_minor));
  END IF;
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'chargeback_losses',
                         'amount_minor', v_fee));
  END IF;

  UPDATE public.payments p SET status = 'refunded' WHERE p.id = p_payment_id;
  PERFORM private.raise_fraud_flag('user', v_payment.payer_id::text, 'payment_chargeback',
    80::smallint, jsonb_build_object('payment_id', p_payment_id, 'reason_key', p_reason_key));
  PERFORM private.emit_event('payment', p_payment_id::text, 'payment.charged_back',
    jsonb_build_object('payment_id', p_payment_id, 'request_id', v_payment.request_id,
                       'fee_minor', v_fee, 'reason_key', p_reason_key));

  RETURN ledger.post('chargeback', v_payment.currency, 'chargeback:' || p_payment_id::text,
    v_entries, v_payment.request_id, NULL);
END $$;

REVOKE ALL ON FUNCTION
  public.add_payout_account(text, public.payout_rail, text, text, bytea, bytea, boolean),
  public.available_balance(text, char),
  public.request_withdrawal(text, text, bigint, uuid),
  public.approve_withdrawal(text, uuid, boolean, text),
  private.available_minor(uuid, ledger.account_type, char),
  private.record_payout_account_verification(uuid, boolean, text),
  private.create_payout(uuid, ledger.account_type, bigint, char, uuid, uuid),
  private.record_payout_result(uuid, public.payout_status, text, text, bigint, text),
  private.pay_out_settled_jobs(integer),
  private.dispatch_approved_withdrawals(integer),
  private.record_chargeback(uuid, bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.add_payout_account(text, public.payout_rail, text, text, bytea, bytea, boolean),
  public.available_balance(text, char),
  public.request_withdrawal(text, text, bigint, uuid),
  public.approve_withdrawal(text, uuid, boolean, text)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- Nigeria's pack, as placeholders for every country until each one's is approved. All `[A]`:
  -- the pack tags `payments.min_withdrawal_minor` and the thresholds as assumptions.
  ('min_withdrawal_minor', NULL, '100000', true),
  ('withdrawal_single_approver_minor', NULL, '50000000', false),
  ('withdrawal_second_approver_minor', NULL, '200000000', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('payout-settled-jobs', '29 * * * *',
      $cron$SELECT private.pay_out_settled_jobs()$cron$);
    PERFORM cron.schedule('dispatch-withdrawals', '43 * * * *',
      $cron$SELECT private.dispatch_approved_withdrawals()$cron$);
  END IF;
END $$;
