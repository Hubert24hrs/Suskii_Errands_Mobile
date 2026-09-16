import hashlib
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path

import pytest

from suskii_workers.backup.manifest import Manifest, backup_stem, latest_manifest_key, sha256_file
from suskii_workers.backup.pgtools import connection_args
from suskii_workers.backup.storage import LocalStorage, storage_from_url


def make_manifest(**overrides) -> Manifest:
    values = dict(
        environment="dev",
        created_at="2026-09-16T02:15:00+00:00",
        dump_key="db/dev/2026/09/16/20260916T021500Z.dump",
        dump_sha256="ab" * 32,
        dump_bytes=1234,
        pg_dump_version="pg_dump (PostgreSQL) 17.5",
        server_version="17.5",
        dumped_schemas=["public", "private"],
        table_row_counts={"public.profiles": 3},
    )
    values.update(overrides)
    return Manifest(**values)


def test_backup_stem_is_utc_and_sortable():
    lagos = timezone(timedelta(hours=1))
    stem = backup_stem("db", "prod", datetime(2026, 9, 16, 3, 15, 0, tzinfo=lagos))
    assert stem == "db/prod/2026/09/16/20260916T021500Z"


def test_latest_manifest_ignores_other_environments_and_incomplete_backups():
    keys = [
        "db/prod/2026/09/15/20260915T021500Z.dump",
        "db/prod/2026/09/15/20260915T021500Z.manifest.json",
        "db/prod/2026/09/16/20260916T021500Z.dump",  # dump without manifest: incomplete
        "db/staging/2026/09/17/20260917T021500Z.manifest.json",
    ]
    assert latest_manifest_key(keys, "db", "prod") == "db/prod/2026/09/15/20260915T021500Z.manifest.json"
    assert latest_manifest_key(keys, "db", "dev") is None


def test_manifest_round_trip_and_version_guard():
    manifest = make_manifest()
    assert Manifest.from_json(manifest.to_json()) == manifest
    with pytest.raises(ValueError, match="format_version"):
        Manifest.from_json(manifest.to_json().replace(b'"format_version": 1', b'"format_version": 99'))


def test_sha256_file(tmp_path: Path):
    path = tmp_path / "f"
    path.write_bytes(b"suskii")
    assert sha256_file(path) == hashlib.sha256(b"suskii").hexdigest()


def test_local_storage_round_trip_and_prefix_listing(tmp_path: Path):
    storage = LocalStorage(tmp_path)
    storage.put_bytes(b"{}", "db/dev/a.manifest.json", "application/json")
    source = tmp_path / "src.dump"
    source.write_bytes(b"dump")
    storage.put_file(source, "db/dev/a.dump")
    storage.put_bytes(b"{}", "db/prod/b.manifest.json", "application/json")

    assert storage.list_keys("db/dev/") == ["db/dev/a.dump", "db/dev/a.manifest.json"]
    assert storage.get_bytes("db/dev/a.dump") == b"dump"
    out = tmp_path / "out.dump"
    storage.get_file("db/dev/a.dump", out)
    assert out.read_bytes() == b"dump"


def test_local_storage_refuses_keys_outside_its_root(tmp_path: Path):
    with pytest.raises(ValueError, match="escapes"):
        LocalStorage(tmp_path / "root").put_bytes(b"x", "../outside", "text/plain")


def test_storage_url_parsing(tmp_path: Path):
    assert isinstance(storage_from_url(tmp_path.as_uri()), LocalStorage)
    with pytest.raises(ValueError, match="unsupported"):
        storage_from_url("s3://bucket")


def test_connection_args_keep_the_password_out_of_argv():
    args, env = connection_args(
        "postgresql://postgres:s3cret@db.example.invalid:6543/postgres?sslmode=require"
    )
    assert "s3cret" not in " ".join(args)
    assert args == [
        "--host",
        "db.example.invalid",
        "--port",
        "6543",
        "--username",
        "postgres",
        "--dbname",
        "postgres",
    ]
    assert env["PGPASSWORD"] == "s3cret"
    assert env["PGSSLMODE"] == "require"


def test_cli_rejects_unknown_command(capsys):
    from suskii_workers.backup.cli import main

    assert main(["restore-everything"]) == 2


def test_cli_requires_environment(monkeypatch):
    from suskii_workers.backup.cli import main

    monkeypatch.delenv("SUSKII_ENV", raising=False)
    with pytest.raises(SystemExit) as exc:
        main(["dump"])
    assert exc.value.code == 2


def test_verify_result_json_is_stable():
    from suskii_workers.backup.manifest import VerifyResult

    result = VerifyResult("dev", "k", datetime(2026, 9, 16, tzinfo=UTC).isoformat(), ok=False, problems=["x"])
    assert b'"problems": [\n    "x"\n  ]' in result.to_json()
