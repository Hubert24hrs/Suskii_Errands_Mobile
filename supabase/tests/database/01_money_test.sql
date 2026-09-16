-- Money primitives: half-even rounding, basis-point application, currency exponents (S-14).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(21);

SELECT is(private.round_half_even(0.5),  0::numeric, 'round_half_even 0.5 -> 0');
SELECT is(private.round_half_even(1.5),  2::numeric, 'round_half_even 1.5 -> 2');
SELECT is(private.round_half_even(2.5),  2::numeric, 'round_half_even 2.5 -> 2 (built-in round gives 3)');
SELECT is(private.round_half_even(-0.5), 0::numeric, 'round_half_even -0.5 -> 0');
SELECT is(private.round_half_even(-1.5), -2::numeric, 'round_half_even -1.5 -> -2');
SELECT is(private.round_half_even(-2.5), -2::numeric, 'round_half_even -2.5 -> -2');
SELECT is(private.round_half_even(2.4999), 2::numeric, 'round_half_even 2.4999 -> 2');
SELECT is(private.round_half_even(2.5001), 3::numeric, 'round_half_even 2.5001 -> 3');

-- Spec worked example: gross 100.00, commission 12.5%, net 87.50, referral 2.5% of net = 2.19.
SELECT is(private.apply_bps(10000, 1250), 1250::bigint, 'commission on 100.00 at 1250 bps is 12.50');
SELECT is(private.apply_bps(8750, 250), 219::bigint, 'referral on 87.50 at 250 bps is 2.19 (2.1875 half-even)');
SELECT is(private.apply_bps(4, 1250), 0::bigint, '0.5 minor unit rounds to even 0');
SELECT is(private.apply_bps(12, 1250), 2::bigint, '1.5 minor units round to even 2');
SELECT is(private.apply_bps(1, 1250), 0::bigint, '0.125 minor units rounds to 0');
SELECT is(private.apply_bps(100000, 1250), 12500::bigint, 'UGX 100000 (exponent 0) at 1250 bps is 12500');
SELECT throws_ok($$SELECT private.apply_bps(100, 10001)$$, '22023', 'ERR_INVALID_RATE',
  'a rate above 10000 bps is refused');

SELECT is(private.currency_exponent('UGX'), 0::smallint, 'UGX has exponent 0');
SELECT is(private.currency_exponent('NGN'), 2::smallint, 'NGN has exponent 2');
SELECT throws_ok($$SELECT private.currency_exponent('XYZ')$$, '22023', 'ERR_UNKNOWN_CURRENCY',
  'an unknown currency is refused, never defaulted');

SET LOCAL ROLE anon;
SELECT ok((SELECT count(*) FROM public.currencies) >= 6, 'anon can read currencies');
SELECT throws_ok($$INSERT INTO public.currencies VALUES ('ABC', 2, 'x')$$, '42501', NULL,
  'anon cannot insert currencies');
SELECT throws_ok($$SELECT private.apply_bps(100, 100)$$, '42501', NULL,
  'anon cannot call money primitives directly');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
