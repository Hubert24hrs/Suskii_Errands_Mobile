-- Storage buckets and their access rules (PRD SH-04 avatars, SH-17/PR KYC documents; threat
-- model §3 "biometric and identity documents"; RLS matrix §11).
--
-- Both buckets are private: nothing is served by URL alone. Clients read through a signed URL
-- or an authenticated request, and every object lives under the owner's user id:
--     <bucket>/<user_id>/<file>
-- The first path segment is the owner check in every policy below. `storage.objects` keeps that
-- segment in the generated column `path_tokens` (supabase/storage migration 0003); the policies
-- recompute it with string_to_array so they do not depend on that column existing.
--
-- Job photos, chat attachments and dispute evidence arrive with Phase 3, when the tables that say
-- who may see them exist.

INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', false),
       ('kyc-docs', 'kyc-docs', false)
ON CONFLICT (id) DO NOTHING;

-- Upload limits, where this Storage version records them (column names have changed over time).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'file_size_limit') THEN
    UPDATE storage.buckets SET file_size_limit = 5 * 1024 * 1024 WHERE id = 'avatars';
    UPDATE storage.buckets SET file_size_limit = 15 * 1024 * 1024 WHERE id = 'kyc-docs';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'allowed_mime_types') THEN
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
    WHERE id = 'avatars';
    UPDATE storage.buckets
    SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'application/pdf']
    WHERE id = 'kyc-docs';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- avatars: a user owns the folder named after their user id, and nothing else.
-- ---------------------------------------------------------------------------
CREATE POLICY avatars_own_folder_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'avatars' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

CREATE POLICY avatars_own_folder_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'avatars' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

CREATE POLICY avatars_own_folder_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'avatars' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text)
  WITH CHECK (bucket_id = 'avatars' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

CREATE POLICY avatars_own_folder_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'avatars' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);

-- ---------------------------------------------------------------------------
-- kyc-docs: write-only for the person being verified. Identity documents and selfies go in, and
-- no client — not even the owner — reads, overwrites or deletes them afterwards: review happens
-- server-side, and the backup worker copies the bucket with the service role (RB-09). A client
-- that could re-read them turns a stolen session into a document leak (threat model §3).
-- ---------------------------------------------------------------------------
CREATE POLICY kyc_docs_own_folder_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'kyc-docs' AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text);
