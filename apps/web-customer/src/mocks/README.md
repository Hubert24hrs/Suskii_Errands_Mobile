# Mock data layer (web customer, M7)

The web customer's mock repositories, mirroring the repository interfaces and
entities defined in `packages/suskii_domain` and the Dart mock layer in
`packages/suskii_data`. The client displays and requests — the server decides.
All authoritative values (prices, fees, payouts, statuses, verification
results) come from server-style objects even in mocks. This layer stays the
**default** at runtime; from W9.1, screens import repositories from
`@/lib/repositories` (the seam), which swaps individual surfaces to the
Supabase-backed implementations in `src/lib/supabase/` when
`NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` are set, behind
the same signatures. Wired so far: auth + user profile.

## Layout

| File | Contents |
|---|---|
| `types.ts` | Entities + string-literal union enums (snake_case wire values). `Money = { amountMinor: number; currency: string }` — integer minor units, never floats. |
| `errors.ts` | `AppError` + `ErrorCodes` (the mobile codes plus the marketplace/chat codes from the state-machine docs). |
| `behavior.ts` | `mockBehavior` switches (latency, offline, failNextCalls, failNextPayment, failLiveness, delays, per-currency withdrawal approval thresholds), the `gate()`, `Emitter`, `IdempotencyStore`, and `simulateQuote` / `roundHalfEven` — the only place money math happens. |
| `fixtures.ts` | `MockDatabase` seed + event channels; `db` shared instance, `createMockDatabase()` for isolated tests/resets. |
| `repos/*.ts` | Repository implementations (see below). |
| `repositories.ts` | Barrel: classes + ready-made singletons over `db`/`mockBehavior`. |
| `../lib/money.ts` | Exponent table (UGX/XOF/… = 0), `formatMoney`, `parseMajorUnits` (string math only). |
| `../lib/idempotency.ts` | `newIdempotencyKey()` — UUIDv7 from `crypto.getRandomValues`. |
| `../lib/serverClock.ts` | `syncServerClock` / `serverNow` — all TTLs evaluate against the server clock, never raw device time. |

## Conventions

- **Idempotency**: every mutating call takes an `idempotencyKey`. Same key +
  same args replays the stored result; same key + different args throws
  `ERR_IDEMPOTENCY_KEY_REUSED`. One key per user intent.
- **Watching**: `watch*(…, onChange)` emits the current value immediately,
  then on every change, and returns an unsubscribe function. All timers are
  per-subscription and are cancelled on unsubscribe.
- **Errors**: thrown as `AppError` with a stable `code`; the UI maps code →
  localization key, never raw text.
- **Demo switches**: mutate `mockBehavior` (e.g. `mockBehavior.offline = true`,
  `mockBehavior.failNextPayment = true`) to exercise error/offline states.
  `authRepository.switchPersona('user-chidi')` flips to the unverified persona.

## Personas and fixture ids

- `user-ada` — verified customer, Lagos (NG, NGN), referral code `ADA-7K2`,
  wallet balance, 4 transactions, trusted contact `tc-1`.
- `user-chidi` — unverified customer (NG, Pidgin) for the
  `ERR_VERIFICATION_REQUIRED` flows.
- Requests: `req-1` negotiating with offers `offer-1a` (pending), `offer-1b`
  (countered, round 2), `offer-1c` (expired) · `req-2` in_progress (PIN 4281,
  chat `msg-1..3`, tracking) · `req-3` disputed (dispute `disp-1` in review) ·
  `req-4` confirmed (rateable, chat open <24h) · `req-5` draft (custom) ·
  `req-6` payment_pending (TTL ticking) · `req-7` agreed (ready to pay) ·
  `req-8` paid_held (chat just opened). Payments `pay-2/3/4/8` are held.
- Promos `WELCOME10` (active) / `FESTIVE20` (expired) — redeeming either an
  unknown, expired or redeemed code yields the single `ERR_PROMO_INVALID`.
- Support ticket `ticket-1` with an AI-triage reply; new tickets get an AI
  triage reply after `supportTriageDelayMs`.
- Country packs NG (live) / KE / GH / ZA / UG (beta) / US (disabled →
  `ERR_COUNTRY_NOT_SUPPORTED`). Voice languages: `{ en: true, pcm: false }`.

## Semantic notes

- **Offers**: the counterparty acts. The customer accepts/declines/counters a
  provider's `pending` offer; acting on your own counter (`countered`) throws
  `ERR_OFFER_NOT_YOUR_TURN`; accepting when a sibling already won throws
  `ERR_OFFER_NOT_ACTIVE`; TTL expiry throws `ERR_OFFER_EXPIRED`. Rounds and
  TTL come from the category. The mock provider answers counters after
  `providerResponseDelayMs`: accepts ≥90% of its ask, counters at the
  midpoint while rounds remain, otherwise declines. Accepting (either side)
  expires all siblings and sets the customer-only handover PIN (`4281`).
- **Payments**: `initializePayment` is verification-gated, 15-minute TTL,
  simulated webhook → `held` (job → `paid_held`) or `failed` (job → `agreed`
  for retry). A pending payment past its TTL fails with `paymentTtlExpired`.
- **Completion**: `jobProgressRepository.confirmCompletion(jobId, key)` is
  customer-only and only legal from `completed_by_provider` (ERR_INVALID_STATE
  otherwise), idempotent by key. It records `jobConfirmedAt` (drives the chat
  window) and — mirroring the Dart mock — releases no funds; settlement is a
  separate server-side step.
- **Chat**: opens at `paid_held`, closes 24h after confirmation unless a
  dispute is open → `ERR_CHAT_CLOSED`. Per-type payload validation; `system`
  messages are server-authored. `markMessagesRead` writes read receipts.
- **Concierge**: never publishes/accepts/pays and never fills money fields —
  a spoken price is acknowledged but the exact amount is set by the user on
  the publish card. Proposed actions: `none`, `show_publish_card`,
  `show_offer_comparison`, `show_sos_card`, `handoff_to_form` (custom
  categories). Drafts sync to a real draft `JobRequest` from the first slot.
- **Disputes**: one per job (re-opening returns the existing); mock ops
  resolves after `disputeResolveDelayMs` with a 50% partial refund → job
  `refunded`, payment `partially_refunded`.
