"""End-to-end backup and restore against real PostgreSQL 17 servers.

BACKUP_TEST_SOURCE_URL  a database with the Suskii migrations and seed applied
BACKUP_TEST_ADMIN_URL   a superuser connection to a server where throwaway databases may be created
PG_BIN_DIR              optional directory holding pg_dump / pg_restore
"""

import json
import os
from datetime import UTC, datetime
from pathlib import Path

import psycopg
import pytest

from suskii_workers.backup.dump import DumpConfig, run_dump
from suskii_workers.backup.manifest import Manifest
from suskii_workers.backup.pgtools import PgTools
from suskii_workers.backup.storage import LocalStorage
from suskii_workers.backup.verify import VerifyConfig, run_verify

SOURCE = os.environ.get("BACKUP_TEST_SOURCE_URL")
ADMIN = os.environ.get("BACKUP_TEST_ADMIN_URL")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (SOURCE and ADMIN), reason="BACKUP_TEST_SOURCE_URL and BACKUP_TEST_ADMIN_URL not set"
    ),
]

SCHEMAS = ["public", "private", "audit", "ledger", "kyc", "auth"]


@pytest.fixture
def tools() -> PgTools:
    bin_dir = os.environ.get("PG_BIN_DIR")
    return PgTools(Path(bin_dir) if bin_dir else None)


@pytest.fixture
def backup(tmp_path: Path, tools: PgTools):
    storage = LocalStorage(tmp_path / "bucket")
    now = datetime.now(UTC)
    manifest = run_dump(DumpConfig("test", SOURCE, "db", SCHEMAS, tools), storage, now)
    return storage, manifest


def test_dump_counts_rows_and_writes_manifest_last(backup):
    storage, manifest = backup
    keys = storage.list_keys("db/test/")
    assert manifest.dump_key in keys
    assert manifest.dump_key.replace(".dump", ".manifest.json") in keys
    assert manifest.table_row_counts["public.currencies"] >= 6
    assert "audit.log" in manifest.table_row_counts
    assert manifest.dump_bytes > 0


def test_verify_restores_and_proves_the_backup(backup, tools: PgTools):
    storage, _ = backup
    result = run_verify(VerifyConfig("test", "db", ADMIN, tools), storage, datetime.now(UTC))
    assert result.problems == []
    assert result.ok
    assert result.tables_checked > 10


def test_verify_detects_a_corrupted_dump(backup, tools: PgTools):
    storage, manifest = backup
    path = storage._path(manifest.dump_key)
    data = bytearray(path.read_bytes())
    data[len(data) // 2] ^= 0xFF
    path.write_bytes(bytes(data))

    result = run_verify(VerifyConfig("test", "db", ADMIN, tools), storage, datetime.now(UTC))
    assert not result.ok
    assert any("sha256" in p for p in result.problems)


def test_verify_detects_rows_missing_from_the_backup(backup, tools: PgTools):
    storage, manifest = backup
    key = manifest.dump_key.replace(".dump", ".manifest.json")
    raw = json.loads(storage.get_bytes(key))
    raw["table_row_counts"]["public.currencies"] += 1
    storage.put_bytes(json.dumps(raw).encode(), key, "application/json")

    result = run_verify(VerifyConfig("test", "db", ADMIN, tools), storage, datetime.now(UTC))
    assert not result.ok
    assert any(p.startswith("public.currencies:") for p in result.problems)


def test_verify_detects_a_broken_audit_chain_in_the_backup(tmp_path: Path, tools: PgTools):
    # Tamper with one audit row, take the backup, then put the original value back so the shared
    # test database's chain verifies again.
    storage = LocalStorage(tmp_path / "bucket")
    with psycopg.connect(SOURCE, autocommit=True) as conn:
        target_id, original_action = conn.execute(
            "SELECT id, action FROM audit.log ORDER BY id DESC LIMIT 1"
        ).fetchone()

        def set_action(action: str) -> None:
            conn.execute("ALTER TABLE audit.log DISABLE TRIGGER audit_log_no_update_delete")
            try:
                conn.execute("UPDATE audit.log SET action = %s WHERE id = %s", (action, target_id))
            finally:
                conn.execute("ALTER TABLE audit.log ENABLE TRIGGER audit_log_no_update_delete")

        set_action("tampered")
        try:
            run_dump(DumpConfig("tampered", SOURCE, "db", SCHEMAS, tools), storage, datetime.now(UTC))
        finally:
            # Restoring the original value restores the hash chain on the shared test database.
            set_action(original_action)
            assert conn.execute("SELECT private.audit_verify_chain()").fetchone()[0] is None

    result = run_verify(VerifyConfig("tampered", "db", ADMIN, tools), storage, datetime.now(UTC))
    assert not result.ok
    assert any(p.startswith("audit chain broken") for p in result.problems)
    assert Manifest.from_json(storage.get_bytes(result.manifest_key)).environment == "tampered"
