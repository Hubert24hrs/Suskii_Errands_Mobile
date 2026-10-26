-- Launch-scale database benchmark on staging (test-strategy §5), every write undone: the block ends
-- by raising its measurements, which rolls the whole thing back.
--
-- 10,000 online providers around Lagos with fresh heartbeats, one verified customer, then the
-- three database-heavy paths timed one call at a time: the nearest-provider query, publish with its
-- synchronous fan-out, and an offer from a matched provider. Plus the heartbeat write itself.
SET statement_timeout = '15min';

DO $bench$
DECLARE
  n_providers constant integer := 10000;
  v_customer uuid := '0b0b0b0b-0000-4000-8000-00000000c001';
  v_cat text := 'document_delivery';
  v_cat_id uuid;
  v_t0 timestamptz;
  v_t timestamptz;
  v_ms double precision[];
  v_out jsonb := '{}';
  v_req uuid;
  v_reqs uuid[] := '{}';
  v_prov uuid;
  v_n integer;
  v_err integer;
  v_lat double precision;
  v_lng double precision;
  v_matched integer;
BEGIN
  v_t0 := clock_timestamp();
  UPDATE public.countries SET status = 'beta' WHERE code = 'NG';
  SELECT id INTO v_cat_id FROM public.service_categories WHERE key = v_cat;

  -- Supply: deterministic ids, phones and positions so a rerun measures the same thing.
  INSERT INTO auth.users (id, aud, role, phone)
  SELECT ('0b0b0b0b-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::uuid, 'authenticated', 'authenticated',
         '2349' || lpad(i::text, 9, '0')
  FROM generate_series(1, n_providers) i;
  UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
  WHERE user_id::text LIKE '0b0b0b0b-0000-4000-8000-%';
  INSERT INTO public.provider_profiles (user_id, online, online_since, vehicle_type)
  SELECT p.user_id, true, now(), 'motorcycle'
  FROM public.profiles p WHERE p.user_id::text LIKE '0b0b0b0b-0000-4000-8000-%';
  INSERT INTO public.provider_services (provider_id, category_id)
  SELECT pp.user_id, v_cat_id FROM public.provider_profiles pp
  WHERE pp.user_id::text LIKE '0b0b0b0b-0000-4000-8000-%';
  INSERT INTO public.provider_live_location (provider_id, pos, updated_at)
  SELECT pp.user_id,
         extensions.ST_SetSRID(extensions.ST_MakePoint(
           3.3792 + (abs(hashtext(pp.user_id::text || 'x')) % 24000 - 12000) / 100000.0,
           6.5244 + (abs(hashtext(pp.user_id::text || 'y')) % 24000 - 12000) / 100000.0), 4326)::extensions.geography,
         now()
  FROM public.provider_profiles pp WHERE pp.user_id::text LIKE '0b0b0b0b-0000-4000-8000-%';
  ANALYZE public.provider_live_location;
  ANALYZE public.provider_profiles;

  INSERT INTO auth.users (id, aud, role, phone) VALUES (v_customer, 'authenticated', 'authenticated', '2348999999001');
  UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified' WHERE user_id = v_customer;
  v_out := v_out || jsonb_build_object('setup_s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1),
    'providers_online', (SELECT count(*) FROM public.provider_profiles WHERE online));

  -- 1. Nearest providers, as the customer, 300 calls at points across the city.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_ms := '{}';
  FOR i IN 1..300 LOOP
    v_lat := 6.5244 + ((i * 7919) % 16000 - 8000) / 100000.0;
    v_lng := 3.3792 + ((i * 104729) % 16000 - 8000) / 100000.0;
    v_t := clock_timestamp();
    PERFORM * FROM public.nearby_providers(v_lat, v_lng, v_cat, 5000);
    v_ms := v_ms || extract(epoch FROM clock_timestamp() - v_t) * 1000;
  END LOOP;
  v_out := v_out || jsonb_build_object('nearby_providers', (
    SELECT jsonb_build_object('n', count(*),
      'p50_ms', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p95_ms', round(percentile_cont(0.95) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p99_ms', round(percentile_cont(0.99) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'max_ms', round(max(m)::numeric, 1)) FROM unnest(v_ms) m),
    'nearby_sample_total', (SELECT total FROM public.nearby_providers(6.5244, 3.3792, v_cat, 5000)));

  -- 2. Publish with its synchronous fan-out, 100 requests. create_request is timed apart.
  v_ms := '{}';
  FOR i IN 1..100 LOOP
    v_lat := 6.5244 + ((i * 7919) % 16000 - 8000) / 100000.0;
    v_lng := 3.3792 + ((i * 104729) % 16000 - 8000) / 100000.0;
    v_req := public.create_request('bench-create-' || lpad(i::text, 8, '0'), v_cat,
      'Benchmark request: deliver an envelope', 'Bench pickup', 'standard', false, NULL, NULL, v_lat, v_lng,
      'Bench drop-off', NULL, v_lat + 0.01, v_lng + 0.01);
    v_reqs := v_reqs || v_req;
    v_t := clock_timestamp();
    PERFORM public.publish_request(v_req, 'bench-publish-' || lpad(i::text, 8, '0'));
    v_ms := v_ms || extract(epoch FROM clock_timestamp() - v_t) * 1000;
  END LOOP;
  SELECT count(*) INTO v_matched FROM private.request_fanouts f WHERE f.request_id = ANY (v_reqs);
  v_out := v_out || jsonb_build_object('publish_with_fanout', (
    SELECT jsonb_build_object('n', count(*),
      'p50_ms', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p95_ms', round(percentile_cont(0.95) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p99_ms', round(percentile_cont(0.99) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'max_ms', round(max(m)::numeric, 1)) FROM unnest(v_ms) m),
    'fanouts_per_request', round(v_matched / 100.0, 1),
    'notifications_written', (SELECT count(*) FROM public.notifications
                              WHERE user_id::text LIKE '0b0b0b0b-0000-4000-8000-%'));

  -- 3. An offer from a matched provider on each request.
  v_ms := '{}';
  v_err := 0;
  FOR i IN 1..100 LOOP
    SELECT f.provider_id INTO v_prov FROM private.request_fanouts f WHERE f.request_id = v_reqs[i]
    ORDER BY f.provider_id LIMIT 1;
    CONTINUE WHEN v_prov IS NULL;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_prov, 'role', 'authenticated', 'aal', 'aal1')::text, true);
    v_t := clock_timestamp();
    BEGIN
      PERFORM public.create_offer('bench-offer-' || lpad(i::text, 8, '0'), v_reqs[i], 500000, NULL);
      v_ms := v_ms || extract(epoch FROM clock_timestamp() - v_t) * 1000;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      IF v_err = 1 THEN v_out := v_out || jsonb_build_object('first_offer_error', SQLERRM); END IF;
    END;
  END LOOP;
  v_out := v_out || jsonb_build_object('create_offer', (
    SELECT jsonb_build_object('n', count(*),
      'p50_ms', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p95_ms', round(percentile_cont(0.95) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'max_ms', round(max(m)::numeric, 1)) FROM unnest(v_ms) m), 'offer_errors', v_err);

  -- 4. The heartbeat write, 300 providers.
  v_ms := '{}';
  FOR i IN 1..300 LOOP
    v_prov := ('0b0b0b0b-0000-4000-8000-' || lpad(to_hex(i * 31), 12, '0'))::uuid;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_prov, 'role', 'authenticated', 'aal', 'aal1')::text, true);
    v_t := clock_timestamp();
    PERFORM public.heartbeat(6.5244 + (i % 100) / 10000.0, 3.3792 + (i % 77) / 10000.0, 90::smallint, 800, 10, false);
    v_ms := v_ms || extract(epoch FROM clock_timestamp() - v_t) * 1000;
  END LOOP;
  v_out := v_out || jsonb_build_object('heartbeat', (
    SELECT jsonb_build_object('n', count(*),
      'p50_ms', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'p95_ms', round(percentile_cont(0.95) WITHIN GROUP (ORDER BY m)::numeric, 1),
      'max_ms', round(max(m)::numeric, 1)) FROM unnest(v_ms) m),
    'total_s', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1));

  RAISE EXCEPTION 'BENCH_RESULT %', v_out;
END $bench$;
