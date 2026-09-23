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

## CR-20260923-03 — client-readable wallet transaction feed
- Requested by: Kimi Code
- Milestone/screen: M9.4 — wallet history (`WalletRepository.getTransactions`)
- Current contract (v1): the double-entry ledger lives in the private schema (by design); the only client-visible movement rows are `withdrawals`/`payouts` table selects and the `available_balance`/`my_balances` RPCs.
- Problem / missing capability: the wallet screen needs a chronological transaction feed (holds, releases, refunds, tips, payouts, referral credits — domain `WalletTransaction.kind` has 8 kinds) and a "pending" amount. Neither is derivable client-side from the exposed tables.
- Proposed change: a `my_wallet_transactions(p_source text, p_cursor timestamptz, p_limit int)` RPC returning rows `(id, kind, status, amount_minor, currency, reference_id, description_key, created_at)` sourced from the ledger with client-safe projection, plus a `pending_balance(p_source, p_currency)` scalar (or a pending column in `my_balances`).
- Backwards compatible? yes (new functions).
- Status: OPEN

## CR-20260923-04 — promo redemption outside a job
- Requested by: Kimi Code
- Milestone/screen: M9.4 — promos screen (`PromoRepository.redeemPromo`)
- Current contract (v1): `preview_promo(p_code, p_request_id)` validates a code against a job; `start_payment` takes `p_promo_code`. There is no job-independent redeem/claim RPC.
- Problem / missing capability: the promos screen lets users redeem a code to their account before any job exists (enter-code flow). The contract only supports applying a code at payment time. Also: the `promo_codes` table select exposes code/discount/ends_at but no title/description keys, so a promo listing can't render localized copy.
- Proposed change: a `redeem_promo(p_idempotency_key, p_code)` RPC (account-level voucher wallet), or confirm that promo entry happens only at checkout and drop the standalone redeem screen. If listings are wanted: add `title_key`/`description_key` to `promo_codes` and its grants.
- Backwards compatible? yes (new function / new nullable columns).
- Status: OPEN

## CR-20260923-05 — provider home summary + provider tools
- Requested by: Kimi Code
- Milestone/screen: M9.5 — provider home (`ProviderRepository.getHomeSummary`) and provider tools (`ProviderToolsRepository`)
- Current contract (v1): `provider_profiles` carries `online`/rating/completion stats; `provider_feed` covers open requests. There is no RPC for today's earnings, jobs completed today, or document-expiry warnings — and no tables/RPCs at all for availability windows, earnings goals, demand heatmap, provider insights, or instant payout quotes.
- Problem / missing capability: the provider home screen renders `todayEarnings`, `completedToday` and `documentWarnings`; the tools screen renders availability slots, an earnings goal with server-computed progress, a demand heatmap, insights, and instant payout (a paid feature with server-computed fees). Today `getHomeSummary` reports zeros/empty lists for the missing fields and `ProviderToolsRepository` stays on the mock.
- Proposed change: a `provider_home_summary()` RPC returning `(online, verification_status, today_earnings_minor, currency, completed_today, nearby_open_requests, document_warnings jsonb)`; plus the provider-tools surface (availability slots table + RPCs, earnings goal, heatmap/insights RPCs, instant payout quote/request). The tools items may be separate migrations — flagged here as one tracked gap.
- Backwards compatible? yes (new functions/tables).
- Status: OPEN

## CR-20260923-06 — trusted-contact phone: client encryption story + masked display
- Requested by: Kimi Code
- Milestone/screen: M9.7 — trusted contacts (`SettingsRepository.addTrustedContact` / `getTrustedContacts`)
- Current contract (v1): `add_trusted_contact(p_idempotency_key, p_name, p_phone_ciphertext bytea, p_phone_blind_index bytea, p_relationship_key)` expects the client to encrypt the phone number and compute the blind index; `trusted_contacts` SELECT returns only `phone_ciphertext`/`phone_blind_index`, never plaintext.
- Problem / missing capability: there is no client-side key-management story (no key delivery, no algorithm spec), so the app cannot produce valid ciphertext — and sending plaintext as "ciphertext" would silently weaken the security model. Reads are also broken UX-wise: the list can show names but never the (even masked) phone number. Today `addTrustedContact` throws ERR_FEATURE_UNAVAILABLE and `phoneE164` maps to ''.
- Proposed change: a server-side `add_trusted_contact_plaintext(p_idempotency_key, p_name, p_phone_e164 text, p_relationship_key)` that encrypts inside the database (consistent with how other PII is handled), plus a `phone_masked text` display column (e.g. `+234••••••1234`) on the SELECT grant.
- Backwards compatible? yes (new function; new nullable column).
- Status: OPEN

