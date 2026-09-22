-- The concierge's tool surface and the admin assistant's KPI functions
-- (`docs/plan/ai-design.md` §4.1, §4.3, §4.4, §9; spec phase 7).
--
-- No model is involved in any of this. What is asserted is the boundary: each tool returns the
-- least that is useful, refuses a caller with no claim on the data, and — for the admin
-- assistant — suppresses a cell too small to be an aggregate.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(31);

INSERT INTO auth.users (id, phone) VALUES
  ('c0111111-1111-4111-8111-bbbbbbbbbbbb', '2348000001101'),   -- customer
  ('c0222222-2222-4222-8222-bbbbbbbbbbbb', '2348000001102'),   -- provider A (cheap, unrated)
  ('c0333333-3333-4333-8333-bbbbbbbbbbbb', '2348000001103'),   -- provider B (dearer, rated)
  ('c0444444-4444-4444-8444-bbbbbbbbbbbb', '2348000001104'),   -- a stranger
  ('c0777777-7777-4777-8777-bbbbbbbbbbbb', '2348000001107'),   -- provider C (cheap and rated)
  ('c0555555-5555-4555-8555-bbbbbbbbbbbb', '2348000001105'),   -- finance, scoped to NG
  ('c0666666-6666-4666-8666-bbbbbbbbbbbb', '2547000001106');   -- finance, scoped to KE
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id IN ('c0111111-1111-4111-8111-bbbbbbbbbbbb', 'c0444444-4444-4444-8444-bbbbbbbbbbbb');
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id IN ('c0222222-2222-4222-8222-bbbbbbbbbbbb', 'c0333333-3333-4333-8333-bbbbbbbbbbbb',
                  'c0777777-7777-4777-8777-bbbbbbbbbbbb');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'c0555555-5555-4555-8555-bbbbbbbbbbbb';
UPDATE public.profiles SET country_code = 'KE'
WHERE user_id = 'c0666666-6666-4666-8666-bbbbbbbbbbbb';
INSERT INTO public.provider_profiles (user_id, rating_avg_milli, rating_count) VALUES
  ('c0222222-2222-4222-8222-bbbbbbbbbbbb', 0, 0),
  ('c0333333-3333-4333-8333-bbbbbbbbbbbb', 4800, 120),
  ('c0777777-7777-4777-8777-bbbbbbbbbbbb', 4800, 120);
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('c0555555-5555-4555-8555-bbbbbbbbbbbb', ARRAY['finance_officer']::public.admin_role[],
   ARRAY['NG']::char(2)[]),
  ('c0666666-6666-4666-8666-bbbbbbbbbbbb', ARRAY['finance_officer']::public.admin_role[],
   ARRAY['KE']::char(2)[]);

CREATE TEMP TABLE ai (name text PRIMARY KEY, val text);
GRANT ALL ON ai TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal1') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

INSERT INTO ai VALUES ('cat', (SELECT id::text FROM public.service_categories
                               WHERE key = 'errands_delivery'));

-- ---------------------------------------------------------------------------
-- Price bands (§9). Rules first, history when there is enough of it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT is((SELECT basis FROM public.get_price_band((SELECT val FROM ai WHERE name = 'cat')::uuid)),
  'rules', 'with no history the band comes from the country''s own guardrails');
SELECT is((SELECT sample_size FROM public.get_price_band(
             (SELECT val FROM ai WHERE name = 'cat')::uuid)), 0,
  'and says so: a band resting on nothing must not look like a measurement');
SELECT ok((SELECT p25_minor <= p50_minor AND p50_minor <= p75_minor
           FROM public.get_price_band((SELECT val FROM ai WHERE name = 'cat')::uuid)),
  'the quantiles are ordered');
SELECT ok((SELECT p50_minor FROM public.get_price_band(
             (SELECT val FROM ai WHERE name = 'cat')::uuid, 'emergency'))
        > (SELECT p50_minor FROM public.get_price_band(
             (SELECT val FROM ai WHERE name = 'cat')::uuid, 'flexible')),
  'and urgency moves the band, because it moves what people agree to');
