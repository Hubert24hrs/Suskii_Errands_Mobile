"""suskii-backup dump | verify | storage-sync

Environment:
  SUSKII_ENV                  dev | staging | prod (required)
  BACKUP_STORAGE_URL          gs://<bucket> or file:///<dir> (required)
  BACKUP_PREFIX               key prefix, default "db"
  BACKUP_SCHEMAS              comma-separated schemas to dump, default below
  BACKUP_SOURCE_URL           database to back up (dump); also where results are recorded
  BACKUP_RESTORE_ADMIN_URL    server for the throwaway restore (verify)
  BACKUP_MANIFEST_KEY         verify a specific backup instead of the latest
  PG_BIN_DIR                  directory holding pg_dump / pg_restore (default: PATH)

storage-sync:
  SUPABASE_URL                project URL (https://<ref>.supabase.co)
  SUPABASE_SECRET_KEY         secret API key used to list and download objects
  STORAGE_SYNC_BUCKETS        comma-separated bucket ids to mirror
  BACKUP_KYC_STORAGE_URL      separate destination, required when kyc-docs is listed

Exit status 0 on success, 1 when the backup or its verification failed, 2 on bad configuration.
Results are logged as one JSON line and, when BACKUP_SOURCE_URL is set, recorded in the source
database's health checks (surfaced by the `health` function).
"""

from __future__ import annotations

import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import psycopg

from .dump import DumpConfig, run_dump
from .pgtools import PgTools
from .storage import storage_from_url
from .storage_sync import SupabaseStorageSource, sync_buckets
from .verify import VerifyConfig, run_verify

DEFAULT_SCHEMAS = "public,private,audit,ledger,kyc,auth"


def _require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(_config_error(f"{name} is required"))
    return value


def _config_error(message: str) -> int:
    print(
        json.dumps({"level": "error", "event": "backup.misconfigured", "message": message}), file=sys.stderr
    )
    return 2


def _log(event: str, **fields: object) -> None:
    print(json.dumps({"level": "info" if fields.get("ok", True) else "error", "event": event, **fields}))


def _record_health(source_url: str | None, key: str, ok: bool, detail: dict) -> None:
    if not source_url:
        return
    try:
        with psycopg.connect(source_url, autocommit=True) as conn:
            conn.execute(
                "SELECT private.record_health_check(%s, %s, %s)",
                (key, "ok" if ok else "fail", json.dumps(detail)),
            )
    except psycopg.Error as exc:
        _log("backup.health_record_failed", ok=False, sqlstate=exc.diag.sqlstate)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in ("dump", "verify", "storage-sync"):
        print(__doc__, file=sys.stderr)
        return 2

    environment = _require("SUSKII_ENV")
    storage = storage_from_url(_require("BACKUP_STORAGE_URL"))
    prefix = os.environ.get("BACKUP_PREFIX", "db")
    bin_dir = os.environ.get("PG_BIN_DIR")
    tools = PgTools(Path(bin_dir) if bin_dir else None)
    source_url = os.environ.get("BACKUP_SOURCE_URL") or None
    now = datetime.now(UTC)

    if argv[0] == "storage-sync":
        buckets = [b.strip() for b in _require("STORAGE_SYNC_BUCKETS").split(",") if b.strip()]
        kyc_url = os.environ.get("BACKUP_KYC_STORAGE_URL") or None
        source = SupabaseStorageSource(_require("SUPABASE_URL"), _require("SUPABASE_SECRET_KEY"))
        try:
            results = sync_buckets(
                source, storage, storage_from_url(kyc_url) if kyc_url else None, environment, buckets, now
            )
        except ValueError as exc:
            return _config_error(str(exc))
        ok = all(r.ok for r in results)
        detail = {
            "buckets": {
                r.bucket: {
                    "copied": r.copied,
                    "unchanged": r.unchanged,
                    "deleted_in_source": r.deleted_in_source,
                    "failed": r.failed[:20],
                }
                for r in results
            }
        }
        _log("backup.storage_sync_completed", ok=ok, **detail)
        _record_health(source_url, "storage_sync", ok, detail)
        return 0 if ok else 1

    if argv[0] == "dump":
        if not source_url:
            return _config_error("BACKUP_SOURCE_URL is required for dump")
        schemas = [
            s.strip() for s in os.environ.get("BACKUP_SCHEMAS", DEFAULT_SCHEMAS).split(",") if s.strip()
        ]
        try:
            manifest = run_dump(DumpConfig(environment, source_url, prefix, schemas, tools), storage, now)
        except (RuntimeError, psycopg.Error, OSError) as exc:
            _log("backup.dump_failed", ok=False, error=type(exc).__name__, message=str(exc)[-500:])
            _record_health(source_url, "backup_dump", False, {"error": type(exc).__name__})
            return 1
        detail = {
            "dump_key": manifest.dump_key,
            "dump_bytes": manifest.dump_bytes,
            "tables": len(manifest.table_row_counts),
        }
        _log("backup.dump_completed", ok=True, **detail)
        _record_health(source_url, "backup_dump", True, detail)
        return 0

    result = run_verify(
        VerifyConfig(
            environment,
            prefix,
            _require("BACKUP_RESTORE_ADMIN_URL"),
            tools,
            os.environ.get("BACKUP_MANIFEST_KEY") or None,
        ),
        storage,
        now,
    )
    if result.manifest_key:
        verify_key = result.manifest_key.replace(".manifest.json", f".verify-{now:%Y%m%dT%H%M%SZ}.json")
        storage.put_bytes(result.to_json(), verify_key, "application/json")
    detail = {
        "manifest_key": result.manifest_key,
        "tables_checked": result.tables_checked,
        "restore_seconds": result.restore_seconds,
        "problems": result.problems[:20],
    }
    _log("backup.verify_completed", ok=result.ok, **detail)
    _record_health(source_url, "backup_verify", result.ok, detail)
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
