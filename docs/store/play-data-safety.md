# Google Play — Data safety (draft)

Answers derived from the code on 2026-09-28. Status: **draft, for the client and counsel**.

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
| Location → Precise location | Yes (provider's position when marking arrival; live trail during an active job) | Optional — a provider may refuse and confirm arrival manually | App functionality; Fraud prevention, security and compliance | `set_job_status`, `location_samples` |
| Messages → Other in-app messages | Yes (job chat) | Optional | App functionality | `messages` |
| Photos and videos → Photos | Yes (ID documents, receipts, proof of delivery, request photos) | Required for some steps (KYC, proof) | App functionality; Fraud prevention, security and compliance | storage buckets |
| App activity → Other user-generated content | Yes (errand descriptions, ratings and reviews, support tickets, disputes) | Optional per feature | App functionality | various |
| App info and performance → Crash logs | Yes, when Sentry is configured | Collected automatically | Analytics; App functionality | `crash_reporting.dart` (no user id, no request bodies) |
| App info and performance → Diagnostics | Same as crash logs | | | |

**Not collected:** contacts, calendar, SMS, call logs, installed apps, web history, health,
advertising ID, audio (until calls and the voice concierge exist), background location.

**Ephemeral processing:** none claimed; every item above is stored.

## Declarations elsewhere in App content

- **Precise location** (enforced from 27 Jan 2027 [V] REPORT §10): transactional — checked when
  a provider marks arrival; live tracking during an active job is the core function.
- **Account deletion URL**: `https://<host>/en/delete-account`.
- **Target audience and content**: adults; user-generated content with reporting and moderation
  (`reports`, `moderation_cases`).
- **Financial features**: the app takes payments for services through a licensed gateway and
  holds funds until completion — "held", never "escrow" (ADR-0002). Counsel confirms the
  declaration wording with OD-12.
