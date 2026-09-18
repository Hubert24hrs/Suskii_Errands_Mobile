-- DEV AND STAGING ONLY. Never applied to production (spec: seed data for dev/staging only).
-- Country statuses follow the OD-14 proposed default (NG live, others beta) so every flow can
-- be exercised; production statuses are set through the four-eyes country-pack approval.
-- Legal document URLs use the reserved .invalid TLD so nothing here looks like a real policy.

INSERT INTO public.countries
  (code, name, status, currency_code, calling_code, default_language, supported_languages, config)
VALUES
  ('NG', 'Nigeria',      'live', 'NGN', '234', 'en', ARRAY['en', 'pcm'],
   '{"client": {"accepted_id_types": ["nin", "bvn", "voters_card", "drivers_licence", "passport"]},
     "server": {"sms_providers": ["console"]}}'),
  ('KE', 'Kenya',        'beta', 'KES', '254', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["national_id", "passport"]}, "server": {"sms_providers": ["console"]}}'),
  ('GH', 'Ghana',        'beta', 'GHS', '233', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["ghana_card", "passport"]}, "server": {"sms_providers": ["console"]}}'),
  ('ZA', 'South Africa', 'beta', 'ZAR', '27',  'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["sa_id", "passport"]}, "server": {"sms_providers": ["console"]}}'),
  ('UG', 'Uganda',       'beta', 'UGX', '256', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["national_id", "passport"]}, "server": {"sms_providers": ["console"]}}')
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.cities (country_code, code, name, timezone, center) VALUES
  ('NG', 'lagos',        'Lagos',        'Africa/Lagos',        extensions.ST_GeogFromText('POINT(3.3792 6.5244)')),
  ('NG', 'abuja',        'Abuja',        'Africa/Lagos',        extensions.ST_GeogFromText('POINT(7.4951 9.0579)')),
  ('KE', 'nairobi',      'Nairobi',      'Africa/Nairobi',      extensions.ST_GeogFromText('POINT(36.8219 -1.2921)')),
  ('GH', 'accra',        'Accra',        'Africa/Accra',        extensions.ST_GeogFromText('POINT(-0.1870 5.6037)')),
  ('ZA', 'johannesburg', 'Johannesburg', 'Africa/Johannesburg', extensions.ST_GeogFromText('POINT(28.0473 -26.2041)')),
  ('UG', 'kampala',      'Kampala',      'Africa/Kampala',      extensions.ST_GeogFromText('POINT(32.5825 0.3476)'))
ON CONFLICT (country_code, code) DO NOTHING;

INSERT INTO public.legal_documents (country_code, type, version, locale, url, published_at) VALUES
  ('NG', 'terms',                   1, 'en', 'https://suskii.invalid/ng/terms/v1',             now()),
  ('NG', 'privacy',                 1, 'en', 'https://suskii.invalid/ng/privacy/v1',           now()),
  ('NG', 'biometric_consent',       1, 'en', 'https://suskii.invalid/ng/biometric-consent/v1', now()),
  ('NG', 'criminal_record_consent', 1, 'en', 'https://suskii.invalid/ng/criminal-record-consent/v1', now())
ON CONFLICT DO NOTHING;

INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible) VALUES
  ('concierge.text',  NULL, true,  100, true),
  ('concierge.voice', NULL, true,  100, true),
  ('concierge.voice', 'NG', true,  100, true),
  ('calls.pstn_fallback', NULL, false, 0, true)
ON CONFLICT DO NOTHING;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('min_supported_app_version', NULL, '{"android": "0.1.0", "ios": "0.1.0", "web": "0.1.0"}', true),
  -- OD-17: Pidgin voice stays off until the S-08 gate passes (review M3.4).
  ('voice_languages', NULL, '{"en": true, "pcm": false}', true)
ON CONFLICT DO NOTHING;

-- Matching weights and the heartbeat gate, as remote config so ops can tune them without a
-- release (ai-design §9; ADR-0009 and S-06 for the gate). These are the same values the
-- functions fall back to, written out so the shape is visible in the admin console.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('matching_weights', NULL,
   '{"distance": 40, "rating": 20, "completion": 15, "response": 10, "cancellation": 15, "workload": 10}',
   false),
  ('location_min_move_m', NULL, '25', true),
  ('location_max_interval_s', NULL, '60', true)
ON CONFLICT DO NOTHING;

-- Ratings and reputation. The window is an assumption until the client sets one: SH-30 requires
-- a window but the timeline does not name a length. The prior is the Bayesian smoothing SH-31
-- calls for — a new provider starts at 4.5 stars with the weight of ten jobs behind it, so one
-- rating moves them a little and fifty move them a lot.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('ratings_window_hours', NULL, '168', true),
  ('reputation_prior_weight', NULL, '10', false),
  ('reputation_prior_milli', NULL, '4500', false),
  ('job_auto_confirm_hours', NULL, '24', true),
  ('job_pin_max_attempts', NULL, '5', true),
  ('job_arrival_geofence_m', NULL, '150', true)
ON CONFLICT DO NOTHING;

-- Chat stays open for a day after the job is confirmed, so a question about work that has just
-- finished still has somewhere to go.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('chat_window_hours_after_confirm', NULL, '24', true)
ON CONFLICT DO NOTHING;
