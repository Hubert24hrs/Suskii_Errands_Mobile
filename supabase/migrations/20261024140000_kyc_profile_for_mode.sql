-- A provider applicant could not see the steps they had to complete (audit 2026-10-24, AA.2).
--
-- `get_my_kyc_profile` listed the steps the caller's *active* mode requires, and
-- `set_active_mode('provider')` refuses anyone not yet verified. So everybody applying to be a
-- provider is in customer mode and was shown the customer list: since customers no longer need
-- verification (20261024120000) the apps drop `customer_facial` and the provider's verification
-- screen was empty, in both apps, on a real backend. `submit_kyc_for_review` checks the provider
-- list, so "Submit for review" then failed with ERR_KYC_INCOMPLETE naming steps nobody could open.
--
-- The screen says which list it is drawing: `p_mode`, optional, defaulting to the active mode as
-- before. The overall status follows the same mode, so a provider applicant sees their provider
-- standing rather than their customer one.

DROP FUNCTION public.get_my_kyc_profile();
CREATE FUNCTION public.get_my_kyc_profile(p_mode public.user_mode DEFAULT NULL)
RETURNS TABLE (
  kind                    public.kyc_step_kind,
  status                  public.kyc_step_status,
  rejection_reason_key    text,
  attempt_count           smallint,
  expires_at              timestamptz,
  required                boolean,
  submitted_at            timestamptz,
  reviewed_at             timestamptz,
  overall_status          public.verification_status,
  submitted_for_review_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_country   char(2);
  v_mode      public.user_mode;
  v_required  public.kyc_step_kind[];
  v_overall   public.verification_status;
  v_submitted timestamptz;
BEGIN
  SELECT p.country_code, coalesce(p_mode, p.active_mode, 'customer'),
         CASE WHEN coalesce(p_mode, p.active_mode) = 'provider' THEN p.provider_verification
              ELSE p.customer_verification END
  INTO v_country, v_mode, v_overall
  FROM public.profiles p WHERE p.user_id = v_uid;
  v_required := private.required_kyc_steps(v_country, coalesce(v_mode, 'customer'));
  SELECT r.submitted_at INTO v_submitted FROM kyc.kyc_reviews r WHERE r.user_id = v_uid;

  RETURN QUERY
  SELECT r.kind,
         coalesce(s.status, 'not_started'::public.kyc_step_status),
         s.rejection_reason_key,
         coalesce(s.attempt_count, 0::smallint),
         s.expires_at,
         true,
         s.submitted_at,
         s.reviewed_at,
         v_overall,
         v_submitted
  FROM unnest(v_required) AS r(kind)
  LEFT JOIN kyc.kyc_steps s ON s.user_id = v_uid AND s.kind = r.kind
  UNION ALL
  SELECT s.kind, s.status, s.rejection_reason_key, s.attempt_count, s.expires_at, false,
         s.submitted_at, s.reviewed_at, v_overall, v_submitted
  FROM kyc.kyc_steps s
  WHERE s.user_id = v_uid AND NOT (s.kind = ANY (v_required));
END $$;

REVOKE ALL ON FUNCTION public.get_my_kyc_profile(public.user_mode) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_kyc_profile(public.user_mode) TO authenticated;
