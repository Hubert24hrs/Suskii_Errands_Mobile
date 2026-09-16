-- S-13 tests. Each case sets a role and JWT claims, attempts something, and records
-- whether the outcome matched. Deny cases are as important as allow cases.

\set ON_ERROR_STOP off

DROP TABLE IF EXISTS test_results;
CREATE TABLE test_results (n serial, name text, expected text, actual text, passed boolean);
-- The harness writes results while impersonating anon/authenticated, so the results table
-- itself must be writable by every test role. It carries no RLS and proves nothing by itself.
GRANT INSERT, SELECT ON test_results TO PUBLIC;
GRANT USAGE, SELECT ON SEQUENCE test_results_n_seq TO PUBLIC;

CREATE OR REPLACE FUNCTION as_user(p_uid text, p_role text DEFAULT 'authenticated')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('request.jwt.claims',
        json_build_object('sub', p_uid, 'role', p_role)::text, true);
END $$;

CREATE OR REPLACE FUNCTION check_case(p_name text, p_expected text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_actual text; v_count int;
BEGIN
    BEGIN
        EXECUTE p_sql INTO v_count;
        v_actual := 'rows=' || coalesce(v_count::text, 'null');
    EXCEPTION WHEN OTHERS THEN
        -- SQLSTATE is what matters; message text varies.
        v_actual := 'error=' || SQLSTATE;
    END;
    INSERT INTO test_results (name, expected, actual, passed)
    VALUES (p_name, p_expected, v_actual, v_actual = p_expected);
END $$;

-- Seed as owner (RLS forced, so seed before switching roles).
TRUNCATE requests, profiles;
INSERT INTO profiles (user_id, display_name, trust_level) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Ada',   1),
    ('22222222-2222-2222-2222-222222222222', 'Chidi', 2);
INSERT INTO requests (customer_id, title, status) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Deliver documents', 'DRAFT'),
    ('22222222-2222-2222-2222-222222222222', 'Move a sofa',       'DRAFT');

DO $$
DECLARE ada text := '11111111-1111-1111-1111-111111111111';
        chidi text := '22222222-2222-2222-2222-222222222222';
        ada_req bigint;
BEGIN
    -- Captured as superuser: under RLS an attacker cannot even name another user's row,
    -- so the test must hand the id over explicitly to exercise the function's own check.
    SELECT min(id) INTO ada_req FROM requests WHERE customer_id = ada::uuid;
    -- 1. anon sees nothing (default deny, no policy at all)
    PERFORM as_user(ada, 'anon');
    SET LOCAL ROLE anon;
    PERFORM check_case('anon cannot read profiles', 'error=42501',
        'SELECT count(*) FROM profiles');
    PERFORM check_case('anon cannot read requests', 'error=42501',
        'SELECT count(*) FROM requests');
    RESET ROLE;

    -- 2. an authenticated user sees only their own rows
    PERFORM as_user(ada);
    SET LOCAL ROLE authenticated;
    PERFORM check_case('user reads only own profile', 'rows=1',
        'SELECT count(*) FROM profiles');
    PERFORM check_case('user reads only own requests', 'rows=1',
        'SELECT count(*) FROM requests');

    -- 3. protected columns are refused even on a row the user owns
    PERFORM check_case('user cannot raise own trust_level', 'error=42501',
        'WITH u AS (UPDATE profiles SET trust_level = 3 WHERE user_id = auth.uid() RETURNING 1) SELECT count(*) FROM u');
    PERFORM check_case('user cannot set verified_at', 'error=42501',
        'WITH u AS (UPDATE profiles SET verified_at = now() WHERE user_id = auth.uid() RETURNING 1) SELECT count(*) FROM u');
    PERFORM check_case('user CAN change own display_name', 'rows=1',
        'WITH u AS (UPDATE profiles SET display_name = ''Ada N'' WHERE user_id = auth.uid() RETURNING 1) SELECT count(*) FROM u');

    -- 4. status and money are server-owned
    PERFORM check_case('user cannot write request status', 'error=42501',
        'WITH u AS (UPDATE requests SET status = ''PAID_HELD'' WHERE customer_id = auth.uid() RETURNING 1) SELECT count(*) FROM u');
    PERFORM check_case('user cannot write agreed amount', 'error=42501',
        'WITH u AS (UPDATE requests SET agreed_amount_minor = 1 WHERE customer_id = auth.uid() RETURNING 1) SELECT count(*) FROM u');

    -- 5. cannot create rows owned by someone else
    PERFORM check_case('user cannot insert for another user', 'error=42501',
        format('WITH i AS (INSERT INTO requests (customer_id, title) VALUES (%L, ''sneaky'') RETURNING 1) SELECT count(*) FROM i', chidi));
    PERFORM check_case('user can insert own request', 'rows=1',
        format('WITH i AS (INSERT INTO requests (customer_id, title) VALUES (%L, ''own'') RETURNING 1) SELECT count(*) FROM i', ada));

    -- 6. the sanctioned path works, and only for the owner
    PERFORM check_case('owner can publish via function', 'rows=1',
        '(SELECT count(*) FROM (SELECT publish_request((SELECT min(id) FROM requests WHERE customer_id = auth.uid()))) s)');
    RESET ROLE;

    PERFORM as_user(chidi);
    SET LOCAL ROLE authenticated;
    PERFORM check_case('non-owner cannot publish another request', 'error=42501',
        format('(SELECT count(*) FROM (SELECT publish_request(%s)) s)', ada_req));
    RESET ROLE;

    -- 7. unauthenticated call to the function is refused
    PERFORM set_config('request.jwt.claims', '', true);
    SET LOCAL ROLE authenticated;
    PERFORM check_case('unauthenticated cannot publish', 'error=28000',
        '(SELECT count(*) FROM (SELECT publish_request(1)) s)');
    RESET ROLE;

    -- 8. a Verification Officer reads every profile but writes none
    PERFORM as_user(ada, 'verification_officer');
    SET LOCAL ROLE verification_officer;
    PERFORM check_case('officer reads all profiles', 'rows=2',
        'SELECT count(*) FROM profiles');
    PERFORM check_case('officer cannot write profiles', 'error=42501',
        'WITH u AS (UPDATE profiles SET trust_level = 3 RETURNING 1) SELECT count(*) FROM u');
    RESET ROLE;

    -- 9. service_role bypasses RLS: proves why the key must never reach a client
    PERFORM as_user(ada, 'service_role');
    SET LOCAL ROLE service_role;
    PERFORM check_case('service_role sees everything (must stay server-side)', 'rows=2',
        'SELECT count(*) FROM profiles');
    RESET ROLE;
END $$;

SELECT n, name, expected, actual, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM test_results ORDER BY n;

SELECT count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed,
       count(*) AS total
FROM test_results;
