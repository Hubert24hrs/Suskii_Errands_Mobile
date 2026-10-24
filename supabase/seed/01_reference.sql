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
  ('NG', 'abuja',        'FCT (Abuja)',  'Africa/Lagos',        extensions.ST_GeogFromText('POINT(7.4951 9.0579)')),
  -- The other 35 states, centred on their capitals [A: approximate coordinates]. Nigeria's service
  -- areas are states; Lagos and Abuja (the FCT) keep their original codes.
  ('NG', 'abia', 'Abia', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.4896 5.5265)')),
  ('NG', 'adamawa', 'Adamawa', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(12.4954 9.2035)')),
  ('NG', 'akwa-ibom', 'Akwa Ibom', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.9128 5.0377)')),
  ('NG', 'anambra', 'Anambra', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.0741 6.2104)')),
  ('NG', 'bauchi', 'Bauchi', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(9.8442 10.3158)')),
  ('NG', 'bayelsa', 'Bayelsa', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(6.2676 4.9267)')),
  ('NG', 'benue', 'Benue', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.5214 7.7337)')),
  ('NG', 'borno', 'Borno', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(13.151 11.8311)')),
  ('NG', 'cross-river', 'Cross River', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.3417 4.9757)')),
  ('NG', 'delta', 'Delta', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(6.7319 6.198)')),
  ('NG', 'ebonyi', 'Ebonyi', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.1137 6.3249)')),
  ('NG', 'edo', 'Edo', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(5.6037 6.335)')),
  ('NG', 'ekiti', 'Ekiti', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(5.2214 7.6211)')),
  ('NG', 'enugu', 'Enugu', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.5464 6.4584)')),
  ('NG', 'gombe', 'Gombe', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(11.1673 10.2897)')),
  ('NG', 'imo', 'Imo', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.0333 5.4836)')),
  ('NG', 'jigawa', 'Jigawa', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(9.3388 11.7562)')),
  ('NG', 'kaduna', 'Kaduna', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.4165 10.5105)')),
  ('NG', 'kano', 'Kano', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.592 12.0022)')),
  ('NG', 'katsina', 'Katsina', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.6018 12.9908)')),
  ('NG', 'kebbi', 'Kebbi', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(4.1975 12.4539)')),
  ('NG', 'kogi', 'Kogi', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(6.7333 7.8023)')),
  ('NG', 'kwara', 'Kwara', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(4.5421 8.4966)')),
  ('NG', 'nasarawa', 'Nasarawa', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.515 8.4939)')),
  ('NG', 'niger', 'Niger', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(6.5569 9.6139)')),
  ('NG', 'ogun', 'Ogun', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(3.3619 7.1475)')),
  ('NG', 'ondo', 'Ondo', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(5.2058 7.2571)')),
  ('NG', 'osun', 'Osun', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(4.5418 7.7827)')),
  ('NG', 'oyo', 'Oyo', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(3.947 7.3775)')),
  ('NG', 'plateau', 'Plateau', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(8.8583 9.8965)')),
  ('NG', 'rivers', 'Rivers', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(7.0498 4.8156)')),
  ('NG', 'sokoto', 'Sokoto', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(5.2476 13.0059)')),
  ('NG', 'taraba', 'Taraba', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(11.3667 8.8833)')),
  ('NG', 'yobe', 'Yobe', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(11.9608 11.747)')),
  ('NG', 'zamfara', 'Zamfara', 'Africa/Lagos', extensions.ST_GeogFromText('POINT(6.6614 12.1628)')),
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

-- Safety (Phase 4). The escalation window is deliberately short: an SOS nobody has acknowledged
-- in three minutes is an SOS that needs someone else's attention (AD-21).
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('trusted_contacts_max', NULL, '5', true),
  ('sos_escalate_after_minutes', NULL, '3', false),
  ('trip_share_ttl_minutes', NULL, '60', true)
ON CONFLICT DO NOTHING;

-- KYC. The required step sets are config so a country that asks for more does not need a
-- migration; these are the spec's minimum. `police_clearance_max_age_months` is OD-09's proposed
-- default and belongs to counsel, not to us.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('kyc_steps_customer', NULL, '["customer_facial"]', true),
  ('kyc_steps_provider', NULL,
   '["provider_facial", "government_id", "id_document_capture", "police_clearance"]', true),
  ('police_clearance_max_age_months', NULL, '6', false)
ON CONFLICT DO NOTHING;

-- Moderation (Phase 4). The global baseline lives in the migration, because a production
-- database that moderates nothing is worse than no moderation at all. These three are the
-- country-specific rules from the packs, which belong with the country rows they depend on.
-- All `[A]`: every pack tags `restricted: assumption`, awaiting counsel.
INSERT INTO public.prohibited_items (country_code, key, kind, match_terms, action) VALUES
  ('NG', 'sim_cards_preregistered', 'item',
   ARRAY['pre-registered sim', 'preregistered sim', 'registered sim card',
         'already registered sim'], 'block'),
  ('KE', 'single_use_plastic_carrier_bags', 'item',
   ARRAY['plastic carrier bag', 'plastic carrier bags', 'polythene bag'], 'hold'),
  ('ZA', 'alcohol_outside_licensed_hours', 'item',
   ARRAY['alcohol after hours', 'after hours alcohol'], 'hold')
ON CONFLICT DO NOTHING;
