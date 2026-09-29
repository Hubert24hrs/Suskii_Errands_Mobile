-- Field-level encryption inside the database (ADR-0018, making ADR-0007 concrete).
--
-- ADR-0007 decided the shape: application envelope encryption, a data key per record class
-- wrapped by a key held in a secret manager, encrypt and decrypt inside vetted SECURITY DEFINER
-- functions, never in a client, and no pgsodium. Until now nothing implemented it. Every
-- `*_ciphertext` column expected bytes "produced outside the database", and no client can
-- produce them, because giving a phone the key is the thing ADR-0007 rules out. That is why
-- CR-20260923-06 and -08 are open, and why an access note could not be built at all.
--
-- The hierarchy:
--
--   Vault secret `suskii_field_kek_v<n>`   the key-encryption key (KEK), 32 random bytes. Vault
--                                          stores it encrypted under a root key that lives
--                                          outside the database, so a dump does not contain it
--   private.field_data_keys                one data key per (class, version), wrapped by a KEK
--   the ciphertext on a row                sealed with its class's data key
--
-- Rotation is re-wrapping, as ADR-0007 requires: a new KEK re-wraps the few data-key rows and
-- touches no ciphertext. A new data-key version is used for new seals, and old versions stay
-- readable, because each ciphertext names the version it was sealed with.
--
-- The seal is encrypt-then-MAC in the Fernet layout, with AES-256-CBC and HMAC-SHA-256 under keys
-- derived from the data key. pgcrypto offers no AEAD mode, and its PGP functions authenticate
-- with SHA-1. The MAC covers the class and a caller-supplied context (the row's id), so a
-- ciphertext copied onto another row does not open there.
--
--   blob = 0x01 | data-key version (int4) | IV (16) | AES-256-CBC(PKCS#7) | HMAC-SHA-256 (32)
--
-- **Where the KEK comes from.** The migration creates `suskii_field_kek_v1` with random bytes if
-- it does not already exist. An environment that must survive losing its project (production)
-- creates the secret itself first, from a value escrowed in GCP Secret Manager, and the migration
-- keeps it. Without that escrow, restoring a dump into a *different* project restores
-- ciphertext nobody can open. RB-16 is the procedure.

CREATE TABLE private.field_keks (
  version     integer PRIMARY KEY CHECK (version > 0),
  -- The name of the Vault entry. The key itself is never in a table or a migration.
  secret_name text NOT NULL UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  retired_at  timestamptz
);
-- Exactly one KEK wraps new data keys.
CREATE UNIQUE INDEX field_keks_one_current ON private.field_keks ((true)) WHERE retired_at IS NULL;

CREATE TABLE private.field_data_keys (
  class       text NOT NULL CHECK (class ~ '^[a-z][a-z0-9_]{1,39}$'),
  version     integer NOT NULL CHECK (version > 0),
  kek_version integer NOT NULL REFERENCES private.field_keks (version),
  wrapped     bytea NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (class, version)
);

REVOKE ALL ON private.field_keks, private.field_data_keys FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The construction. `p_key` is 32 bytes; the encryption and MAC keys are derived from it so
-- one key is never used for two jobs.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.crypto_seal_raw(p_key bytea, p_plain bytea, p_aad bytea)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  v_enc bytea := extensions.hmac('suskii.field.enc'::bytea, p_key, 'sha256');
  v_mac bytea := extensions.hmac('suskii.field.mac'::bytea, p_key, 'sha256');
  v_iv  bytea := extensions.gen_random_bytes(16);
  v_ct  bytea;
BEGIN
  IF p_key IS NULL OR length(p_key) <> 32 OR p_plain IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_ct := extensions.encrypt_iv(p_plain, v_enc, v_iv, 'aes-cbc/pad:pkcs');
  -- The AAD is length-prefixed so the boundary between it and the IV cannot be moved.
  RETURN v_iv || v_ct || extensions.hmac(
    int4send(length(coalesce(p_aad, ''::bytea))) || coalesce(p_aad, ''::bytea) || v_iv || v_ct,
    v_mac, 'sha256');
END $$;

CREATE FUNCTION private.crypto_open_raw(p_key bytea, p_blob bytea, p_aad bytea)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_enc bytea := extensions.hmac('suskii.field.enc'::bytea, p_key, 'sha256');
  v_mac bytea := extensions.hmac('suskii.field.mac'::bytea, p_key, 'sha256');
  v_len integer := length(p_blob);
  v_iv  bytea;
  v_ct  bytea;
BEGIN
  -- IV, at least one AES block, tag.
  IF p_key IS NULL OR length(p_key) <> 32 OR p_blob IS NULL OR v_len < 16 + 16 + 32 THEN
    RAISE EXCEPTION 'ERR_CIPHERTEXT_INVALID' USING ERRCODE = 'P0001';
  END IF;
  v_iv := substring(p_blob FROM 1 FOR 16);
  v_ct := substring(p_blob FROM 17 FOR v_len - 48);
  -- Not a constant-time comparison. Ciphertext is only ever written by these functions, never
  -- by a client, so there is no oracle to time.
  IF extensions.hmac(
       int4send(length(coalesce(p_aad, ''::bytea))) || coalesce(p_aad, ''::bytea) || v_iv || v_ct,
       v_mac, 'sha256') <> substring(p_blob FROM v_len - 31 FOR 32) THEN
    RAISE EXCEPTION 'ERR_CIPHERTEXT_INVALID' USING ERRCODE = 'P0001';
  END IF;
  RETURN extensions.decrypt_iv(v_ct, v_enc, v_iv, 'aes-cbc/pad:pkcs');
END $$;

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.field_kek(p_version integer)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hex text;
BEGIN
  SELECT s.decrypted_secret INTO v_hex
  FROM private.field_keks k
  JOIN vault.decrypted_secrets s ON s.name = k.secret_name
  WHERE k.version = p_version;
  IF v_hex IS NULL OR v_hex !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'ERR_ENCRYPTION_KEY_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  RETURN decode(v_hex, 'hex');
END $$;

CREATE FUNCTION private.field_data_key(p_class text, p_version integer)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.field_data_keys%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM private.field_data_keys d
  WHERE d.class = p_class AND d.version = p_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_ENCRYPTION_KEY_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  RETURN private.crypto_open_raw(private.field_kek(v_row.kek_version), v_row.wrapped,
    convert_to('dk|' || p_class || '|' || p_version, 'UTF8'));
END $$;

-- A new data-key version for a class, wrapped by the current KEK. Used once per class when the
-- class is introduced, and again to rotate it; earlier versions stay readable.
CREATE FUNCTION private.create_field_data_key(p_class text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_kek     integer;
  v_version integer;
BEGIN
  SELECT k.version INTO v_kek FROM private.field_keks k WHERE k.retired_at IS NULL;
  IF v_kek IS NULL THEN
    RAISE EXCEPTION 'ERR_ENCRYPTION_KEY_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  -- Serialise version numbering per class.
  PERFORM pg_advisory_xact_lock(hashtextextended('field_data_keys|' || p_class, 0));
  SELECT coalesce(max(d.version), 0) + 1 INTO v_version
  FROM private.field_data_keys d WHERE d.class = p_class;

  INSERT INTO private.field_data_keys (class, version, kek_version, wrapped)
  VALUES (p_class, v_version, v_kek,
          private.crypto_seal_raw(private.field_kek(v_kek), extensions.gen_random_bytes(32),
            convert_to('dk|' || p_class || '|' || v_version, 'UTF8')));
  RETURN v_version;
END $$;

-- A new KEK. Every data key is re-wrapped under it in the same transaction; no ciphertext is
-- touched. The old Vault entry is left in place, retired, until an operator has verified the new
-- one and removes it (RB-16), because deleting it first would make a failed rotation fatal.
CREATE FUNCTION private.rotate_field_kek()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old  integer;
  v_new  integer;
  v_name text;
  v_key  record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('field_keks', 0));
  SELECT k.version INTO v_old FROM private.field_keks k WHERE k.retired_at IS NULL;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'ERR_ENCRYPTION_KEY_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  v_new := v_old + 1;
  v_name := 'suskii_field_kek_v' || v_new;

  IF NOT EXISTS (SELECT 1 FROM vault.secrets s WHERE s.name = v_name) THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), v_name,
      'Field-encryption KEK (ADR-0018). Escrow before relying on it (RB-16).');
  END IF;
  UPDATE private.field_keks SET retired_at = now() WHERE version = v_old;
  INSERT INTO private.field_keks (version, secret_name) VALUES (v_new, v_name);

  FOR v_key IN SELECT d.class, d.version, d.kek_version FROM private.field_data_keys d LOOP
    UPDATE private.field_data_keys d
    SET kek_version = v_new,
        wrapped = private.crypto_seal_raw(
          private.field_kek(v_new),
          private.field_data_key(v_key.class, v_key.version),
          convert_to('dk|' || v_key.class || '|' || v_key.version, 'UTF8'))
    WHERE d.class = v_key.class AND d.version = v_key.version;
  END LOOP;

  PERFORM private.audit_write('field_kek.rotated', 'private.field_keks', v_new::text,
    jsonb_build_object('version', v_old), jsonb_build_object('version', v_new), NULL);
  RETURN v_new;
