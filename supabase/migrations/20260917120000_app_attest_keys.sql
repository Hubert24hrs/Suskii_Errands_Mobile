-- iOS App Attest keys (PRD SH-38; threat model §1). After the device-integrity Edge Function
-- verifies an attestation, it stores the attested public key and Apple's receipt here; later
-- assertions are verified with that key and must carry a strictly increasing counter.
-- Apple: store one (key, receipt) pair per device, keep development and production keys apart,
-- and never accept a key already associated with another user (developer.apple.com, "Validating
-- apps that connect to your server", checked 2026-09-17).

CREATE TABLE private.app_attest_keys (
  key_id              bytea       PRIMARY KEY CHECK (length(key_id) = 32),
  user_id             uuid        NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  device_id           uuid        NOT NULL REFERENCES public.user_devices (id) ON DELETE CASCADE,
  environment         text        NOT NULL CHECK (environment IN ('development', 'production')),
  -- X9.62 uncompressed P-256 point.
  public_key          bytea       NOT NULL CHECK (length(public_key) = 65 AND get_byte(public_key, 0) = 4),
  -- Kept for Apple's fraud-risk metric (server-to-server receipt exchange, not built yet).
  receipt             bytea       NOT NULL,
  sign_count          bigint      NOT NULL DEFAULT 0 CHECK (sign_count >= 0),
  validation_category integer,
  bundle_version      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  last_used_at        timestamptz
);
CREATE INDEX app_attest_keys_device ON private.app_attest_keys (device_id);
CREATE INDEX app_attest_keys_user ON private.app_attest_keys (user_id);
REVOKE ALL ON private.app_attest_keys FROM PUBLIC, anon, authenticated;

-- Base64 (standard alphabet) to bytea; NULL for anything that is not valid base64.
CREATE FUNCTION private.try_decode_base64(p_value text)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  RETURN decode(p_value, 'base64');
EXCEPTION
  WHEN invalid_parameter_value OR invalid_text_representation THEN
    RETURN NULL;
END $$;

-- Called only by the device-integrity Edge Function (service_role) after a verified attestation.
-- Returns false when the key id is already registered (to anyone): Apple forbids re-associating
-- a key, and an attestation can only be produced once per key.
CREATE FUNCTION public.app_attest_register_key(
  p_user_id uuid,
  p_device_id uuid,
  p_key_id text,
  p_public_key text,
  p_receipt text,
  p_environment text,
  p_validation_category integer DEFAULT NULL,
  p_bundle_version text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_key_id     bytea := private.try_decode_base64(p_key_id);
  v_public_key bytea := private.try_decode_base64(p_public_key);
  v_receipt    bytea := private.try_decode_base64(p_receipt);
BEGIN
  IF p_user_id IS NULL OR v_key_id IS NULL OR v_public_key IS NULL OR v_receipt IS NULL
     OR length(v_key_id) <> 32 OR length(v_public_key) <> 65 OR get_byte(v_public_key, 0) <> 4
     OR p_environment IS NULL OR p_environment NOT IN ('development', 'production')
     OR (p_bundle_version IS NOT NULL AND length(p_bundle_version) > 64) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_devices d
                 WHERE d.id = p_device_id AND d.user_id = p_user_id AND d.platform = 'ios') THEN
    RAISE EXCEPTION 'ERR_DEVICE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO private.app_attest_keys
    (key_id, user_id, device_id, environment, public_key, receipt, validation_category, bundle_version)
  VALUES
    (v_key_id, p_user_id, p_device_id, p_environment, v_public_key, v_receipt, p_validation_category, p_bundle_version)
  ON CONFLICT (key_id) DO NOTHING;
  RETURN FOUND;
END $$;

-- The stored key for an assertion, or NULL when this user has no such key on this device (the
-- app then attests a new key).
CREATE FUNCTION public.app_attest_key_for_assertion(p_user_id uuid, p_device_id uuid, p_key_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    -- encode() wraps base64 at 76 characters; the function expects one line.
    'public_key', replace(encode(k.public_key, 'base64'), E'\n', ''),
    'sign_count', k.sign_count,
    'environment', k.environment)
  FROM private.app_attest_keys k
  WHERE k.key_id = private.try_decode_base64(p_key_id)
    AND k.user_id = p_user_id
    AND k.device_id = p_device_id
$$;

-- Advances the counter only if the new value is higher, atomically: of two concurrent requests
-- replaying one assertion, exactly one succeeds.
CREATE FUNCTION public.app_attest_record_assertion(p_user_id uuid, p_key_id text, p_counter bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.app_attest_keys k
  SET sign_count = p_counter, last_used_at = now()
  WHERE k.key_id = private.try_decode_base64(p_key_id)
    AND k.user_id = p_user_id
    AND k.sign_count < p_counter;
  RETURN FOUND;
END $$;

REVOKE ALL ON FUNCTION
  private.try_decode_base64(text),
  public.app_attest_register_key(uuid, uuid, text, text, text, text, integer, text),
  public.app_attest_key_for_assertion(uuid, uuid, text),
  public.app_attest_record_assertion(uuid, text, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.app_attest_register_key(uuid, uuid, text, text, text, text, integer, text),
  public.app_attest_key_for_assertion(uuid, uuid, text),
  public.app_attest_record_assertion(uuid, text, bigint)
  TO service_role;
