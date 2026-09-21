-- The double-entry ledger (ERD §6; `docs/plan/money-flows.md`; ADR-0011; spike S-14).
--
-- The spine of this file is the spec's own worked example — a USD 100.00 job, 12.50 commission,
-- 87.50 net, 2.19 referral, 2.90 collection fee, 0.50 transfer fee — posted through 1a…1d exactly
-- as `money-flows.md` sets them out, and then checked: every transaction sums to zero, the
-- balances match the entries, and the platform's net position is the spec's 10.31.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(30);

INSERT INTO auth.users (id, phone) VALUES
  ('c1111111-1111-4111-8111-888888888888', '2348000000211'),   -- customer
  ('c2222222-2222-4222-8222-888888888888', '2348000000212'),   -- provider
  ('c3333333-3333-4333-8333-888888888888', '2348000000213');   -- referrer
UPDATE public.profiles SET country_code = 'NG' WHERE user_id IN
  ('c1111111-1111-4111-8111-888888888888',
   'c2222222-2222-4222-8222-888888888888',
   'c3333333-3333-4333-8333-888888888888');

-- ---------------------------------------------------------------------------
-- The schema is unreachable, which is the whole point of putting money in it.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
                  unnest(ARRAY['ledger.accounts', 'ledger.transactions', 'ledger.entries',
                               'ledger.balances']) t
           WHERE has_table_privilege(r, t, 'SELECT')), 0,
  'no client role, and not the service role either, can read a ledger table');
SELECT is((SELECT count(*)::int FROM information_schema.columns
           WHERE table_schema = 'ledger' AND data_type IN
                 ('real', 'double precision', 'numeric', 'money')), 0,
  'and there is no floating point anywhere in the books');

-- ---------------------------------------------------------------------------
-- The arithmetic the spec states, before any of it is written down.
-- ---------------------------------------------------------------------------
SELECT is(private.apply_bps(10000::bigint, 1250), 1250::bigint,
  'commission on the spec''s worked example is 12.50, not 12.00 (OD-06)');
SELECT is(private.apply_bps(8750::bigint, 250), 219::bigint,
  'and the referral is 2.19 — half-even on 218.75, which rounds to even');
SELECT is(private.apply_bps(250::bigint, 250), 6::bigint,
  'half-even rounds 6.25 down to 6, where half-up would give 7');

-- ---------------------------------------------------------------------------
-- 1a. Payment confirmed. The customer's 100.00 becomes a liability, the gateway keeps 2.90.
-- ---------------------------------------------------------------------------
SELECT ok(ledger.post('payment_captured', 'USD', 'key-lg-1a-00000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', 9710),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                       'amount_minor', 290),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', -10000))) > 0,
  '1a: the payment is captured and the money is held');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'and it balances');

-- A retry of the same webhook must not post the money twice.
SELECT is(ledger.post('payment_captured', 'USD', 'key-lg-1a-00000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', 9710),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                       'amount_minor', 290),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', -10000))),
  (SELECT min(id) FROM ledger.transactions),
  'a replayed webhook returns the transaction that exists rather than posting a second');
SELECT is((SELECT count(*)::int FROM ledger.entries), 3, 'so there are still three entries');

-- ---------------------------------------------------------------------------
-- 1b. The gateway settles into the merchant balance.
-- ---------------------------------------------------------------------------
SELECT ok(ledger.post('gateway_settled', 'USD', 'key-lg-1b-00000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', 9710),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_pending',
                       'amount_minor', -9710))) > 0,
  '1b: the gateway settles, T+1 to T+5');

-- ---------------------------------------------------------------------------
-- 1c. Earnings recognised. Commission, the fee recovered from the provider (ADR-0003), the
-- referral the platform funds (OD-01 default).
-- ---------------------------------------------------------------------------
SELECT ok(ledger.post('earnings_recognised', 'USD', 'key-lg-1c-00000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', 10000),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', -1250),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                       'amount_minor', -290),
    jsonb_build_object('owner_kind', 'user', 'owner_id', 'c2222222-2222-4222-8222-888888888888',
                       'account_type', 'provider_earnings', 'amount_minor', -8460),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_referral_expense',
                       'amount_minor', 219),
    jsonb_build_object('owner_kind', 'user', 'owner_id', 'c3333333-3333-4333-8333-888888888888',
                       'account_type', 'referral_earnings', 'amount_minor', -219))) > 0,
  '1c: earnings are recognised');
SELECT is((SELECT count(*)::int FROM ledger.unbalanced_transactions()), 0, 'and it balances');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c2222222-2222-4222-8222-888888888888'
             AND a.account_type = 'provider_earnings'), 8460::bigint,
  'the provider is owed 84.60 — net 87.50 minus the 2.90 fee they bear (ADR-0003)');
