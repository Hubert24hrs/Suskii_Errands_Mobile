# RLS policy matrix

| | |
|---|---|
| Owner | Claude Code |
| Date | 2026-09-16 |
| Status | Phase 1 draft — every cell becomes a pgTAP allow **and** deny test in Phase 2 |
| Evidence | Spike [S-13](../research/spikes/S-13-results.md) (17/17 on plain Postgres); spec `security.supabase_specific` |
| Companion | [erd.md](erd.md) |

## Why this matrix has a "writable columns" dimension

S-13's headline finding: **RLS does not protect a column.** A policy decides *which rows* a user may update; it cannot stop the user rewriting `status`, `trust_level` or `agreed_amount_minor` on a row they legitimately own. Column-level `GRANT UPDATE (col, …)` does that work. A matrix that lists only policies would design this hole straight back in, so every writable table below names its writable columns explicitly. Everything not named is read-only to clients.

## Roles and how they are established

| Role | Database role | Established by | Re-checked by |
|---|---|---|---|
| Anonymous | `anon` | No JWT | — |
| User (customer and/or provider) | `authenticated` | Supabase JWT; `sub` = user id | `auth.uid()` |
| Provider (acting) | `authenticated` | Same JWT; **not a separate DB role** — mode is a UI concern, eligibility is data | `private.is_active_provider()` reads `provider_profiles` + verification |
| Job participant | `authenticated` | Relationship: customer of the request, or assigned provider/worker | `private.is_participant(request_id)` |
| Business owner / dispatcher | `authenticated` | Row in `organization_members` | `private.org_role(org_id)` |
| Admin roles (5) | `authenticated` | Custom Access Token Hook adds `admin_roles` claim | `private.has_admin_role(role)` **re-reads `admin_users` and requires `aal2`** (MFA) — the claim alone is never trusted for sensitive data (spec) |
| Backend | `service_role` | Edge Functions and Cloud Run only | `BYPASSRLS` — but still needs table grants (S-13 finding 3). Never in any client |

### Helper functions

All `STABLE`, `SECURITY DEFINER`, `SET search_path = ''`, `EXECUTE` granted to `authenticated` only.

| Function | Returns | Note |
|---|---|---|
| `auth.uid()` | `uuid` or NULL | Must `nullif` the claims GUC **before** the JSON cast, or unauthenticated calls raise `22P02` instead of returning NULL (S-13 finding 2) |
| `private.is_participant(request_id)` | boolean | Customer of the request, or `jobs.provider_id`/`worker_id` |
| `private.is_active_provider()` | boolean | Provider verified, not suspended, documents valid |
| `private.org_role(org_id)` | `business_role` or NULL | |
| `private.has_admin_role(role)` | boolean | DB re-check + `auth.jwt() ->> 'aal' = 'aal2'` |

Policies call these rather than inlining joins, so a rule changes in one place and pgTAP tests the function once.

## Legend

| Cell | Meaning |
|---|---|
| `—` | No access. Default deny: no policy exists |
| `R` | Read all rows |
| `R:own` | Read rows where the user is the subject/owner |
| `R:part` | Read rows of jobs the user participates in |
| `R:org` | Read rows belonging to the user's organisation (owner/dispatcher) |
| `R:scope` | Read rows within the admin's country/assignment scope |
| `I:own` | Insert rows owned by the user (`WITH CHECK` on ownership) |
| `U:own(cols)` | Update own rows, **only the listed columns** (column grant) |
| `F` | No direct write; via a named `SECURITY DEFINER` function only |

Every table below has `ENABLE ROW LEVEL SECURITY` **and** `FORCE ROW LEVEL SECURITY` (S-13 finding 5).

---

## 1. Reference and configuration

| Table | anon | User | Support | Verification | Finance | Dispute | Super admin |
|---|---|---|---|---|---|---|---|
| `currencies` | R | R | R | R | R | R | R + F |
| `countries` | — | — | R | R | R | R | R + F (four-eyes) |
| `cities`, `zones` | R | R | R | R | R | R | R + F |
| `service_categories` | R | R | R | R | R | R | R + F |
| `category_country_settings` | — | R | R | R | R | R | R + F |
| `feature_flags` | — | — | R | R | R | R | R + F (four-eyes) |
| `legal_documents` | R | R | R | R | R | R | R + F |
| `prohibited_items`, `price_bands` | — | — | R | — | — | R | R + F |

Clients get country configuration through `get_bootstrap()`, which returns the **client-safe subset** — not by selecting `countries`, whose `config` holds vendor routing and thresholds (draft review 1.7).

## 2. Identity and relationships

