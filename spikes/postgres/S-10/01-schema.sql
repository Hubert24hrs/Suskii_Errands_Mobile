-- S-10: does accepting an offer stay correct under contention, retries and TTL expiry?
-- Models only what the race needs: requests, offers, an idempotency table, an event log.

DROP TABLE IF EXISTS job_events, idempotency_keys, offers, requests CASCADE;

CREATE TABLE requests (
    id              bigserial PRIMARY KEY,
    customer_id     bigint      NOT NULL,
    status          text        NOT NULL DEFAULT 'OFFERS_RECEIVED',
    accepted_offer  bigint,
    version         int         NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE offers (
    id           bigserial PRIMARY KEY,
    request_id   bigint      NOT NULL REFERENCES requests(id),
    provider_id  bigint      NOT NULL,
    amount_minor bigint      NOT NULL,
    currency     text        NOT NULL DEFAULT 'NGN',
    status       text        NOT NULL DEFAULT 'ACTIVE',   -- ACTIVE | ACCEPTED | EXPIRED | WITHDRAWN
    expires_at   timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);
CREATE INDEX ON offers (request_id, status);

-- Idempotency: the same key must return the same outcome, never act twice.
CREATE TABLE idempotency_keys (
    key         text PRIMARY KEY,
    result      jsonb       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Append-only event log; the outbox would hang off this in the real system.
CREATE TABLE job_events (
    id          bigserial PRIMARY KEY,
    request_id  bigint      NOT NULL,
    event       text        NOT NULL,
    payload     jsonb       NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON job_events (request_id);
