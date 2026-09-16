"""Nightly logical backup (infra-cicd.md §8).

The row counts in the manifest and the dump itself come from the same exported snapshot, so the
restore check can require exact equality: any difference means the backup is wrong, not that
the database moved on in between.
"""

from __future__ import annotations

import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import psycopg
from psycopg import sql

from .manifest import Manifest, backup_stem, sha256_file
from .pgtools import PgTools, connection_args, run
from .storage import Storage

COUNT_TABLES_SQL = """
SELECT n.nspname, c.relname
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY(%s)
  AND c.relkind IN ('r', 'p')
  AND NOT c.relispartition
ORDER BY 1, 2
"""


@dataclass(frozen=True)
class DumpConfig:
    environment: str
    source_url: str
    prefix: str
    schemas: list[str]
    tools: PgTools


def run_dump(cfg: DumpConfig, storage: Storage, now: datetime) -> Manifest:
    stem = backup_stem(cfg.prefix, cfg.environment, now)
    dump_key = f"{stem}.dump"

    with tempfile.TemporaryDirectory(prefix="suskii-backup-") as tmp:
        dump_path = Path(tmp) / "backup.dump"

        with psycopg.connect(cfg.source_url) as conn:
            conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            snapshot = conn.execute("SELECT pg_export_snapshot()").fetchone()[0]
            server_version = conn.execute("SHOW server_version").fetchone()[0]

            counts: dict[str, int] = {}
            for schema, table in conn.execute(COUNT_TABLES_SQL, (cfg.schemas,)).fetchall():
                query = sql.SQL("SELECT count(*) FROM {}.{}").format(
                    sql.Identifier(schema), sql.Identifier(table)
                )
                counts[f"{schema}.{table}"] = conn.execute(query).fetchone()[0]

            # pg_dump must run while this transaction holds the exported snapshot open.
            args, env = connection_args(cfg.source_url)
            cmd = [
                cfg.tools.executable("pg_dump"),
                *args,
                "--format=custom",
                "--compress=6",
                f"--snapshot={snapshot}",
                f"--file={dump_path}",
            ]
            for schema in cfg.schemas:
                cmd.append(f"--schema={schema}")
            run(cmd, env)
            conn.rollback()

        manifest = Manifest(
            environment=cfg.environment,
            created_at=now.isoformat(),
            dump_key=dump_key,
            dump_sha256=sha256_file(dump_path),
            dump_bytes=dump_path.stat().st_size,
            pg_dump_version=cfg.tools.version("pg_dump"),
            server_version=server_version,
            dumped_schemas=list(cfg.schemas),
            table_row_counts=counts,
        )
        storage.put_file(dump_path, dump_key)
        storage.put_bytes(manifest.to_json(), f"{stem}.manifest.json", "application/json")
        return manifest
