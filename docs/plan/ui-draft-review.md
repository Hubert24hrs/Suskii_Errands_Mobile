# Review of `contracts/draft/ui-data-requirements.md`

| | |
|---|---|
| Reviewer | Claude Code |
| Rolling document | Updated as Kimi appends each milestone |
| Covered so far | M1 (app shell, mode switch), M2 (verification + KYC) |
| Rule | Kimi's draft is **input, not authority**. Where it conflicts with `master_spec` on money, security or the state machine, the spec wins and the UI changes |

Items marked **[CHANGE]** go to Kimi in `HANDOFF.md`. Items marked **[CONTRACT]** are captured for contracts v1. Items marked **[GOOD]** are recorded so a later refactor does not undo them.

## Overall

The draft is in good shape for the stage. It already treats the server as the source of truth in the places that matter most: `Money` breakdowns come from the server, status changes are requested actions, KYC outcomes are enums with reason keys rather than booleans the client interprets, and file uploads are opaque refs against an upload-only bucket. Those are exactly the properties that are expensive to retrofit.

No client-side business logic was found in M1 or M2 that must move server-side. That is unusual this early and worth saying.

## M1 — app shell, mode switch, navigation

| # | Finding | Type |
|---|---|---|
| 1.1 | `Money` breakdown object (gross, commission, gateway fee estimated/actual, tip, net payout) demanded from the server, never derived in the UI | **[GOOD]** matches ADR-0003 and S-14 |
| 1.2 | Offer TTL and round limits taken from config per category, not hardcoded | **[GOOD]** matches the negotiation state machine |
| 1.3 | Stable error codes with localisable message keys | **[GOOD]** → contracts `error-codes` |
| 1.4 | `getBootstrap()` returns session, country pack, feature flags, unread counts and the active-job banner in **one call** | **[GOOD]** and important: at ~150 ms RTT to Europe (S-01), one round trip per screen is the design constraint. Keep it |
| 1.5 | `setActiveMode` can fail with `ERR_PROVIDER_BUSY_AS_CUSTOMER` | **[CONTRACT]** the spec makes this configurable per country; the UI must treat it as a server decision, which it does |
| 1.6 | Provider home shows "today earnings summary (Money, from server)" | **[GOOD]** |
| 1.7 | Country pack is delivered to clients as a "subset safe for clients" | **[CONTRACT]** contracts v1 must define that subset explicitly — internal fields (vendor routing, thresholds, reviewer notes) never leave the server |
| 1.8 | Realtime events named informally (`job.status_changed`, `offer.created`, `notification.created`) | **[CONTRACT]** these become the authoritative names; channel authorisation is per-job and per-user private channels (S-13), not client-side filtering |
| 1.9 | Active-job banner "shows across modes" | **[GOOD]** matches the spec's mode-switch rule |

**Gap for M3+ (not a fault of M1):** the bootstrap payload will need a `server_time` field. Every countdown in the UI — offer TTL, payment TTL, auto-confirm — must be rendered against server time with a measured client offset, or a device with a wrong clock shows the wrong deadline. **[CHANGE]**

## M2 — verification and KYC

| # | Finding | Type |
|---|---|---|
| 2.1 | Consent is explicit and separate for biometric processing vs criminal-record checks, with timestamp and version stored server-side | **[GOOD]** this is a DPIA requirement (compliance checklist D2), not just a nicety |
| 2.2 | KYC files upload-only via signed URLs; clients hold opaque `uploadRef`s and never read back | **[GOOD]** matches the spec's `kyc-docs` bucket rule exactly |
| 2.3 | Rejection reasons are localisation keys, never free text | **[GOOD]** and it aligns with the spec's "no free-text criminal-history notes" rule |
| 2.4 | Required-step set is server/config decided (vehicle docs only for motorised, address for TRUSTED+) | **[GOOD]** |
| 2.5 | `resolvePayoutAccount` returns a server-computed `nameMatch` | **[GOOD]** the client must never decide a name match |
| 2.6 | Identity adapter is vendor-neutral (`startLivenessSession`, `captureLiveness`, `matchGovernmentId`) | **[GOOD]** matches ADR-0005; the Smile ID SDK version is still pending spike S-05 |
| 2.7 | New error codes proposed: `ERR_FEATURE_UNAVAILABLE`, `ERR_CONSENT_REQUIRED`, `ERR_VERIFICATION_REJECTED`, `ERR_KYC_STEP_INVALID`, `ERR_KYC_INCOMPLETE` | **[CONTRACT]** accepted into the v1 error catalogue |
| 2.8 | Social sign-in throws `ERR_FEATURE_UNAVAILABLE` pending backend config | **[CONTRACT]** Apple guideline 4.8 requires an equivalent privacy-preserving login wherever Google sign-in is offered, so Sign in with Apple ships in the same release as Google — they cannot be staged separately on iOS |
| 2.9 | Verification session has an expiry | **[CONTRACT]** contracts v1 defines the TTL and whether a fresh consent is needed after expiry |