SELECT is((SELECT currency FROM public.get_price_band(
             (SELECT val FROM ai WHERE name = 'cat')::uuid)), 'NGN'::char(3),
  'in the caller''s own currency, never converted');
RESET ROLE;

SELECT is(private.recompute_price_bands(), 0,
  'the nightly recompute writes nothing while every cell is below the sample threshold');

-- ---------------------------------------------------------------------------
-- Availability (§4.3): counts, never a provider.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c0222222-2222-4222-8222-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT ok(public.set_online(true), 'a provider comes online');
SELECT ok(public.update_provider_services(ARRAY['errands_delivery']) > 0,
  'and registers for the category');
SELECT ok(public.heartbeat(6.5095, 3.3711), 'and is somewhere');
RESET ROLE;

SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT is((SELECT providers_online FROM public.get_availability_summary(
             (SELECT val FROM ai WHERE name = 'cat')::uuid, 6.5095, 3.3711)), 1,
  'the customer learns that somebody is nearby');
SELECT is((SELECT providers_online FROM public.get_availability_summary(
             (SELECT val FROM ai WHERE name = 'cat')::uuid, 9.0579, 7.4951)), 0,
  'and that nobody is, four hundred kilometres away');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Offer ranking (§4.1). The caller's own request, and nothing about the providers beyond a name.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
INSERT INTO ai VALUES ('req', public.create_request('key-ai-req-0000000001',
  'errands_delivery', 'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL,
  6.5095, 3.3711)::text);
SELECT ok(public.publish_request((SELECT val FROM ai WHERE name = 'req')::uuid,
  'key-ai-pub-0000000001') IS NOT NULL, 'a request is published');
RESET ROLE;

SELECT pg_temp.act('c0222222-2222-4222-8222-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT ok(public.create_offer('key-ai-off-a-00000001',
  (SELECT val FROM ai WHERE name = 'req')::uuid, 8000, NULL) IS NOT NULL,
  'an unrated provider offers 80.00');
RESET ROLE;
SELECT pg_temp.act('c0333333-3333-4333-8333-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT ok(public.create_offer('key-ai-off-b-00000001',
  (SELECT val FROM ai WHERE name = 'req')::uuid, 10000, NULL) IS NOT NULL,
  'and a well-rated one offers 100.00');
RESET ROLE;

SELECT pg_temp.act('c0777777-7777-4777-8777-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT ok(public.create_offer('key-ai-off-c-00000001',
  (SELECT val FROM ai WHERE name = 'req')::uuid, 8000, NULL) IS NOT NULL,
  'and a third matches the cheapest price with the same reputation as the second');
RESET ROLE;

SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.rank_offers(
             (SELECT val FROM ai WHERE name = 'req')::uuid)), 3, 'all three offers are ranked');
-- **Price leads, and it should.** Half the weight is the price relative to the offers actually on
-- the table, so a 20% saving beats a hundred and twenty ratings. That is a judgement about this
-- market rather than an accident, and the factors travel with the score so a screen can show it.
SELECT is((SELECT provider_id FROM public.rank_offers(
             (SELECT val FROM ai WHERE name = 'req')::uuid) LIMIT 1),
  'c0777777-7777-4777-8777-bbbbbbbbbbbb'::uuid,
  'the cheapest well-rated offer leads');
-- And this is what makes it a ranking rather than a price sort: at the same price, reputation
-- decides, and the unrated newcomer comes second rather than last.
SELECT is((SELECT array_agg(provider_id ORDER BY score DESC)
           FROM public.rank_offers((SELECT val FROM ai WHERE name = 'req')::uuid)),
  ARRAY['c0777777-7777-4777-8777-bbbbbbbbbbbb',
        'c0222222-2222-4222-8222-bbbbbbbbbbbb',
        'c0333333-3333-4333-8333-bbbbbbbbbbbb']::uuid[],
  'at equal prices reputation decides, so this is a ranking and not a price sort');
