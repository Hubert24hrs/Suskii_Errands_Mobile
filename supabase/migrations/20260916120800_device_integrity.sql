-- Device integrity nonces (PRD SH-38; threat model §1). The app asks for a single-use nonce,
-- passes it to Play Integrity (Android) or App Attest (iOS), and sends the resulting token to
-- the device-integrity Edge Function, which consumes the nonce and records the verdict on the
-- device row. Binding the nonce to user + device + purpose stops a token minted for one action
-- or one device being replayed for another.

CREATE TABLE private.integrity_nonces (
  nonce       text        PRIMARY KEY,
  user_id     uuid        NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  device_id   uuid        NOT NULL REFERENCES public.user_devices (id) ON DELETE CASCADE,
  purpose     text        NOT NULL CHECK (purpose IN
                ('register_device', 'sign_in', 'go_online', 'payment', 'withdrawal', 'payout_account_change', 'sos')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '5 minutes',
  consumed_at timestamptz
);
CREATE INDEX integrity_nonces_expires_at ON private.integrity_nonces (expires_at);

CREATE FUNCTION public.request_integrity_nonce(p_device_id uuid, p_purpose text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_nonce text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_devices d WHERE d.id = p_device_id AND d.user_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_DEVICE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- 32 random bytes as unpadded base64url: 43 characters, inside Play Integrity's 16–500 range,
  -- and carrying no personal data (Google receives the nonce as-is).
  v_nonce := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');

  INSERT INTO private.integrity_nonces (nonce, user_id, device_id, purpose)
  VALUES (v_nonce, v_uid, p_device_id, p_purpose);
  RETURN v_nonce;
EXCEPTION
  WHEN check_violation THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
END $$;

-- Called only by the device-integrity Edge Function (service_role), with the user id taken
-- from the verified JWT. Returns the device and purpose, or raises if the nonce is unknown,
-- belongs to someone else, expired or was already used.
CREATE FUNCTION public.consume_integrity_nonce(p_nonce text, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row      private.integrity_nonces%ROWTYPE;
  v_platform public.device_platform;
BEGIN
  UPDATE private.integrity_nonces n
  SET consumed_at = now()
  WHERE n.nonce = p_nonce
    AND n.user_id = p_user_id
    AND n.consumed_at IS NULL
    AND n.expires_at > now()
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_INTEGRITY_NONCE_INVALID' USING ERRCODE = 'P0001';
  END IF;

  SELECT d.platform INTO v_platform FROM public.user_devices d WHERE d.id = v_row.device_id;
  RETURN jsonb_build_object('device_id', v_row.device_id, 'purpose', v_row.purpose, 'platform', v_platform);
END $$;

REVOKE ALL ON FUNCTION public.request_integrity_nonce(uuid, text), public.consume_integrity_nonce(text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_integrity_nonce(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_integrity_nonce(text, uuid) TO service_role;
REVOKE ALL ON private.integrity_nonces FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('integrity-nonces-cleanup', '*/30 * * * *',
      $cron$DELETE FROM private.integrity_nonces WHERE expires_at < now() - interval '1 day'$cron$);
    PERFORM cron.schedule('idempotency-keys-cleanup', '5 * * * *',
      $cron$DELETE FROM private.idempotency_keys WHERE expires_at < now()$cron$);
  END IF;
END $$;