| Table | anon | User | Participant | Support | Verification | Finance | Dispute | Super admin |
|---|---|---|---|---|---|---|---|---|
| `profiles` | — | R:own, **U:own(`display_name`, `language`, `avatar_path`)** | R (public card fields via `get_provider_card()` only) | R:scope | R:scope | R:scope | R:scope | R |
| `user_devices` | — | R:own, F (`register_device`) | — | R:scope | — | — | — | R |
| `consents` | — | R:own, F (`record_consent`) — append-only | — | R:scope | R:scope | — | — | R |
| `blocks` | — | R:own, I:own, delete own | — | R:scope | — | — | — | R |
| `favorites` | — | R:own, I:own, delete own | — | — | — | — | — | R |
| `trusted_contacts` | — | R:own, I:own (max 5 by trigger), **U:own(`name`)**, delete own | — | — | — | — | — | — |
| `saved_places` | — | R:own, I:own, **U:own(`label`, `point`, `landmark_note`)**, delete own; access note via F only | access note via `reveal_access_note(request_id)` for the assigned provider **during an active job only** | — | — | — | — | — |
| `notification_preferences` | — | R:own, I:own, **U:own(`enabled`, `quiet_start`, `quiet_end`)** | — | R:scope | — | — | — | R |
| `admin_users` | — | — | — | — | — | — | — | R + F (four-eyes) |

`profiles.customer_verification`, `provider_verification`, `trust_level` and `active_mode` have **no client grant**. `active_mode` changes through `set_active_mode()`. Super admin deliberately has no read on `trusted_contacts` and `saved_places`: nobody operates on them, so nobody sees them.

## 3. Providers, businesses and fleets

| Table | anon | User | Participant | Org owner / dispatcher | Support | Verification | Super admin |
|---|---|---|---|---|---|---|---|
| `provider_profiles` | — | R:own, **U:own(`bio`)**; `online` via F (`set_online` — selfie check, documents, busy-as-customer) | public card via F | R:org | R:scope | R:scope | R |
| `provider_services`, `provider_service_areas` | — | R:own, F (`update_services`) | — | R:org | R:scope | R:scope | R |
| `provider_live_location` | — | F only (`heartbeat`, movement-gated) | position of **own assigned provider** during active job via Broadcast, not select | fleet map via F (`org_fleet_positions`) | — | — | — |
| `availability_schedules` | — | R:own, I:own, **U:own(`weekday`, `start_time`, `end_time`)**, delete own | — | R:org | — | — | R |
| `organizations` | — | R (members) | public name via card | R:org, **U:org-owner(`legal_name`)** before verification only | R:scope | R:scope | R |
| `organization_members` | — | R:own | — | R:org, F (`invite_member`, `set_member_role`) | R:scope | R:scope | R |
| `vehicles` | — | R:own, F (`register_vehicle`) | vehicle type/colour via job snapshot | R:org, F | R:scope | R:scope | R |

No human reads `provider_live_location` directly — not even super admin. Live position is personal location data (DPIA); ops sees it only through the SOS console for an open incident.

## 4. Verification and KYC — schema `kyc`, not exposed

No role has table privileges on `kyc.*`. The matrix is expressed as **functions**.

| Function | User | Verification Officer | Support | Super admin |
|---|---|---|---|---|
| `start_verification_session(kind)` / `submit_kyc_step(kind, input)` | own | — | — | — |
| `get_my_verification()` / `get_my_kyc_profile()` → outcomes + reason keys | own | — | — | — |
| `resolve_payout_account(input)` → `name_match` | own | — | — | — |
| `review_queue()` | — | scope | — | — |
| `decide_kyc_step(step_id, decision, reason_key)` | — | scope; **writes `audit.log`** | — | — |
| `get_document_url(upload_ref, reason_code)` → signed URL ≤ 5 min | — | scope; **writes `audit.kyc_access`** | — | — |
| `verification_summary(user_id)` — status only, no documents | — | scope | scope | yes |

**Deny cases that must have tests:** a user reading their own uploaded document (upload-only bucket — denied, spec); support viewing any document; a Verification Officer deciding their *own* KYC; a signed URL used after expiry.

## 5. Marketplace

