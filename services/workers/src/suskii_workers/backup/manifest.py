"""Backup manifest: written last, so a manifest's existence means the backup is complete."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

FORMAT_VERSION = 1


@dataclass(frozen=True)
class Manifest:
    environment: str
    created_at: str
    dump_key: str
    dump_sha256: str
    dump_bytes: int
    pg_dump_version: str
    server_version: str
    dumped_schemas: list[str]
    table_row_counts: dict[str, int]
    format_version: int = FORMAT_VERSION

    def to_json(self) -> bytes:
        return json.dumps(asdict(self), indent=2, sort_keys=True).encode("utf-8")

    @classmethod
    def from_json(cls, data: bytes) -> Manifest:
        raw = json.loads(data)
        if raw.get("format_version") != FORMAT_VERSION:
            raise ValueError(f"unsupported manifest format_version {raw.get('format_version')!r}")
        return cls(**raw)


@dataclass(frozen=True)
class VerifyResult:
    environment: str
    manifest_key: str
    verified_at: str
    ok: bool
    problems: list[str] = field(default_factory=list)
    restore_seconds: float = 0.0
    tables_checked: int = 0

    def to_json(self) -> bytes:
        return json.dumps(asdict(self), indent=2, sort_keys=True).encode("utf-8")


def backup_stem(prefix: str, environment: str, now: datetime) -> str:
    """db/prod/2026/09/16/20260916T021500Z — sortable, so the latest backup is the greatest key."""
    now = now.astimezone(UTC)
    return f"{prefix}/{environment}/{now:%Y/%m/%d}/{now:%Y%m%dT%H%M%SZ}"


def latest_manifest_key(keys: list[str], prefix: str, environment: str) -> str | None:
    base = f"{prefix}/{environment}/"
    manifests = [k for k in keys if k.startswith(base) and k.endswith(".manifest.json")]
    return max(manifests) if manifests else None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
