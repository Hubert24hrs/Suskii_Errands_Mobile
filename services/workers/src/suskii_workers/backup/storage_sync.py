"""Mirror Supabase Storage buckets into the backup bucket (infra-cicd.md §8; RB-09).

Endpoints follow the official storage-js client (checked 2026-09-17):
  POST {url}/storage/v1/object/list/{bucket}   body {prefix, limit, offset, sortBy}
       entries with id == null are folders; files carry metadata.eTag and metadata.size
  GET  {url}/storage/v1/object/{bucket}/{path}  authenticated download
Both with `apikey: <key>` and `Authorization: Bearer <key>`.

Backups are immutable. An object is copied to `storage/<env>/<bucket>/objects/<path>@<etag>`,
so a changed file gets a new key and history is kept until the bucket lifecycle deletes it. Each
run writes an index (`storage/<env>/<bucket>/index/<stamp>.json`) mapping every path to its
current copy; objects gone from the source stay in the index as `deleted_at` until the backup
itself ages out (120 days, which is what bounds how long deleted personal data survives).
"""

from __future__ import annotations

import json
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .manifest import sha256_file
from .storage import Storage

PAGE_SIZE = 100
KYC_BUCKET = "kyc-docs"


@dataclass(frozen=True)
class SourceObject:
    path: str
    etag: str
    size: int


class SupabaseStorageSource:
    def __init__(self, project_url: str, secret_key: str, timeout_s: float = 60.0) -> None:
        self._base = project_url.rstrip("/") + "/storage/v1"
        self._headers = {"apikey": secret_key, "Authorization": f"Bearer {secret_key}"}
        self._timeout = timeout_s

    def _request(self, method: str, url: str, body: dict | None = None) -> urllib.request.Request:
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self._headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        return urllib.request.Request(url, data=data, headers=headers, method=method)

    def list_objects(self, bucket: str, prefix: str = "") -> Iterator[SourceObject]:
        url = f"{self._base}/object/list/{urllib.parse.quote(bucket)}"
        offset = 0
        while True:
            body = {
                "prefix": prefix,
                "limit": PAGE_SIZE,
                "offset": offset,
                "sortBy": {"column": "name", "order": "asc"},
            }
            with urllib.request.urlopen(self._request("POST", url, body), timeout=self._timeout) as res:
                entries = json.load(res)
            for entry in entries:
                name = entry["name"]
                if entry.get("id") is None:
                    yield from self.list_objects(bucket, f"{prefix}{name}/")
                else:
                    metadata = entry.get("metadata") or {}
                    yield SourceObject(
                        path=f"{prefix}{name}",
                        etag=str(metadata.get("eTag", "")).strip('"'),
                        size=int(metadata.get("size", -1)),
                    )
            if len(entries) < PAGE_SIZE:
                return
            offset += PAGE_SIZE

    def download(self, bucket: str, path: str, target: Path) -> None:
        url = f"{self._base}/object/{urllib.parse.quote(bucket)}/{urllib.parse.quote(path)}"
        with (
            urllib.request.urlopen(self._request("GET", url), timeout=self._timeout) as res,
            target.open("wb") as out,
        ):
            while chunk := res.read(1024 * 1024):
                out.write(chunk)


@dataclass
class BucketResult:
    bucket: str
    copied: int = 0
    unchanged: int = 0
    deleted_in_source: int = 0
    failed: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.failed


def _safe_etag(etag: str) -> str:
    return "".join(c for c in etag if c.isalnum() or c in "-_") or "noetag"


def _latest_index(storage: Storage, base: str) -> dict:
    keys = [k for k in storage.list_keys(f"{base}/index/") if k.endswith(".json")]
    return json.loads(storage.get_bytes(max(keys))) if keys else {"objects": {}}


def sync_bucket(
    source: SupabaseStorageSource, storage: Storage, environment: str, bucket: str, now: datetime
) -> BucketResult:
    base = f"storage/{environment}/{bucket}"
    previous = _latest_index(storage, base)["objects"]
    current: dict[str, dict] = {}
    result = BucketResult(bucket)
    stamp = f"{now:%Y%m%dT%H%M%SZ}"

    with tempfile.TemporaryDirectory(prefix="suskii-storage-") as tmp:
        for obj in source.list_objects(bucket):
            known = previous.get(obj.path)
            if (
                known
                and not known.get("deleted_at")
                and known["etag"] == obj.etag
                and known["size"] == obj.size
            ):
                current[obj.path] = known
                result.unchanged += 1
                continue

            local = Path(tmp) / "object"
            try:
                source.download(bucket, obj.path, local)
                size = local.stat().st_size
                if obj.size >= 0 and size != obj.size:
                    raise ValueError(f"size {size} != listed {obj.size}")
                key = f"{base}/objects/{obj.path}@{_safe_etag(obj.etag)}"
                # An object deleted and later restored with identical content maps to a copy
                # that already exists; backups are never overwritten, so reuse it.
                if key not in storage.list_keys(key):
                    storage.put_file(local, key)
            except (OSError, ValueError, urllib.error.URLError) as exc:
                # Keep the previous copy in the index so a transient failure never drops a backup.
                if known:
                    current[obj.path] = known
                result.failed.append(f"{obj.path}: {type(exc).__name__}")
                continue

            current[obj.path] = {
                "key": key,
                "etag": obj.etag,
                "size": size,
                "sha256": sha256_file(local),
                "synced_at": now.isoformat(),
            }
            result.copied += 1

    for path, entry in previous.items():
        if path not in current:
            current[path] = {**entry, "deleted_at": entry.get("deleted_at") or now.isoformat()}
            if not entry.get("deleted_at"):
                result.deleted_in_source += 1

    index = {
        "bucket": bucket,
        "environment": environment,
        "generated_at": now.isoformat(),
        "objects": current,
    }
    storage.put_bytes(
        json.dumps(index, indent=2, sort_keys=True).encode(), f"{base}/index/{stamp}.json", "application/json"
    )
    return result


def sync_buckets(
    source: SupabaseStorageSource,
    general: Storage,
    kyc: Storage | None,
    environment: str,
    buckets: list[str],
    now: datetime,
) -> list[BucketResult]:
    if KYC_BUCKET in buckets and kyc is None:
        raise ValueError(f"{KYC_BUCKET} requires its own destination (BACKUP_KYC_STORAGE_URL)")
    return [
        sync_bucket(source, kyc if bucket == KYC_BUCKET else general, environment, bucket, now)
        for bucket in buckets
    ]
