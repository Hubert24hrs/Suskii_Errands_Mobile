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
