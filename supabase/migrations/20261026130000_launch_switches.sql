-- The switches RB-13 flips, present in every environment.
--
-- Rehearsing RB-13 on staging (2026-10-26) found `feature_flags` empty and no
-- `min_supported_app_version`: the dev seed creates them and nothing else does, so in an environment
-- built from migrations alone the break-glass `UPDATE` changes no row and reports success. A switch
-- that is not there cannot be flipped in an incident.
--
-- Defaults are the launch-safe ones, not the seed's: the concierge stays off until its service
-- exists, PSTN fallback stays off until a telephony provider does. `ON CONFLICT DO NOTHING`, so an
-- environment that already has a row (the sandbox, which was seeded) keeps its value.

INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible) VALUES
  ('concierge.text', NULL, false, 100, true),
  ('concierge.voice', NULL, false, 100, true),
  ('calls.pstn_fallback', NULL, false, 0, true)
ON CONFLICT DO NOTHING;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('min_supported_app_version', NULL, '{"android": "0.1.0", "ios": "0.1.0", "web": "0.1.0"}', true),
  -- OD-17: Pidgin voice stays off until the S-08 gate passes.
  ('voice_languages', NULL, '{"en": true, "pcm": false}', true)
ON CONFLICT DO NOTHING;