## CR-20260923-07 — account deletion + data export RPCs
- Requested by: Kimi Code
- Milestone/screen: M9.7 — settings (`SettingsRepository.requestAccountDeletion` / `requestDataExport`)
- Current contract (v1): no RPCs exist for self-serve account deletion or GDPR-style data export.
- Problem / missing capability: store-readiness requires in-app account deletion with a grace period (signing back in cancels), and the data-export screen needs an opaque export reference. Both currently throw ERR_FEATURE_UNAVAILABLE.
- Proposed change: `request_account_deletion(p_idempotency_key) → timestamptz` (scheduled deletion date; sign-in before it cancels) and `request_data_export(p_idempotency_key) → text` (export reference / ticket id).
- Backwards compatible? yes (new functions).
- Status: OPEN

## CR-20260923-08 — KYC PII: plaintext variants that encrypt server-side
- Requested by: Kimi Code
- Milestone/screen: M9.8 — provider KYC (`submitStep` for governmentId / policeClearance / payoutAccount) and customer `submitIdLookup`
- Current contract (v1): `submit_identity_document`, `submit_police_clearance`, `add_payout_account` and `register_vehicle` all require client-produced `*_ciphertext bytea` + `*_blind_index bytea`.
- Problem / missing capability: same unsolved client-encryption problem as CR-20260923-06 (no key delivery or algorithm spec). These four steps throw ERR_FEATURE_UNAVAILABLE rather than send plaintext as "ciphertext". `add_payout_account` additionally takes `p_holder_name`, which the client must not invent — the verified holder name lives server-side.
- Proposed change: plaintext variants (e.g. `p_id_number text`, `p_certificate_number text`, `p_account_number text`) that encrypt inside the database, with holder name resolved server-side for payout accounts. One shared approach with CR-20260923-06 would keep the surface small.
- Backwards compatible? yes (new optional parameters or new functions).
- Status: OPEN

## CR-20260923-09 — liveness result submission + server-side verdict
- Requested by: Kimi Code
- Milestone/screen: M9.8 — customer + provider facial verification (`submitIdLookup`, `submitStep(providerFacial)`)
- Current contract (v1): `start_verification_session(p_kind)` creates the session, and the wire defines `identity_check_outcome`, but no client-callable RPC accepts the liveness capture result or advances a facial step to a verdict.
- Problem / missing capability: after the liveness SDK captures, there is no way to submit the evidence; the step can never leave `in_progress`. The client must never decide or report an authoritative verification outcome, so we cannot fake the transition client-side.
- Proposed change: a `submit_liveness_result(p_idempotency_key, p_kind, p_session_id, p_evidence_ref text)` RPC (evidence = Dojah/vendor reference or storage ref) that makes the verdict server-side and transitions the step; reading the outcome via `get_my_kyc_profile`.
- Backwards compatible? yes (new function).
- Status: OPEN

## CR-20260923-10 — KYC profile completeness (payloads, submit-for-review, rollup)
- Requested by: Kimi Code
- Milestone/screen: M9.8 — provider KYC screens (`ProviderKycRepository`)
- Current contract (v1): `submit_kyc_step` accepts only `p_upload_refs`; `get_my_kyc_profile` returns per-step kind/status/attempt_count/expires_at/required; there is no submit-for-review RPC and no payout name-enquiry RPC.
- Problem / missing capability: (a) structured payloads for `address` (line1/line2/city/state/landmark), `guarantor` (name/phone/relationship) and `credentials.description` have nowhere to go — those steps throw ERR_FEATURE_UNAVAILABLE; (b) `submitForReview` cannot exist client-side (the client must not self-declare the profile in-review) — throws ERR_FEATURE_UNAVAILABLE; (c) `resolvePayoutAccount` needs a server-computed name match — throws ERR_FEATURE_UNAVAILABLE; (d) the profile lacks `overall_status`, `submitted_for_review_at`, per-step `submitted_at`/`reviewed_at`, a readable session id and `updated_at` — the UI falls back to a display-only client rollup and epoch timestamps; (e) `provider_profiles` has no `business_name` column and `kind` is not updatable; (f) `update_provider_services`/`update_provider_service_areas` take no idempotency key; (g) no realtime topic or streamable view for KYC step changes (watch* polls).
- Proposed change: `p_payload jsonb` on `submit_kyc_step` (schema per kind); `submit_kyc_for_review(p_idempotency_key)`; a payout name-enquiry RPC returning `(masked_account, resolved_name, name_match)`; extend `get_my_kyc_profile` with `overall_status`, `submitted_for_review_at`, per-step `submitted_at`/`reviewed_at`; nullable `business_name` on `provider_profiles` + UPDATE grant (or an onboarding RPC); idempotency keys on the two update RPCs; optionally a `user:{id}:kyc` realtime topic.
- Backwards compatible? yes (added columns/parameters/new functions).
- Status: OPEN
