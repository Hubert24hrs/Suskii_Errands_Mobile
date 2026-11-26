# ADR-0028 — Play Billing: verify on the server, listen to RTDN, claw back voids

| | |
|---|---|
| Status | Proposed |
| Date | 2026-11-26 |
| Deciders | Owner (decision 4 of 2026-11-25: build Google Play Billing now, behind a flag); Claude Code |
| Unblocked by | Spike S-15 (license testers, end to end); the owner fixing the Play payments profile and creating the products; OD-44 and OD-51; M2-PR1 accepts it |
| Related | [ADR-0026](0026-meet-v5-social-layer.md) D19, D23; [ADR-0027](0027-cowries-sealed-spend-only-economy.md); OD-29, OD-43, OD-51; design §5.4; `contracts/v1/state-machines/meet_play_purchase.json` |

## Context

Owner decision 4 (2026-11-25): Cowrie packs are Play consumables, VIP is a Play subscription, every
purchase is verified on the server before anything is credited, and refunds and voided purchases
are caught through Real-time Developer Notifications (RTDN) and clawed back. Everything
purchase-related sits behind a server flag that stays off until the owner has fixed the Play
payments profile and created the products.

Constraints:

- **"No funds lost"** (spec §6): a paid token must always end up granted or refunded, even when the
  app dies between paying and telling the server.
- **The client cannot be trusted.** Price strings, purchase state and product ids it reports are
  claims; only the Play Developer API is evidence.
- **The account.** The app is on a personal developer account whose payments profile has carried an
  alert since 30 Oct (design §10.1 risk 3). Google rejected the first submission because a personal
  account declared a financial feature (OD-29, RB-15).
- **The database is the Free plan with no daily backups** (OD-33). Balances and purchase tokens are
  money-equivalent records, so the plan upgrade and working backups are readiness items (OD-53).
- **Testers' sandbox doubles as production**, so test purchases happen on the production database.

The exact androidpublisher v3 paths and responses are taken from the research map `[S]` and are
VERIFY-IN-RESEARCH until S-15 runs them with license testers.

## Decision

We will verify every purchase on the server, consume or acknowledge it from the server, and treat
RTDN plus an hourly voided-purchases sweep as the source of refunds and clawbacks.

**Client.** `in_app_purchase` 3.3.1, pinned exactly (it resolves Play Billing Library 9.1.0 `[S]`).
Packs are bought with `autoConsume: false`, so the client never consumes before the server grants.
Each purchase carries `applicationUserName` = a 32-hex `billing_account_ref` minted by the server,
never an email, phone or uid. Prices are shown only from `ProductDetails.price`; no naira figure is
hard-coded. A coordinator listens to the purchase stream from app start and calls
`restorePurchases()` at start and on every resume. The Android app never links or steers to any
other way to pay; iOS shows no purchase UI.

**Verification** (`meet-purchase-verify`, the one new app-callable Edge Function in M2):

1. `gateway_meet_purchase_begin` binds the token to the caller once. A second account presenting it
   gets `{state:'rejected', reason:'token_claimed'}`, returned rather than raised (ADR-0026 D24), the
   attempt recorded and a fraud flag raised.
2. The function reads the purchase from the Play Developer API (productsv2 for packs,
   subscriptionsv2 for VIP `[S]`).
3. `gateway_meet_purchase_verified` checks, in one transaction with the grant: the package is one of
   `PLAY_PACKAGE_NAMES`; the product is the bound one and an active pack or `meet_vip`; the state is
   PURCHASED (PENDING grants nothing; CANCELLED rejects); `obfuscatedExternalAccountId` equals the
   caller's `billing_account_ref` (absent: bound by first claim and flagged); no fraud hold. Then it
   grants `units × quantity` to `purchased`.
4. The server consumes (packs) or acknowledges (VIP). A failure leaves the purchase `granted` and the
   worker retries with backoff well inside Play's 3-day auto-refund window `[S]`.
5. A rejected token that was paid for is refunded and revoked by the worker, so nobody pays for
   nothing.

**Starting a purchase is gated; verifying one never is.** `meet.purchases` and `meet.vip` control
the store UI only, and cannot be switched on until the M2 readiness checklist is complete
(ADR-0026 D23). A paid token always verifies. `meet.purchases_verify_paused` queues tokens for up to
48 h as a break-glass switch.

**RTDN.** Google Play publishes to a Pub/Sub topic in `suskii-prod` that pushes to `play-rtdn`
with an OIDC token, which the function verifies (issuer, audience, service-account email, verified
email) before storing anything. Raw messages reuse `public.webhook_events` through
`private.ingest_webhook('google_play', …)`, whose partitions, health checks and cross-partition
de-duplication already exist. The notification body is never trusted for state: every type re-reads
the API. A PURCHASED notification for a token the app never submitted resolves its owner by
`obfuscatedExternalAccountId`, which is the "no funds lost" path. The hourly `voidedpurchases` sweep
is the backstop for missed notifications; Play keeps 30 days of voided history `[S]`.