SELECT is((SELECT -b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.owner_id = 'c3333333-3333-4333-8333-888888888888'
             AND a.account_type = 'referral_earnings'), 219::bigint,
  'and the referrer 2.19, funded by the platform so provider earnings are untouched (OD-01)');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'held_funds'), 0::bigint,
  'the hold is released to nothing: the platform no longer owes anybody the customer''s money');

-- ---------------------------------------------------------------------------
-- 1d. The payout lands, and the provider bears the transfer fee (OD-10 default).
-- ---------------------------------------------------------------------------
SELECT ok(ledger.post('payout_paid', 'USD', 'key-lg-1d-00000001', jsonb_build_array(
    jsonb_build_object('owner_kind', 'user', 'owner_id', 'c2222222-2222-4222-8222-888888888888',
                       'account_type', 'provider_earnings', 'amount_minor', 8460),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', -8410),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', -50))) > 0,
  '1d: the payout succeeds, and the provider bears the transfer fee (OD-10)');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_available'), 1250::bigint,
  'two entries to one account in a single posting land on one balance, and the platform is left
   holding exactly its 12.50 in cash');

-- ---------------------------------------------------------------------------
-- The spec's worked example, checked at the end of the whole flow.
-- ---------------------------------------------------------------------------
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'platform_revenue'), -1250::bigint,
  'the platform recognised 12.50 of revenue');
SELECT is((SELECT -(SELECT b.balance_minor FROM ledger.balances b
                    JOIN ledger.accounts a ON a.id = b.account_id
                    WHERE a.account_type = 'platform_revenue')
           - (SELECT b.balance_minor FROM ledger.balances b
              JOIN ledger.accounts a ON a.id = b.account_id
              WHERE a.account_type = 'platform_referral_expense')), 1031::bigint,
  'net platform revenue is 10.31 — revenue 12.50 less the 2.19 it still owes the referrer');
SELECT is((SELECT b.balance_minor FROM ledger.balances b
           JOIN ledger.accounts a ON a.id = b.account_id
           WHERE a.account_type = 'gateway_fees'), 0::bigint,
  'the collection fee nets to zero: it was recovered from the provider, not absorbed');
SELECT is((SELECT count(*)::int FROM ledger.reconcile()), 0,
  'and every balance still matches the entries behind it');
SELECT is((SELECT sum(e.amount_minor) FROM ledger.entries e), 0::bigint,
  'the whole book sums to zero, which is the only invariant that matters');

-- ---------------------------------------------------------------------------
-- What the ledger refuses.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT ledger.post('adjustment', 'USD', 'key-lg-bad-0000001', jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', -100),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', 99)))$$,
  'P0001', 'ERR_LEDGER_UNBALANCED',
  'a penny out is refused before anything is written — catchably, per S-14');
SELECT throws_ok(
  $$SELECT ledger.post('adjustment', 'USD', 'key-lg-bad-0000002', jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', 0),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', 0)))$$,
  'P0001', 'ERR_LEDGER_EMPTY_ENTRY', 'an entry of zero records nothing and is refused');
SELECT throws_ok(
  $$SELECT ledger.post('adjustment', 'USD', 'key-lg-bad-0000003', jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', 100)))$$,
  'P0001', 'ERR_LEDGER_UNBALANCED', 'one entry is not double entry');
SELECT throws_ok(
  $$SELECT ledger.post('adjustment', 'XXX', 'key-lg-bad-0000004', jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', -100),
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                         'amount_minor', 100)))$$,
  '22023', 'ERR_UNKNOWN_CURRENCY', 'and a currency nobody has an exponent for is refused');
SELECT throws_ok(
  $$SELECT ledger.account('platform', 'c1111111-1111-4111-8111-888888888888'::uuid,
      'platform_revenue', 'USD')$$,
  '22023', 'ERR_INVALID_ARGUMENT', 'the platform is not a user, and cannot own a user account');
SELECT is((SELECT count(*)::int FROM ledger.transactions WHERE kind = 'adjustment'), 0,
  'none of the refusals left a transaction behind');

-- The deferred invariant, which `ledger.post` should never reach. Forced immediate, because a
-- deferred trigger otherwise fires at COMMIT — and this file ends in ROLLBACK.
SELECT lives_ok($$
  INSERT INTO ledger.transactions (kind, currency, idempotency_key)
  VALUES ('adjustment', 'USD', 'key-lg-direct-000001')$$,
  'a transaction row on its own is fine');
INSERT INTO ledger.entries (transaction_id, account_id, amount_minor, currency)
SELECT (SELECT max(id) FROM ledger.transactions),
       ledger.account('platform', NULL, 'platform_revenue', 'USD'), -100, 'USD';
SELECT throws_ok($$SET CONSTRAINTS ALL IMMEDIATE$$,
  'P0001', 'ERR_LEDGER_UNBALANCED',
  'writing entries around the posting function is still caught, by the invariant nothing can route around');

SELECT * FROM finish();
ROLLBACK;
