# PRD — Provider mode

Conventions in [README.md](README.md) §4. Refs: JL = [job-lifecycle.md](../state-machines/job-lifecycle.md), ON = [offer-negotiation.md](../state-machines/offer-negotiation.md), MF = [money-flows.md](../money-flows.md), DF = [data-flow.md](../data-flow.md), TM = [threat-model.md](../threat-model.md).

Every provider — including every worker under a business — completes full provider KYC with police clearance before Provider mode unlocks (spec).

## Onboarding and KYC

### PR-01 — Start provider onboarding
*As a customer who wants to earn, I want to set up a provider profile, so that I can start verification.*
- Choose individual or business (business continues in BU-01), services offered, service areas and vehicle type (walking, bicycle, motorcycle, tricycle, car, van, truck).
- Service areas and categories come from server lists for the country (`list_service_areas`; review 2.16).
- A checklist shows every required step with its status (not started, consent pending, in progress, in review, verified, rejected, expired); required steps are server configuration per country and category, not hardcoded.
- Provider mode stays locked until the overall status is `VERIFIED` (SH-08).

### PR-02 — Verify my government ID
*As a provider, I want to verify my national ID, so that Suskii knows who I am.*
- Accepted ID types come from the country pack (e.g. NIN or BVN in Nigeria, Ghana Card, Kenya National ID, South African ID).
- The lookup is server-side; the app receives outcome and reason key only, never the name on the record (review C.2).
- ID numbers are encrypted with a blind index so one identity cannot register two provider accounts; they are never shown back after submission (ADR-0007; DF class G).

### PR-03 — Verify my face and capture my ID document
*As a provider, I want to complete a liveness check and photograph my ID, so that my identity is confirmed.*
- Explicit biometric consent first (SH-07).
- Liveness plus face match against the government ID record; ID document capture with OCR and tamper checks in the vendor SDK.
- Duplicate-face detection across accounts blocks banned users re-registering (spec).
- Works on 2 GB RAM devices with ≥ 90% genuine pass rate (S-05, **Gated**).
- Captures are never cached on device after upload (review D.2).

### PR-04 — Consent to a criminal-record check
*As a provider, I want to understand and agree to the criminal-record check separately, so that I know exactly what I'm consenting to.*
- Separate consent screen from biometrics, with its own version and record (spec).
- Declining ends the flow with an explanation that police clearance is required for every provider (client decision).

### PR-05 — Submit my police clearance
*As a provider, I want to upload my police clearance certificate, so that I can be approved.*
- Document name, issuing body and validity rules come from the country pack (e.g. Nigeria Police Character Certificate, Kenya Certificate of Good Conduct).
- Provider enters certificate number, issue date and expiry date and uploads the file to the upload-only `kyc-docs` bucket; the app can never read it back (spec; DF flow 5).
- Recency and renewal rules per OD-09 default: issued within 6 months, re-verified every 12 months, per-country override.
- Verified via an official or vendor channel where one exists, otherwise by a Verification Officer (AD-05).
- **No free-text criminal-history notes** are stored anywhere; rejection uses reason keys (spec).

### PR-06 — Verify my address and add a guarantor
*As a provider, I want to add my address and a guarantor where required, so that I can reach higher trust levels.*
- Address verification is required for TRUSTED and above (spec).
- Guarantor or reference is required per category and country configuration; the guarantor's contact details are used only for verification.

### PR-07 — Add my payout account
*As a provider, I want to add a bank or mobile-money account, so that I can get paid.*
- Payout institutions and rails come from the country pack (bank transfer, mobile money such as M-Pesa, MTN MoMo, Airtel Money, card payouts where supported) (`list_payout_institutions`; review 2.16).
- The server resolves the account name and shows whether it matches the verified identity **before** submission; a mismatch cannot be used for payouts (spec; R-32).
- Account numbers are encrypted with a blind index.

### PR-08 — Submit vehicle documents and credentials, then get a decision
*As a provider, I want to submit my vehicle papers and trade certificates and be told the outcome, so that I can start working.*
- Vehicle documents (licence, registration, insurance per country pack) are required only for motorized vehicles.
- Service-specific credentials (e.g. trade certificates) are required per category configuration.
- "Submit for review" is allowed only when every required step is verified or in review (`ERR_KYC_INCOMPLETE`).
- A Verification Officer approves (→ `VERIFIED`) or rejects individual steps with reason keys; the provider is notified and can resubmit rejected steps within the attempt limit.

