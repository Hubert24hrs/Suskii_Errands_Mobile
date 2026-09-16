-- S-14: money rules from the spec, tested in SQL.
--   * integer minor units + ISO 4217, never floating point
--   * per-currency exponents (UGX = 0, so "100" is 100 shillings, not 1.00)
--   * round_half_even on commission and referral
--   * double-entry ledger where the entries of a transaction sum to zero
-- No Supabase needed.

DROP TABLE IF EXISTS ledger_entries, ledger_transactions, currencies CASCADE;
DROP FUNCTION IF EXISTS round_half_even(numeric, int), commission_minor(bigint, numeric), post_transaction(text, jsonb);

CREATE TABLE currencies (
    code     text PRIMARY KEY,
    exponent smallint NOT NULL CHECK (exponent BETWEEN 0 AND 4)
);
INSERT INTO currencies (code, exponent) VALUES
    ('NGN', 2), ('KES', 2), ('GHS', 2), ('ZAR', 2), ('USD', 2),
    ('UGX', 0);   -- the one that breaks a hardcoded /100

-- Postgres round() on numeric is half-away-from-zero. The spec requires half-even
-- (banker's rounding), so it needs implementing rather than assuming.
CREATE FUNCTION round_half_even(v numeric, dp int DEFAULT 0)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE scaled numeric; floored numeric; diff numeric;
BEGIN
    scaled  := v * power(10::numeric, dp);
    floored := floor(scaled);
    diff    := scaled - floored;
    IF diff > 0.5 THEN
        floored := floored + 1;
    ELSIF diff = 0.5 THEN
        -- exact tie: pick the even neighbour
        IF floored % 2 <> 0 THEN floored := floored + 1; END IF;
    END IF;
    RETURN floored / power(10::numeric, dp);
END $$;

-- Commission in minor units. Input and output are integers; the rate is exact numeric.
CREATE FUNCTION commission_minor(gross_minor bigint, rate numeric)
RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
    SELECT round_half_even(gross_minor::numeric * rate, 0)::bigint
$$;

CREATE TABLE ledger_transactions (
    id         bigserial PRIMARY KEY,
    kind       text NOT NULL,
    currency   text NOT NULL REFERENCES currencies(code),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (
    id             bigserial PRIMARY KEY,
    transaction_id bigint NOT NULL REFERENCES ledger_transactions(id) ON DELETE CASCADE,
    account        text   NOT NULL,
    -- Signed minor units: debits positive, credits negative. Never floating point.
    amount_minor   bigint NOT NULL,
    currency       text   NOT NULL REFERENCES currencies(code),
    CHECK (amount_minor <> 0)
);
CREATE INDEX ON ledger_entries (transaction_id);
CREATE INDEX ON ledger_entries (account);

-- The invariant, enforced by the database rather than by discipline: the entries of a
-- transaction must sum to zero, checked at COMMIT so multi-statement posting still works.
CREATE OR REPLACE FUNCTION assert_transaction_balanced()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_tx bigint; v_sum bigint; v_currencies int;
BEGIN
    v_tx := coalesce(NEW.transaction_id, OLD.transaction_id);
    SELECT sum(amount_minor), count(DISTINCT currency)
      INTO v_sum, v_currencies
      FROM ledger_entries WHERE transaction_id = v_tx;
    IF v_sum <> 0 THEN
        RAISE EXCEPTION 'LEDGER_UNBALANCED: transaction % sums to %', v_tx, v_sum
            USING ERRCODE = 'P0001';
    END IF;
    -- No cross-currency transactions: a job is priced and settled in one currency.
    IF v_currencies > 1 THEN
        RAISE EXCEPTION 'LEDGER_MIXED_CURRENCY: transaction %', v_tx USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_balanced
AFTER INSERT OR UPDATE OR DELETE ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION assert_transaction_balanced();

-- Post a whole transaction atomically: [{"account": "...", "amount_minor": n}, ...]
CREATE FUNCTION post_transaction(p_kind text, p_entries jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_tx bigint; v_currency text; v_sum bigint; v_currencies int;
BEGIN
    -- Validate BEFORE writing. The deferred trigger below is the backstop, but it fires at
    -- COMMIT, outside any PL/pgSQL exception handler, and aborts the whole transaction -
    -- so a caller could never turn it into a friendly error code. (Found by S-14 cases 19-20.)
    SELECT sum((e ->> 'amount_minor')::bigint), count(DISTINCT e ->> 'currency')
      INTO v_sum, v_currencies
      FROM jsonb_array_elements(p_entries) e;
    IF v_sum <> 0 THEN
        RAISE EXCEPTION 'LEDGER_UNBALANCED: entries sum to %', v_sum USING ERRCODE = 'P0001';
    END IF;
    IF v_currencies > 1 THEN
        RAISE EXCEPTION 'LEDGER_MIXED_CURRENCY' USING ERRCODE = 'P0001';
    END IF;

    v_currency := p_entries -> 0 ->> 'currency';
    INSERT INTO ledger_transactions (kind, currency) VALUES (p_kind, v_currency) RETURNING id INTO v_tx;
    INSERT INTO ledger_entries (transaction_id, account, amount_minor, currency)
    SELECT v_tx, e ->> 'account', (e ->> 'amount_minor')::bigint, e ->> 'currency'
      FROM jsonb_array_elements(p_entries) e;
    RETURN v_tx;
END $$;

-- Balances are derived, never stored as truth.
CREATE OR REPLACE VIEW account_balances AS
SELECT account, currency, sum(amount_minor) AS balance_minor
FROM ledger_entries GROUP BY account, currency;