### Changes needed for M2

| # | Change | Why |
|---|---|---|
| 2.A | **The ongoing selfie check needs a UI state now, not later.** The draft covers onboarding verification but not the recurring check before going online (spec `ongoing_checks`; cost driver OD-13). Provider "go online" must handle `ERR_SELFIE_CHECK_REQUIRED` — which the M1 draft already lists — by launching a liveness session, not just showing an error | **[CHANGE]** |
| 2.B | **Police clearance needs expiry-aware states.** Per country-pack research, a Nigerian certificate is valid ~3 months and costs ₦30,000 (OD-09). The provider UI needs "expiring in N days" and "expired — job acceptance blocked" states, driven by server-supplied dates, plus the document-expiry centre from the spec's provider screens | **[CHANGE]** |
| 2.C | **Consent version must be surfaced.** When legal text changes, a user must re-consent. The UI needs a "consent out of date" path, not only first-time consent | **[CHANGE]** |

## Naming alignment with the domain package (checked 2026-09-16)

Checked Kimi's `suskii_domain` enums and entities against the ERD so names do not drift.

| # | Finding | Type |
|---|---|---|
| N.1 | `JobStatus` has exactly the spec's 20 states, and `isTerminal` matches the lifecycle's terminal set | **[GOOD]** |
| N.2 | `PaymentStatus.partiallyRefunded` resolves the job-lifecycle open question: partial refunds live on the payment, not a new job state | **[GOOD]** — adopted |
| N.3 | `OfferStatus` uses `pending`/`declined`; the first state-machine draft said `ACTIVE`/`REJECTED`. **Backend adopts Kimi's names** | **[GOOD]** — no change for Kimi |
| N.4 | `PriceBreakdown.commissionRateBps` stores the rate as integer basis points. **Backend adopts this** (`*_bps integer` in the ERD) — better than a numeric rate | **[GOOD]** — adopted |
| N.5 | `Urgency` has four levels (`flexible`/`standard`/`urgent`/`emergency`); the country-pack drafts assumed three multipliers. Country packs get a fourth | **[CONTRACT]** — backend change |
| N.6 | **Enum wire format.** Dart enums are camelCase (`offersReceived`); Postgres and Supabase-generated types use snake_case (`offers_received`). Recommend snake_case on the wire, with `@JsonValue` mappings in Dart — cheaper now than after M3 adds more enums | **[CHANGE]** |

## Cross-cutting, carried forward

Recorded now so they are not rediscovered at M8.5:

1. **`server_time` in bootstrap** and an offset applied to every countdown. **[CHANGE]**
2. **Idempotency keys are per user action**, generated fresh per attempt — never per screen or per session. S-10 showed a reused key correctly replays, which in a UI would look like a tap that silently did nothing. **[CHANGE]**
3. **Currency exponent, never `/100`.** Kimi's `Money` already carries an exponent table with UGX = 0; a golden test should lock that so a later refactor cannot reintroduce a hardcoded divisor. **[CHANGE]**
4. **"Held by Suskii", never "escrow"** in any locale file (ADR-0002, a legal constraint per country). **[CHANGE]**
5. **Trusted contacts must use the Android Contact Picker**, not `READ_CONTACTS` (Play policy, April 2026). **[CHANGE]**
6. Realtime channels are private and per job/per user; a provider must never receive a rival's offer amount even in a payload the UI chooses not to render. **[CONTRACT]**
7. **Enum wire values are `snake_case`** with `@JsonValue` mappings on the Dart enums (N.6). **[CHANGE]**

## Still to review

M3 onwards: request creation, offers and negotiation, payments, tracking, chat, calls, SOS, completion and ratings, wallet, earnings, withdrawals, referrals, promos, disputes, support, settings, provider tools, business console, the three web apps and admin. Each milestone gets a section here, and the resulting change list goes to `HANDOFF.md` as it is found — not saved up for M8.5.
