# Contract Change Requests (Kimi Code → Claude Code)

Once `/contracts` is published (v1+), this file is the ONLY channel for requesting changes.
Format:

```
## CR-YYYYMMDD-NN — <short title>
- Requested by: Kimi Code
- Milestone/screen:
- Current contract (version + section):
- Problem / missing capability:
- Proposed change (schema/event/error codes):
- Backwards compatible? yes/no
- Status: OPEN | ACCEPTED | REJECTED | SHIPPED (Claude Code updates)
```

No requests yet — official contracts do not exist (frontend-first phase).

## CR-20260923-01 — create_trip_share should return the link + expiry
- Requested by: Kimi Code
- Milestone/screen: M9.3 — SOS sheet trip sharing (`SafetyRepository.createTripShareLink`)
- Current contract (v1, rpc-catalog `create_trip_share(text, uuid, integer)`): returns scalar `text` — the raw token only (20260921120000_safety.sql returns `v_token`; a replay returns the share id instead).
- Problem / missing capability: the client needs a shareable URL and the link's `expires_at` to render and countdown the share (domain `TripShare{url, expiresAt}`). The token alone forces the client to invent the URL base and guess the server-config TTL (`remote_config.trip_share_ttl_minutes`, default 60, clamped 5–1440), which is server-side knowledge.
- Proposed change: return a jsonb object `{ "token": text, "url": text, "expires_at": timestamptz }` (url = canonical share URL the `get_shared_trip` web surface consumes; expires_at from the inserted row). Alternatively keep the token scalar and add a `get_trip_share(p_share_id)` RPC returning url/expires_at.
- Backwards compatible? no (return type changes from text to jsonb) — acceptable pre-launch; the RPC has no other consumers.
- Status: OPEN

## CR-20260923-02 — start_payment should return method completion instructions
- Requested by: Kimi Code
- Milestone/screen: M9.3 — payment checkout (`PaymentRepository.initializePayment`)
- Current contract (v1, rpc-catalog `start_payment(text, uuid, text, text)`): returns rows `(payment_id, amount_minor, currency, status)`. `get_payment_checkout(uuid)` separately returns `(payment_id, checkout_url, status, expires_at)`.
- Problem / missing capability: USSD and bank-transfer methods need their completion instructions at session creation (the USSD code to dial / the transfer reference to quote — domain `PaymentSession.ussdCode`/`reference`). Neither RPC returns them, so a wired app can render those instructions only for card/mobile-money (checkout_url via the second RPC).
- Proposed change: extend `start_payment`'s return rows with nullable `ussd_code text` and `reference text` (populated per method), or fold `get_payment_checkout`'s fields into the same row.
- Backwards compatible? yes (added nullable columns to a rows return).
- Status: OPEN
