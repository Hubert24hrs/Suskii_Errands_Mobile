-- Phase 9, part 7: the country scope on the two queues that were listed rather than half-done
-- (`docs/audit/AUDIT-2026-09-22b.md`, U.1's remainder).
--
-- Every other table the matrix marks `R:scope` names a country, or reaches one in a single hop
-- through a request or a profile. `fraud_flags` and `moderation_cases` do not: their subject is
-- `subject_kind` plus an id held as **text**, because the thing being flagged might be a user, a
-- request, a device fingerprint or a pair of people. Reaching a country means a switch, and a
-- switch in the middle of a policy is the kind of thing worth writing once, in a function, where
-- it can be read.
--
-- **A subject can belong to more than one country**, which is the interesting part. A
-- `device_reuse` flag exists precisely because one handset has been several accounts, and those
-- accounts may be in different countries; a `collusive_pair` flag names two people who might be.
-- Hiding such a flag from an officer in one of those countries would hide it from somebody whose
-- problem it is. So the resolvers return a **set** of countries and the scope test is an overlap,
-- not an equality.
--
-- `moderation_cases` takes a shortcut the audit did not anticipate: it already carries
-- `author_id`, and a moderation case is about something a person wrote, so the author's country
-- is the answer whenever there is an author. The subject switch is the fallback, which in
-- practice means `profile` cases and any case whose author has since been deleted.

CREATE FUNCTION private.admin_scope_allows_any(p_countries char(2)[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admin_users a
    WHERE a.user_id = auth.uid()
      AND a.disabled_at IS NULL
      AND (a.country_scope IS NULL
           -- `&&` is array overlap: any one of the subject's countries being in scope is enough.
           OR (p_countries IS NOT NULL AND p_countries && a.country_scope)));
$$;

CREATE FUNCTION private.admin_may_read_countries(
  p_countries char(2)[], p_roles public.admin_role[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])
      OR (private.has_admin_role(p_roles) AND private.admin_scope_allows_any(p_countries));
$$;

-- ---------------------------------------------------------------------------
-- Where a fraud flag's subject lives. `subject_kind` is one of user, request, device, pair.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.fraud_subject_countries(p_subject_kind text, p_subject_id text)
RETURNS char(2)[]
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE p_subject_kind
    WHEN 'user' THEN
      (SELECT array_remove(array_agg(p.country_code), NULL) FROM public.profiles p
       WHERE p.user_id = private.try_uuid(p_subject_id))
    WHEN 'request' THEN
      (SELECT array_remove(array_agg(r.country_code), NULL) FROM public.requests r
       WHERE r.id = private.try_uuid(p_subject_id))
    WHEN 'device' THEN
      -- The id is the hex of a fingerprint hash, and the flag exists because more than one
      -- account has used it. Every owner's country counts.
      (SELECT array_remove(array_agg(DISTINCT p.country_code), NULL)
       FROM public.user_devices d
       JOIN public.profiles p ON p.user_id = d.user_id
       WHERE p_subject_id ~ '^[0-9a-f]+$'
         AND d.device_fingerprint_hash = decode(p_subject_id, 'hex'))
    WHEN 'pair' THEN
      -- `<customer uuid>:<provider uuid>`. Either party's country makes the flag theirs.
      (SELECT array_remove(array_agg(DISTINCT p.country_code), NULL)
       FROM unnest(string_to_array(p_subject_id, ':')) AS s(part)
       JOIN public.profiles p ON p.user_id = private.try_uuid(s.part))
  END;
$$;

-- ---------------------------------------------------------------------------
-- Where a moderation case's subject lives. The author answers it whenever there is one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.moderation_subject_countries(
  p_subject_kind text, p_subject_id text, p_author_id uuid)
RETURNS char(2)[]
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(
    (SELECT array_remove(array_agg(p.country_code), NULL) FROM public.profiles p
     WHERE p_author_id IS NOT NULL AND p.user_id = p_author_id),
    CASE p_subject_kind
      WHEN 'profile' THEN
        (SELECT array_remove(array_agg(p.country_code), NULL) FROM public.profiles p
         WHERE p.user_id = private.try_uuid(p_subject_id))
      WHEN 'request' THEN
        (SELECT array_remove(array_agg(r.country_code), NULL) FROM public.requests r
         WHERE r.id = private.try_uuid(p_subject_id))
      WHEN 'rating' THEN
        (SELECT array_remove(array_agg(r.country_code), NULL)
         FROM public.ratings rt
         JOIN public.requests r ON r.id = rt.request_id
         WHERE rt.id = private.try_uuid(p_subject_id))
      WHEN 'message' THEN
        -- A message id is a `bigint`, not a uuid, so the text is checked for digits before it is
        -- cast — a subject id is free text and a cast that raises inside a policy takes the whole
        -- query with it. `messages` is also partitioned with the partition key in its primary
        -- key, so a lookup by id alone visits every partition; reachable only through this
        -- fallback, which needs a case whose author has been deleted, so the cost is rare.
        (SELECT array_remove(array_agg(r.country_code), NULL)
         FROM public.messages m
         JOIN public.conversations c ON c.id = m.conversation_id
         JOIN public.requests r ON r.id = c.request_id
         WHERE p_subject_id ~ '^[0-9]{1,18}$' AND m.id = p_subject_id::bigint)
    END);
$$;

REVOKE ALL ON FUNCTION
  private.admin_scope_allows_any(char[]),
  private.admin_may_read_countries(char[], public.admin_role[]),
  private.fraud_subject_countries(text, text),
  private.moderation_subject_countries(text, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  private.admin_scope_allows_any(char[]),
  private.admin_may_read_countries(char[], public.admin_role[]),
  private.fraud_subject_countries(text, text),
  private.moderation_subject_countries(text, text, uuid)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- The two policies. A flag whose subject resolves to no country at all — a device fingerprint
-- nobody has registered any more, a pair whose accounts are gone — is left to `super_admin`,
-- which is the same fail-closed rule as everywhere else.
-- ---------------------------------------------------------------------------
DROP POLICY fraud_flags_read ON public.fraud_flags;
CREATE POLICY fraud_flags_read ON public.fraud_flags FOR SELECT TO authenticated
  USING ((SELECT private.admin_may_read_countries(
            private.fraud_subject_countries(fraud_flags.subject_kind, fraud_flags.subject_id),
            ARRAY['support_agent']::public.admin_role[])));

DROP POLICY moderation_cases_read ON public.moderation_cases;
CREATE POLICY moderation_cases_read ON public.moderation_cases FOR SELECT TO authenticated
  USING (author_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_countries(
               private.moderation_subject_countries(moderation_cases.subject_kind,
                                                    moderation_cases.subject_id,
                                                    moderation_cases.author_id),
               ARRAY['support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The queues themselves are functions, and a function is not a policy: `moderation_queue` and
-- `fraud_queue` read their tables as `SECURITY DEFINER`, so RLS does not apply to them and the
-- scope has to be stated again. Replaced whole rather than patched, because a queue that shows a
-- row the table would hide is the gap under another name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fraud_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.fraud_flags
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.fraud_flags f
  WHERE f.status = 'open'
    AND private.admin_may_read_countries(
          private.fraud_subject_countries(f.subject_kind, f.subject_id),
          ARRAY['support_agent']::public.admin_role[])
  ORDER BY f.score DESC, f.created_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE OR REPLACE FUNCTION public.moderation_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.moderation_cases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.moderation_cases c
  WHERE c.status = 'open'
    AND private.admin_may_read_countries(
          private.moderation_subject_countries(c.subject_kind, c.subject_id, c.author_id),
          ARRAY['support_agent']::public.admin_role[])
  ORDER BY c.created_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;
