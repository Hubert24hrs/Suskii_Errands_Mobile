"""Where backups live: the EU GCS bucket in real environments, a local directory in tests."""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Protocol
from urllib.parse import urlparse


class Storage(Protocol):
    def put_file(self, local_path: Path, key: str) -> None: ...
    def get_file(self, key: str, local_path: Path) -> None: ...
    def put_bytes(self, data: bytes, key: str, content_type: str) -> None: ...
    def get_bytes(self, key: str) -> bytes: ...
    def list_keys(self, prefix: str) -> list[str]: ...


class LocalStorage:
    def __init__(self, root: Path) -> None:
        self.root = root

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError(f"key escapes storage root: {key}")
        return path

    def put_file(self, local_path: Path, key: str) -> None:
        target = self._path(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(local_path, target)

    def get_file(self, key: str, local_path: Path) -> None:
        shutil.copyfile(self._path(key), local_path)

    def put_bytes(self, data: bytes, key: str, content_type: str) -> None:
        target = self._path(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def get_bytes(self, key: str) -> bytes:
        return self._path(key).read_bytes()

    def list_keys(self, prefix: str) -> list[str]:
        base = self.root.resolve()
        if not base.exists():
            return []
        keys = [p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file()]
        return sorted(k for k in keys if k.startswith(prefix))


class GcsStorage:
    """Uploads use the job's service account (Workload Identity on Cloud Run); no keys."""

    def __init__(self, bucket_name: str) -> None:
        from google.cloud import storage

        self._bucket = storage.Client().bucket(bucket_name)

    def put_file(self, local_path: Path, key: str) -> None:
        # if_generation_match=0: never overwrite an existing backup object.
        self._bucket.blob(key).upload_from_filename(str(local_path), if_generation_match=0)

    def get_file(self, key: str, local_path: Path) -> None:
        self._bucket.blob(key).download_to_filename(str(local_path))

    def put_bytes(self, data: bytes, key: str, content_type: str) -> None:
        self._bucket.blob(key).upload_from_string(data, content_type=content_type, if_generation_match=0)

    def get_bytes(self, key: str) -> bytes:
        return self._bucket.blob(key).download_as_bytes()

    def list_keys(self, prefix: str) -> list[str]:
        return sorted(blob.name for blob in self._bucket.client.list_blobs(self._bucket, prefix=prefix))


def storage_from_url(url: str) -> Storage:
    parsed = urlparse(url)
    if parsed.scheme == "gs" and parsed.netloc:
        return GcsStorage(parsed.netloc)
    if parsed.scheme == "file":
        path = parsed.path
        if re.match(r"^/[A-Za-z]:", path):  # file:///C:/dir on Windows
            path = path[1:]
        return LocalStorage(Path(path))
    raise ValueError(f"unsupported storage URL {url!r}: use gs://bucket or file:///path")
