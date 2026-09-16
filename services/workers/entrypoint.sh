#!/usr/bin/env bash
# dump:   back up BACKUP_SOURCE_URL to BACKUP_STORAGE_URL.
# verify: restore the latest backup into a throwaway PostgreSQL started inside this container
#         (unless BACKUP_RESTORE_ADMIN_URL points somewhere else) and check it.
set -euo pipefail

command="${1:-dump}"

if [ "$command" = "verify" ] && [ -z "${BACKUP_RESTORE_ADMIN_URL:-}" ]; then
  pgdata="$(mktemp -d /tmp/suskii-restore-XXXXXX)"
  initdb --pgdata="$pgdata" --username=postgres --auth=trust --encoding=UTF8 --locale=C.UTF-8 >/dev/null
  pg_ctl --pgdata="$pgdata" --wait --silent \
    --options="-c listen_addresses=127.0.0.1 -c port=5433 -c fsync=off -c full_page_writes=off" start
  trap 'pg_ctl --pgdata="$pgdata" --mode=immediate --silent stop || true' EXIT
  export BACKUP_RESTORE_ADMIN_URL="postgresql://postgres@127.0.0.1:5433/postgres"
fi

suskii-backup "$command"
