# PRD — Customer mode

Conventions in [README.md](README.md) §4. Refs: JL = [job-lifecycle.md](../state-machines/job-lifecycle.md) (transition numbers `#n`), ON = [offer-negotiation.md](../state-machines/offer-negotiation.md), MF = [money-flows.md](../money-flows.md), AI = [ai-design.md](../ai-design.md).

## Requests and AI concierge

### CU-01 — Describe what I need to the AI concierge
*As a customer, I want to type what I need in my own words, in English or Pidgin, so that the app turns it into a proper request.*
- Available to unverified customers (spec).
- The concierge replies in the user's language, asks one question at a time for missing details, and classifies the category (including custom services) (AI §5.2).
- As details are gathered, a **server-side draft** is saved; leaving and returning resumes it.
- The concierge never publishes, accepts, pays or sets a price. When the draft is complete it shows a **publish card**; publishing is the customer's tap (AI §4.1, CU-07).
- Preferred price, item float and declared value are only set by the customer on the card, never by the assistant (AI §5.3).
- The concierge can show the advisory price band with its basis ("rough guide" when rule-based) (AI §9).
- Distress phrases show the SOS card and emergency numbers first (AI §6.4).
- At any point, or when AI is unavailable or over budget, "Use the form instead" opens CU-03 prefilled with what was gathered (AI §6.5).
- Quality gate: English task success ≥ 90%, Pidgin ≥ 85% on the golden sets (AI §8.1; OD-20).

### CU-02 — Speak to the concierge
*As a customer who prefers talking, I want to describe my errand by voice, so that I don't have to type.*
- Same capabilities, limits and publish card as CU-01; the assistant reads the draft back before showing the card.
- English voice at launch; **Pidgin voice is Gated** on S-08 (OD-17) — if it fails, Pidgin users get the text concierge and the voice entry point is hidden for Pidgin by a per-language flag.
- Audio is not recorded; only a redacted transcript is kept for 90 days.
- End of speech to first audio p95 ≤ 1.5 s (live route) or ≤ 2.2 s (cascade).
- Voice sessions resume from the saved draft if interrupted.

