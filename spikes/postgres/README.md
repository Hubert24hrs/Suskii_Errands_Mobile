# Postgres spikes — S-06 and S-10

Throwaway harnesses. They need **Docker**, nothing else: no Supabase project, no credentials, no vendor accounts. They were written on a machine without Docker, so they are **unrun**. Treat the first execution as part of the spike, and fix the harness where it is wrong rather than trusting it.

```bash
cd spikes/postgres
docker compose up -d
docker compose exec -T db pg_isready -U postgres -d spike
```

## S-06 — nearest eligible provider at 100k providers

```bash
docker compose exec -T db psql -U postgres -d spike -f - < S-06/01-schema.sql
docker compose exec -T db psql -U postgres -d spike -f - < S-06/02-generate.sql   # ~100k rows
docker compose exec -T db psql -U postgres -d spike -f - < S-06/03-bench.sql
```

Three query shapes are compared: everything off the `providers` table, the separate hot `provider_live_location` table from ADR-0009, and a widening radius (2 km, then 8 km only when supply is thin).

**Pass:** p95 ≤ 50 ms and p99 ≤ 120 ms.

Two things that decide whether the result means anything:

1. **Run it with writes in flight.** Real load has thousands of heartbeats per minute hitting the same hot table. Open a second shell and keep this running during the benchmark:
   ```bash
   docker compose exec -T db psql -U postgres -d spike -c "
     DO \$\$ BEGIN FOR i IN 1..200000 LOOP
       UPDATE provider_live_location
          SET pos = ST_SetSRID(ST_MakePoint(ST_X(pos::geometry)+0.0001, ST_Y(pos::geometry)), 4326)::geography,
              updated_at = now()
        WHERE provider_id = (SELECT provider_id FROM provider_live_location ORDER BY random() LIMIT 1);
     END LOOP; END \$\$;"
   ```
2. **Read the `EXPLAIN` output at the end.** A fast number with a sequential scan in the plan means the dataset was too small or the index was ignored, not that the design works.

Container settings approximate a Supabase Large instance (2 vCPU / 8 GB). Absolute numbers are only meaningful when re-run on the instance size we actually buy; the *ranking* of the three shapes transfers.

## S-10 — concurrent offer acceptance

```bash
docker compose exec -T db psql -U postgres -d spike -f - < S-10/01-schema.sql
docker compose exec -T db psql -U postgres -d spike -f - < S-10/02-accept-offer.sql
bash S-10/race.sh 25 20      # 25 rounds x 20 concurrent accepts
```

Each round has 20 callers racing to accept 20 *different* offers on the same request, each with its own idempotency key — the worst case for the row lock. After every round it asserts:

- exactly one offer `ACCEPTED`, none left `ACTIVE`;
- exactly one `OFFER_ACCEPTED` event (the outbox must not fire twice);
- request moved to `PAYMENT_PENDING`;
- exactly one caller was told it succeeded.

It then checks that replaying an idempotency key returns the original result without acting again, and that an expired offer is rejected.

**Pass:** zero double acceptances, and both extra checks pass. This is risk R-12 (critical): a double acceptance means two providers dispatched and potentially two charges.

## When they have run

Write `docs/research/spikes/S-06-results.md` and `S-10-results.md` with the numbers, the plans, and what changed in the design. Then update the risk register (R-11, R-12) and any ADR that was waiting. Delete this harness when the real functions and pgTAP tests exist — the tests inherit from it.

## Teardown

```bash
docker compose down -v
```
