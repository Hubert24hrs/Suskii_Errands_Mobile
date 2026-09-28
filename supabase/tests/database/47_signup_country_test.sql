-- A new profile's country: the app's choice when it sends one, the phone's calling code when it
-- does not (audit 2026-09-27 Y.27).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(5);

INSERT INTO auth.users (id, phone, raw_user_meta_data) VALUES
  ('a4711111-1111-4111-8111-111111111111', '2348000000471', '{}'),
  ('a4722222-2222-4222-8222-222222222222', '254700000472', '{}'),
  ('a4733333-3333-4333-8333-333333333333', '2348000000473', '{"country_code": "gh", "language": "en"}'),
  ('a4744444-4444-4444-8444-444444444444', '2348000000474', '{"country_code": "zz"}');
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('a4755555-5555-4555-8555-555555555555', 'no-phone@example.test', '{}');

SELECT is((SELECT country_code::text FROM public.profiles WHERE user_id = 'a4711111-1111-4111-8111-111111111111'),
  'NG', 'a Nigerian number with no metadata lands in Nigeria');
SELECT is((SELECT country_code::text FROM public.profiles WHERE user_id = 'a4722222-2222-4222-8222-222222222222'),
  'KE', 'a Kenyan number lands in Kenya');
SELECT is((SELECT country_code::text FROM public.profiles WHERE user_id = 'a4733333-3333-4333-8333-333333333333'),
  'GH', 'the country the user chose wins when it is open');
SELECT is((SELECT country_code::text FROM public.profiles WHERE user_id = 'a4744444-4444-4444-8444-444444444444'),
  'NG', 'a country that is not open is ignored, and the number decides');
SELECT ok((SELECT country_code IS NULL FROM public.profiles WHERE user_id = 'a4755555-5555-4555-8555-555555555555'),
  'with neither, there is nothing to guess from, and nothing is guessed');

SELECT * FROM finish();
ROLLBACK;