### CU-03 — Create a request with the form (Request Anything)
*As a customer, I want a straightforward form, so that I can post a request without the AI.*
- Fields: category (the spec's 12 groups including custom), description, photos, pickup, optional destination, urgency, schedule, preferred price, item float, declared value.
- Category-specific required fields come from the server (e.g. vehicle needed, proof required, float allowed).
- Saved as `DRAFT` (JL #1) until published; drafts are editable and deletable only while `DRAFT` (RLS).

### CU-04 — Add photos to a request
*As a customer, I want to attach photos, so that providers understand the job.*
- Up to the configured number of images; compressed on device before upload; uploaded to the private request-media bucket by signed URL.
- Server re-encodes images and strips EXIF; malware-scanned before providers can see them.
- Upload resumes after connectivity loss without duplicating the request (SH-34).

### CU-05 — Add an item float or declared value
*As a customer sending someone shopping, I want to prepay the cost of the items, so that the provider can buy them.*
- Item float is a separate, non-commissionable line; the customer pays a gateway-fee surcharge on it (OD-04 default; MF 3a).
- Float is available only in categories that allow it.
- Declared value is recorded for disputes; no insurance is sold (OD-05).
- The unused float is refunded after receipt review (CU-22).

### CU-06 — Set pickup and destination the way people give directions
*As a customer, I want to set places with a map pin, a saved place or a landmark description, so that providers can find me even without a street address.*
- Map pin, place search, saved places and free-text landmark notes are all valid.
- Gate or estate **access notes** are encrypted and revealed only to the assigned provider, only during the active job, and deleted at job close (spec; DF flow 8).
- Address search queries are not logged by Suskii (DF rule 5).

### CU-07 — Publish my request
*As a customer, I want to publish a request, so that nearby providers can make offers.*
- `publish_request(request_id, idempotency_key)` (JL #2); a retried tap never creates two published requests.
- Server checks, each with a specific error: customer verified (`ERR_VERIFICATION_REQUIRED` → SH-06), country live or beta, category allowed, **prohibited items** (SH-29), preferred price within the category's hard limits (`ERR_PRICE_OUT_OF_RANGE`), soft limits as a confirmable warning, not self-dealing.
- Moderation runs before publication; if AI moderation is unavailable the request publishes and is queued for review (OD-21 default).
- On success, matched providers are notified (PostGIS matching) and the request TTL starts (default 60 min).

### CU-08 — Set urgency or schedule for later
*As a customer, I want to mark how urgent a job is or book it for a future time, so that providers plan accordingly.*
- Urgency levels: flexible, standard, urgent, emergency, with per-country multipliers in the price guardrails.
- Scheduled errands publish automatically at the configured lead time before the chosen time (queued job); recurrence is **Later**.
- Times display in the user's time zone; countdowns use server time (review item 1).

### CU-09 — Get help when no one offers
*As a customer whose request gets no offers, I want a suggestion and an easy way to retry, so that my errand still gets done.*
- When the request TTL elapses without acceptance, the request expires (JL #22) and the app suggests a price adjustment based on the price band (spec: AI suggests a price adjustment).
- The customer can edit and republish in one step; the suggestion is advisory and never changes the price without the customer's action.

## Offers and negotiation

### CU-10 — Receive offers in real time
*As a customer, I want offers to appear as they arrive, so that I can respond quickly.*
- Offers arrive over the customer's private channel within the realtime target (N-03); on reconnect, missed offers are fetched.
- Each offer shows provider display name, rating, trust level, completed jobs, distance, ETA, amount and time left.
- Customers never see providers' payout estimates or other customers' data; providers never see rivals' amounts (ON; review item 6).

### CU-11 — Compare offers
*As a customer with several offers, I want help comparing them, so that I pick the best one, not just the cheapest.*
- Offers can be sorted by price, rating, distance and ETA.
- "Help me choose" shows a deterministic ranking with the factors that drove it, and a short plain-language explanation that may not reorder it (AI §4.1, §5.4).

### CU-12 — Accept an offer
*As a customer, I want to accept an offer, so that the job is agreed and I can pay.*
- `accept_offer(request_id, offer_id, idempotency_key)` (JL #6) locks the request, expires all other offers, snapshots the agreed amount and commission rate, and emits one event — in one transaction (spec; S-10).
- If another action won the race, the customer sees a clear message (`ERR_OFFER_NOT_ACTIVE`, `ERR_OFFER_EXPIRED`), not a failure.
- Provider eligibility is re-checked at acceptance (verified, not suspended, documents valid, not blocked).
- The next screen shows the total to pay (agreed amount, promo, item float and surcharge) and the payment countdown.

### CU-13 — Counter an offer
*As a customer, I want to propose a different price, so that we can meet in the middle.*
- Counter allowed while the thread is under its round limit (default 5) and it is the customer's turn (sides alternate) (ON thread rules).
- Price guardrails apply to counters; the offer TTL resets on each counter (ON).
- At the round limit, only accept, decline or withdraw remain, and the UI says so.

### CU-14 — Decline an offer
*As a customer, I want to decline an offer I don't want, so that the provider knows and my list stays tidy.*
- Declining is final for that thread; the provider is notified; the request stays open for other offers.

### CU-15 — See negotiation history and expiry
*As a customer, I want to see every offer and counter in a thread and when each expires, so that nothing surprises me.*
- History is append-only and shown in order; withdrawn and expired offers remain visible with their status (ON).
- Countdowns use server time.

## Payment, tracking, completion

### CU-16 — Pay upfront
*As a customer, I want to pay right after agreeing, so that the provider can start knowing the money is secured.*
- Payment starts only after agreement (JL #7); methods come from the country pack (cards, bank transfer, mobile money, USSD where available); gateway routing is per country (Flutterwave primary, Paystack secondary, OD-11).
- Card details are entered only in the gateway's hosted checkout, never in Suskii's app (PCI SAQ-A; DF flow 10).
- The app never marks a payment successful: the job moves to `PAID_HELD` only on a signature-verified webhook plus a server-side verify call (JL #8).
- Copy says the money is **held by Suskii until the job is done**, never "escrow" (ADR-0002; OD-12).
- **No cash option anywhere** (client decision).

### CU-17 — Recover from a failed or slow payment
*As a customer, I want clear handling when payment fails or times out, so that I don't pay twice or lose the job silently.*
- Payment TTL defaults to 15 min with a visible countdown.
- On failure the customer can retry within the TTL; retries reuse the payment intent so no double charge.
- On TTL expiry the job returns to negotiating if the offer is still valid, otherwise expires (JL #9, #10); a late successful payment is refunded automatically.
- Returning from checkout always reconciles from the server, not from the redirect result.

### CU-18 — See who is coming and my PIN
*As a customer whose job is paid, I want to see the assigned provider and my handover PIN, so that I know who to expect and can verify them.*
- Shows provider name, photo, rating, trust level, vehicle type and plate where applicable.
- Pickup and delivery PINs are generated server-side and shown **only to the customer**; the provider must enter them (spec).
- PIN attempts are limited server-side; lockout alerts the customer and support.

### CU-19 — Track the provider live
*As a customer, I want to see the provider moving on a map with an ETA, so that I know when they'll arrive.*
- Live position via the job's private realtime channel; not persisted per ping (ADR-0009).
- On poor networks positions degrade to sampled updates; stale positions are labelled, never invented (network matrix).
- Status timeline shows assigned, en route, arrived, in progress, completed.

### CU-20 — Replace a provider who doesn't start
*As a customer whose provider hasn't set off, I want to get a different provider without penalty, so that I'm not stuck.*
- If the provider isn't en route within the start timeout (default 15 min), the customer can reassign: the provider is released, matching reopens, funds stay held, no fee (JL #26; spec).

### CU-21 — Confirm completion and get a receipt
*As a customer, I want to review the proof and confirm the job is done, so that the provider is paid and I have a record.*
- When the provider completes, the customer sees proof photos (with server timestamps), PIN status and receipts, and can confirm (JL #16) or open a dispute (CU-25).
- Confirming starts the dispute window (default 24 h) and shows the receipt (SH-19) with rating and tip prompts.

### CU-22 — Review an item-float receipt
*As a customer who prepaid for items, I want to check the receipt, so that I only pay for what was bought.*
- Receipt image and the extracted total are shown as a **suggestion**; the customer approves the amount spent.
- Unused float is refunded automatically on approval (MF 3b).
- A receipt above the float is never charged automatically; the provider may request a top-up the customer approves, otherwise it goes to a dispute (OD-04 sub-question).

### CU-23 — Auto-confirmation
*As a customer who forgets to confirm, I want the job confirmed automatically only when it's safe, so that the provider isn't left waiting.*
- Auto-confirm after the configured period (default 24 h) **only** if the PIN was verified and required proof exists (JL #17; spec).
- The customer is notified before and when it happens; the dispute window still applies.

## Cancellation, disputes, support

### CU-24 — Cancel a job
*As a customer, I want to cancel, seeing any fee first, so that I can change my mind fairly.*
- Before payment: free (JL #23).
- After payment: the fee depends on state and elapsed time per the country pack and is shown **before** confirming; refund = paid − fee, with gateway-fee handling per OD-08 and the fee going to the provider net of commission by default (OD-19) (JL #24; MF 5a–5c).
- Cancellations feed cancellation-rate metrics.
- If the provider cancels after payment, the customer gets a full refund (JL #25).

### CU-25 — Open a dispute
*As a customer with a problem, I want to open a dispute with evidence, so that a person reviews it and payouts wait.*
- Available from payment through the end of the dispute window (JL #27).
- Payout is frozen immediately while the dispute is open.
- Evidence bundle is assembled automatically: chat, photos, GPS trail, PIN logs, call metadata; the customer adds a reason key, description and extra photos (spec).
- Location trail samples linked to the dispute are kept beyond the normal 90 days until it closes.

### CU-26 — Follow a dispute to its outcome
*As a customer with an open dispute, I want to see its progress and result, so that I know what will happen to my money.*
- Shows status, SLA timer, requests for more information and the outcome.
- Outcomes: provider's favour (settlement resumes), full refund or partial refund (payment status `partially_refunded`) (JL #28, #29; review N.2).
- Referral commissions on refunded jobs are reversed (SH-22).

### CU-27 — Get help
*As a customer, I want a help centre and a way to reach support, so that I can solve problems quickly.*
- Help centre articles are searchable and localized.
- A support ticket can be opened from any job or payment; AI triage suggests queue and priority, and a human agent handles it (spec; AI §5.4).
- Safety-related tickets always go to the safety queue.

### CU-28 — Track my refund
*As a customer owed a refund, I want to see its status and timing, so that I know when to expect it.*
- Shows amount, reason, method and status from initiation to gateway confirmation (JL #30).
- Refunds go back to the original payment method or wallet credit per country pack rules.

## Promos, tips, favourites, scheduled errands

### CU-29 — Use a promo code
*As a customer, I want to apply a promo code, so that I pay less.*
- Validated server-side for country, dates, usage limits and stacking rules with referrals (spec anti-fraud).
- Platform-funded discounts **never reduce provider earnings** (spec; MF promo scenario).

### CU-30 — Tip the provider
*As a customer, I want to tip after a job, so that I can reward good service.*
- Tips are commission-free; only the tip's own gateway fee is deducted (spec; MF).
- Available after confirmation for a configured period.

### CU-31 — Favourite and rebook a provider
*As a customer, I want to save providers I like and offer them my next job first, so that I get consistent service.*
- Favourites list; "Rebook" publishes a new request offered first to that provider for a short exclusive window, then to the market.
- Blocked pairs cannot be favourited.

### CU-32 — Book a scheduled errand
*As a customer, I want to book an errand for a future date and time, so that it's handled when I need it.*
- Covered by CU-08; scheduled requests list separately with edit and cancel until they publish.
- Recurrence is **Later**.
