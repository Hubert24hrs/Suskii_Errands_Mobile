-- The switch RB-05 tells on-call to flip during an identity-vendor outage.
--
-- Rehearsing RB-05 on staging (2026-10-26): step 4 says to turn off the verification entry with a
-- flag (RB-13), so people stop failing at a liveness check that cannot succeed and assume they are
-- the problem. No such flag existed, in RB-13's table or in any environment. On by default:
-- verification is the normal state, and the switch exists for the outage.
--
-- A client switch, like every other flag today: it hides the entry screen, it does not refuse a
-- session. Nothing is lost by a session started anyway; it queues (RB-05, resolution A).

INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible) VALUES
  ('kyc.verification_entry', NULL, true, 100, true)
ON CONFLICT DO NOTHING;