## Going online and finding work

### PR-09 — Pass a selfie check before going online
*As Suskii, I want a quick selfie check when a provider goes online, so that accounts can't be shared or rented.*
- A real-time selfie check at least once per 24 h plus random checks (spec); implementation follows OD-13 default: on-device liveness daily, vendor 1:1 check weekly and on risk triggers.
- Face re-verification also on profile photo change, device change, payout account change and large withdrawals (spec).
- Failure blocks going online with `ERR_SELFIE_CHECK_REQUIRED` and a retry.

### PR-10 — Go online
*As a verified provider, I want to go online, so that I start receiving nearby requests.*
- Continuous location and foreground-service permissions are requested **only** the first time the provider goes online (spec), with a clear explanation screen and the Play/App Store justifications.
- Server blocks going online with a specific error when: KYC or documents expired (`ERR_KYC_EXPIRED`), selfie check due, provider has an active customer job needing attention (`ERR_PROVIDER_BUSY_AS_CUSTOMER`, configurable), or the account is suspended.
- Online status sends a movement-gated heartbeat, not a write per GPS fix (ADR-0009); background location survives an 8 h shift on the A-tier devices (S-04, **Gated**).
- Going offline stops location collection immediately.

### PR-11 — See nearby requests
*As an online provider, I want a feed of requests near me that match my services, so that I can choose what to bid on.*
- The feed contains only requests the matching function sends to this provider (distance, category, vehicle, zone rules, availability, blocks); a provider can never list all open requests (RLS named deny test).
- Each card shows category, description, photos, approximate pickup area (exact address and access notes are revealed only after assignment), distance, urgency, schedule, customer's preferred price, price band, customer rating and time left.
- New matching requests notify the provider; the feed updates in real time.
- A provider never sees their own requests (self-dealing block).

### PR-12 — Make an offer and see what I'll earn
*As a provider, I want to offer a price and see my estimated payout before I send it, so that I don't work at a loss.*
- Before submitting, the app shows the server's estimate: offer − commission (default 12.5%, OD-06) − estimated gateway fee = estimated payout (spec transparency rule).
- Guardrails: soft limits warn, hard limits reject (`ERR_PRICE_OUT_OF_RANGE`), and offers that would net ≤ 0 are refused (ON).
- Offers expire after the category TTL (default 10 min).
- Server blocks offers from ineligible providers (expired documents, suspended, blocked by the customer, self-dealing).

### PR-13 — Counter or withdraw
*As a provider, I want to respond to a customer's counter or withdraw my offer, so that I can negotiate.*
- Counter while under the round limit and on the provider's turn; each counter shows an updated payout estimate.
- Withdraw a pending offer at any time before acceptance (review C.4); to lower a price, withdraw and re-offer, visible in history (ON).
- If the customer accepts a different provider, the offer shows as expired with a neutral message.

### PR-14 — Keep my documents current
*As a provider, I want reminders before my documents expire, so that I don't get suspended.*
- Reminders at 30, 14 and 3 days before expiry of police clearance and vehicle documents (spec).
- On expiry, accepting new jobs is blocked and the relevant step returns to `expired`; an in-progress job can be completed.
- Renewal re-enters the review queue.

## Job execution and proof

