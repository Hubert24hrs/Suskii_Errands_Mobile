-- Generate 100k providers clustered like a real market rather than spread uniformly:
-- density matters, because a uniform scatter makes any index look good.
-- 60% Lagos, 30% Nairobi, 10% Accra; 30% online; 3% suspended.

\timing on

INSERT INTO providers (online, trust_level, vehicle_type, service_ids, rating, suspended, home)
SELECT
    random() < 0.30                                             AS online,
    (array[0,1,1,1,2,2,3])[1 + floor(random() * 7)::int]        AS trust_level,
    (array[0,1,2,2,3,3,4,4,4,5,6])[1 + floor(random() * 11)::int] AS vehicle_type,
    -- NOTE: this sub-select must reference g. Without the correlation Postgres runs it
    -- once as an InitPlan and every provider ends up with the SAME array, which silently
    -- turns the benchmark into a measurement of empty result sets. (Found the hard way.)
    ARRAY(SELECT DISTINCT (1 + floor(random() * 12))::smallint
          FROM generate_series(1, 1 + (g % 3)))                 AS service_ids,
    3.5 + random() * 1.5                                        AS rating,
    random() < 0.03                                             AS suspended,
    ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography         AS home
FROM (
    SELECT
        g,
        CASE
            WHEN g <= 60000 THEN  3.3792 + (random() + random() + random() - 1.5) * 0.28   -- Lagos
            WHEN g <= 90000 THEN 36.8219 + (random() + random() + random() - 1.5) * 0.24   -- Nairobi
            ELSE                 -0.1870 + (random() + random() + random() - 1.5) * 0.20   -- Accra
        END AS lon,
        CASE
            WHEN g <= 60000 THEN  6.5244 + (random() + random() + random() - 1.5) * 0.24
            WHEN g <= 90000 THEN -1.2921 + (random() + random() + random() - 1.5) * 0.22
            ELSE                  5.6037 + (random() + random() + random() - 1.5) * 0.18
        END AS lat
    FROM generate_series(1, 100000) g
) pts;

-- Live positions: online providers only, jittered a little from home, with varied freshness
-- so the query has to cope with stale rows (ADR-0009 allows up to ~60 s staleness).
INSERT INTO provider_live_location (provider_id, pos, updated_at)
SELECT
    id,
    ST_SetSRID(
        ST_MakePoint(ST_X(home::geometry) + (random() - 0.5) * 0.05,
                     ST_Y(home::geometry) + (random() - 0.5) * 0.05), 4326)::geography,
    now() - (random() * interval '180 seconds')
FROM providers
WHERE online;

ANALYZE providers;
ANALYZE provider_live_location;

SELECT count(*) AS providers,
       count(*) FILTER (WHERE online) AS online,
       count(*) FILTER (WHERE suspended) AS suspended
FROM providers;
SELECT count(*) AS live_rows FROM provider_live_location;
