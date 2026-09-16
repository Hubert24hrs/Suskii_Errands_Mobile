#!/usr/bin/env bash
# End-to-end storage sync against a real Supabase Storage API (the CLI local stack in CI).
# Requires: API_URL and SECRET_KEY (from `supabase status -o env`), uv, curl, python3.
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"

bucket="e2e-proofs"
auth=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")
dest="$(mktemp -d)"

curl -sSf "${auth[@]}" -H "Content-Type: application/json" \
  -d "{\"id\":\"$bucket\",\"name\":\"$bucket\",\"public\":false}" \
  "$API_URL/storage/v1/bucket" >/dev/null

upload() {
  printf '%s' "$2" > "$dest/upload.tmp"
  curl -sSf "${auth[@]}" -H "Content-Type: text/plain" --data-binary @"$dest/upload.tmp" \
    "$API_URL/storage/v1/object/$bucket/$1" >/dev/null
}
upload "jobs/0001/before.txt" "before photo"
upload "jobs/0001/after.txt" "after photo"
upload "root.txt" "root object"

export SUSKII_ENV=ci
export BACKUP_STORAGE_URL="file://$dest/backup"
export SUPABASE_URL="$API_URL"
export SUPABASE_SECRET_KEY="$SECRET_KEY"
export STORAGE_SYNC_BUCKETS="$bucket"

first="$(uv run suskii-backup storage-sync)"
second="$(uv run suskii-backup storage-sync)"
echo "$first"
echo "$second"

python3 - "$first" "$second" "$dest/backup" "$bucket" <<'PY'
import json, pathlib, sys
first, second = json.loads(sys.argv[1]), json.loads(sys.argv[2])
root, bucket = pathlib.Path(sys.argv[3]), sys.argv[4]
f, s = first["buckets"][bucket], second["buckets"][bucket]
assert first["ok"] and second["ok"], (first, second)
assert (f["copied"], f["unchanged"]) == (3, 0), f
assert (s["copied"], s["unchanged"]) == (0, 3), s
index_dir = root / "storage" / "ci" / bucket / "index"
index = json.loads(sorted(index_dir.iterdir())[-1].read_text())["objects"]
expected = {"jobs/0001/before.txt": "before photo", "jobs/0001/after.txt": "after photo", "root.txt": "root object"}
assert set(index) == set(expected), index.keys()
for path, content in expected.items():
    assert (root / index[path]["key"]).read_text() == content, path
print("storage sync e2e: ok")
PY
