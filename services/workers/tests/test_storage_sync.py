import json
import threading
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pytest

from suskii_workers.backup import storage_sync
from suskii_workers.backup.storage import LocalStorage
from suskii_workers.backup.storage_sync import SupabaseStorageSource, sync_bucket, sync_buckets

KEY = "sb_secret_test"


class FakeStorage:
    """In-memory stand-in for the Supabase Storage list and download endpoints."""

    def __init__(self):
        self.buckets: dict[str, dict[str, bytes]] = {}
        self.lie_about_size: set[str] = set()
        self.list_calls = 0

    def list(self, bucket: str, prefix: str, limit: int, offset: int) -> list[dict]:
        self.list_calls += 1
        files, folders = [], set()
        for path in sorted(self.buckets.get(bucket, {})):
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix) :]
            if "/" in rest:
                folders.add(rest.split("/", 1)[0])
            else:
                files.append(rest)
        entries = [{"name": f, "id": None, "metadata": None} for f in sorted(folders)]
        for name in files:
            data = self.buckets[bucket][prefix + name]
            size = len(data) + (1 if prefix + name in self.lie_about_size else 0)
            etag = f'"{abs(hash(data)) % 10**12}"'
            entries.append(
                {"name": name, "id": f"id-{prefix}{name}", "metadata": {"eTag": etag, "size": size}}
            )
        entries.sort(key=lambda e: e["name"])
        return entries[offset : offset + limit]


@pytest.fixture
def fake(monkeypatch):
    state = FakeStorage()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _authorised(self) -> bool:
            ok = self.headers.get("apikey") == KEY and self.headers.get("Authorization") == f"Bearer {KEY}"
            if not ok:
                self.send_response(401)
                self.end_headers()
            return ok

        def do_POST(self):
            if not self._authorised():
                return
            bucket = unquote(self.path.removeprefix("/storage/v1/object/list/"))
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            payload = json.dumps(state.list(bucket, body["prefix"], body["limit"], body["offset"])).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if not self._authorised():
                return
            bucket, path = unquote(self.path.removeprefix("/storage/v1/object/")).split("/", 1)
            data = state.buckets[bucket][path]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setattr(storage_sync, "PAGE_SIZE", 3)
    state.source = SupabaseStorageSource(f"http://127.0.0.1:{server.server_address[1]}", KEY, timeout_s=5)
    yield state
    server.shutdown()


NOW = datetime(2026, 9, 17, 3, 15, tzinfo=UTC)


def latest_index(storage: LocalStorage, bucket: str) -> dict:
    keys = storage.list_keys(f"storage/test/{bucket}/index/")
    return json.loads(storage.get_bytes(max(keys)))


def test_first_sync_copies_every_object_across_folders_and_pages(fake, tmp_path: Path):
    fake.buckets["proofs"] = {f"jobs/{i:02d}/photo.jpg": f"img{i}".encode() for i in range(7)}
    fake.buckets["proofs"]["root.txt"] = b"root"
    storage = LocalStorage(tmp_path)

    result = sync_bucket(fake.source, storage, "test", "proofs", NOW)

    assert (result.copied, result.unchanged, result.failed) == (8, 0, [])
    index = latest_index(storage, "proofs")["objects"]
    assert set(index) == set(fake.buckets["proofs"])
    assert storage.get_bytes(index["jobs/03/photo.jpg"]["key"]) == b"img3"


def test_second_sync_copies_only_changes_and_keeps_history(fake, tmp_path: Path):
    fake.buckets["receipts"] = {"a.jpg": b"one", "b.jpg": b"two"}
    storage = LocalStorage(tmp_path)
    sync_bucket(fake.source, storage, "test", "receipts", NOW)
    first_key = latest_index(storage, "receipts")["objects"]["a.jpg"]["key"]

    fake.buckets["receipts"]["a.jpg"] = b"one, edited"
    result = sync_bucket(fake.source, storage, "test", "receipts", NOW + timedelta(days=1))

    assert (result.copied, result.unchanged) == (1, 1)
    new_key = latest_index(storage, "receipts")["objects"]["a.jpg"]["key"]
    assert new_key != first_key
    assert storage.get_bytes(first_key) == b"one"
    assert storage.get_bytes(new_key) == b"one, edited"


