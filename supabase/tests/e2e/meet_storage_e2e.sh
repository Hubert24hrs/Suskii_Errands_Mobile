#!/usr/bin/env bash
# End-to-end proof against a real Storage API (the CLI local stack in CI) that the Meet buckets
# behave as design §2.7 and §8.5 say: an eligible member uploads only into their own inbox folder,
# nobody reads the inbox back, and the inbox has a cap; `meet-media` is fetched through the
# authenticated endpoint by the people the policy admits and by nobody else, and a block applies
# at once; and nobody but staff can sign a `meet-media` URL, because a signed URL works without a
# session and outlives a block. pgTAP 74 checks the predicates; this checks the service that
# enforces them, including the one thing pgTAP cannot: that Storage names its sign operations in
# the `storage.operation` setting the policy reads.
#
# Requires: API_URL, SECRET_KEY (service role) and ANON_KEY from `supabase status -o env`, DB_URL
# (the same, defaulting to the CLI's local database); curl, jq, psql. Puts `meet.v5` back as it was.
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SECRET_KEY:?SECRET_KEY is required}"
ANON_KEY="${ANON_KEY:-${PUBLISHABLE_KEY:-}}"
: "${ANON_KEY:?ANON_KEY or PUBLISHABLE_KEY is required}"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

tmp="$(mktemp -d)"
failures=0
password="meet-e2e-$RANDOM-$RANDOM"
service=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")

check() { # description, actual, expected
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; failures=$((failures + 1)); fi
}

sql() { psql "$DB_URL" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }

new_user() { # email prefix -> "<user_id> <access_token>"
  local email="$1-$RANDOM@suskii.test" id token
  id="$(curl -sSf "${service[@]}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p,email_confirm:true}')" \
    "$API_URL/auth/v1/admin/users" | jq -r .id)"
  token="$(curl -sSf -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" \
    "$API_URL/auth/v1/token?grant_type=password" | jq -r .access_token)"
  echo "$id $token"
}

upload() { # bucket, path, bearer -> http status
  printf 'not a real photo' > "$tmp/file.bin"
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $3" -H "Content-Type: image/jpeg" \
    --data-binary @"$tmp/file.bin" "$API_URL/storage/v1/object/$1/$2"
}

fetch() { # bucket, path, bearer -> http status, through the authenticated endpoint the app uses
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $3" "$API_URL/storage/v1/object/authenticated/$1/$2"
}

refused() { # http status -> allowed | refused
  [ "$1" = 200 ] && echo allowed || echo refused
}

sign() { # path, bearer -> "signed" when a URL came back, else "refused"
  curl -sS -H "apikey: $ANON_KEY" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -d '{"expiresIn":3600}' "$API_URL/storage/v1/object/sign/meet-media/$1" \
    | jq -r 'if (.signedURL // "") != "" then "signed" else "refused" end'
}

sign_many() { # path, bearer -> "signed" when any URL came back, else "refused"
  curl -sS -H "apikey: $ANON_KEY" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$1" '{expiresIn:3600, paths:[$p]}')" "$API_URL/storage/v1/object/sign/meet-media" \
    | jq -r 'if type == "array" and any(.[]; (.signedURL // "") != "") then "signed" else "refused" end'
}

# meet.v5 on for testers only, as the release plan's first step leaves it; put back on the way out.
flag_before="$(sql "SELECT jsonb_build_object('enabled', enabled, 'payload', payload)
                    FROM public.feature_flags WHERE key = 'meet.v5' AND country_code IS NULL")"
restore() {
  sql "UPDATE public.feature_flags
       SET enabled = ('$flag_before'::jsonb ->> 'enabled')::boolean,
           payload = '$flag_before'::jsonb -> 'payload'
       WHERE key = 'meet.v5' AND country_code IS NULL" || true
  rm -rf "$tmp"
}
trap restore EXIT
sql "UPDATE public.feature_flags SET enabled = true, payload = '{\"testers_only\": true}'
     WHERE key = 'meet.v5' AND country_code IS NULL"

read -r owner owner_token <<< "$(new_user meet-owner)"
read -r viewer viewer_token <<< "$(new_user meet-viewer)"
read -r outsider outsider_token <<< "$(new_user meet-outsider)"

# Two eligible testers with active, discoverable profiles a few kilometres apart in Lagos, each
# with one approved photo (a person's review, which M1-PR4 builds, written directly here).
member() { # user id, first name, lat, lng -> profile id
  sql "WITH p AS (
         INSERT INTO public.meet_profiles (user_id, country_code, first_name, area_geohash, area_point,
                                           area_set_at)
         SELECT '$1', 'NG', '$2', g.cell,
                extensions.ST_SetSRID(extensions.ST_PointFromGeoHash(g.cell), 4326)::extensions.geography,
                now()
         FROM (SELECT extensions.ST_GeoHash(extensions.ST_SetSRID(
                        extensions.ST_MakePoint($4, $3), 4326), 5) AS cell) g
         RETURNING id)
       SELECT id FROM p"
}
sql "UPDATE public.profiles SET country_code = 'NG' WHERE user_id IN ('$owner', '$viewer', '$outsider');
     INSERT INTO private.meet_testers (user_id) VALUES ('$owner'), ('$viewer');
     INSERT INTO public.meet_eligibility (user_id, status, birth_date, guidelines_version)
     VALUES ('$owner', 'eligible', '1995-03-03', private.meet_guidelines_version()),
            ('$viewer', 'eligible', '1994-01-15', private.meet_guidelines_version())"
