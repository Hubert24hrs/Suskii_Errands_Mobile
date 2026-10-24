-- Dev seed: placeholder price guardrails for Nigeria. The service catalogue and its proof
-- rules are reference data, created by migration 20261024150000 in every environment.

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
