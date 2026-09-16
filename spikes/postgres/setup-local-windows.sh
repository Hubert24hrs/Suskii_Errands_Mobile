#!/usr/bin/env bash
# Portable Postgres + PostGIS for the S-06 and S-10 spikes, for when Docker will not install.
#
# No installer, no admin rights, no services: it unzips binaries, runs initdb into a
# scratch directory and starts a server on port 55432. Delete the directory to undo it.
#
# Run from Git Bash:
#   bash setup-local-windows.sh /c/path/to/scratch
#
# Downloads (~430 MB total, cached if already present):
#   EDB PostgreSQL 17 Windows x64 binaries zip
#   PostGIS 3.6 bundle for pg17 x64
set -euo pipefail

ROOT="${1:-$PWD/.pglocal}"
PORT="${PGPORT:-55432}"
PGZIP_URL="https://get.enterprisedb.com/postgresql/postgresql-17.5-1-windows-x64-binaries.zip"
POSTGIS_URL="https://download.osgeo.org/postgis/windows/pg17/postgis-bundle-pg17-3.6.2x64.zip"

mkdir -p "$ROOT/dl"
cd "$ROOT"

[ -f dl/pg.zip ]      || curl -sL --max-time 3000 -o dl/pg.zip "$PGZIP_URL"
[ -f dl/postgis.zip ] || curl -sL --max-time 3000 -o dl/postgis.zip "$POSTGIS_URL"

# The EDB zip contains a top-level pgsql/ directory.
[ -d pgsql ] || unzip -q dl/pg.zip -d .
# The PostGIS bundle contains one postgis-bundle-*/ directory whose bin, lib and share
# contents merge into the Postgres installation.
if [ ! -f pgsql/share/extension/postgis.control ]; then
  rm -rf pgbundle && mkdir -p pgbundle && unzip -q dl/postgis.zip -d pgbundle
  BUNDLE_DIR="$(find pgbundle -maxdepth 1 -mindepth 1 -type d | head -1)"
  cp -r "$BUNDLE_DIR"/* pgsql/
fi

export PATH="$PWD/pgsql/bin:$PATH"

if [ ! -f data/PG_VERSION ]; then
  echo "spike" > pwfile
  initdb -D data -U postgres --pwfile=pwfile -E UTF8 >/dev/null
  rm -f pwfile
  # Spike-sized settings; mirror the real instance before trusting absolute numbers.
  cat >> data/postgresql.conf <<'CONF'
shared_buffers = 1GB
effective_cache_size = 3GB
work_mem = 32MB
maintenance_work_mem = 512MB
random_page_cost = 1.1
max_connections = 200
track_io_timing = on
CONF
fi

pg_ctl -D data -o "-p $PORT" -l server.log start || true
sleep 3
export PGPASSWORD=spike
psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -c "SELECT version();" | head -3
psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='spike'" \
  | grep -q 1 || createdb -h 127.0.0.1 -p "$PORT" -U postgres spike
psql -h 127.0.0.1 -p "$PORT" -U postgres -d spike -c "CREATE EXTENSION IF NOT EXISTS postgis;" >/dev/null
psql -h 127.0.0.1 -p "$PORT" -U postgres -d spike -tAc "SELECT postgis_full_version();"

cat <<EOF

Ready. Use this Postgres for the spikes:

  export PATH="$ROOT/pgsql/bin:\$PATH"
  export PGPASSWORD=spike
  export PSQL="psql -h 127.0.0.1 -p $PORT -U postgres -d spike -qAt"

  psql -h 127.0.0.1 -p $PORT -U postgres -d spike -f S-06/01-schema.sql
  psql -h 127.0.0.1 -p $PORT -U postgres -d spike -f S-06/02-generate.sql
  psql -h 127.0.0.1 -p $PORT -U postgres -d spike -f S-06/03-bench.sql
  bash S-10/race.sh 25 20

Stop:   $ROOT/pgsql/bin/pg_ctl -D $ROOT/data stop
Remove: rm -rf $ROOT
EOF
