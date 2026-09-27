-- The two deferred invariants run as the owner (audit 2026-09-27 Y.28, Critical).
--
-- `ledger.entries_balanced` and `refunds_within_payment` are DEFERRABLE INITIALLY DEFERRED
-- constraint triggers (S-14): they fire at COMMIT, after every SECURITY DEFINER function in the
-- transaction has returned — so they execute as the role that opened the transaction. Through the
-- API that is `service_role` (the payments webhook, settlement, payouts, chargebacks) or
-- `authenticated` (tips, cancellations, withdrawals), and neither may read the `ledger` schema.
-- Every money-moving call would have failed at COMMIT with "permission denied for schema ledger"
-- — the first real payment webhook included.
--
-- The refunds invariant failed the other way: it reads `payments` and `refunds` through the
-- caller's row level security, so for a caller who cannot see those rows the sum is short or the
-- payment is invisible, and the check passes whatever the refunds add up to.
--
-- Neither was visible to pgTAP, because a test transaction rolls back and deferred triggers never
-- fire. `48_deferred_invariants_test` fires them as each calling role with
-- `SET CONSTRAINTS ALL IMMEDIATE`. Trigger functions cannot be called directly, so definer rights
-- widen nothing a client can reach.

ALTER FUNCTION ledger.assert_balanced() SECURITY DEFINER;
ALTER FUNCTION private.assert_refunds_within_payment() SECURITY DEFINER;
