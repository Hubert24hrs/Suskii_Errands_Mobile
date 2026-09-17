-- Dev seed: the service taxonomy the apps render. Matches the categories Kimi Code's mock
-- fixtures use, so the same screens work against a real local stack (`custom` last, and it is
-- the only one that accepts a free-text label).
INSERT INTO public.service_categories
  (key, name_key, icon_key, requires_vehicle, allows_custom, offer_ttl_seconds, max_counter_rounds, sort_order)
VALUES
  ('errands_delivery',  'catErrandsDelivery',  'package',  true,  false, 600, 5, 10),
  ('food_pickup',       'catFoodPickup',       'food',     true,  false, 600, 5, 20),
  ('grocery_shopping',  'catGroceryShopping',  'basket',   true,  false, 900, 5, 30),
  ('document_delivery', 'catDocumentDelivery', 'document', false, false, 600, 5, 40),
  ('queue_waiting',     'catQueueWaiting',     'clock',    false, false, 900, 5, 50),
  ('home_services',     'catHomeServices',     'tools',    false, false, 1800, 5, 60),
  ('custom',            'catCustom',           'magic',    false, true,  900, 5, 900)
ON CONFLICT (key) DO NOTHING;
