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

  -- Nigeria launches paying providers directly and signing in by email and Google (ADR-0025),
  -- so it needs no payment, payout or SMS provider, and its legal pages are published
  -- (20261121120100). Nothing is left but the four-eyes approval itself (RB-08).
  IF (SELECT config -> 'client' ->> 'payment_mode' FROM public.countries WHERE code = 'NG')
       IS DISTINCT FROM 'direct'
     OR (SELECT config -> 'client' -> 'sign_in_methods' FROM public.countries WHERE code = 'NG')
       IS DISTINCT FROM '["email", "google"]'::jsonb THEN
    RAISE EXCEPTION 'Nigeria is not set to direct payment with email and Google sign-in';
  END IF;
  v_gaps := private.country_pack_gaps('NG');
  IF v_gaps IS DISTINCT FROM '{}'::text[] THEN
    RAISE EXCEPTION 'unexpected go-live gaps for NG: %', v_gaps;
  END IF;
  IF (SELECT count(*) FROM public.legal_documents
      WHERE country_code = 'NG' AND type IN ('terms', 'privacy')
        AND url LIKE 'https://suskiierrand.com/en/legal/%') <> 2 THEN
    RAISE EXCEPTION 'Nigeria''s terms and privacy policy are not the published pages';
  END IF;
  -- The other four still take payment in the app, so they still need every provider.
  IF NOT private.country_pack_gaps('KE') @> ARRAY['config.server.payment_providers',
                                                  'config.server.sms_providers'] THEN
    RAISE EXCEPTION 'an in-app country lost its payment or SMS gap: %',
      private.country_pack_gaps('KE');
  END IF;

  -- Meet v5 arrives dark (20261126120100): every Meet flag off, meet.v5 testers-only, nobody a
  -- tester, and the checklist open, so the only way on is the release steps of RB-17.
  IF EXISTS (SELECT 1 FROM public.feature_flags WHERE key LIKE 'meet.%' AND enabled)
     OR (SELECT payload ->> 'testers_only' FROM public.feature_flags
         WHERE key = 'meet.v5' AND country_code IS NULL) IS DISTINCT FROM 'true'
     OR EXISTS (SELECT 1 FROM private.meet_testers)
     OR cardinality(private.meet_readiness_missing('m1')) = 0 THEN
    RAISE EXCEPTION 'Meet v5 is not dark on a fresh database';
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