| Table | anon | Customer (own request) | Provider | Participant | Support | Dispute | Super admin |
|---|---|---|---|---|---|---|---|
| `requests` | — | R:own; I:own **as `draft` only**; **U:own(`description`, `pickup_*`, `destination_*`, `scheduled_at`, `preferred_price_minor`, `urgency`) `WITH CHECK (status = 'draft')`**; everything else F | open requests matched to them via F (`provider_feed`, PostGIS) — never a table select, so a provider cannot enumerate all requests | R:part | R:scope | R:scope | R |
| `request_media` | — | R:own, F (`attach_media`) | via feed card | R:part | R:scope | R:scope | R |
| `offer_threads` | — | R:own-request | R:own-thread | — | R:scope | R:scope | R |
| `offers` | — | R:own-request (all threads); F (`accept_offer`, `decline_offer`, `counter_offer`) | **R:own-thread only**; F (`create_offer`, `counter_offer`, `withdraw_offer`) | — | R:scope | R:scope | R |
| `jobs` | — | R:part | R:part | R:part — **except `pickup_pin_hash`/`delivery_pin_hash`, which no role selects** | R:scope | R:scope | R |
| `proofs` | — | R:part | F (`submit_proof`) | R:part (display path only) | R:scope | R:scope | R |
| `ratings` | — | R (published, moderated); F (`rate_job`) | R (published); F | R:own-given | R:scope | R:scope | R |
| `reports` | — | I:own via F (`report_user`); R:own | same | — | R:scope + F | R:scope | R |

The competitive invariant: **a provider never reads another provider's offer amount.** Enforced at two layers — `offers` RLS limits providers to their own thread, and the realtime channel carrying offers is per-provider private (§9). Neither relies on the client choosing not to render.

## 6. Money

`ledger.*` has no client or staff table access. `public` money tables are read-only to clients.

| Table / function | User | Participant | Support | Finance | Dispute | Super admin |
|---|---|---|---|---|---|---|
| `payments` | R:own (customer) | R:part (status, amount) | R:scope | R + F (`reconcile`) | R:scope | R |
| `refunds` | R:own | R:part | R:scope | R + F (`approve_refund`) | R + F (`resolve_dispute` creates) | R |
| `payouts` | R:own (beneficiary) | — | R:scope | R + F (`approve_payout`, four-eyes above threshold) | — | R |
| `withdrawals` | R:own, F (`request_withdrawal` — KYC, name match, min balance, biometric/PIN confirm on device, integrity token) | — | R:scope | R + F (approve) | — | R |
| `tips` | R:own, F (`add_tip`) | R:part | R:scope | R | R:scope | R |
| `promo_codes` | via F (`validate_promo`) | — | R | R | — | R + F (four-eyes) |
| `promo_redemptions` | R:own | — | R:scope | R | — | R |
| `webhook_events` | — | — | — | R | — | R |
| `get_wallet()` → balances + history | own | — | scope | scope | — | yes |
| `get_price_breakdown(request_id)` | own/part | part | scope | scope | scope | yes |

**Four-eyes** (spec): `approvals.approved_by <> requested_by` is a table `CHECK`, so it holds even if a function has a bug. Applies to payouts and withdrawals above the country threshold, commission changes, country-pack changes, promo budgets and admin role grants.

## 7. Referrals

| Table / function | User | Finance | Support | Super admin |
|---|---|---|---|---|
| `referral_codes` | R:own, F (`get_or_create_referral_code`) | R | R:scope | R |
| `referral_attributions` | R:own-as-referrer (referee **display name only**, never contact details) | R | R:scope | R |
| `referral_commissions` | R:own | R + F (`release`, `reverse`) | R:scope | R |
| `referral_campaigns` | via F (active campaign for my country) | R | R | R + F (four-eyes) |
| `fraud_flags` | — | R + F (review) | R:scope | R |
| `attribute_referral(code)` | own, **before first job only** (spec) | — | — | — |

## 8. Communication

| Table | User | Participant | Support | Dispute | Super admin |
|---|---|---|---|---|---|
| `conversations` | — | R:part | R:scope (ticket-linked only) | R:scope (dispute-linked) | R |
| `messages` | — | R:part; F (`send_message` — moderation first, then insert) | R:scope (ticket-linked only) | R:scope (evidence) | R |
| `message_reads` | — | R:part, **U:own(`last_read_message_id`, `read_at`)** | — | — | — |
| `calls` | — | R:part (metadata); F (`start_call` → LiveKit token, participants only, job window only) | R:scope | R:scope (evidence) | R |
| `masked_numbers` | — | F (`request_pstn_fallback`) | — | — | R |
| `notifications` | R:own, **U:own(`read_at`)** | — | R:scope | — | R |

Support reads a conversation only when a ticket references it, not by browsing. That is a data-minimisation control the DPIA relies on.

## 9. Tracking, history, safety, disputes, support

