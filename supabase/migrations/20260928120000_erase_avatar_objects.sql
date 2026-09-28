-- Erasure removes the profile photo as well as the pointer to it (audit 2026-09-27 Y.30).
--
-- private.erase_account cleared profiles.avatar_path and left the file in the `avatars` bucket:
-- the photo of an erased person stayed in storage for ever, reachable by anybody holding a
-- signed URL minted before, and outside what the delete-account page promises. The fix cannot be
-- a DELETE here. Storage refuses direct deletes from storage.objects (storage.protect_delete),
-- because the bytes live in the object store and a row removed underneath the Storage API
-- orphans them. So erasure queues the folder, and storage-worker removes it through the API.
--
-- The event goes on its own aggregate, `storage`, and not on `user`: notifications-worker claims
-- `user` and completes what it does not recognise, which is exactly how a refund once went
-- missing (audit T.2). An aggregate with one reader cannot be swallowed by another.
--
-- Only `avatars`. Documents in `kyc-docs` are kept for the verification retention period the
-- law sets; chat, request and proof media stay with the records of the jobs they belong to,
-- which is what the delete-account page says.

CREATE OR REPLACE FUNCTION private.erase_account(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = '', avatar_path = NULL, timezone = NULL
  WHERE user_id = p_user;

  DELETE FROM public.trusted_contacts WHERE user_id = p_user;
  DELETE FROM public.favorites WHERE customer_id = p_user OR provider_id = p_user;
  -- Device rows are referenced by consents, which are the record of what was agreed; the
  -- addresses a push could still reach are what identify the handset, so those go.
  UPDATE public.user_devices SET push_token = NULL, voip_token = NULL WHERE user_id = p_user;
  UPDATE public.provider_profiles SET online = false WHERE user_id = p_user;

  DELETE FROM auth.sessions WHERE user_id = p_user;
  DELETE FROM auth.identities WHERE user_id = p_user;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user;
  UPDATE auth.users
  SET phone = NULL, email = NULL, encrypted_password = NULL,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = 'infinity', deleted_at = now()
  WHERE id = p_user;

  -- The user's folder in `avatars` (one folder per user, named by id).
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'avatars', 'prefix', p_user::text || '/'));

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;
