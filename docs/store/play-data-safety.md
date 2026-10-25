# Google Play — Data safety (draft)

Answers derived from the code on 2026-09-28. Status: **draft, for the client and counsel**.

**Saved in Play Console on 2026-10-25** (App content → Data safety, not yet sent for review). What
was saved differs from this draft in four places; the form is the record, and this file keeps the
reasoning:

- **Contacts: collected.** A trusted contact is a name and a phone number the user types in
  (`trusted_contacts`, up to five). That is data about another person, so it is declared, as optional,
  for app functionality. The app never reads the phone's contact list, which is what the privacy
  policy now says.
- **Files and docs: collected**, optional, for fraud prevention: identity and police-clearance
  documents uploaded to `kyc-docs`.
- **Device or other IDs: collected**, for fraud prevention: the device-integrity verdicts and the
  per-handset signals the risk sweep uses.
- **Name and email are optional** (a customer may leave the name blank and may sign in by phone).
  Name, email and user IDs are for app functionality and account management. Phone number is for
  fraud prevention and account management.

Unchanged: nothing is shared, nothing is ephemeral, data is encrypted in transit, and deletion is
at `https://suskiierrand.com/en/delete-account` (no partial deletion offered). The listing shows "No
data shared with third parties" and links the privacy policy at `/en/legal/privacy`.

## Overview answers

| Question | Draft answer | Basis |
|---|---|---|
| Does the app collect or share any of the required user data types? | Yes | Below |
| Is all user data encrypted in transit? | Yes | HTTPS only (network security config; Supabase over TLS) |
| Do you provide a way for users to request that their data is deleted? | Yes — in the app, on the web, and at `https://<host>/<locale>/delete-account` | `request_account_deletion`; RB-15 §2 |
| Has the app undergone an independent security review (MASA)? | No | The external penetration test is timeline row 20 |
| Is the app directed at children? | No | Terms set an adult minimum age (counsel, OD-24) |

## Sharing

**Draft answer: no data is "shared"** in Play's sense. Every third party below processes data on
Suskii's behalf (a service provider, which Play does not count as sharing), or receives it because
the user asked for it to be sent (which Play also excludes):

| Recipient | What | Why it is not sharing | Confirm |
|---|---|---|---|
| Payment gateway (Flutterwave / Paystack) | The amount and a reference; card or bank details are entered on the gateway's own page, never in the app | Service provider; the app does not collect payment details | Client, counsel |
| Identity vendor (when contracted) | ID number, document photos, selfie | Service provider for verification | Counsel, once the vendor contract exists |
| The other party to a job | Name, rating, pickup and drop-off, messages, live position during the job | Inherent to the service the user requested | — |
| Trusted contacts, via a trip link | The trip's route and status | User-initiated | — |
| SOS partner (when contracted) | Position and job details during an SOS | User-initiated emergency | Counsel |

## Data collected

| Category → type | Collected | Optional? | Purposes | Where in the code |
|---|---|---|---|---|
| Personal info → Name | Yes | Required for providers; customers may leave it blank | App functionality; Account management | `profiles.display_name` |
| Personal info → Email address | Yes, if the person signs in with email | Optional (phone is the alternative) | Account management | Supabase Auth |
| Personal info → Phone number | Yes, if the person signs in with a phone number | Optional (email is the alternative) | Account management; Fraud prevention, security and compliance | Supabase Auth |
| Personal info → User IDs | Yes | Required | Account management | Account id |
| Personal info → Address | Yes (pickup and drop-off descriptions, landmarks) | Required to post an errand | App functionality | `requests` |
| Personal info → Other info | Yes (government ID number, for identity verification) | Required for providers; for customers only when a limit requires it | Fraud prevention, security and compliance | `submit_id_lookup`, `kyc` schema |
| Financial info → Purchase history | Yes (jobs, payments, refunds, tips) | Required | App functionality | `payments`, ledger |
| Financial info → Other financial info | Yes (payout bank account, for providers) | Required for providers to be paid | App functionality | `payout_accounts` (encrypted) |
| Location → Precise location | Yes: a customer's pickup point when they tap "use my location"; an online provider's position every 45 s while the app is open (matching, `heartbeat`); the provider's position when marking arrival and the live trail during an active job; Suskii Meet's distance sort (not stored) | Optional — the pickup can be set on the map by hand, a provider may refuse and confirm arrival manually | App functionality; Fraud prevention, security and compliance | `create_request`, `heartbeat`, `set_job_status`, `location_samples` |
| Location → Approximate location | Yes (2026-10-24): the **country** a new account is created in, inferred on the device from the mobile network, the SIM, the time zone or the region setting, with no permission, and sent once at sign-up. `VERIFY-IN-RESEARCH` whether a country-level inference counts as approximate location in Play's definition; declaring it is the conservative answer, and costs nothing because precise location is declared anyway | Required (it decides which country's rules apply) | App functionality | `lib/app/device_country.dart`, `profiles.country_code` |
| Messages → Other in-app messages | Yes (job chat) | Optional | App functionality | `messages` |
| Photos and videos → Photos | Yes (ID documents, receipts, proof of delivery, request photos) | Required for some steps (KYC, proof) | App functionality; Fraud prevention, security and compliance | storage buckets |
| App activity → Other user-generated content | Yes (errand descriptions, ratings and reviews, support tickets, disputes) | Optional per feature | App functionality | various |
| App info and performance → Crash logs | Yes, when Sentry is configured | Collected automatically | Analytics; App functionality | `crash_reporting.dart` (no user id, no request bodies) |
| App info and performance → Diagnostics | Same as crash logs | | | |

**Not collected:** the phone's contact list (trusted contacts are typed in; see above), calendar, SMS, call logs, installed apps, web history, health,
advertising ID, audio (until calls and the voice concierge exist), background location.

**Ephemeral processing:** none claimed; every item above is stored.

## Declarations elsewhere in App content

- **Precise location** (enforced from 27 Jan 2027 [V] REPORT §10): core function, foreground
  only — matching a request to the nearest online providers (their position while online), the
  customer's pickup point, the arrival check and live tracking during an active job.
- **Account deletion URL**: `https://<host>/en/delete-account`.
- **Target audience and content**: adults; user-generated content with reporting and moderation
  (`reports`, `moderation_cases`).
- **Financial features**: the app takes payments for services through a licensed gateway and
  holds funds until completion — "held", never "escrow" (ADR-0002). Counsel confirms the
  declaration wording with OD-12.
  **Saved 2026-10-25** as *Mobile payments and digital wallets* (the provider's earnings balance
  and withdrawals, and payments held until completion) plus *Rewards, points, frequent flier
  miles, and other incentives* (cash referral rewards and promo codes). It is not *Money transfer*,
  because users cannot send money to each other. Play asked for no documents for either feature.
  This is provisional until counsel answers OD-12. Declaring "no financial features" would have
  certified something untrue.
