# Meet copy rules

| | |
|---|---|
| Owner | Claude Code (rules and checker); whoever writes Meet copy follows them |
| Date | 2026-11-26 |
| Applies to | Every word a person can read about Suskii Meet: the app, the website, push titles, the Play listing, screenshots and the legal pages |
| Related | [ADR-0026](../adr/0026-meet-v5-social-layer.md), [ADR-0027](../adr/0027-cowries-sealed-spend-only-economy.md), [ADR-0028](../adr/0028-play-billing-verification-rtdn-clawback.md); design §5.1, §8.8, §8.10, §8.12 |

## Why words matter here

Meet is a dating surface with gifts, inside an app on a personal Play account. Google's
Inappropriate Content policy names gifts in its sugar-dating example, and Google rejected this
app's first submission over a "wallet" declaration on a personal account (OD-29, RB-15). Copy that
suggests money changes hands, that gifts buy attention or company, or that Cowries are worth cash
can turn a policy-compliant design into a policy violation on its own. The product already has no
cash-out, no earnings and no transfers (ADR-0027); the copy must not imply otherwise.

## Forbidden terms

These never appear in Meet copy, in English or Pidgin, in any form (case-insensitive, whole word,
plurals and verb forms included):

| Term | Why |
|---|---|
| wallet | Cowries are not a store of money. Say "Cowries" or "your Cowries" |
| earn, earnings | Nobody earns anything in Meet. Gifts give status (ADR-0027) |
| cash | Cowries have no cash value |
| cash out | There is no cash-out |
| withdraw | Nothing can be withdrawn |
| get paid | Nobody is paid |
| sponsor | Sugar-dating vocabulary |
| sugar | Sugar-dating vocabulary |
| generous | Sugar-dating vocabulary; also a held bio term |
| allowance | Sugar-dating vocabulary; also a blocked chat term |
| pay to chat | Chatting with a match is free; a reach request is the privilege to reach, never a paid conversation |
| gifts for dates | Gifts never buy a meeting |
| discreet affairs | Meet is for meeting new people, not for infidelity |

The CI grep enforces exactly this list (below). The words to use instead:

| Instead of | Say |
|---|---|
| wallet, balance top-up | Cowries, Get Cowries |
| send money, tip | Send a gift, react |
| earn Cowries | Get free Cowries (streaks and missions), or describe the reward: "+2 Cowries" |
| unlock a chat | Send a request; "They decide whether to accept" |
| VIP access to people | Reach popular members; "Reaching someone is never a promise of a reply" |

## Rules that are not a word list

- **Gifts are reactions to content.** Copy says a gift was sent "on your status", "on your photo",
  "on your profile". It never frames a gift as a thank-you for time, a reply, a call or a meeting,
  and never appears in a 1:1 chat (ADR-0026 D8).
- **Receivers never see a price.** "Ada sent you a Rose", never "Ada sent you 20 Cowries". No
  totals of what anyone has spent on someone.
- **No leaderboards, rankings or "top" language** about gifts or gifters: no "top gifter", "biggest
  fan", "most generous".
- **Cowrie disclosures are plain.** The Cowries page carries: "Cowries have no cash value. They
  can't be withdrawn, transferred or exchanged, and refunds go through Google Play." Prices are
  Play's own strings; copy never writes a naira figure for a pack or VIP.
- **The daily surprise is not gambling.** It is "Today's surprise" or "Pick a card". Never "spin",
  "wheel", "jackpot", "lucky draw", "win big" or casino imagery, and the odds are shown beside it
  (D7). These words are guidance rather than part of the CI list, because "spin" and "win" also
  appear innocently.
- **No presence.** Never "online now", "active now" or "online". Only "Active today" or "Active this
  week" (D20).
- **No exact location.** "Nearby", "Under 5 km", "Lekki, Lagos". Never "0.4 km away" or a map of
  people (D21).
- **Unlocking is the privilege to reach.** Badge-locked teasers say what the card opens and that the
  owner can always decline. Never "guaranteed reply", "they'll answer" or "meet them".
- **Lock screens carry nothing personal.** Push titles are generic: "Someone likes you", "You have a
  new match", "New message", "A gift arrived". Never a name, an amount or a gift name (design §2.8).
- **"Held", never "escrow"**, if Meet copy ever mentions errands money (ADR-0002; already enforced
  repository-wide by `infra/policy/policy_check.py`).

## The Play listing and screenshots (design §8.10)

- Allowed line: "Meet new people nearby — adults 18+, verified photos, private chat and group
  meet-ups". From M2 the listing mentions optional in-app purchases.
- Never in the listing: "earn", "money", "gifts for dates", "sugar", "sponsor", "discreet affairs",
  or anything that suggests hook-ups or paid company.
- Screenshots use licensed or illustrative imagery, never fixture faces presented as members, and
  nothing from InMessage (owner decision 1: layout patterns only, never their name, logo, icons or
  imagery).

## Safety copy may name what it forbids

Guidelines, safety tips and report reasons sometimes have to name a forbidden practice to forbid it:
"Never send money or gift cards to someone you haven't met", "Asking for money or gifts". That is
allowed, and only there. The checker carries an exception list of such keys, each with a reason; a
string is added to it only when it warns against the thing it names.

## Enforcement

`contracts/tools/check_preview.py` gains a grep in M0-PR2 (design §9). It reads:

- `meet*` keys and their values in `packages/suskii_l10n/lib/l10n/app_en.arb` and `app_pcm.arb`;
- the website's Meet dictionaries, `meet.en.ts` and `meet.pcm.ts`, which the M1 web pages create;
- the web-marketing Meet copy;

and fails CI on any forbidden term outside the exception list. It does not read errands copy, where
"wallet", "earnings" and "withdraw" are correct words for the provider side. The listing,
screenshots and push titles have no file to grep; they are checked by hand against this page at
each milestone's release (M1-PR14, M2-PR15).
