# ADR-0018 — Field-level encryption inside the database: a Vault-held KEK and wrapped data keys

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-29 |
| Deciders | Claude Code |
| Unblocked by | — |
| Related | [ADR-0007](0007-encryption-without-pgsodium.md) (made concrete here, not superseded), [RB-16](../runbooks/RB-16-field-encryption-keys.md), migration `20260929120000_field_encryption.sql` |

## Context

ADR-0007 decided the shape of field-level encryption:
- application envelope encryption, with a data key per record class wrapped by a key held in a secret manager;
- encryption and decryption inside vetted `SECURITY DEFINER` functions or Edge Functions, never in a client;
- no pgsodium.

Nothing had implemented it. Every `*_ciphertext` column in the schema (`trusted_contacts`, `kyc`, `payout_accounts`, `organizations`, `vehicles`) expects bytes "produced outside the database". No client can produce them, because shipping the key to a phone is the option ADR-0007 rejects. So those four features cannot be used honestly. Kimi filed it twice (CR-20260923-06 and -08), and audit Y.19 is blocked on it. The access note specified in RLS matrix §2 could not be built at all, because revealing a note means decrypting it.

What is available in every Supabase project, locally and in CI:
- `supabase_vault` 0.3.1 [V: `pg_extension` on the local stack]. Vault stores secrets encrypted under a root key held outside the database, and a migration's owner (`postgres`) can create and read them.
- `pgcrypto` [V: the foundation migration installs it]. It offers AES-CBC and HMAC but no AEAD mode, and its PGP functions authenticate with SHA-1.

GCP KMS, which the payments worker names for payout accounts, needs GCP billing (timeline action 1), which does not exist.

## Decision

We will encrypt sensitive fields **inside the database**, with this key hierarchy:

1. **KEK**: 32 random bytes in a Vault secret named `suskii_field_kek_v<n>`. `private.field_keks` records which version is current and the secret's name, never the key. The migration creates `v1` with random bytes if the secret is absent. An environment whose data must survive losing its project creates the secret first, from a value escrowed in GCP Secret Manager, and the migration keeps it (RB-16).
2. **Data keys**: one per record class and version (`access_note` first). They are stored in `private.field_data_keys`, wrapped by the KEK, and bound to their class and version. A class exists only once a migration calls `private.create_field_data_key(class)`, so a misspelt class fails rather than silently becoming a new one.
3. **The seal**: encrypt-then-MAC in the Fernet layout.
   - Keys: AES-256-CBC with PKCS#7 padding, and HMAC-SHA-256, under separate keys derived from the data key by HMAC.
   - Blob: `0x01 | data-key version | IV | ciphertext | tag`.
   - MAC input: the length-prefixed associated data `class|context` plus the IV and ciphertext. The context is the row's identity, so a ciphertext copied to another row, or read as another class, fails with `ERR_CIPHERTEXT_INVALID`.
4. **The API** is `private.seal(class, plaintext, context)` and `private.open(class, blob, context)`. They are granted to no role, `service_role` included. Only `SECURITY DEFINER` functions owned by the migration role call them, and each of those functions decides who may see the plaintext.
5. **Rotation is re-wrapping**, as ADR-0007 requires:
   - `private.rotate_field_kek()` creates a new KEK and re-wraps every data key in one transaction. No ciphertext is touched.
   - `private.create_field_data_key(class)` adds a new version, which new seals use. Old versions stay readable, because each blob names its version.

Blind indexes (keyed HMAC for lookups) are not part of this change. They arrive with the first class that needs a lookup (CR-06 phone numbers, CR-08 identity numbers), under a separate key, so a KEK rotation never forces a re-index.

## Consequences

**Good:**
- The server can finally hold a secret it must read (access notes now; trusted-contact phones, KYC numbers and payout accounts next) without any client holding a key.
- A database dump alone does not open anything, because the KEK is under Vault's root key outside the database.
- Rotation is a single function call.
- Every decryption happens in a function that states who may see the result.

**Bad / costs:**
- **The key is in the same trust domain as the data at run time.** Anyone who can run SQL as `postgres` can call `private.open`, so this protects against dumps, backups, logs and client roles, not against a compromised database owner. KMS would narrow that, at the cost of every decryption becoming a network call from an Edge Function. Payout account numbers are the class where that trade may go the other way, because the payments worker must hold the number at transfer time anyway. That class is decided with the payouts work; this ADR does not change the payments worker's plan.
- **Restoring a dump into another project restores ciphertext nobody can open**, unless the KEK was escrowed. RB-16 makes escrow a step before production data exists, and it depends on GCP Secret Manager (action 1).
- We own the construction and its tests (`49_field_encryption_test.sql`). The HMAC comparison is not constant-time. There is nothing to time, because only these functions ever write ciphertext; clients never supply it.

**Follow-on work:**
- Plaintext variants of `add_trusted_contact`, `submit_identity_document`, `submit_police_clearance`, `register_organization` and `register_vehicle` that seal server-side (CR-06, CR-08, audit Y.19), each with its own class and, where a lookup is needed, a blind index.
- Escrow of `suskii_field_kek_v1` per environment (RB-16).

## Alternatives considered

| Option | Why not |
|---|---|
| Keep "ciphertext produced outside the database" | Nobody can produce it: clients must not hold the key, and no Edge Function did. It left five features unusable |
| An Edge Function that encrypts with a key from its environment | Moves the key out of Vault into a function secret with no rotation story, and makes every write a round trip. It does not reduce who can decrypt |
| GCP KMS as the KEK now | Needs GCP billing (action 1). The hierarchy here keeps the same shape, so switching the KEK to KMS later means re-wrapping the data keys, not re-encrypting rows |
| pgcrypto `pgp_sym_encrypt` | Authenticates with SHA-1 (MDC), and the S2K step derives keys from a passphrase that is already a random key. Encrypt-then-MAC with HMAC-SHA-256 is the stronger construction for the same effort |
| pgsodium / Transparent Column Encryption | Ruled out by ADR-0007 (pending deprecation) |

## Revisit when

- GCP billing exists and KMS is available: consider a KMS-held KEK for the classes a compromised database owner must not read.
- Supabase ships a supported column-encryption successor.
- A country requires in-country key custody.
