"""Restore verification (infra-cicd.md §8; RB-09 drill, automated).

Restores a backup into a throwaway database and proves it is usable: the dump is intact, every
table has exactly the rows counted at dump time, the audit hash chain still verifies, and the
ledger is zero-sum. A backup that has never been restored is a hope, not a backup.
"""

from __future__ import annotations

import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import psycopg
from psycopg import sql

from .manifest import Manifest, VerifyResult, latest_manifest_key, sha256_file
from .pgtools import PgTools, connection_args, run
from .storage import Storage

# Objects a Supabase project provides outside the dumped schemas. Restoring our schemas needs
# them to exist: policies name these roles, and columns use PostGIS types from `extensions`.
PREPARE_ROLES = ("anon", "authenticated", "service_role", "supabase_auth_admin")
# The dump recreates `public` itself, so the empty default schema of the fresh database goes first.
PREPARE_SQL = """
DROP SCHEMA public;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
"""


@dataclass(frozen=True)
class VerifyConfig:
    environment: str
    prefix: str
    restore_admin_url: str
    tools: PgTools
    manifest_key: str | None = None


def _restore_url(admin_url: str, dbname: str) -> str:
    return psycopg.conninfo.make_conninfo(admin_url, dbname=dbname)


def run_verify(cfg: VerifyConfig, storage: Storage, now: datetime) -> VerifyResult:
    manifest_key = cfg.manifest_key or latest_manifest_key(
        storage.list_keys(f"{cfg.prefix}/{cfg.environment}/"), cfg.prefix, cfg.environment
    )
    if manifest_key is None:
        return VerifyResult(cfg.environment, "", now.isoformat(), ok=False, problems=["no backup found"])

    manifest = Manifest.from_json(storage.get_bytes(manifest_key))
    problems: list[str] = []
    dbname = f"suskii_restore_{int(time.time())}"
    started = time.monotonic()

    with tempfile.TemporaryDirectory(prefix="suskii-verify-") as tmp:
        dump_path = Path(tmp) / "backup.dump"
        storage.get_file(manifest.dump_key, dump_path)

        if dump_path.stat().st_size != manifest.dump_bytes:
            problems.append(f"size mismatch: {dump_path.stat().st_size} != {manifest.dump_bytes}")
        if sha256_file(dump_path) != manifest.dump_sha256:
            problems.append("sha256 mismatch: the dump is corrupt or was modified")
        if problems:
            return VerifyResult(cfg.environment, manifest_key, now.isoformat(), ok=False, problems=problems)

        with psycopg.connect(cfg.restore_admin_url, autocommit=True) as admin:
            for role in PREPARE_ROLES:
                exists = admin.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone()
                if not exists:
                    admin.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)))
            admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbname)))

        restore_url = _restore_url(cfg.restore_admin_url, dbname)
        tables_checked = 0
        try:
            with psycopg.connect(restore_url, autocommit=True) as conn:
                conn.execute(PREPARE_SQL)

            args, env = connection_args(restore_url)
            run(
                [
                    cfg.tools.executable("pg_restore"),
                    *args,
                    "--no-owner",
                    "--no-privileges",
                    "--exit-on-error",
                    "--single-transaction",
                    str(dump_path),
                ],
                env,
            )

            with psycopg.connect(restore_url, autocommit=True) as conn:
                for table, expected in sorted(manifest.table_row_counts.items()):
                    schema, name = table.split(".", 1)
                    query = sql.SQL("SELECT count(*) FROM {}.{}").format(
                        sql.Identifier(schema), sql.Identifier(name)
                    )
                    try:
                        actual = conn.execute(query).fetchone()[0]
                    except psycopg.Error as exc:
                        problems.append(f"{table}: not restorable ({exc.diag.sqlstate})")
                        continue
                    tables_checked += 1
                    if actual != expected:
                        problems.append(f"{table}: {actual} rows restored, {expected} at dump time")

                problems.extend(_integrity_checks(conn))
        except RuntimeError as exc:
            problems.append(str(exc))
        finally:
            with psycopg.connect(cfg.restore_admin_url, autocommit=True) as admin:
                admin.execute(
                    sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(dbname))
                )

    return VerifyResult(
        environment=cfg.environment,
        manifest_key=manifest_key,
        verified_at=now.isoformat(),
        ok=not problems,
        problems=problems,
        restore_seconds=round(time.monotonic() - started, 1),
        tables_checked=tables_checked,
    )


def _integrity_checks(conn: psycopg.Connection) -> list[str]:
    problems: list[str] = []

    has_audit = conn.execute("SELECT to_regprocedure('private.audit_verify_chain()') IS NOT NULL").fetchone()[
        0
    ]
    if has_audit:
        broken = conn.execute("SELECT private.audit_verify_chain()").fetchone()[0]
        if broken is not None:
            problems.append(f"audit chain broken at id {broken}")

    has_ledger = conn.execute("SELECT to_regclass('ledger.entries') IS NOT NULL").fetchone()[0]
    if has_ledger:
        unbalanced = conn.execute(
            "SELECT count(*) FROM (SELECT transaction_id FROM ledger.entries "
            "GROUP BY transaction_id HAVING sum(amount_minor) <> 0) t"
        ).fetchone()[0]
        if unbalanced:
            problems.append(f"ledger: {unbalanced} unbalanced transaction(s)")

    return problems