def test_objects_deleted_at_source_are_marked_not_removed(fake, tmp_path: Path):
    fake.buckets["chat-media"] = {"x.png": b"x", "y.png": b"y"}
    storage = LocalStorage(tmp_path)
    sync_bucket(fake.source, storage, "test", "chat-media", NOW)

    del fake.buckets["chat-media"]["x.png"]
    result = sync_bucket(fake.source, storage, "test", "chat-media", NOW + timedelta(days=1))
    again = sync_bucket(fake.source, storage, "test", "chat-media", NOW + timedelta(days=2))

    assert result.deleted_in_source == 1
    assert again.deleted_in_source == 0
    entry = latest_index(storage, "chat-media")["objects"]["x.png"]
    assert entry["deleted_at"] == (NOW + timedelta(days=1)).isoformat()
    assert storage.get_bytes(entry["key"]) == b"x"


def test_a_size_mismatch_fails_that_object_and_keeps_the_previous_copy(fake, tmp_path: Path):
    fake.buckets["avatars"] = {"u1.png": b"face"}
    storage = LocalStorage(tmp_path)
    sync_bucket(fake.source, storage, "test", "avatars", NOW)

    fake.buckets["avatars"]["u1.png"] = b"new face"
    fake.lie_about_size.add("u1.png")
    result = sync_bucket(fake.source, storage, "test", "avatars", NOW + timedelta(days=1))

    assert not result.ok
    assert result.failed == ["u1.png: ValueError"]
    assert storage.get_bytes(latest_index(storage, "avatars")["objects"]["u1.png"]["key"]) == b"face"


def test_kyc_documents_never_go_to_the_general_backup_bucket(fake, tmp_path: Path):
    fake.buckets["kyc-docs"] = {"u1/id.jpg": b"id"}
    general = LocalStorage(tmp_path / "general")
    with pytest.raises(ValueError, match="kyc-docs requires its own destination"):
        sync_buckets(fake.source, general, None, "test", ["kyc-docs"], NOW)

    kyc = LocalStorage(tmp_path / "kyc")
    sync_buckets(fake.source, general, kyc, "test", ["kyc-docs"], NOW)
    assert general.list_keys("") == []
    copies = kyc.list_keys("storage/test/kyc-docs/objects/")
    assert len(copies) == 1 and copies[0].startswith("storage/test/kyc-docs/objects/u1/id.jpg@")


def test_an_object_restored_with_identical_content_reuses_its_existing_copy(fake, tmp_path: Path):
    fake.buckets["proofs"] = {"p.jpg": b"same"}
    storage = LocalStorage(tmp_path)
    sync_bucket(fake.source, storage, "test", "proofs", NOW)
    del fake.buckets["proofs"]["p.jpg"]
    sync_bucket(fake.source, storage, "test", "proofs", NOW + timedelta(days=1))

    fake.buckets["proofs"]["p.jpg"] = b"same"
    written: list[str] = []
    original_put = storage.put_file
    storage.put_file = lambda local, key: (written.append(key), original_put(local, key))
    result = sync_bucket(fake.source, storage, "test", "proofs", NOW + timedelta(days=2))

    assert (result.copied, result.failed, written) == (1, [], [])
    assert "deleted_at" not in latest_index(storage, "proofs")["objects"]["p.jpg"]


def test_requests_carry_the_api_key_headers(fake, tmp_path: Path):
    fake.buckets["proofs"] = {"a": b"a"}
    wrong = SupabaseStorageSource(fake.source._base.removesuffix("/storage/v1"), "wrong-key", timeout_s=5)
    with pytest.raises(Exception, match="401"):
        list(wrong.list_objects("proofs"))
