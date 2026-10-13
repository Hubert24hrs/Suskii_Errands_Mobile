-- The provider's demand heatmap: cells rather than points, cells below the k-anonymity floor never
-- shown, open requests in the provider's own country and categories only, and nothing that
-- names a customer.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(14);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-565656565656', '2348000005601'),   -- the provider
  ('e2222222-2222-4222-8222-565656565656', '2348000005602');   -- a customer
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified',
       customer_verification = 'verified'
WHERE user_id IN ('e1111111-1111-4111-8111-565656565656', 'e2222222-2222-4222-8222-565656565656');
INSERT INTO public.provider_profiles (user_id) VALUES ('e1111111-1111-4111-8111-565656565656');
INSERT INTO public.provider_services (provider_id, category_id)
SELECT 'e1111111-1111-4111-8111-565656565656', id FROM public.service_categories
WHERE key = 'errands_delivery';

CREATE FUNCTION pg_temp.request(p_lat float8, p_lng float8, p_category text,
                                p_status public.job_status DEFAULT 'published',
                                p_country char(2) DEFAULT 'NG') RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO public.requests (customer_id, country_code, category_id, description, pickup_label,
                               currency, status, pickup_point)
  VALUES ('e2222222-2222-4222-8222-565656565656', p_country,
          (SELECT id FROM public.service_categories WHERE key = p_category),
          'Heatmap test', 'Somewhere', CASE p_country WHEN 'NG' THEN 'NGN' ELSE 'KES' END,
          p_status,
          extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography);
$fn$;

-- Yaba: six open requests inside one 0.02-degree cell (rows 325, column 168).
SELECT pg_temp.request(6.5011 + g * 0.002, 3.3611 + g * 0.0025, 'errands_delivery')
FROM generate_series(0, 5) g;
-- Ikeja: two, below the floor of five.
SELECT pg_temp.request(6.6011, 3.3511, 'errands_delivery');
SELECT pg_temp.request(6.6031, 3.3531, 'errands_delivery');
-- Ikeja again, five in a category this provider does not serve.
SELECT pg_temp.request(6.6051 + g * 0.001, 3.3551, 'personal_assistance') FROM generate_series(0, 4) g;
-- Surulere: five that are not open any more.
SELECT pg_temp.request(6.4911 + g * 0.001, 3.3511, 'errands_delivery', 'cancelled')
FROM generate_series(0, 4) g;
-- Five in another country.
SELECT pg_temp.request(-1.2811 + g * 0.001, 36.8211, 'errands_delivery', 'published', 'KE')
FROM generate_series(0, 4) g;
-- One alone, far from everything: a customer's home on a quiet street.
SELECT pg_temp.request(6.4011, 3.4111, 'errands_delivery');

CREATE FUNCTION pg_temp.act(p_user text) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  SELECT NULL::void;
$fn$;

SELECT ok(NOT has_function_privilege('anon', 'public.provider_demand_heatmap()', 'EXECUTE'),
  'nobody signed out can ask');
SELECT ok(position('customer' IN pg_get_function_result('public.provider_demand_heatmap'::regproc)) = 0,
  'the answer has no column that could name a customer');

SELECT pg_temp.act('e2222222-2222-4222-8222-565656565656');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.provider_demand_heatmap()$$, 'P0001',
  'ERR_PROVIDER_NOT_VERIFIED', 'a customer is not shown where demand is');
RESET ROLE;

SELECT pg_temp.act('e1111111-1111-4111-8111-565656565656');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.provider_demand_heatmap()), 1,
  'one cell: the two-request cell, the other category, closed requests, another country and the '
  'lone request are all left out');
SELECT is((SELECT open_requests FROM public.provider_demand_heatmap()), 6,
  'the Yaba cell counts its six open requests');
SELECT is((SELECT round(center_lat::numeric, 4) || ',' || round(center_lng::numeric, 4)
           FROM public.provider_demand_heatmap()), '6.5100,3.3700',
  'and reports the centre of the cell');
SELECT is((SELECT count(*)::int FROM public.provider_demand_heatmap() h
           JOIN public.requests r
             ON round(extensions.ST_Y(r.pickup_point::extensions.geometry)::numeric, 4)
                = round(h.center_lat::numeric, 4)
            AND round(extensions.ST_X(r.pickup_point::extensions.geometry)::numeric, 4)
                = round(h.center_lng::numeric, 4)), 0,
  'which is not where anybody asked to be picked up');
SELECT is((SELECT intensity FROM public.provider_demand_heatmap()), 1.00::numeric,
  'the busiest cell has intensity 1');
SELECT isnt((SELECT label FROM public.provider_demand_heatmap()), NULL,
  'every cell has a label, empty when no zone or city is near');
RESET ROLE;

-- The floor is configuration, but it cannot go below two.
UPDATE public.remote_config SET value = '7' WHERE key = 'demand_heatmap_min_requests';
SELECT pg_temp.act('e1111111-1111-4111-8111-565656565656');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.provider_demand_heatmap()), 0,
  'with a floor of seven, six is not enough');
RESET ROLE;
UPDATE public.remote_config SET value = '1' WHERE key = 'demand_heatmap_min_requests';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.provider_demand_heatmap()), 2,
  'a floor configured at one is held at two: the Ikeja pair appears');
SELECT is((SELECT count(*)::int FROM public.provider_demand_heatmap() WHERE open_requests = 1), 0,
  'and the lone request still never does');
SELECT is((SELECT intensity FROM public.provider_demand_heatmap() WHERE open_requests = 2),
  0.33::numeric, 'intensity is relative to the busiest cell');
RESET ROLE;

-- A suspended provider sees nothing.
UPDATE public.provider_profiles SET suspended_until = now() + interval '1 day'
WHERE user_id = 'e1111111-1111-4111-8111-565656565656';
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.provider_demand_heatmap()$$, 'P0001',
  'ERR_PROVIDER_SUSPENDED', 'a suspended provider is told so');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