### PR-15 — Get assigned and start
*As a provider whose offer was accepted, I want to know the job is paid and confirm I'm starting, so that I don't travel for an unpaid job.*
- The provider is notified at acceptance, and told to start only once the job is `PAID_HELD` → `ASSIGNED` (JL #8, #11).
- Exact pickup address and access notes become visible only now, and only until the job ends (CU-06).
- If not en route within the start timeout (default 15 min), the customer may reassign (CU-20); this counts toward reliability metrics.

### PR-16 — Navigate and update status
*As a provider on a job, I want to navigate and mark en route and arrived, so that the customer knows where I am.*
- Status changes go through `set_job_status` with an idempotency key; illegal transitions are rejected (JL).
- En route requires location permission and no mock location (JL #12); arrived requires being within the pickup geofence or a manual reason (JL #13).
- Handoff to an external navigation app is available.
- Status updates made offline queue and replay once, in order (SH-34).

### PR-17 — Verify the pickup and delivery PIN
*As a provider, I want to enter the customer's PIN at handover, so that pickup and delivery are proven.*
- The PIN is verified server-side with attempt limits; the provider never sees the PIN in the app (spec).
- A correct pickup PIN moves the job to in progress (JL #14); lockout alerts the customer and support.

### PR-18 — Submit proof of completion
*As a provider, I want to submit photos and mark the job complete, so that I get paid.*
- Required proof is per category configuration: photos, delivery PIN, receipts for item float (JL #15).
- Photos are captured in-app with server timestamp and device GPS attached; EXIF is stripped for display (spec).
- Proof uploads queue offline and resume (SH-34).
- The provider sees whether the customer confirmed or auto-confirmation is pending (CU-21, CU-23).

### PR-19 — Buy items with the float and upload the receipt
*As a provider on a shopping errand, I want to use the prepaid float and upload the receipt, so that I'm reimbursed correctly.*
- The float is released when the job starts (JL #14; OD-04).
- The provider photographs the receipt; the extracted total is a suggestion both parties confirm, with amounts parsed server-side (AI §5.4).
- Spending above the float requires a customer-approved top-up; it is never charged automatically (OD-04 sub-question).

### PR-20 — Cancel a job as a provider
*As a provider who can't do a job, I want to cancel, so that the customer can find someone else.*
- Before payment: free, counts toward cancellation-rate metrics (JL #23).
- After payment: the customer gets a full refund and the provider's reliability score drops (JL #25); a reason key is required.
- Repeated cancellations feed the risk engine and may restrict going online.

## Earnings, withdrawals, provider tools

### PR-21 — See my earnings and breakdowns
*As a provider, I want to see what I earned per job and in total, so that I trust the numbers.*
- Per job: agreed amount, commission at the snapshotted rate, actual gateway fee, item float spent, tips, payout, and status (held, settlement pending, settled) (spec transparency; MF formula: payout = agreed − commission − gateway fee + float spent + tips − tip fees).
- Totals by day, week and month; history paginated.
- Earnings become available after confirmation, the dispute window and a successful settlement (JL #18, #19).

### PR-22 — Withdraw my earnings
*As a provider, I want to withdraw available earnings to my account, so that I get my money.*
- Requires completed KYC, a name-matched payout account and a balance above the per-currency minimum (spec).
- The preview shows amount, transfer fee (paid by the provider by default, OD-10) and amount received.
- Above a configurable threshold a Finance Officer approves; above a higher threshold a second approver is required (AD-14).
- Failed or reversed payouts return to the balance with a notification (RB-04).
- "Instant payout" is the same withdrawal where the rail supports immediate transfer.

### PR-23 — Change my payout account safely
*As a provider, I want to change my payout account without making it easy for a thief to redirect my money.*
- Requires face re-verification plus biometric or PIN confirmation, and a name match (spec; TM §8).
- A cooling-off delay applies before the first payout to a new account, and after a recent phone-number change (R-32; SH-38).
- The provider is notified on every channel when the account changes.

### PR-24 — Set my availability
*As a provider, I want to set the hours I usually work, so that I get requests when I'm available.*
- Weekly availability schedule and service areas; matching uses them together with the online toggle.

### PR-25 — See where demand is
*As a provider, I want a demand heatmap, so that I know where to wait for jobs.*
- Heatmap of recent request density by area and category, aggregated so no individual request or customer location can be inferred.

### PR-26 — Track goals and performance
*As a provider, I want earnings goals and performance insights, so that I can improve.*
- Earnings goals by day or week; insights on acceptance rate, response time, completion rate, cancellation rate and rating trends — the same factors matching uses (spec matching factors).

### PR-27 — See my reputation and trust level
*As a provider, I want to know my trust level and what gets me to the next one, so that I can earn more trust.*
- Shows rating (Bayesian), completed jobs, trust level and the requirements for the next level (e.g. address verification for TRUSTED) (SH-31).
