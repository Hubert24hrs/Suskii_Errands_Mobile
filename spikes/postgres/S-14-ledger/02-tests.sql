-- S-14 tests: rounding, the spec's worked example, and ledger invariants.

\set ON_ERROR_STOP off

DROP TABLE IF EXISTS money_results;
CREATE TABLE money_results (n serial, name text, expected text, actual text, passed boolean);

CREATE OR REPLACE FUNCTION expect(p_name text, p_expected text, p_actual text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO money_results (name, expected, actual, passed)
    VALUES (p_name, p_expected, p_actual, p_expected = p_actual);
END $$;

CREATE OR REPLACE FUNCTION expect_error(p_name text, p_sqlstate text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_actual text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        v_actual := 'no error';
    EXCEPTION WHEN OTHERS THEN
        v_actual := SQLSTATE;
    END;
    INSERT INTO money_results (name, expected, actual, passed)
    VALUES (p_name, p_sqlstate, v_actual, v_actual = p_sqlstate);
END $$;

TRUNCATE ledger_entries, ledger_transactions RESTART IDENTITY CASCADE;

DO $$
DECLARE
    gross    bigint := 10000;   -- USD 100.00 in minor units (spec worked example)
    comm     bigint;
    net      bigint;
    referral bigint;
    gateway  bigint := 290;     -- USD 2.90, as reported by the gateway
    payout   bigint;
    tx       bigint;
BEGIN
    -- 1. half-even really is half-even (Postgres round() is not)
    -- trim_scale(): numeric keeps its scale, so 2 and 2.0000 differ as TEXT but not as numbers.
    PERFORM expect('round_half_even(0.5)  -> 0 (even)', '0', trim_scale(round_half_even(0.5))::text);
    PERFORM expect('round_half_even(1.5)  -> 2 (even)', '2', trim_scale(round_half_even(1.5))::text);
    PERFORM expect('round_half_even(2.5)  -> 2 (even)', '2', trim_scale(round_half_even(2.5))::text);
    PERFORM expect('round_half_even(3.5)  -> 4 (even)', '4', trim_scale(round_half_even(3.5))::text);
    PERFORM expect('round_half_even(-2.5) -> -2 (even)', '-2', trim_scale(round_half_even(-2.5))::text);
    PERFORM expect('round_half_even(2.4)  -> 2', '2', trim_scale(round_half_even(2.4))::text);
    PERFORM expect('round_half_even(2.6)  -> 3', '3', trim_scale(round_half_even(2.6))::text);
    -- and it differs from the built-in, which is why it has to exist
    PERFORM expect('built-in round(2.5) is NOT half-even', '3', round(2.5)::text);

    -- 2. the spec's worked example: USD 100.00
    comm     := commission_minor(gross, 0.125);            -- 12.50
    net      := gross - comm;                              -- 87.50
    referral := round_half_even(net::numeric * 0.025, 0)::bigint;  -- 2.1875 -> 2.19
    payout   := net - gateway;

    PERFORM expect('commission of 100.00 at 12.5%', '1250', comm::text);
    PERFORM expect('net after commission',          '8750', net::text);
    PERFORM expect('referral 2.5% of net (2.1875 -> 2.19)', '219', referral::text);
    PERFORM expect('provider payout = net - gateway fee',   '8460', payout::text);
    PERFORM expect('platform revenue = commission - referral', '1031', (comm - referral)::text);

    -- 3. a half-even tie that actually bites: 12.5 minor units at a 12.5% rate
    PERFORM expect('commission_minor(100, 0.125) ties to even', '12', commission_minor(100, 0.125)::text);
    PERFORM expect('commission_minor(300, 0.125) ties to even', '38', commission_minor(300, 0.125)::text);

    -- 4. UGX has exponent 0: 10000 UGX is ten thousand shillings, not 100.00
    PERFORM expect('UGX exponent is 0', '0', (SELECT exponent FROM currencies WHERE code = 'UGX')::text);
    PERFORM expect('NGN exponent is 2', '2', (SELECT exponent FROM currencies WHERE code = 'NGN')::text);

    -- 5. the money movement of one completed job, as a balanced transaction
    tx := post_transaction('job_settlement', jsonb_build_array(
        jsonb_build_object('account', 'held_funds',         'amount_minor', -gross,    'currency', 'USD'),
        jsonb_build_object('account', 'provider_earnings',  'amount_minor',  payout,   'currency', 'USD'),
        jsonb_build_object('account', 'gateway_fees',       'amount_minor',  gateway,  'currency', 'USD'),
        jsonb_build_object('account', 'platform_revenue',   'amount_minor',  comm - referral, 'currency', 'USD'),
        jsonb_build_object('account', 'referral_earnings',  'amount_minor',  referral, 'currency', 'USD')
    ));
    PERFORM expect('settlement transaction balances',
        '0', (SELECT sum(amount_minor)::text FROM ledger_entries WHERE transaction_id = tx));
END $$;

-- 6. the invariant is enforced, not merely documented
SELECT expect_error('unbalanced transaction is rejected', 'P0001', $sql$
    SELECT post_transaction('bad', jsonb_build_array(
        jsonb_build_object('account', 'held_funds',        'amount_minor', -10000, 'currency', 'USD'),
        jsonb_build_object('account', 'provider_earnings', 'amount_minor',   9999, 'currency', 'USD')))
$sql$);

SELECT expect_error('mixed-currency transaction is rejected', 'P0001', $sql$
    SELECT post_transaction('bad_fx', jsonb_build_array(
        jsonb_build_object('account', 'held_funds',        'amount_minor', -10000, 'currency', 'USD'),
        jsonb_build_object('account', 'provider_earnings', 'amount_minor',  10000, 'currency', 'NGN')))
$sql$);

SELECT expect_error('zero-amount entry is rejected', '23514', $sql$
    SELECT post_transaction('zero', jsonb_build_array(
        jsonb_build_object('account', 'held_funds',        'amount_minor', 0, 'currency', 'USD'),
        jsonb_build_object('account', 'provider_earnings', 'amount_minor', 0, 'currency', 'USD')))
$sql$);

-- 7. a refund reverses cleanly and leaves the ledger balanced overall
DO $$
DECLARE tx bigint;
BEGIN
    tx := post_transaction('refund', jsonb_build_array(
        jsonb_build_object('account', 'provider_earnings', 'amount_minor', -8460, 'currency', 'USD'),
        jsonb_build_object('account', 'referral_earnings', 'amount_minor',  -219, 'currency', 'USD'),
        jsonb_build_object('account', 'platform_revenue',  'amount_minor', -1031, 'currency', 'USD'),
        jsonb_build_object('account', 'gateway_fees',      'amount_minor',  -290, 'currency', 'USD'),
        jsonb_build_object('account', 'refunds_payable',   'amount_minor', 10000, 'currency', 'USD')
    ));
    PERFORM expect('refund transaction balances', '0',
        (SELECT sum(amount_minor)::text FROM ledger_entries WHERE transaction_id = tx));
    PERFORM expect('whole ledger sums to zero', '0',
        (SELECT sum(amount_minor)::text FROM ledger_entries));
    PERFORM expect('provider earnings back to zero after clawback', '0',
        (SELECT coalesce(sum(amount_minor), 0)::text FROM ledger_entries WHERE account = 'provider_earnings'));
END $$;

SELECT n, name, expected, actual, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM money_results ORDER BY n;

SELECT count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed,
       count(*) AS total
FROM money_results;
