# RB-16 — Field-encryption keys: escrow, rotation, a missing key, a failed integrity check

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | Routine rotation and escrow: none. `ERR_ENCRYPTION_KEY_UNAVAILABLE` in production: SEV2 (the features that seal or open stop working). `ERR_CIPHERTEXT_INVALID`: SEV1 security incident (RB-01, and RB-07 if personal data could be read) |
| Last rehearsed | **Not yet.** Rehearse escrow, rotation and a cross-project restore on staging before any real access note exists |
| Related | [ADR-0018](../adr/0018-field-encryption-in-the-database.md), [ADR-0007](../adr/0007-encryption-without-pgsodium.md), [RB-10](RB-10-key-rotation.md) (inventory), [RB-09](RB-09-backup-restore.md) (restore), migration `20260929120000_field_encryption.sql` |

## What exists

| Thing | Where | Notes |
|---|---|---|
| KEK `suskii_field_kek_v<n>` | Supabase Vault (`vault.secrets`), encrypted under Vault's root key outside the database | 64 hex characters (32 bytes). `private.field_keks` names the current one |
| Data keys | `private.field_data_keys`, wrapped by the KEK | One per `(class, version)`. Classes today: `access_note` |
| Sealed fields | `saved_places.access_note_ciphertext`, `private.request_access_notes.ciphertext` | Each blob names its data-key version |

Nothing outside the database needs a key, and no client role can execute `private.seal` or `private.open`.

## 1. Escrow the KEK (once per environment, before real data)

A Vault secret is readable only inside its own project. **Restoring a dump into a different project (RB-09 into a fresh project, or a region move) restores ciphertext that nobody can open**, unless the KEK is escrowed. Do this for staging and production before the first real user. It needs GCP Secret Manager, which needs GCP billing (timeline action 1).

- **New environment (preferred).** Generate the key outside the database and create the secret *before* the first `db push`. The migration keeps an existing `suskii_field_kek_v1` and does not create one:
  ```bash
  KEK=$(openssl rand -hex 32)
  printf %s "$KEK" | gcloud secrets create suskii-field-kek-v1 --data-file=- --project <env-project>
  psql "$DB_URL" -c "select vault.create_secret('$KEK', 'suskii_field_kek_v1', 'Field-encryption KEK (ADR-0018)')"
  unset KEK
  ```
- **Existing environment.** Read it once as `postgres` and store it in Secret Manager:
  `select decrypted_secret from vault.decrypted_secrets where name = 'suskii_field_kek_v1'`
  Never paste it into a ticket, a chat or a shell history that is kept.

After a restore into another project: create the same Vault secret there (same name, same value, from Secret Manager) **before** anything calls `private.seal`. Then check with `select private.field_kek(1) is not null`.

## 2. Rotate the KEK (yearly, or at once on suspected exposure)

```sql
select private.rotate_field_kek();   -- returns the new version, e.g. 2
```

This creates `suskii_field_kek_v<new>` in Vault, re-wraps every data key under it in one transaction, retires the old version and writes `field_kek.rotated` to `audit.log`. No ciphertext changes.

Then:
1. Escrow the new version (section 1, "existing environment"). Rotation creates a KEK that exists only in Vault until you do.
2. Verify: `select class, version, kek_version from private.field_data_keys` shows the new version everywhere, and a known note still opens through the app.
3. Only then remove the old Vault entry: `delete from vault.secrets where name = 'suskii_field_kek_v<old>'`. Keep the escrowed copy until the next backup that postdates the rotation has been verified (RB-09), because older backups still need it.

**Backout.** If the call fails, its transaction rolled back and nothing changed. If it committed and the new KEK turns out to be unusable (for example, escrow failed and the Vault entry was damaged), the old KEK is still in Vault because step 3 has not happened yet. Restore the new entry from wherever it can be read, or rotate again with `rotate_field_kek()`, which re-wraps from whatever is current. Never hand-edit `private.field_data_keys`.

## 3. Rotate a data key (when a class's key may have been exposed)

```sql
select private.create_field_data_key('access_note');   -- new version for new seals
```

Old blobs keep opening under their version. To retire an old version completely, re-seal its rows (open, seal) in a migration written for that purpose, then delete the old row from `private.field_data_keys`. That is rarely worth doing: a data key is only ever usable together with the KEK that wraps it.

## 4. `ERR_ENCRYPTION_KEY_UNAVAILABLE`

**Symptoms.** Saving a place with a note, setting a request's note or revealing one fails. Function logs show the code. Features that do not seal are unaffected.

**Diagnosis.**
- `select * from private.field_keks` shows the current KEK's `secret_name`.
- `select name from vault.secrets where name like 'suskii_field_kek_%'` shows whether that secret exists.
- If the secret exists, check it is 64 hex characters (a pasted value with a newline fails the check).
- `select class, max(version) from private.field_data_keys group by class` shows whether the class has a data key.

**Fix.** Restore the Vault secret from escrow (section 1). If the class has no data key, the migration that introduced the class did not run; apply it. **Never generate a new KEK to "fix" a missing one**: every existing data key is wrapped by the lost one, so a new KEK opens nothing.

**If the KEK is lost and was never escrowed**, every sealed field in that environment is unrecoverable. Access notes are re-entered by customers (they are short-lived by design). For any future class that holds something the platform must keep, such as identity or payout numbers, this is an RB-07 assessment and a user communication, not an ops fix.

## 5. `ERR_CIPHERTEXT_INVALID`

Only the database's own functions write ciphertext. A blob that fails its integrity check was therefore altered, truncated, or copied onto a row it was not sealed for. **Treat it as a security incident (RB-01):**
1. Record which table and row (the function that raised it names the class; the request or place id is its context).
2. Check `audit.log` and the Postgres logs for direct writes to that table by anything other than the sealing functions.
3. If other rows are affected, assume the database owner role is compromised and start RB-07.

Do not "fix" the row by re-sealing a guess.

## Communication

- Rotation: none externally.
- Lost KEK: customers whose notes are gone see an empty note and re-enter it. Say so in the app release notes if many are affected.
- Integrity failure: RB-01 comms.