owner_profile="$(member "$owner" Ada 6.4281 3.4219)"
viewer_profile="$(member "$viewer" Bola 6.4549 3.4246)"

photo() { # profile id -> "<media path> <thumb path>", the row approved and the profile discoverable
  local id main thumb
  id="$(sql "SELECT gen_random_uuid()")"
  main="$1/p/$id.jpg"
  thumb="$1/pt/$id.jpg"
  sql "INSERT INTO public.meet_photos (id, profile_id, position, media_path, thumb_path, sha256, width,
                                       height, mime, status)
       VALUES ('$id', '$1', 0, '$main', '$thumb', sha256('$id'::text::bytea), 1080, 1350, 'image/jpeg',
               'approved');
       SELECT private.meet_refresh_profile('$1');
       UPDATE public.meet_profiles SET discoverable = true WHERE id = '$1'" > /dev/null
  echo "$main $thumb"
}
read -r media thumb <<< "$(photo "$owner_profile")"
photo "$viewer_profile" > /dev/null

# Only the worker writes meet-media; here the service role stands in for it.
printf 'not a real photo' > "$tmp/file.bin"
for path in "$media" "$thumb"; do
  check "the service role stores $(basename "$(dirname "$path")")/ in meet-media" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${service[@]}" -H "Content-Type: image/jpeg" \
         --data-binary @"$tmp/file.bin" "$API_URL/storage/v1/object/meet-media/$path")" "200"
done
check "the two are discoverable to each other" \
  "$(sql "SELECT private.meet_discoverable_to('$viewer_profile', '$owner_profile')")" "t"

# The inbox.
check "an eligible tester uploads into their own inbox folder" \
  "$(upload meet-inbox "$owner/$(sql "SELECT gen_random_uuid()").jpg" "$owner_token")" "200"
check "but not into somebody else's" \
  "$(refused "$(upload meet-inbox "$viewer/$(sql "SELECT gen_random_uuid()").jpg" "$owner_token")")" "refused"
check "and somebody Meet is not on for cannot upload at all" \
  "$(refused "$(upload meet-inbox "$outsider/$(sql "SELECT gen_random_uuid()").jpg" "$outsider_token")")" "refused"
first_inbox="$(sql "SELECT name FROM storage.objects WHERE bucket_id = 'meet-inbox' AND name LIKE '$owner/%' LIMIT 1")"
check "nobody reads the inbox back, the uploader included" \
  "$(refused "$(fetch meet-inbox "$first_inbox" "$owner_token")")" "refused"

# meet-media through the authenticated endpoint.
check "a viewer the profile is discoverable to fetches the approved photo" "$(fetch meet-media "$media" "$viewer_token")" "200"
check "and its thumbnail" "$(fetch meet-media "$thumb" "$viewer_token")" "200"
check "the owner fetches it" "$(fetch meet-media "$media" "$owner_token")" "200"
check "somebody Meet is not on for cannot" "$(refused "$(fetch meet-media "$media" "$outsider_token")")" "refused"

# No shareable URL: signing is refused to everybody but staff.
check "the viewer cannot sign a URL for it" "$(sign "$media" "$viewer_token")" "refused"
check "nor sign several at once" "$(sign_many "$media" "$viewer_token")" "refused"
check "nor can the owner" "$(sign "$media" "$owner_token")" "refused"
check "while the viewer can still fetch it the ordinary way" "$(fetch meet-media "$media" "$viewer_token")" "200"
check "and signing works at all (the service role, which the policy does not apply to)" \
  "$(curl -sS "${service[@]}" -H "Content-Type: application/json" -d '{"expiresIn":60}' \
       "$API_URL/storage/v1/object/sign/meet-media/$media" \
     | jq -r 'if (.signedURL // "") != "" then "signed" else "refused" end')" "signed"

# A block applies at the next fetch.
sql "INSERT INTO public.blocks (blocker_id, blocked_id) VALUES ('$owner', '$viewer')"
check "once the owner blocks the viewer, the viewer's next fetch is refused" \
  "$(refused "$(fetch meet-media "$media" "$viewer_token")")" "refused"

# The inbox cap: two files per allowed photo, plus one pair (14 with meet.photos.max at 6). One
# file is already there.
cap="$(sql "SELECT 2 * (least(greatest(coalesce(private.remote_config_int('meet.photos.max'), 6), 1), 6) + 1)")"
statuses=""
for _ in $(seq 2 "$cap"); do
  statuses="$statuses $(upload meet-inbox "$owner/$(sql "SELECT gen_random_uuid()").jpg" "$owner_token")"
done
check "uploads up to the cap ($cap) are taken" "$(echo "$statuses" | tr ' ' '\n' | grep -vc '^200$\|^$' || true)" "0"
check "and the next one is refused" \
  "$(refused "$(upload meet-inbox "$owner/$(sql "SELECT gen_random_uuid()").jpg" "$owner_token")")" "refused"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "meet storage e2e: all checks passed"
