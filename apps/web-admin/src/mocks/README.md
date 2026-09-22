# Web Admin mock layer (M8)

Mock data layer for the internal admin console, mirroring the conventions of
`apps/web-customer/src/mocks`. The console displays and requests — the
(server-style) mock decides. Replaced by Supabase-backed implementations at
M9 behind the same signatures.

## Layout

```
mocks/
  types.ts          Admin-scope entities (Money is integer minor units + ISO 4217)
  errors.ts         Core error codes + admin codes (session, reauth, approvals)
  behavior.ts       Latency/offline/failure knobs, idempotency store, emitters
  fixtures.ts       Seeded in-memory "database" (see below)
  db.ts             Compatibility shim (re-exports fixtures/behavior)
  repositories.ts   Barrel: classes + singletons + PERMISSIONS
  repos/
    base.ts         MockRepo: gate, idempotency, session check, permission
                    matrix, reauth window, audit helper
    session.ts      Session (sign-in/MFA/reauth/signOut/switchPersona) + metrics
    directory.ts    Users/providers/businesses/workers/vehicles + suspend
    verification.ts Queues, claim/approve/reject, 60s document-view grants
    jobs.ts         Job search, timeline, live-map watch
    payments.ts     Holds/settlements/payouts/withdrawals + approval flows
    growth.ts       Referrals (flags, campaigns) + promos
    trust.ts        Disputes, support tickets, SOS console, risk cases
    config.ts       Config w/ approval flow, analytics, audit log, AI assistant
    adminUsers.ts   Staff management (super_admin only)
src/lib/
  money.ts          Integer-minor-unit money helpers (copy of web-customer)
  idempotency.ts    UUIDv7 idempotency keys
  serverClock.ts    Simulated server clock (TTLs never use device time)
```

## Security model (spec rules, enforced in the mock)

- **Role × action matrix** (`PERMISSIONS` in `repos/base.ts`) — every repo
  method calls `requirePermission(action)`; hidden buttons are not security.
  Violations throw `ERR_PERMISSION_DENIED`.
- **Sessions** slide-expire after 30 min and are checked on every call
  (`ERR_SESSION_EXPIRED`). Sign-in is email + any password → MFA step (any
  6-digit code; `mockBehavior.failNextMfa` demos failure).
- **Sensitive actions** — document views, payment approvals, dispute
  resolutions, config propose/approve, admin-user changes — additionally
  require `sessionRepository.reauth(purpose)` within the last 5 minutes,
  else `ERR_REAUTH_REQUIRED`.
- **Two-person rules** — withdrawals at/above
  `mockBehavior.twoPersonApprovalThresholds` (per currency, minor units) are
  refused by `approveWithdrawal` with `ERR_APPROVAL_REQUIRED`; the UI then
  uses `requestApproval` → `confirmApproval` by a *different* admin (same
  admin → `ERR_INVALID_STATE`); config changes use `proposeChange` →
  `approveChange` by a different admin.
- **Audit log** — append-only; every mutation (and session event) writes an
  entry via `db.appendAudit`. Readable by super_admin only, filterable, and
  watchable live.

## Personas & fixtures

- Staff: `admin-amina` (super_admin, default), `admin-femi` (verification),
  `admin-kojo` (support), `admin-zainab` (finance), `admin-sola` (disputes,
  MFA not yet enrolled — demo for `enforceMfa`). `switchPersona(id)` jumps
  between them without the password dance (audit-logged demo hook).
- Metrics for NG / KE / GH. Directory: users `mu-1..8` (mu-4 suspended,
  mu-7 flagged), providers `mp-1..6` (mp-4 suspended), businesses `mb-1..3`,
  workers `mw-1..3`, vehicles `mv-1..4`.
- Verification: `vq-1..7` covering all five kinds and all four statuses.
- Jobs `job-1..8` across the state machine with timelines + route points
  (job-1 in_progress with live position; job-5 disputed; job-7
  payment_pending).
- Payments: holds `pay-hold-1/2`, settlement `pay-set-1`, payouts
  `pay-pay-1/2`, withdrawals `pay-wd-1` (awaiting second approval — first by
  admin-zainab), `pay-wd-2` (single_pending, below threshold — directly
  approvable), `pay-wd-3` (approved), `pay-wd-4` (single_pending, ₦45,000 —
  above the NGN two-person threshold, so `approveWithdrawal` throws
  `ERR_APPROVAL_REQUIRED`).
- Referrals `ra-1..4` with flags `rf-1` (device_cluster), `rf-2`
  (self_referral_suspected); campaigns `rc-1` active / `rc-2` paused
  (`pauseCampaign` ⇄ `resumeCampaign`, both audit-logged).
- Promos `promo-1` WELCOME10 active, `promo-2` FESTIVE20 expired, `promo-3`
  RIDEGH15 draft.
- Disputes `disp-1` (in_review, 3 evidence refs, held ₦25,000), `disp-2`
  (open). Resolution quotes are server-computed in the repo.
- Tickets `st-1..3`. SOS: `sos-1` active with a ticking location trail
  (watch via `sosRepository.watchAlerts`), `sos-2` acknowledged.
- Risk cases `rk-1..3`. Feature flags ×5, country packs NG/KE/GH,
  commissions NG 1250 / KE 1200 / GH 1300 bps; `cc-1` is a pending GH
  commission change (1100 bps) for the approval flow.
- Analytics: 30-day series ×5 metrics ×3 countries (deterministic).
- Audit log seeded with 5 historical entries.

## Semantic notes

- **Document viewing**: `requestDocumentView(itemId)` returns a 60s
  `viewToken` + opaque URL, role-gated (verification_officer/super_admin),
  reauth-gated, audit-logged. `validateDocumentView` enforces the TTL —
  expired tokens throw `ERR_SESSION_EXPIRED` and are destroyed.
- **Dispute resolution**: `getResolutionQuote(id, action, pct?)` returns
  exact Money amounts (integer, half-even rounding); `resolveDispute`
  applies them — refund actions move the job to `refunded`, release/reject
  to `confirmed`. The client never computes amounts.
- **AI Admin Assistant**: read-only. `sendMessage` streams its reply via an
  optional `onChunk` callback and returns `proposedActions` cards that link
  to modules. The only writes are the chat transcript.
- **Idempotency**: all mutating methods take `idempotencyKey`; same key +
  same args replays the stored result, same key + different args throws
  `ERR_IDEMPOTENCY_KEY_REUSED`. Use `newIdempotencyKey()` per user intent.
- **Money**: always `{ amountMinor, currency }` integer minor units.
  Payment/resolution amounts arrive as server quote objects.