| Table / function | User | Participant | Support | Dispute | Super admin (ops) |
|---|---|---|---|---|---|
| `location_samples` | — | R:part (own job trail, post-completion) | — | R:scope (evidence) | R |
| `job_events` | — | R:part | R:scope | R:scope | R |
| `sos_incidents` | F (`raise_sos`) | R:part | R (ops console) + F (`ack`, `escalate`, `resolve`) | — | R |
| `sos_partners` | — | — | R (name, phone) | — | R + F |
| `trip_share_links` | R:own, F (`create_trip_share`, `revoke`) | — | — | — | R |
| `get_shared_trip(token)` | **anon** with valid, unexpired, unrevoked token — the one intentional anon read | — | — | — | — |
| `disputes` | R:own, F (`open_dispute`) | R:part | R:scope | R + F (`assign`, `resolve`) | R |
| `dispute_evidence` | F (`submit_evidence`) | R:part (own submissions) | R:scope | R | R |
| `support_tickets`, `ticket_messages` | R:own, F (`open_ticket`, `reply`) | — | R + F | R:scope | R |

## 10. Platform internals

| Object | Access |
|---|---|
| `private.idempotency_keys`, `private.outbox` | No role. Written only inside `SECURITY DEFINER` functions |
| `approvals` | Requester R:own; approvers R:scope + F (`approve`); `CHECK (approved_by <> requested_by)` |
| `ai_conversations`, `ai_messages` | User R:own (conversation list, redacted content); support R:scope (ticket-linked) |
| `audit.log`, `audit.kyc_access` | Super admin R via F (`audit_search`). **No role has `UPDATE` or `DELETE`, including `service_role`** — revoked explicitly, so the hash chain cannot be rewritten through the API |

## Storage bucket policies

| Bucket | Client upload | Client read | Staff read |
|---|---|---|---|
| `avatars` | own path, image types, ≤ 2 MB | public | — |
| `request-media` | own request, draft or open | participants + matched providers (via signed URL from feed) | support/dispute scope |
| `chat-media` | participants, via `send_message` path | participants | support/dispute scope |
| `proofs` | assigned provider, active job | participants (EXIF-stripped rendition only) | dispute scope |
| `receipts` | assigned provider, item-float jobs | participants | finance, dispute scope |
| `kyc-docs` | **own path via signed upload URL** | **none — no client read policy exists** (spec) | Verification Officer via `get_document_url`, audited |

All uploads: size and MIME limits per bucket, malware scan and image re-encode before the file becomes readable (spec).

## Realtime channel authorisation (RLS on `realtime.messages`)

| Channel topic | Who may join | Carries |
|---|---|---|
| `user:{user_id}` | that user | notifications, wallet updates, job banner |
| `request:{request_id}:customer` | the customer | offer summaries from **all** providers, status changes |
| `request:{request_id}:provider:{provider_id}` | that provider | **their own thread only** — never a rival's amount |
| `job:{request_id}` | participants, from `assigned` until completion | live location (Broadcast), typing, call events, status |
| `ops:sos` | super admin (ops) | SOS queue |
| `org:{org_id}:fleet` | owner/dispatcher | fleet positions, dispatch events |

All channels are private (`private: true`); public channels are not used anywhere.

> **Built 2026-09-18** as `private.may_join_topic(topic)`, with SELECT and INSERT policies on
> `realtime.messages` that call it. `user`, `request:*:customer`, `request:*:provider:*`, `job:*`
> and `ops:sos` are implemented; `org:*:fleet` waits for the organisations table. Two deviations
> from the table above, both recorded here rather than silently: `message_reads` moves through
> `mark_read()` instead of the column grant, because a column grant cannot create the row it
> updates and no client may insert one; and the marker never moves backwards, so two devices
> reading the same conversation cannot make the unread badge flicker.


## pgTAP obligations

For each table: one **allow** test per non-`—` cell and one **deny** test per role that is `—`, asserted by SQLSTATE (S-13 method). Plus these named deny tests, each of which maps to a spec rule or a spike finding:

| Test | Rule |
|---|---|
| User updates own `trust_level` → `42501` | S-13 finding 1 |
| Customer updates `requests.status` / `agreed_amount_minor` → `42501` | State and money server-owned |
| Customer edits a request after `draft` → denied by `WITH CHECK` | Drafts only |
| Provider selects another provider's offer → 0 rows | Competitive invariant |
| Provider selects all open requests by table → 0 rows | Feed only via matching |
| Anyone selects `jobs.pickup_pin_hash` → `42501` | PIN secrecy |
| User reads own `kyc-docs` object → denied | Upload-only bucket |
| Support reads a conversation with no linked ticket → 0 rows | Data minimisation |
| Approver approves own request → `CHECK` violation | Four eyes |
| `service_role` updates `audit.log` → `42501` | Hash chain integrity |
| Unauthenticated call to any F → `28000`, not `22P02` | S-13 finding 2 |
| Admin claim present but `aal1` → denied | MFA mandatory for admins |
