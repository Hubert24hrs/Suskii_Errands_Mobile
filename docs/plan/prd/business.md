# PRD — Business providers and fleets

Conventions in [README.md](README.md) §4. Refs: JL = [job-lifecycle.md](../state-machines/job-lifecycle.md), ERD = [erd.md](../erd.md). Source: spec `business_accounts_and_fleets`, `verification_kyc`. Roles inside an organisation: **Owner**, **Dispatcher**, **Worker**.

### BU-01 — Register my business
*As a business owner, I want to register my company as a provider, so that my team can take jobs under one name.*
- Business details and registration documents per the country pack are submitted and reviewed by a Verification Officer (AD-09).
- Registration numbers are encrypted with a blind index; one registration number cannot back two organisations in a country (ERD).
- The organisation cannot bid until business verification and owner KYC are both verified.

### BU-02 — Complete owner KYC
*As a business owner, I want to verify myself, so that the business can be approved.*
- The owner completes full provider KYC (PR-02…PR-08) including police clearance.

### BU-03 — Invite members and assign roles
*As an owner, I want to invite dispatchers and workers, so that my team can use Suskii.*
- Invitations by phone number; invitees join after signing in and accepting.
- Roles: Owner (everything), Dispatcher (assign jobs, see job status, no finance), Worker (own assigned jobs). Enforced in RLS, not just the UI (I-14).
- Owners can remove members; removal ends access immediately, including to active job details.

### BU-04 — Verify every worker
*As Suskii, I want every worker verified like an individual provider, so that customers are equally protected.*
- Each worker completes facial verification and police clearance (spec); unverified workers cannot be assigned jobs.
- Worker document expiry follows PR-14; the owner and dispatcher see expiry warnings.

### BU-05 — Bid as the organisation
*As an owner or dispatcher, I want to make offers as the business, so that customers see our company.*
- Offers are made in the organisation's name with its reputation; the payout estimate reflects the organisation's commission and fees.
- The same guardrails, TTLs and round limits apply as PR-12, PR-13.
- Self-dealing checks include every member of the organisation.

### BU-06 — Dispatch a job to a worker
*As a dispatcher, I want to assign an accepted job to an available verified worker, so that the right person does it.*
- Only verified, eligible, available workers with an allowed vehicle for the zone are offered (BU-09).
- Assignment moves the job to `ASSIGNED` (JL #11) and notifies the worker and the customer with the worker's details.
- Reassignment before en route is allowed and logged.

### BU-07 — Let workers self-accept
*As an owner, I want to allow trusted workers to take jobs themselves, so that dispatch isn't a bottleneck.*
- Configurable per organisation and per worker; when enabled, a worker's accept assigns the job to them directly (spec).

### BU-08 — Manage the vehicle registry
*As an owner, I want a register of our vehicles, so that the right vehicle is used and papers stay current.*
- Vehicle type, plate, documents, assigned worker and document expiry (spec).
- Expiry reminders at 30, 14 and 3 days; an expired vehicle cannot be used on a job.

### BU-09 — Respect city zone rules
*As Suskii, I want vehicle types restricted per city zone, so that jobs follow local rules.*
- Allowed vehicle types per zone come from the country pack (spec); matching and dispatch exclude disallowed vehicles, and the provider sees why a request isn't shown.

### BU-10 — Get paid and see per-worker performance
*As an owner, I want payouts to the business account and reports per worker, so that I can run my company.*
- All job payouts go to the organisation's verified payout account (spec); workers cannot withdraw organisation earnings.
- Per-worker earnings, jobs, ratings and cancellation reports are visible to the Owner only.
- Reputation is tracked for both the organisation and each worker (spec).
