-- Phase 5, part 1: the double-entry ledger (ERD §6; `docs/plan/money-flows.md`; ADR-0011 chart of
-- accounts; spike S-14; spec `money_rules`).
--
-- **Nothing here talks to a gateway.** This is the book the gateway's answers get written into.
-- It can be built and proved now because the spec states the formulas and the rate
-- (`commission_rate` default 0.125, snapshotted on the job) and `money-flows.md` gives every
-- posting, each one script-verified to sum to zero. Flutterwave and Paystack wait for merchant
-- accounts; the ledger does not.
--
-- **Validate first, then write.** S-14's finding: a `DEFERRABLE INITIALLY DEFERRED` constraint
-- trigger fires outside any PL/pgSQL exception handler, so the posting function cannot catch it,
-- and the abort takes every other row in the transaction — audit entries, outbox records — with
-- it. So `ledger.post` checks the entries balance *before* inserting anything and raises a
-- catchable `P0001`; the deferred trigger stays as the last-resort invariant that no future code
-- path can route around.
--
-- **Balances are derived, and the derivation is checked.** `ledger.balances` is a materialised
-- convenience; `ledger.entries` is the truth. `ledger.reconcile()` compares them and is meant to
-- be run nightly — any drift is a bug in something, and finding it a day later is the difference
-- between a fix and an investigation.
--
-- Signed minor units throughout: debit positive, credit negative. One currency per transaction —
-- a job is priced and settled in its own country's currency, and no cross-currency job exists at
-- launch.

CREATE TYPE ledger.owner_kind AS ENUM ('platform', 'user', 'organization');

-- The spec names nine accounts; double entry needs four more, recorded in ADR-0011. Without an
-- asset account there is nothing to debit when a customer pays, so the books cannot balance.
-- Splitting the asset into pending and available is what makes daily reconciliation mechanical:
-- pending must match what the gateway says it owes us, available the merchant balance.
CREATE TYPE ledger.account_type AS ENUM (
  'gateway_pending', 'gateway_available',
  'held_funds', 'item_float', 'refunds_payable',
  'customer_wallet', 'provider_earnings', 'referral_earnings',
  'platform_revenue', 'gateway_fees', 'platform_promo_expense',
  'platform_referral_expense', 'chargeback_losses');

CREATE TYPE ledger.transaction_kind AS ENUM (
  'payment_captured', 'gateway_settled', 'earnings_recognised', 'payout_paid',
  'tip_captured', 'float_released', 'promo_funded', 'cancellation', 'refund',
  'chargeback', 'adjustment');

CREATE TABLE ledger.accounts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_kind   ledger.owner_kind NOT NULL,
  -- NULL for platform accounts; the platform is not a user row.
  owner_id     uuid,
  account_type ledger.account_type NOT NULL,
  currency     char(3) NOT NULL REFERENCES public.currencies (code),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT accounts_owner_matches_kind CHECK (
    (owner_kind = 'platform' AND owner_id IS NULL)
    OR (owner_kind <> 'platform' AND owner_id IS NOT NULL))
);
-- `coalesce`, because a unique index over a nullable column would let the platform's revenue
-- account be created twice and silently split the books.
CREATE UNIQUE INDEX accounts_identity ON ledger.accounts
  (owner_kind, coalesce(owner_id, '00000000-0000-0000-0000-000000000000'::uuid),
   account_type, currency);

CREATE TABLE ledger.transactions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind            ledger.transaction_kind NOT NULL,
  currency        char(3) NOT NULL REFERENCES public.currencies (code),
  request_id      uuid REFERENCES public.requests (id),
  -- A retried settlement cannot post twice. This is the ledger's own key, separate from the
  -- caller's idempotency key, because the same webhook may legitimately drive two postings.
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  created_by      uuid REFERENCES auth.users (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, idempotency_key)
);
CREATE INDEX transactions_request ON ledger.transactions (request_id, id)
  WHERE request_id IS NOT NULL;

CREATE TABLE ledger.entries (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id bigint NOT NULL REFERENCES ledger.transactions (id) ON DELETE RESTRICT,
  account_id     uuid NOT NULL REFERENCES ledger.accounts (id) ON DELETE RESTRICT,
  -- Debit positive, credit negative. A zero entry records nothing and hides a bug.
  amount_minor   bigint NOT NULL CHECK (amount_minor <> 0),
  currency       char(3) NOT NULL REFERENCES public.currencies (code)
);
CREATE INDEX entries_account ON ledger.entries (account_id, id);
CREATE INDEX entries_transaction ON ledger.entries (transaction_id);

