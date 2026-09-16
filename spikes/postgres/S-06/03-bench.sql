-- S-06 benchmark. Pass criteria from the spike plan: p95 <= 50 ms, p99 <= 120 ms,
-- measured with concurrent heartbeat writes running (see run.sh).

\timing off

CREATE OR REPLACE FUNCTION bench_nearest(variant text, iterations int DEFAULT 300)
RETURNS TABLE (variant_name text, n int, p50_ms numeric, p95_ms numeric, p99_ms numeric, max_ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz;
    lat double precision;
    lon double precision;
    samples double precision[] := '{}';
    dummy bigint;
BEGIN
    FOR i IN 1..iterations LOOP
        -- Customer points drawn from the same clusters as supply.
        IF i % 10 < 6 THEN
            lon := 3.3792 + (random() - 0.5) * 0.4; lat := 6.5244 + (random() - 0.5) * 0.35;
        ELSIF i % 10 < 9 THEN
            lon := 36.8219 + (random() - 0.5) * 0.35; lat := -1.2921 + (random() - 0.5) * 0.3;
        ELSE
            lon := -0.1870 + (random() - 0.5) * 0.3; lat := 5.6037 + (random() - 0.5) * 0.25;
        END IF;

        t0 := clock_timestamp();

        IF variant = 'home_all' THEN
            SELECT count(*) INTO dummy FROM (
                SELECT p.id
                FROM providers p
                WHERE p.online AND NOT p.suspended
                  AND p.service_ids && ARRAY[3::smallint]
                  AND p.vehicle_type = ANY (ARRAY[2,3,4]::smallint[])
                  AND ST_DWithin(p.home, ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, 5000)
                ORDER BY p.home <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
                LIMIT 10) s;

        ELSIF variant = 'live_hot' THEN
            SELECT count(*) INTO dummy FROM (
                SELECT p.id
                FROM provider_live_location l
                JOIN providers p ON p.id = l.provider_id
                WHERE p.online AND NOT p.suspended
                  AND l.updated_at > now() - interval '120 seconds'
                  AND p.service_ids && ARRAY[3::smallint]
                  AND p.vehicle_type = ANY (ARRAY[2,3,4]::smallint[])
                  AND ST_DWithin(l.pos, ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, 5000)
                ORDER BY l.pos <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
                LIMIT 10) s;

        ELSIF variant = 'live_hot_widening' THEN
            -- Widening search: 2 km first, fall back to 8 km only when thin.
            -- Cheaper in dense cities, which is where most jobs are.
            SELECT count(*) INTO dummy FROM (
                SELECT p.id
                FROM provider_live_location l
                JOIN providers p ON p.id = l.provider_id
                WHERE p.online AND NOT p.suspended
                  AND l.updated_at > now() - interval '120 seconds'
                  AND ST_DWithin(l.pos, ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, 2000)
                ORDER BY l.pos <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
                LIMIT 10) s;
            IF dummy < 5 THEN
                SELECT count(*) INTO dummy FROM (
                    SELECT p.id
                    FROM provider_live_location l
                    JOIN providers p ON p.id = l.provider_id
                    WHERE p.online AND NOT p.suspended
                      AND l.updated_at > now() - interval '120 seconds'
                      AND ST_DWithin(l.pos, ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography, 8000)
                    ORDER BY l.pos <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
                    LIMIT 10) s;
            END IF;
        ELSE
            RAISE EXCEPTION 'unknown variant %', variant;
        END IF;

        samples := samples || EXTRACT(epoch FROM clock_timestamp() - t0) * 1000;
    END LOOP;

    RETURN QUERY
    SELECT variant,
           iterations,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY v)::numeric, 2),
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY v)::numeric, 2),
           round(percentile_cont(0.99) WITHIN GROUP (ORDER BY v)::numeric, 2),
           round(max(v)::numeric, 2)
    FROM unnest(samples) v;
END $$;

-- Warm the cache, then measure.
SELECT * FROM bench_nearest('home_all', 50);

SELECT * FROM bench_nearest('home_all');
SELECT * FROM bench_nearest('live_hot');
SELECT * FROM bench_nearest('live_hot_widening');

-- Keep the plans with the results: a passing number with a sequential scan in the plan
-- means the dataset was too small, not that the design is right.
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id
FROM provider_live_location l
JOIN providers p ON p.id = l.provider_id
WHERE p.online AND NOT p.suspended
  AND l.updated_at > now() - interval '120 seconds'
  AND p.service_ids && ARRAY[3::smallint]
  AND ST_DWithin(l.pos, ST_SetSRID(ST_MakePoint(3.3792, 6.5244), 4326)::geography, 5000)
ORDER BY l.pos <-> ST_SetSRID(ST_MakePoint(3.3792, 6.5244), 4326)::geography
LIMIT 10;
