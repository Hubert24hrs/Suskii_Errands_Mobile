-- Reference data every environment needs, production included (owner, 2026-10-24: the app is
-- on Google Play, so a production project is next). Until now the countries, Nigeria's 37 states
-- and the service catalogue existed only in `supabase/seed/`, which is dev and staging only, and
-- no client or admin path can create them: a production project built from these migrations
-- had no country to sign up in, no state to serve and no category to request.
--
-- What goes in is reference data, not configuration. Every country is `disabled`, with only the
-- ID types its pack lists; going live is still the four-eyes country approval
-- (`propose_config_change`), which refuses `live` until `private.country_pack_gaps` is empty:
-- legal pages, and the SMS, payment and payout providers. Price guardrails (OD-23), the
-- country-specific prohibited items (OD-24) and the legal pages stay out because they need the
-- client's or counsel's answer, not ours. Everything is ON CONFLICT DO NOTHING, so an
-- environment that already has these rows keeps its own values; the dev seed then upgrades the
-- countries to the statuses local work needs.

INSERT INTO public.countries
  (code, name, status, currency_code, calling_code, default_language, supported_languages, config)
VALUES
  ('NG', 'Nigeria',      'disabled', 'NGN', '234', 'en', ARRAY['en', 'pcm'],
   '{"client": {"accepted_id_types": ["nin", "bvn", "voters_card", "drivers_licence", "passport"]}, "server": {}}'),
  ('KE', 'Kenya',        'disabled', 'KES', '254', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["national_id", "passport"]}, "server": {}}'),
  ('GH', 'Ghana',        'disabled', 'GHS', '233', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["ghana_card", "passport"]}, "server": {}}'),
  ('ZA', 'South Africa', 'disabled', 'ZAR', '27',  'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["sa_id", "passport"]}, "server": {}}'),
  ('UG', 'Uganda',       'disabled', 'UGX', '256', 'en', ARRAY['en'],
   '{"client": {"accepted_id_types": ["national_id", "passport"]}, "server": {}}')
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

-- The taxonomy the apps render: keys and label keys match both apps' catalogues, so
-- `create_request(category_key …)` resolves what they send. `custom` is the only category that
-- accepts a free-text label.
INSERT INTO public.service_categories
  (key, name_key, icon_key, requires_vehicle, allows_custom, offer_ttl_seconds, max_counter_rounds, sort_order)
VALUES
  ('errands_delivery',    'catErrandsDelivery',    'package',   true,  false,  600, 5,  10),
  ('shopping',            'catShopping',           'basket',    true,  false,  900, 5,  20),
  ('cleaning_laundry',    'catCleaningLaundry',    'sparkle',   false, false, 1800, 5,  30),
  ('moving',              'catMoving',             'truck',     true,  false, 1800, 5,  40),
  ('repairs',             'catRepairs',            'tools',     false, false, 1800, 5,  50),
  ('personal_assistance', 'catPersonalAssistance', 'person',    false, false,  900, 5,  60),
  ('document_delivery',   'catDocumentDelivery',   'document',  false, false,  600, 5,  70),
  ('food_pickup',         'catFoodPickup',         'food',      true,  false,  600, 5,  80),
  ('transportation',      'catTransportation',     'car',       true,  false,  900, 5,  90),
  ('tech_business',       'catTechBusiness',       'laptop',    false, false, 1800, 5, 100),
  ('event_assistance',    'catEventAssistance',    'calendar',  false, false, 1800, 5, 110),
  ('mechanics',           'catMechanics',          'mechanic',  false, false, 1800, 5, 120),
  ('fashion_design',      'catFashionDesign',      'fashion',   false, false, 1800, 5, 130),
  ('beauty_hair',         'catBeautyHair',         'beauty',    false, false, 1800, 5, 140),
  ('plumbing',            'catPlumbing',           'plumbing',  false, false, 1800, 5, 150),
  ('electrical',          'catElectrical',         'electric',  false, false, 1800, 5, 160),
  ('carpentry',           'catCarpentry',          'carpentry', false, false, 1800, 5, 170),
  ('catering',            'catCatering',           'catering',  false, false, 1800, 5, 180),
  ('photography',         'catPhotography',        'camera',    false, false, 1800, 5, 190),
  ('tutoring',            'catTutoring',           'school',    false, false, 1800, 5, 200),
  ('custom',              'catCustom',             'magic',     false, true,   900, 5, 900)
ON CONFLICT (key) DO NOTHING;

-- What each category has to show before a provider can mark the work done (job lifecycle
-- transition 15). Defaults; ops tunes them per category. Only rows still at the empty default
-- are touched, so an environment that has tuned them keeps its values.
UPDATE public.service_categories SET proof_requirements = v.req
FROM (VALUES
  ('errands_delivery',   '{"photo": 1}'::jsonb),
  ('shopping',           '{"photo": 1, "receipt": 1}'::jsonb),
  ('cleaning_laundry',   '{"photo": 1}'::jsonb),
  ('moving',             '{"photo": 2}'::jsonb),
  ('repairs',            '{"photo": 1}'::jsonb),
  ('document_delivery',  '{"photo": 1, "signature": 1}'::jsonb),
  ('food_pickup',        '{"photo": 1}'::jsonb),
  ('event_assistance',   '{"photo": 1}'::jsonb)
) AS v(key, req)
WHERE public.service_categories.key = v.key
  AND public.service_categories.proof_requirements = '{}'::jsonb;