CREATE TABLE ledger.balances (
  account_id    uuid PRIMARY KEY REFERENCES ledger.accounts (id) ON DELETE RESTRICT,
  balance_minor bigint NOT NULL DEFAULT 0,
  -- The posting path increments in place under the row lock, so it does not need this to be
  -- correct; `version` is for readers — a statement or a reconciliation that read a balance and
  -- wants to know whether it moved underneath them.
  version       integer NOT NULL DEFAULT 1,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Nothing in `ledger` is exposed. The schema already has no USAGE for client roles; these are
-- belt and braces, and they include `service_role`: money is posted through functions, never by
-- an API client holding a key.
REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC, anon, authenticated, service_role;
ALTER TABLE ledger.accounts     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.accounts     FORCE  ROW LEVEL SECURITY;
ALTER TABLE ledger.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.transactions FORCE  ROW LEVEL SECURITY;
ALTER TABLE ledger.entries      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.entries      FORCE  ROW LEVEL SECURITY;
ALTER TABLE ledger.balances     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.balances     FORCE  ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- The last-resort invariant. Deferred, so it sees the whole transaction; uncatchable, which is
-- exactly why `ledger.post` validates first and this should never be what fires.
-- ---------------------------------------------------------------------------
CREATE FUNCTION ledger.assert_balanced()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_tx    bigint;
  v_sum   bigint;
  v_currs integer;
BEGIN
  -- `NEW` is unassigned on DELETE, so reading a field off it would raise before the check ran.
  IF TG_OP = 'DELETE' THEN
    v_tx := OLD.transaction_id;
  ELSE
    v_tx := NEW.transaction_id;
  END IF;

  SELECT coalesce(sum(e.amount_minor), 0), count(DISTINCT e.currency)
  INTO v_sum, v_currs
  FROM ledger.entries e WHERE e.transaction_id = v_tx;

  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'ERR_LEDGER_UNBALANCED' USING ERRCODE = 'P0001',
      DETAIL = format('transaction %s sums to %s, not zero', v_tx, v_sum);
  END IF;
  IF v_currs > 1 THEN
    RAISE EXCEPTION 'ERR_LEDGER_CURRENCY_MISMATCH' USING ERRCODE = 'P0001',
      DETAIL = format('transaction %s mixes %s currencies', v_tx, v_currs);
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER entries_balanced
  AFTER INSERT OR UPDATE OR DELETE ON ledger.entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_balanced();

-- ---------------------------------------------------------------------------
-- Accounts are created on first use. A chart of accounts seeded ahead of time would be thirteen
-- rows per currency per user, nearly all of them zero for ever.
-- ---------------------------------------------------------------------------
CREATE FUNCTION ledger.account(
  p_owner_kind ledger.owner_kind, p_owner_id uuid,
  p_account_type ledger.account_type, p_currency char(3))
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF (p_owner_kind = 'platform') <> (p_owner_id IS NULL) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'platform accounts have no owner; user and organization accounts must have one';
  END IF;

  SELECT a.id INTO v_id FROM ledger.accounts a
  WHERE a.owner_kind = p_owner_kind
    AND coalesce(a.owner_id, '00000000-0000-0000-0000-000000000000'::uuid)
        = coalesce(p_owner_id, '00000000-0000-0000-0000-000000000000'::uuid)
    AND a.account_type = p_account_type
    AND a.currency = p_currency;
  IF FOUND THEN
    RETURN v_id;
  END IF;

  INSERT INTO ledger.accounts (owner_kind, owner_id, account_type, currency)
  VALUES (p_owner_kind, p_owner_id, p_account_type, p_currency)
  RETURNING id INTO v_id;
  INSERT INTO ledger.balances (account_id) VALUES (v_id);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- post — the only way money is written down.
--
-- `p_entries` is a JSON array of {owner_kind, owner_id, account_type, amount_minor}. The caller
-- states the postings; this function proves they balance, resolves the accounts and writes them.
-- Every posting in `money-flows.md` is expressible here and nothing else is.
-- ---------------------------------------------------------------------------
CREATE FUNCTION ledger.post(
  p_kind ledger.transaction_kind,
  p_currency char(3),
  p_idempotency_key text,
  p_entries jsonb,
  p_request_id uuid DEFAULT NULL,
  p_created_by uuid DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_tx      bigint;
  v_sum     bigint := 0;
  v_count   integer := 0;
  v_entry   jsonb;
  v_amount  bigint;
  v_account uuid;
BEGIN
  IF jsonb_typeof(p_entries) <> 'array' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'entries must be a JSON array';
  END IF;
  PERFORM private.currency_exponent(p_currency);

  -- Validate before writing anything: S-14's finding is that the deferred trigger's abort cannot
  -- be caught and takes the whole transaction with it.
  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    v_amount := (v_entry ->> 'amount_minor')::bigint;
    IF v_amount IS NULL OR v_amount = 0 THEN
      RAISE EXCEPTION 'ERR_LEDGER_EMPTY_ENTRY' USING ERRCODE = 'P0001',
        DETAIL = 'an entry of zero records nothing and hides a bug';
    END IF;
    v_sum := v_sum + v_amount;
    v_count := v_count + 1;
  END LOOP;

  IF v_count < 2 THEN
    RAISE EXCEPTION 'ERR_LEDGER_UNBALANCED' USING ERRCODE = 'P0001',
      DETAIL = 'a transaction with fewer than two entries is not double entry';
  END IF;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'ERR_LEDGER_UNBALANCED' USING ERRCODE = 'P0001',
      DETAIL = format('entries sum to %s, not zero', v_sum);
  END IF;

  -- A replay returns the transaction that already exists rather than posting a second one.
  INSERT INTO ledger.transactions (kind, currency, request_id, idempotency_key, created_by)
  VALUES (p_kind, p_currency, p_request_id, p_idempotency_key, p_created_by)
  ON CONFLICT (kind, idempotency_key) DO NOTHING
  RETURNING id INTO v_tx;

  IF v_tx IS NULL THEN
    SELECT t.id INTO v_tx FROM ledger.transactions t
    WHERE t.kind = p_kind AND t.idempotency_key = p_idempotency_key;
    RETURN v_tx;
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    v_account := ledger.account(
      (v_entry ->> 'owner_kind')::ledger.owner_kind,
      nullif(v_entry ->> 'owner_id', '')::uuid,
      (v_entry ->> 'account_type')::ledger.account_type,
      p_currency);
    v_amount := (v_entry ->> 'amount_minor')::bigint;

    INSERT INTO ledger.entries (transaction_id, account_id, amount_minor, currency)
    VALUES (v_tx, v_account, v_amount, p_currency);

    -- In place, under the row lock the upsert takes: two concurrent postings to one account
    -- cannot lose each other's money the way a read-modify-write would.
    INSERT INTO ledger.balances AS b (account_id, balance_minor)
    VALUES (v_account, v_amount)
    ON CONFLICT (account_id) DO UPDATE
      SET balance_minor = b.balance_minor + excluded.balance_minor,
          version = b.version + 1,
          updated_at = now();
  END LOOP;

  PERFORM private.emit_event('ledger', v_tx::text, 'ledger.posted',
    jsonb_build_object('transaction_id', v_tx, 'kind', p_kind, 'currency', p_currency,
                       'request_id', p_request_id, 'entries', v_count));
  RETURN v_tx;
END $$;

-- ---------------------------------------------------------------------------
-- reconcile — the balances against the entries they are supposed to summarise. Nightly; drift is
-- a bug in something, and finding it the next morning is the difference between a fix and an
-- investigation.
-- ---------------------------------------------------------------------------
CREATE FUNCTION ledger.reconcile()
RETURNS TABLE (account_id uuid, stored_minor bigint, derived_minor bigint, drift_minor bigint)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT b.account_id, b.balance_minor,
         coalesce(e.total, 0),
         b.balance_minor - coalesce(e.total, 0)
  FROM ledger.balances b
  LEFT JOIN (SELECT en.account_id, sum(en.amount_minor) AS total
             FROM ledger.entries en GROUP BY en.account_id) e
    ON e.account_id = b.account_id
  WHERE b.balance_minor <> coalesce(e.total, 0);
$$;

-- Every transaction, checked. A cheap whole-book assertion for the nightly job and for tests.
CREATE FUNCTION ledger.unbalanced_transactions()
RETURNS TABLE (transaction_id bigint, sum_minor bigint)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT e.transaction_id, sum(e.amount_minor)
  FROM ledger.entries e
  GROUP BY e.transaction_id
  HAVING sum(e.amount_minor) <> 0;
$$;

-- ---------------------------------------------------------------------------
-- What a person may see of their own money. Balances only — the entries behind them name the
-- platform's accounts, and a provider does not need the platform's books to read their earnings.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_balances()
RETURNS TABLE (account_type text, currency char(3), balance_minor bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY
  -- Negated: these are liabilities in the books, and a credit balance is money owed *to* the
  -- user. Showing them a negative number would be true bookkeeping and a terrible answer.
  SELECT a.account_type::text, a.currency, -b.balance_minor
  FROM ledger.accounts a
  JOIN ledger.balances b ON b.account_id = a.id
  WHERE a.owner_kind = 'user' AND a.owner_id = v_uid
    AND a.account_type IN ('customer_wallet', 'provider_earnings', 'referral_earnings')
  ORDER BY a.account_type, a.currency;
END $$;

REVOKE ALL ON FUNCTION
  ledger.post(ledger.transaction_kind, char, text, jsonb, uuid, uuid),
  ledger.account(ledger.owner_kind, uuid, ledger.account_type, char),
  ledger.assert_balanced(),
  ledger.reconcile(),
  ledger.unbalanced_transactions(),
  public.my_balances()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_balances() TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Records the result rather than raising: a reconciliation job that dies at 03:00 tells
    -- nobody anything.
    PERFORM cron.schedule('ledger-reconcile', '17 3 * * *',
      $cron$SELECT private.record_health_check('ledger_reconcile',
              CASE WHEN EXISTS (SELECT 1 FROM ledger.reconcile())
                     OR EXISTS (SELECT 1 FROM ledger.unbalanced_transactions())
                   THEN 'fail' ELSE 'ok' END,
              jsonb_build_object(
                'drifted_accounts', (SELECT count(*) FROM ledger.reconcile()),
                'unbalanced_transactions', (SELECT count(*) FROM ledger.unbalanced_transactions())))$cron$);
  END IF;
END $$;
