-- Dev seed: the service taxonomy the apps render. Keys and label keys match Kimi Code's
-- `catalog` fixtures exactly (checked in a running build, 2026-09-18), so the same screens work
-- against a local stack and `create_request(category_key …)` resolves what the app sends.
-- `custom` is the only category that accepts a free-text label.
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
  ('custom',              'catCustom',             'magic',     false, true,   900, 5, 900)
ON CONFLICT (key) DO NOTHING;

-- Price guardrails, NG only: the values the country pack carries today (`pricing.guardrails`),
-- which it marks as placeholders to calibrate with pilot data (OD-23). `repairs_trades` in the
-- pack is `repairs` in the app's catalogue. A category with no row here has no hard cap, so the
-- remaining seven are unbounded until the client sets them.
INSERT INTO public.pricing_guardrails (country_code, category_id, soft_min_minor, soft_max_minor, hard_max_minor)
SELECT 'NG', sc.id, g.soft_min, g.soft_max, g.hard_max
FROM (VALUES
  ('errands_delivery', 100000::bigint, 5000000::bigint, 50000000::bigint),
  ('shopping',         100000,         5000000,         50000000),
  ('cleaning_laundry', 300000,        10000000,        100000000),
  ('moving',          1000000,        50000000,        500000000),
  ('repairs',          300000,        20000000,        200000000)
) AS g(key, soft_min, soft_max, hard_max)
JOIN public.service_categories sc ON sc.key = g.key
ON CONFLICT DO NOTHING;

-- What each category has to show for itself before a provider can mark the work done (job
-- lifecycle transition 15). A kind that is absent or zero is not required, so a category with an
-- empty object needs no proof at all. These are the defaults; ops tunes them per category.
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
