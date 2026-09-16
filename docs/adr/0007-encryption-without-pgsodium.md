# ADR-0007 — Field-level encryption with Vault and application envelope encryption, not pgsodium

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | — |

## Context

The spec requires field-level encryption for ID numbers, payout details, certificate numbers and access notes, with blind indexes for lookups, and names "Vault/pgsodium or application-level envelope encryption" as options.

Supabase documents pgsodium as **pending deprecation** and recommends Vault instead; Transparent Column Encryption is explicitly not recommended [V]. Vault itself is unaffected and its API is stable [V].

## Decision

We will not use pgsodium or Transparent Column Encryption anywhere. Secrets (vendor keys, webhook secrets, signing keys) live in Supabase Vault and GCP Secret Manager. Sensitive columns are encrypted with application-level envelope encryption: a data key per record class, wrapped by a key held in the secret manager, with encrypt and decrypt happening inside vetted `SECURITY DEFINER` functions or Edge Functions rather than in clients. Lookups use deterministic blind-index columns (keyed HMAC), never the ciphertext. Key rotation is a documented runbook with re-wrapping, not re-encryption of every row.

## Consequences

**Good:** no dependency on a deprecating extension; keys live outside the database, so a database dump alone does not reveal plaintext; rotation is explicit.

**Bad / costs:** we own the crypto envelope code and its tests; encrypted columns cannot be searched except through blind indexes, so query patterns must be designed up front.

**Follow-on work:** key hierarchy and rotation runbook; blind-index design per lookup (phone, ID number, payout account); pgTAP tests proving clients cannot read plaintext columns.

## Alternatives considered

| Option | Why not |
|---|---|
| pgsodium TCE | Pending deprecation; Supabase advises against it |
| Rely on disk encryption only | Does not protect against application-level or role-level exposure |
| Encrypt in the client | Key distribution to mobile clients is unsafe; the server must read these values for verification and payouts |

## Revisit when

Supabase ships a supported successor for column encryption, or a country requires a specific key-custody model (for example an in-country HSM).
