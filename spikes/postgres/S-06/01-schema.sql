-- S-06 schema: nearest eligible provider at 100k providers.
-- Two shapes are compared: everything on one table, and a separate hot table for live position.

CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS provider_live_location, providers CASCADE;

CREATE TABLE providers (
    id              bigserial PRIMARY KEY,
    online          boolean     NOT NULL DEFAULT false,
    trust_level     smallint    NOT NULL DEFAULT 1,   -- 0 NEW, 1 VERIFIED, 2 TRUSTED, 3 ELITE
    vehicle_type    smallint    NOT NULL,             -- 0 walking .. 6 truck
    service_ids     smallint[]  NOT NULL,
    rating          numeric(3,2) NOT NULL DEFAULT 4.50,
    suspended       boolean     NOT NULL DEFAULT false,
    home            geography(Point, 4326) NOT NULL
);

-- The hot table the heartbeat RPC writes to (ADR-0009). Kept narrow on purpose:
-- one row per provider, overwritten in place, so it stays small enough to cache.
CREATE TABLE provider_live_location (
    provider_id bigint PRIMARY KEY REFERENCES providers(id),
    pos         geography(Point, 4326) NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Index variants. Build them one at a time in 03-bench.sql and compare.
-- (a) plain GiST over every provider
CREATE INDEX IF NOT EXISTS idx_prov_home_gist        ON providers USING gist (home);
-- (b) partial GiST: only providers who can actually take work
CREATE INDEX IF NOT EXISTS idx_prov_home_online_gist ON providers USING gist (home)
    WHERE online AND NOT suspended;
-- (c) hot table GiST, freshness-aware queries
CREATE INDEX IF NOT EXISTS idx_live_pos_gist         ON provider_live_location USING gist (pos);
CREATE INDEX IF NOT EXISTS idx_live_updated          ON provider_live_location (updated_at);
-- supporting filters
CREATE INDEX IF NOT EXISTS idx_prov_services_gin     ON providers USING gin (service_ids);