END $$;

-- ---------------------------------------------------------------------------
-- The two functions everything else calls. `p_context` binds the ciphertext to its row.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.seal(p_class text, p_plain text, p_context text)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_version integer;
BEGIN
  IF p_plain IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT max(d.version) INTO v_version FROM private.field_data_keys d WHERE d.class = p_class;
  IF v_version IS NULL THEN
    -- A class exists only once a migration has created its key; a typo is not a new class.
    RAISE EXCEPTION 'ERR_ENCRYPTION_KEY_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  RETURN '\x01'::bytea || int4send(v_version)
      || private.crypto_seal_raw(private.field_data_key(p_class, v_version),
           convert_to(p_plain, 'UTF8'),
           convert_to(p_class || '|' || coalesce(p_context, ''), 'UTF8'));
END $$;

CREATE FUNCTION private.open(p_class text, p_blob bytea, p_context text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_blob IS NULL THEN
    RETURN NULL;
  END IF;
  IF length(p_blob) < 5 OR get_byte(p_blob, 0) <> 1 THEN
    RAISE EXCEPTION 'ERR_CIPHERTEXT_INVALID' USING ERRCODE = 'P0001';
  END IF;
  RETURN convert_from(
    private.crypto_open_raw(
      private.field_data_key(p_class,
        (get_byte(p_blob, 1) << 24) | (get_byte(p_blob, 2) << 16)
        | (get_byte(p_blob, 3) << 8) | get_byte(p_blob, 4)),
      substring(p_blob FROM 6),
      convert_to(p_class || '|' || coalesce(p_context, ''), 'UTF8')),
    'UTF8');
END $$;

REVOKE ALL ON FUNCTION
  private.crypto_seal_raw(bytea, bytea, bytea),
  private.crypto_open_raw(bytea, bytea, bytea),
  private.field_kek(integer),
  private.field_data_key(text, integer),
  private.create_field_data_key(text),
  private.rotate_field_kek(),
  private.seal(text, text, text),
  private.open(text, bytea, text)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The first KEK. Kept when an environment created it beforehand from an escrowed value.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets s WHERE s.name = 'suskii_field_kek_v1') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
      'suskii_field_kek_v1',
      'Field-encryption KEK (ADR-0018). Escrow before production data exists (RB-16).');
  END IF;
END $$;
INSERT INTO private.field_keks (version, secret_name) VALUES (1, 'suskii_field_kek_v1');