**Clawback.** A void debits `units per item × voided quantity` from `purchased` (pack bonus units
included), which may go negative. A negative wallet refuses every spend but **allows purchases**, so
the person can repay, and the restriction clears itself at zero. Voids for fraud, friendly fraud or
chargeback also hold new purchases for 90 days, reverse the popularity the person's gifts conferred
since the voided purchase, and raise a fraud flag; two voids in 90 days set a fraud hold that only a
person lifts (OD-25). Remorse voids reverse nothing for receivers, who received status only.

**Subscriptions.** Entitlement is `expiry_time > now()` with an active, grace-period or
cancelled-not-yet-expired state; a token whose `linkedPurchaseToken` names an older one supersedes
it, so nobody holds two entitlements. Deleting an account cancels an active VIP at Play
(VERIFY-IN-RESEARCH, S-15) and pseudonymises the purchase rows, which are kept for accounting.

**Test purchases** are accepted, stored with `is_test`, and mark the wallet `test_funds`. They are
excluded from revenue analytics, the card spend path and VIP-day accrual.

**Financial features.** Decision 4 supersedes OD-29 for in-app digital goods only: the app keeps
declaring that it provides no financial features, because Cowries are Play-billed, used only in the
app, and cannot be withdrawn, transferred or exchanged. Whether Google treats in-app virtual currency
as a financial feature is VERIFY-IN-RESEARCH (no exemption page found) and is re-checked at M2
submission. Any cash-out would be a financial feature and is not built (ADR-0027).

**Secrets.** `PLAY_BILLING_SERVICE_ACCOUNT_JSON` (a dedicated `play-billing@` service account with
app-level "View financial data" and "Manage orders and subscriptions" only; `play-publisher@` is not
widened), `PLAY_PACKAGE_NAMES`, `PLAY_RTDN_AUDIENCE`, `PLAY_RTDN_PUSH_SA`. None is ever committed.

## Consequences

**Good:**

- A token is granted at most once (it is a true UNIQUE; the purchase table is not partitioned) and
  never before Play says PURCHASED for the right package, product and account.
- Refunds cannot be farmed: every void claws back, and fraud voids also undo what the Cowries bought
  in status.
- RTDN reuses the webhook pipeline the payment gateways already proved: store raw, de-duplicate,
  re-read, act.

**Bad / costs:**

- Revenue lands on the personal payments profile until OD-29 is settled; orders made before an
  account transfer stay on the old account and financial reports do not transfer (OD-51, monthly
  report downloads in RB-18).
- Negative balances are a support burden: a refunded buyer finds Meet's paid actions locked until
  they repay.
- Terraform for Pub/Sub, a new service account and three Play Console settings are owner actions
  before anything can be tested.

**Follow-on work:** `meet_econ.play_purchases`, `play_subscriptions`, `billing_state` and the
`gateway_meet_*` functions (M2-PR5); `meet-purchase-verify`, `play-rtdn`, `meet-billing-worker`
(M2-PR6); Pub/Sub Terraform (M2-PR7); RB-18 (license tests, RTDN, clawback, refunds, monthly
reconciliation); health checks `meet_billing_unacknowledged` and `meet_billing_rtdn_backlog`.

## Alternatives considered

| Option | Why not |
|---|---|
| Trust the client's purchase result and `autoConsume: true` | The client would consume before the server grants, and a forged result would mint Cowries |
| Reject test purchases (`accept_test_purchases: false`) | Testers buy on the production database (decision 5); flagging `is_test` and excluding it from revenue keeps them usable without polluting the books |
| A new raw-event table for RTDN | `webhook_events` already has partitions, `partition_health` coverage and cross-partition de-duplication; the gateway CHECK only needs `google_play` |
| Rely on RTDN alone | Push delivery can be missed; the voided-purchases sweep is the backstop Play documents for that `[S]` |
| Wait for an organisation account before building | The owner chose to build now behind a flag (decision 4); the flag and the readiness guard keep anything from selling early |

## Revisit when

- S-15 reports: the API paths, whether `completePurchase` after a server consume is a no-op, whether
  the plugin redelivers after a server consume, and the subscription cancel endpoint.
- The app moves to an organisation account or Meet to its own package (OD-29, OD-43).
- Google publishes guidance on in-app virtual currency and the financial-features declaration.
- An iOS release wants purchases (StoreKit plan, M3-PR8).
