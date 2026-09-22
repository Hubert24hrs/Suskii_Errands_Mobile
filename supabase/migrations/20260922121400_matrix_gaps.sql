-- Three gaps the new matrix-coverage check found on its first run
-- (`docs/audit/AUDIT-2026-09-22d.md`, findings W.1 to W.3).
--
-- The second pass on 2026-09-22 declared U.1 closed: "twenty-eight policies scope through three
-- helpers now". Twenty-eight was not all of them. `profiles` and `approvals` were never rewritten
-- and still read through `private.is_any_admin()`, which is every role in every country -- the
-- exact thing U.1 was about. Nobody noticed because the way U.1 was closed was by reading the
-- matrix and fixing what the reading found, and a reading stops where the reader's attention does.
--
-- `supabase/tools/check_rls_matrix.py` does not get tired. It is the control this file exists
-- because of, and these three are what it found the first time it ran.

-- ---------------------------------------------------------------------------
-- W.1 -- profiles. The matrix gives Support, Verification, Finance and Dispute `R:scope` on four
-- separate columns, and super admin plain `R`. The policy asked `is_any_admin()`, so a support
-- agent scoped to Nigeria read every profile on the platform: display name, country,
-- verification standing, trust level. That is personal data and the DPIA is written on it being
-- scoped.
-- ---------------------------------------------------------------------------
DROP POLICY profiles_read ON public.profiles;
CREATE POLICY profiles_read ON public.profiles FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_country(profiles.country_code,
               ARRAY['support_agent', 'verification_officer',
                     'finance_officer', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- W.2 -- approvals. The matrix says "requester R:own; approvers R:scope". The policy said
-- requester or *any* admin, so a verification officer could read every withdrawal approval in
-- every country, which is a ledger of who is taking money out and when.
--
-- `approvals` is polymorphic in the same way `fraud_flags` is -- `subject_kind` plus a text id --
-- so reaching a country means a resolver rather than a column. Two kinds are ever written:
-- `withdrawal` (by request_withdrawal) and `config_change` (by propose_config_change, including
-- the referral campaign path).
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.approval_subject_country(p_kind text, p_id text)
RETURNS char(2)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  -- `w.id::text = p_id` and not `p_id::uuid`: a subject id that is not a uuid must resolve to
  -- nothing, not raise inside a policy. Same lesson as moderation_subject_countries.
  SELECT CASE p_kind
    WHEN 'withdrawal' THEN (
      SELECT p.country_code FROM public.withdrawals w
      JOIN public.profiles p ON p.user_id = w.user_id
      WHERE w.id::text = p_id)
    WHEN 'config_change' THEN (
      SELECT c.country_code FROM public.config_changes c WHERE c.id::text = p_id)
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION private.approval_subject_country(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.approval_subject_country(text, text) TO authenticated;

DROP POLICY approvals_read_own_or_admin ON public.approvals;
-- A global config change has no country. It resolves to NULL, `admin_scope_allows` refuses NULL,
-- and only super admin reads it -- which is the fail-closed rule everywhere else and is right
-- here too: a change with no country is a change to everybody's platform.
CREATE POLICY approvals_read_own_or_admin ON public.approvals FOR SELECT TO authenticated
  USING (requested_by = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_country(
               private.approval_subject_country(approvals.subject_kind, approvals.subject_id),
               ARRAY['finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- W.3 -- payments.checkout_url. The matrix gives a job participant `R:part (status, amount)` and
-- the grant covered every column, so the provider on a job could read the customer's hosted
-- checkout URL.
--
-- That URL is a capability, not a reference: whoever holds it can open the customer's payment
-- page. It is NULL today because nothing populates it until a real gateway exists (client action
-- 4), which is the only reason this is a latent hole rather than a live one -- and the reason to
-- close it now, while the column is empty and no client reads it, rather than after M9 when
-- closing it would be a breaking change against a wired app.
--
-- The rest of the row stays readable. The matrix's "(status, amount)" is narrower than the
-- product needs -- a provider legitimately sees the amount breakdown that decides their earnings
-- -- so that half is recorded as a deliberate divergence in `rls-matrix-waivers.json` rather than
-- pretended away.
-- ---------------------------------------------------------------------------
REVOKE SELECT ON public.payments FROM authenticated;
GRANT SELECT (id, request_id, payer_id, gateway, gateway_reference, method, amount_minor,
              currency, status, fee_minor, expires_at, confirmed_at, failed_reason_key,
              created_at, updated_at, kind, discount_minor, job_amount_minor, float_minor,
              float_surcharge_minor)
  ON public.payments TO authenticated;

-- The payer still needs the URL, so it moves from a column read to a function that checks who is
-- asking. `start_payment` cannot return it: the worker writes it afterwards.
CREATE FUNCTION public.get_payment_checkout(p_request_id uuid)
RETURNS TABLE (payment_id uuid, checkout_url text, status public.payment_status,
               expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY
  SELECT p.id, p.checkout_url, p.status, p.expires_at
  FROM public.payments p
  WHERE p.request_id = p_request_id
    AND p.payer_id = v_uid
  ORDER BY p.created_at DESC
  LIMIT 1;
END $$;

REVOKE ALL ON FUNCTION public.get_payment_checkout(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_payment_checkout(uuid) TO authenticated;
