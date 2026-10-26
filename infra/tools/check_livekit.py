#!/usr/bin/env python3
"""Prove a project's LiveKit credentials work, end to end, without a phone and without showing them.

Reads the latest `livekit-credentials` version from Secret Manager, signs a token exactly the way
the `call-token` function does (HS256 over the API secret, `iss` the API key; here with the
`roomList` grant instead of a room join), and calls LiveKit's documented server API,
`POST /twirp/livekit.RoomService/ListRooms` (docs.livekit.io, Room service API, read 2026-10-26).
A 200 means the URL, the key, the secret and the signing all agree with LiveKit. Prints the outcome
and the number of open rooms, nothing else (the response carries TURN credentials).

Usage: python infra/tools/check_livekit.py <gcp-project>
"""

import base64
import hashlib
import hmac
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(api_key: str, api_secret: str) -> str:
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"iss": api_key, "sub": "suskii-credentials-check", "nbf": now, "exp": now + 120,
               "video": {"roomList": True}}
    signing = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}." \
              f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    sig = hmac.new(api_secret.encode(), signing.encode(), hashlib.sha256).digest()
    return f"{signing}.{b64url(sig)}"


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", sys.argv[1]):
        sys.exit(__doc__)
    r = subprocess.run(f"gcloud secrets versions access latest --secret livekit-credentials --project {sys.argv[1]}",
                       shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("no livekit-credentials version yet: run infra/tools/set_livekit_credentials.py first")
    creds = json.loads(r.stdout)
    host = re.sub(r"^wss://", "https://", creds["url"])
    req = urllib.request.Request(
        f"{host}/twirp/livekit.RoomService/ListRooms", data=b"{}", method="POST",
        headers={"Authorization": f"Bearer {token(creds['api_key'], creds['api_secret'])}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
            rooms = body.get("rooms", [])
            print(f"LiveKit OK: {host} accepted the key and the signature ({len(rooms)} open room(s)).")
    except urllib.error.HTTPError as e:
        sys.exit(f"LiveKit refused it: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")
    except urllib.error.URLError as e:
        sys.exit(f"could not reach {host}: {e.reason}")


if __name__ == "__main__":
    main()
