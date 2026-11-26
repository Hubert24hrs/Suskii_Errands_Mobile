# ADR-0027 — Cowries: a sealed, spend-only economy

| | |
|---|---|
| Status | Proposed |
| Date | 2026-11-26 |
| Deciders | Owner (decisions 2 and 5 of 2026-11-25); Claude Code; counsel for the Cowrie terms |
| Unblocked by | M2-PR1 (accepts this ADR with `docs/plan/meet-cowrie-flows.md`); counsel on OD-44; the owner on OD-45 and OD-46 |
| Related | [ADR-0026](0026-meet-v5-social-layer.md) D7, D8, D9, D17, D18, D19, D22; [ADR-0028](0028-play-billing-verification-rtdn-clawback.md); design §5 |

## Context

Spec v5 §4–§7 asks for a prepaid balance spent in tiny amounts (5, 10, 20 Cowries) with no payment
prompt, and its §5 originally let gift receivers convert "Earnings" to cash at 60/40. Two owner
decisions of 2026-11-25 change that:

- **Decision 2: gifts give status, not cash.** Cowries are spend-only and never withdrawable. There
  is no Earnings balance and no cash-out in this build. Gifts must never be framed as payment for
  attention, company or meetings.
- **Decision 5: Cowries must not touch `public.payments` or the errands ledger.** Nigeria runs in
  direct-payment mode (ADR-0025), where the errands side moves no money at all.

The research map had recommended posting Cowries through `ledger.post` with an `XCW` currency. That
verdict assumed naira Earnings, which decision 2 removed. Without a counter-party the ledger adds
cost and risk and nothing else:

- each 5-Cowrie wink would write a transaction, two entries and an unpruned `ledger.posted` outbox
  row on a Free-plan database (OD-33);
- `XCW` in the anon-readable `public.currencies` table would reach clients whose
  `Money.exponentOf` asserts or throws on an unknown code;
- withdrawal CHECKs reference `ledger.account_type`, so a Cowrie account type would sit one
  constraint away from a cash-out path.

Play's Inappropriate Content policy names gifts in its sugar-dating clause `[S]`, which is why the
receiving side must confer nothing that resembles value.

## Decision

We will keep Cowries in a **sealed `meet_econ` schema**, spend-only for everyone, with gifts that
confer status and nothing else.

- **Sealed.** `REVOKE ALL ON SCHEMA meet_econ FROM PUBLIC, anon, authenticated, service_role`. Only
  SECURITY DEFINER functions owned by the migration role touch it. No `ledger.post`, no row in
  `public.currencies`, no `Money` type, no `payments` row. On the clients `Cowries` (Dart) and
  `CowrieAmount` (TypeScript) are plain integer value types.
- **Two balances per person.** `wallets.purchased` may go negative after a clawback (ADR-0028);
  `wallets.bonus` holds free Cowries and is never negative. Spends use bonus first.
- **Append-only entries.** `meet_econ.entries` is partitioned monthly; an UPDATE or DELETE raises.
  A CHECK encodes the posting rules by kind, so no function can credit the wrong balance whatever
  its bug: `purchase` only increases `purchased`; `bonus_grant` and `admin_grant` only increase
  `bonus`; `spend` and `admin_debit` only decrease; `spend_refund` only increases;
  `purchase_void` only decreases `purchased`. A person can never create purchased Cowries.
- **One spend primitive.** `private.meet_spend` checks the expected price first
  (`ERR_MEET_PRICE_CHANGED`), then takes the wallet row lock, refuses a restricted or negative wallet
  (`ERR_MEET_WALLET_RESTRICTED`) or a shortfall (`ERR_MEET_INSUFFICIENT_COWRIES`), and only then
  writes one entry and one wallet update. Every raise happens before any write, so each is a
  catchable `P0001` (the S-14 lesson). Every spend returns the wallet so the balance pill updates
  without a second call.
- **Nothing moves between people.** No function transfers, converts, exchanges or withdraws Cowries,
  purchased or free. Gifts debit the sender and credit no wallet, so there are no cross-user lock
  cycles either.
- **Gifts confer status.** Popularity (capped per sender and per receiver per day), receiver XP
  (its own daily cap) and card progress. Never into a 1:1 chat; canned notes only; the receiver
  never sees a price or a total; no leaderboard anywhere. Gifts between accounts on one device are
  delivered and award nothing, silently, and raise a flag. Content removed for policy refunds its
  gifts to the senders and reverses the popularity (ADR-0026 D8).
- **Free Cowries are bounded.** Streak, mission and welcome Cowries go only to profiles at least
  72 h old with an approved photo, under a daily cap of 20; the welcome grant is 20 once (OD-46).
  The daily surprise never pays Cowries (D7). VIP never grants Cowries (D17). Levels never pay
  Cowries, and spending never buys XP, so paying up and playing up stay separate paths.
- **Reconciled nightly.** `private.meet_reconcile()` checks every wallet against the sum of its
  entries and the purchase entries against `play_purchases.units_granted` and voided units, and
  records the result through `private.record_health_check('meet_wallets', …)`.
- **Words.** The app says "Cowries", "Get Cowries", "send a gift", "react". It never says "wallet",
  "earn", "cash", "withdraw", "sponsor", "get paid" or "pay to chat" ([`docs/store/meet-copy-rules.md`](../store/meet-copy-rules.md)).

The spend menu, card ladder, XP curve, streak rewards, missions, surprise odds and gift catalogue are
configuration (`meet.*` remote config, two signatures to change) and every number in them is `[A]`
until the owner answers OD-45.

## Consequences

**Good:**

- No payout liability exists, so nothing has to be priced, held or reported as owed to users.
- The firewall is structural: there is no code path from a Cowrie to a naira, so a bug cannot open
  one.
- Play stays merchant of record; naira revenue appears only in Play's reports, which RB-18
  reconciles monthly against `play_purchases`.

**Bad / costs:**

- A second set of books with its own reconcile, partitions and health checks, outside the
  double-entry ledger the rest of the platform trusts.
- Without Earnings, receivers get status only. If the owner later wants cash-out it needs counsel,
  an organisation Play account (OD-29) and a financial-features declaration; it is deliberately not
  built and nothing in this design makes it easy.

**Follow-on work:** `docs/plan/meet-cowrie-flows.md` (postings, sign rules, invariants, reconcile)
in M2-PR1; `meet_econ` in `partition_health`, the lint schema list and `00_structure_test`; the
`meet_spend_e2e.sh` concurrency test (20 parallel 30-Cowrie spends against 100: exactly 3 succeed);
OD-44 terms on the Meet terms page.

## Alternatives considered

| Option | Why not |
|---|---|
| `ledger.post` with an `XCW` currency (research map) | No counter-party once Earnings were removed; row cost on the Free plan; `XCW` would reach clients through `public.currencies`; withdrawal CHECKs sit next to it |
| Gift Earnings convertible to naira (spec §5 as written) | Removed by owner decision 2; a financial feature on a personal Play account (OD-29) and next to Play's sugar-dating example |
| One balance with a "purchased" flag per entry | Clawback needs a balance that may go negative while free Cowries never can; two columns with sign rules make that a CHECK instead of a convention |
| Paid daily spins | Real-money gambling and loot-box rules; the surprise stays free and perks-only (D7) |

## Revisit when

- Counsel answers OD-44 (Cowrie terms) or the owner answers OD-45 or OD-46.
- The owner asks for any cash-out or transfer between users: that reopens this ADR, OD-29 and the
  financial-features declaration together.
- An iOS release wants to sell Cowries (App Store guideline 3.1.1 requires StoreKit `[S]`).
