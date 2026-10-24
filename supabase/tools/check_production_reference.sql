-- A database built the way production is built: migrations only, no seed
-- (`supabase db reset --local --no-seed`). It must already hold what the apps cannot work
-- without, and nothing that only belongs in dev. Run with `psql -v ON_ERROR_STOP=1`; any failure
-- raises. Migration 20261024150000 is what this guards.
DO $$
DECLARE
  v_gaps text[];
BEGIN
  IF (SELECT count(*) FROM public.countries) <> 5 THEN
    RAISE EXCEPTION 'expected the five pack countries, found %', (SELECT count(*) FROM public.countries);
  END IF;
  IF EXISTS (SELECT 1 FROM public.countries WHERE status <> 'disabled') THEN
    RAISE EXCEPTION 'a country is open without the four-eyes approval: %',
      (SELECT string_agg(code || '=' || status, ', ') FROM public.countries WHERE status <> 'disabled');
  END IF;
  IF (SELECT count(*) FROM public.cities WHERE country_code = 'NG') <> 37 THEN
    RAISE EXCEPTION 'Nigeria needs its 36 states and the FCT, found %',
      (SELECT count(*) FROM public.cities WHERE country_code = 'NG');
  END IF;
  IF EXISTS (SELECT 1 FROM public.countries c
             WHERE NOT EXISTS (SELECT 1 FROM public.cities ci WHERE ci.country_code = c.code)) THEN
    RAISE EXCEPTION 'a country has no service area';
  END IF;
  IF (SELECT count(*) FROM public.service_categories WHERE active) <> 21
     OR NOT EXISTS (SELECT 1 FROM public.service_categories WHERE key = 'custom' AND allows_custom) THEN
    RAISE EXCEPTION 'the service catalogue is incomplete';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.service_categories WHERE key = 'shopping'
                 AND proof_requirements = '{"photo": 1, "receipt": 1}'::jsonb) THEN
    RAISE EXCEPTION 'proof requirements are missing';
  END IF;

  -- What is left before Nigeria can go live is configuration the client supplies, nothing the
  -- migrations could have provided.
  v_gaps := private.country_pack_gaps('NG');
  IF v_gaps && ARRAY['cities', 'config.client.accepted_id_types'] THEN
    RAISE EXCEPTION 'reference data still missing for NG: %', v_gaps;
  END IF;
  IF NOT v_gaps @> ARRAY['legal.privacy', 'legal.terms', 'config.server.sms_providers',
                         'config.server.payment_providers', 'config.server.payout_providers'] THEN
    RAISE EXCEPTION 'unexpected go-live gaps for NG: %', v_gaps;
  END IF;

  -- Dev-only rows must not reach production.
  IF EXISTS (SELECT 1 FROM public.legal_documents WHERE url LIKE '%.invalid%') THEN
    RAISE EXCEPTION 'a placeholder legal document is in the migrations';
  END IF;
  IF EXISTS (SELECT 1 FROM public.countries WHERE config -> 'server' -> 'sms_providers' ? 'console') THEN
    RAISE EXCEPTION 'the console SMS provider is in the migrations';
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users) THEN
    RAISE EXCEPTION 'the migrations create user accounts';
  END IF;
  RAISE NOTICE 'production reference data: ok (NG go-live gaps: %)', v_gaps;
END $$;
