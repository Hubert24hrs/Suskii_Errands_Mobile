# ADR-0021 — Identity verification is for service providers; Google and Apple sign-in

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-24 |
| Deciders | Owner; Claude Code |
| Related | migration `20261024120000_customer_publish_and_social_country.sql`, `58_social_sign_up_country_test.sql` |

## Context

1. The app asked every customer to verify their identity before publishing their first request: a banner on the home screen, and a database guard in `private.do_publish_request`. The owner decided that verification is for service providers only.
2. The owner asked for Google and Apple sign-in alongside phone and email. Native sign-in (`signInWithIdToken`) carries no sign-up metadata, so `private.handle_new_user` leaves `profiles.country_code` NULL, and a profile without a country can be neither published, matched nor paid.

## Decision

1. **Customer verification is off by default, not deleted.** The guard reads `customer_verification_required` (remote config, per country, default `false`, client-visible). A country whose regulator wants it back gets it from a configuration change, not a migration. Providers are untouched: every provider path still goes through `private.is_active_provider`, which requires `provider_verification`. The customer home banner and the profile's customer-verification row are removed. The screens that react to `ERR_VERIFICATION_REQUIRED` stay, for a country that switches it on.
2. **Social sign-in.**
   - **Mobile:** the device's own SDK (`google_sign_in` 7.2, `sign_in_with_apple` 8.2) issues an ID token, and the app exchanges it with `signInWithIdToken`. Apple is given the SHA-256 of a fresh nonce, and Supabase is given the raw nonce, so a captured token cannot be replayed. Apple is offered on iOS only, where guideline 4.8 requires it alongside Google.
   - **Web:** GoTrue's OAuth redirect flow.
   - **Country:** a new account takes the country chosen before sign-in through `set_initial_country`, which sets it only while it is NULL. The same answer again is not an error; a different one is `ERR_COUNTRY_ALREADY_SET`. The country stays as fixed as it is for an OTP sign-up, because it decides currency, rules and the ledger.
   - **Configuration:** client IDs are public identifiers and come from the define file (`GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`). With them empty, the Google button explains that it is not set up rather than failing obscurely. The server side was already in `supabase/deploy/write-remote-config.sh`.

## Consequences

- **Fraud exposure.** An unverified customer can now publish and pay. The fraud controls that do not depend on KYC are unchanged: device integrity, the self-dealing and velocity sweeps, held funds and disputes. Payment risk sits with the gateway's own checks once one exists (action 4).
- **Before Google or Apple sign-in works anywhere real,** the client must provide the following (RB-15 and client action 9):
  - a Google Cloud OAuth client per platform (web, Android with the signing SHA-1, iOS);
  - an Apple Services ID and key;
  - the provider entries in each Supabase project.
