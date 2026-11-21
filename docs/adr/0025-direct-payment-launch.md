# ADR-0025 — Launch with direct payment: customers pay providers, the app moves no money

| | |
|---|---|
| Status | Accepted |
| Date | 2026-11-21 |
| Deciders | Owner, for the client; Claude Code |
| Unblocked by | Google Play production access (granted 2026-11-21) |
| Supersedes | Nothing. ADR-0002 (held funds) and ADR-0004 (gateways) stand for the in-app mode |

## Context

Google granted production access on 2026-11-21, but a clean production database cannot take
Nigeria live: `private.country_pack_gaps` refuses a country with no payment or payout provider,
and no gateway can exist before the business is registered (OD-29, OD-12; client action 4). Every
step of the in-app route waits on CAC registration, then a merchant account, a D-U-N-S number and
moving the app to an organisation Play account. That is months, mostly of paperwork only the client
can do.

The options were written up for the client on 2026-11-19 ("Launching without in-app payments",
a Claude doc) and the owner chose on 2026-11-21.

## Decision

A country can run in **direct-payment mode** (`countries.config.client.payment_mode = 'direct'`).
Nigeria launches in it.

- The customer agrees a price as before, then taps **Confirm hire** (`confirm_hire`, transition 32:
  agreed → assigned). Nothing is charged. The address, chat and calls open at the hire, which only
  the customer can trigger.
- The customer pays the provider directly, in cash or by transfer, at the agreed price, when the
  errand is done. A confirmed direct job closes once the chat window after confirmation has passed
  (transition 33). There is no settlement, payout, commission or referral reward.
- Payments, tips, promo codes, float top-ups, refunds and disputes refuse with
  `ERR_DIRECT_PAYMENT_ONLY`, enforced on the `payments` and `disputes` tables rather than in each
  function. Cancelling a direct job charges and refunds nothing, and is impossible once the
  provider says the work is done.
- **Shopping is allowed with a goods cap**: the customer sets the most the goods may cost
  (`requests.item_float_minor`), the provider records what they spent with a receipt
  (`record_goods_receipt`, at most the cap) before marking the job done, and the customer repays
  that with the agreed price.
- **Sign-in is email and Google only** (`config.client.sign_in_methods`). A country that offers no
  phone sign-in needs no SMS provider to go live; a direct-payment country needs no payment or
  payout provider. Every other gap is unchanged.
- `jobs.direct_payment` is written once, at hire, and later steps read it rather than the country,
  so a job keeps the terms it was agreed under if the country changes mode.

Decided with it (owner, 2026-11-21; `docs/OPEN-DECISIONS.md` OD-30 … OD-34): the production project
runs on the Supabase **Free** plan, taking the testers' sandbox's slot at launch; the terms of
service are **published as a draft now** and reviewed by counsel afterwards; the platform charges
**nothing** while payments are off.

## Consequences

- No platform revenue until in-app payments return. The 12.5% commission (OD-06) and the referral
  rewards (OD-01…OD-03) stay configured and switch back on with `payment_mode = 'in_app'`.
- No money protection. A provider who is not paid, or a customer let down by a provider, has a
  complaint to support, ratings and suspension (OD-25), not held funds. A provider can lose up to the
  goods cap on a shopping errand.
- The personal Play account keeps declaring **no financial features**, which is what Google
  approved; OD-29 still applies before any build takes payments.
- Switching a country back to in-app is one approved config change. Jobs hired directly finish
  directly.
- Counsel must still confirm that introducing people without handling money changes the platform's
  licensing position (OD-12). That is an assumption `[A]` until they do.
