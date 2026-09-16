#!/usr/bin/env bash
# Fallback test runner for machines without Docker: applies the Supabase shim, every
# migration and the seed to a fresh database on a plain PostgreSQL 17 + PostGIS server,
# then runs each pgTAP file and fails if any assertion fails.
#
# CI and every real environment use `supabase db reset` + `supabase test db` instead.
#
# Requirements: psql on PATH or $PSQL; a server with PostGIS and the pgtap extension files
# installed (see spikes/postgres/setup-local-windows.sh for a no-admin Windows setup).
#
# Usage:
#   PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=... \
#     bash supabase/local-fallback/run-plain-postgres.sh [test-file-glob]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPABASE_DIR="$(cd "$HERE/.." && pwd)"
PSQL="${PSQL:-psql}"
DB="${SUSKII_TEST_DB:-suskii_test}"
PATTERN="${1:-*.sql}"

run_sql() { "$PSQL" -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

"$PSQL" -X -q -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" \
  -c "CREATE DATABASE $DB"

echo "== shim"
run_sql -f "$HERE/supabase-shim.sql"

for f in "$SUPABASE_DIR"/migrations/*.sql; do
  echo "== migration $(basename "$f")"
  run_sql -f "$f"
done

for f in "$SUPABASE_DIR"/seed/*.sql; do
  [ -e "$f" ] || continue
  echo "== seed $(basename "$f")"
  run_sql -f "$f"
done

run_sql -c "CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions"

failed=0
for f in "$SUPABASE_DIR"/tests/database/$PATTERN; do
  [ -e "$f" ] || continue
  out="$("$PSQL" -X -q -At -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)" || { echo "$out"; echo "!! $(basename "$f") errored"; failed=1; continue; }
  if echo "$out" | grep -Eq '^not ok|# Looks like'; then
    echo "$out" | grep -E '^not ok|^#' ; echo "!! $(basename "$f") failed"; failed=1
  else
    echo "ok   $(basename "$f") ($(echo "$out" | grep -c '^ok'))"
  fi
done
exit $failed
