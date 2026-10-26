# Architecture Decision Records

Every major technical decision gets an ADR (spec: `agent_claude_code.output_instructions`). An ADR is short, dated, and immutable once accepted: to change a decision, write a new ADR and mark the old one `Superseded by ADR-xxxx`.

## Status values

| Status | Meaning |
|---|---|
| `Proposed` | Written, not yet ratified. Blocked on a client decision, counsel opinion or spike result |
| `Accepted` | In force. Code and contracts must follow it |
| `Superseded` | Replaced; the header names the replacement |
| `Deprecated` | No longer applies and has no replacement |

## Process

1. Copy [0000-template.md](0000-template.md) to `NNNN-short-kebab-title.md` using the next free number.
2. Fill in context, decision and consequences. Cite evidence: a `docs/research/` section, a spike result, or a vendor document.
3. Add a row to the index below.
4. `Proposed` ADRs list what unblocks them. When it arrives, flip the status and date it.

## Index

| ADR | Title | Status | Decision ref | Unblocked by |
|---|---|---|---|---|
| [0001](0001-wave-1-countries.md) | Wave-1 countries: NG live, KE/GH/ZA/UG beta | Accepted (2026-10-12, OD-07) | D-01 | — |
| [0002](0002-funds-hold-model.md) | Hold funds in our ledger, release via gateway transfers | Proposed | D-02 | Counsel (OD-12), spike S-12 |
| [0003](0003-gateway-fee-bearer.md) | Merchant bears gateway fees; allocate to the provider in the ledger | Accepted | D-03 | — |
| [0004](0004-flutterwave-v3.md) | Build on Flutterwave v3, not the v4 beta | Accepted | D-04 | — |
| [0005](0005-identity-vendor-smile-id.md) | Smile ID as the primary identity vendor | Proposed | D-05 | Spike S-05, vendor contract |
| [0006](0006-llm-model-routing.md) | Model IDs in remote config; routing chosen by evals | Accepted | D-06 | — |
| [0007](0007-encryption-without-pgsodium.md) | Vault + application envelope encryption; no pgsodium | Accepted | D-07 | — |
| [0008](0008-supabase-region.md) | Supabase region: London, provisional | Proposed | D-08 | Spike S-01 |
| [0009](0009-location-transport.md) | Realtime Broadcast for live location; sparse DB heartbeat | Accepted | D-09 | Validated by S-11 |
| [0010](0010-client-package-exclusions.md) | Client packages we will not adopt | Accepted | D-10 | — |
| [0011](0011-chart-of-accounts.md) | Extend the spec's ledger accounts with gateway assets and two expense accounts | Accepted | Phase 1 money flows | — |
| [0012](0012-ai-tools-act-as-user.md) | The AI service and voice agent act with the end user's JWT, never the service role | Accepted | Phase 1 C4 / threat model | — |
| [0013](0013-backend-foundation-before-contracts-v1.md) | Build the backend foundation before contracts v1; pre-contract migrations editable until a shared environment applies them | Accepted | Timeline §6, user approval | S-02 confirms platform assumptions |
| [0014](0014-marketplace-core-before-contracts-v1.md) | Build the marketplace core before contracts v1, on ADR-0013's terms | Accepted | Phase 2 complete, Phase 3 on the critical path | — |
| [0015](0015-environments-from-the-define-file.md) | One define file per environment drives the app on both platforms | Accepted | Store-readiness goal (2026-09-27) | First `mobile-native` / `mobile-ios` runs |
| [0016](0016-aurora-design-system.md) | "Aurora": a dark-first design system driven by one token set | Accepted | Store-readiness goal (redesign) | — |
| [0017](0017-store-identity-and-release-signing.md) | Store identity, signing and the release pipeline | Accepted | Store-readiness goal | Client confirms the app id (OD-26) |
| [0018](0018-field-encryption-in-the-database.md) | Field-level encryption inside the database: a Vault-held KEK and wrapped data keys (makes ADR-0007 concrete) | Accepted | Access notes; CR-06/CR-08; audit Y.19 | KMS once GCP billing exists (action 1) |
| [0019](0019-brand-from-the-logo.md) | The brand comes from the Suskii Errands logo: icon, in-app logo, palette (supersedes ADR-0016's palette only) | Accepted | Owner supplied the logo (2026-10-24) | Store screenshots retaken (RB-15) |
| [0020](0020-suskii-meet.md) | Suskii Meet: social meet-ups designed around who can see what | Accepted | Owner request (2026-10-24) | Client: attendee chat, paid events, age limits |
| [0021](0021-verification-for-providers-only.md) | Identity verification is for service providers; Google and Apple sign-in, with the country set once | Accepted | Owner decision (2026-10-24) | OAuth clients per platform (client action 9) |
| [0022](0022-nearest-providers-first.md) | The nearest providers first, a Google Map for the pickup, and Nigeria's 37 states as service areas | Accepted | Owner request (2026-10-24) | Maps key and billing (RB-15) |
| [0023](0023-web-hosting-on-cloudflare.md) | Host the three websites on Cloudflare (OpenNext on Workers), the admin console behind Cloudflare Access | Accepted | Owner decision (2026-10-24), infra I-2 | Domain (action 18), Cloudflare account, production backend |
| [0024](0024-concierge-as-an-edge-function.md) | Ask Suskii runs as a Supabase Edge Function calling Vertex AI (amends ai-design §3's Cloud Run placement) | Accepted | Go-live goal item 5 (2026-10-26) | Voice, which needs a long-running worker |

Decision refs D-01…D-10 come from [the Phase 0 checkpoint](../research/CHECKPOINT-PHASE-0.md#2-decisions-made). Open client decisions live in [docs/OPEN-DECISIONS.md](../OPEN-DECISIONS.md).