SELECT is((SELECT (factors ->> 'new_provider')::boolean FROM public.rank_offers(
             (SELECT val FROM ai WHERE name = 'req')::uuid)
           WHERE provider_id = 'c0222222-2222-4222-8222-bbbbbbbbbbbb'), true,
  'the newcomer is flagged as one rather than buried: they score a neutral 0.6, not zero');
SELECT is((SELECT count(*)::int FROM public.rank_offers(
             (SELECT val FROM ai WHERE name = 'req')::uuid)
           WHERE (factors ->> 'cheapest')::boolean), 2,
  'and the screen can still say which offers are cheapest, because the factors travel along');
RESET ROLE;

SELECT pg_temp.act('c0444444-4444-4444-8444-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT * FROM public.rank_offers(%L)$$, (SELECT val FROM ai WHERE name = 'req')),
  'P0001', 'ERR_REQUEST_NOT_FOUND',
  'a stranger gets the same answer the table gives: somebody else''s offers are not admitted '
  'to exist');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Job summary and category requirements.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT is((SELECT requires_vehicle FROM public.get_category_requirements(
             (SELECT val FROM ai WHERE name = 'cat')::uuid)), false,
  'a category says what a request of it needs');
SELECT throws_ok(
  format($$SELECT * FROM public.get_job_summary(%L)$$, (SELECT val FROM ai WHERE name = 'req')),
  'P0001', 'ERR_JOB_NOT_FOUND',
  'and a job summary needs a job — a published request is not one yet');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The admin assistant (§4.4): aggregates, small cells suppressed, scoped by role and country.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('c0111111-1111-4111-8111-bbbbbbbbbbbb');
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT * FROM public.kpi_gmv(current_date - 30, current_date)$$,
  '42501', NULL, 'a customer is not an analyst');
RESET ROLE;

SELECT pg_temp.act('c0555555-5555-4555-8555-bbbbbbbbbbbb', 'aal2');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT * FROM public.kpi_gmv(current_date - 30, current_date)$$,
  'a finance officer is');
SELECT is((SELECT count(*)::int FROM public.kpi_jobs_by_state(current_date - 30, current_date)
           WHERE jobs IS NOT NULL), 0,
  'and every cell is suppressed, because one request is not an aggregate — the answer is NULL, '
  'not zero, because a suppressed cell and an empty one are different claims');
SELECT throws_ok(
  $$SELECT * FROM public.kpi_gmv(current_date - 30, current_date, 'KE')$$,
  '42501', NULL, 'asking about a country outside your scope is refused, not answered emptily');
SELECT throws_ok(
  $$SELECT * FROM public.kpi_disputes(current_date - 30, current_date)$$,
  '42501', NULL, 'and a finance officer does not read the dispute numbers');
RESET ROLE;

-- The suppression threshold is config, and lowering it reveals the cell rather than changing it.
UPDATE public.remote_config SET value = '1' WHERE key = 'ai.kpi_min_cell';
SELECT pg_temp.act('c0555555-5555-4555-8555-bbbbbbbbbbbb', 'aal2');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.kpi_jobs_by_state(current_date - 30, current_date)
           WHERE jobs IS NOT NULL) > 0,
  'with the threshold at one, the same query answers');
SELECT is((SELECT count(*)::int FROM public.kpi_funnel(current_date - 30, current_date)), 1,
  'the funnel is cohorted on publication, so it is one row for one country');
RESET ROLE;

SELECT pg_temp.act('c0666666-6666-4666-8666-bbbbbbbbbbbb', 'aal2');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.kpi_jobs_by_state(current_date - 30, current_date)), 0,
  'and an officer scoped to Kenya sees nothing of a Nigerian week');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
