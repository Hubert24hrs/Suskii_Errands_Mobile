# services/workers — scheduled backend jobs

Owner: Claude Code. Python 3.13, managed with uv. CI: `.github/workflows/services-workers.yaml`. Image: `postgres:17-trixie` + PostGIS from the PostgreSQL apt repository.

## Backups (`suskii-backup`)

Implements [infra-cicd.md](../../docs/plan/infra-cicd.md) §8 and the automated part of [RB-09](../../docs/runbooks/RB-09-backup-restore.md).

| Command | What it does | Schedule (Terraform) |
|---|---|---|
| `dump` | Opens a repeatable-read snapshot on the database, counts every table in the backed-up schemas **inside that snapshot**, runs `pg_dump --snapshot` so the dump matches the counts exactly, uploads the dump, then uploads the manifest (sha256, size, tool and server versions, row counts). The manifest is written last, so a backup without one is incomplete and never used | 02:15 UTC |
| `verify` | Downloads the latest complete backup, checks size and sha256, restores it into a throwaway database (`--exit-on-error --single-transaction`), requires **exactly** the manifest's row counts, re-verifies the audit hash chain, and checks the ledger is zero-sum once ledger tables exist. Writes a `.verify-<time>.json` result next to the backup | 04:15 UTC |

Both record their outcome in the source database (`private.record_health_check`), so the `health` function reports `backup_dump` and `backup_verify` once `ops.backup_max_age_hours` is set in remote config (for example `36`); a stale or failed backup then turns the uptime check red.

Backups are named `db/<env>/<yyyy>/<mm>/<dd>/<yyyymmddThhmmssZ>.{dump,manifest.json,verify-*.json}`. Objects are never overwritten (`if_generation_match=0`); the bucket keeps versions, enforces a minimum retention and deletes backups after 120 days (Terraform).

### Configuration

See `suskii-backup --help` output in `src/suskii_workers/backup/cli.py`. In Cloud Run the container gets `SUSKII_ENV`, `BACKUP_STORAGE_URL` (`gs://…`) and `BACKUP_SOURCE_URL` (from Secret Manager `supabase-db-backup-url`). In `verify` mode the entrypoint starts a throwaway PostgreSQL 17 + PostGIS inside the container unless `BACKUP_RESTORE_ADMIN_URL` is set.

### Local development

```bash
cd services/workers
uv sync
uv run ruff format --check . && uv run ruff check .
uv run pytest -q -m "not integration"

# end to end against a local PostgreSQL 17 + PostGIS with the Supabase migrations applied
# (supabase/local-fallback/run-plain-postgres.sh with SKIP_TESTS=1 prepares one)
BACKUP_TEST_SOURCE_URL=postgresql://postgres:…@127.0.0.1:55432/suskii_test \
BACKUP_TEST_ADMIN_URL=postgresql://postgres:…@127.0.0.1:55432/postgres \
PG_BIN_DIR=/path/to/postgres/bin uv run pytest -q -m integration
```

The integration tests prove that verification **fails** on a corrupted dump, on a row count that does not match, and on a backup whose audit chain was tampered with — not only that a good backup passes.

### Open items

| Item | Why open |
|---|---|
| Which schemas to include on a hosted Supabase project (default `public,private,audit,ledger,kyc,auth`) and whether the `postgres` role can read all of them | Needs a real project (spike S-02). `BACKUP_SCHEMAS` makes it configurable |
| Storage buckets (`kyc-docs` and others) | Object sync to GCS is a separate job, not built yet (RB-09) |
| Row counts on very large partitioned tables | Counting is exact but slow at scale; revisit when `location_samples` and `messages` grow (Phase 3) |
| `roles/run.invoker` for Cloud Scheduler triggering jobs | Per Google's scheduling guidance [S]; confirm on first apply |
