-- Phase 9, part 4: `R:scope` made real (`docs/audit/AUDIT-2026-09-22b.md`, findings U.1 and U.2).
--
-- **`admin_users.country_scope` has existed since Phase 2 and one function reads it.**
--
-- The RLS matrix's legend defines `R:scope` as "read rows within the admin's country/assignment
-- scope", and fifty-odd cells across the matrix carry it. Exactly one place honours it:
-- `kyc_review_queue`. Everywhere else the policy was written as
-- `has_admin_role(ARRAY[...])` — role, not rule — so a support agent scoped to Nigeria reads
-- Kenya, Ghana, South Africa and Uganda, and a finance officer scoped to one country reads every
-- country's payouts, withdrawals and payout accounts.
--
-- That is audit S.1 again at a larger scale, and it gets worse rather than better with time: the
-- control is decorative while one country is live and becomes material the moment a second is,
-- which `country_pack_readiness` now makes straightforward.
--
-- **Three helpers rather than a subquery per policy.** Each takes the row's key, checks the role
-- first and only then resolves the country, so a policy on a table a caller has no role for costs
-- one function call and no join. `super_admin` is never country-scoped — the matrix gives it
-- plain `R` in every row, and the role that can do anything is not made safer by pretending
-- otherwise.
--
-- **Fails closed.** A scoped officer does not see a row whose country cannot be determined. The
-- alternative — show it, because hiding it is inconvenient — turns a restriction into a
-- suggestion, and `super_admin` is the escape hatch for the cases that need one.

CREATE FUNCTION private.admin_scope_allows(p_country char(2))
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admin_users a
    WHERE a.user_id = auth.uid()
      AND a.disabled_at IS NULL
      -- NULL scope is the whole platform, which is what the column already means.
      AND (a.country_scope IS NULL
           OR (p_country IS NOT NULL AND p_country = ANY (a.country_scope))));
$$;

-- A country named directly on the row.
CREATE FUNCTION private.admin_may_read_country(p_country char(2), p_roles public.admin_role[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])
      OR (private.has_admin_role(p_roles) AND private.admin_scope_allows(p_country));
$$;

-- A row that belongs to a request: the country is the request's.
CREATE FUNCTION private.admin_may_read_request(p_request_id uuid, p_roles public.admin_role[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])
      OR (private.has_admin_role(p_roles)
          AND private.admin_scope_allows(
                (SELECT r.country_code FROM public.requests r WHERE r.id = p_request_id)));
$$;

-- A row that belongs to a person: the country is the one on their profile.
CREATE FUNCTION private.admin_may_read_user(p_user_id uuid, p_roles public.admin_role[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])
      OR (private.has_admin_role(p_roles)
          AND private.admin_scope_allows(
                (SELECT p.country_code FROM public.profiles p WHERE p.user_id = p_user_id)));
$$;

REVOKE ALL ON FUNCTION
  private.admin_scope_allows(char),
  private.admin_may_read_country(char, public.admin_role[]),
  private.admin_may_read_request(uuid, public.admin_role[]),
  private.admin_may_read_user(uuid, public.admin_role[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  private.admin_scope_allows(char),
  private.admin_may_read_country(char, public.admin_role[]),
  private.admin_may_read_request(uuid, public.admin_role[]),
  private.admin_may_read_user(uuid, public.admin_role[])
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Identity and relationships. The country is the subject's own.
-- ---------------------------------------------------------------------------
DROP POLICY user_devices_read ON public.user_devices;
CREATE POLICY user_devices_read ON public.user_devices FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(user_devices.user_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY consents_read ON public.consents;
CREATE POLICY consents_read ON public.consents FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(consents.user_id,
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

DROP POLICY notification_preferences_read ON public.notification_preferences;
CREATE POLICY notification_preferences_read ON public.notification_preferences
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(notification_preferences.user_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY blocks_read_own ON public.blocks;
CREATE POLICY blocks_read_own ON public.blocks FOR SELECT TO authenticated
  USING (blocker_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(blocks.blocker_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY favorites_read_own ON public.favorites;
CREATE POLICY favorites_read_own ON public.favorites FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(favorites.customer_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY reports_read_own ON public.reports;
CREATE POLICY reports_read_own ON public.reports FOR SELECT TO authenticated
  USING (reporter_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(reports.reporter_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Providers.
-- ---------------------------------------------------------------------------
DROP POLICY provider_profiles_read_own ON public.provider_profiles;
CREATE POLICY provider_profiles_read_own ON public.provider_profiles FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(provider_profiles.user_id,
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

DROP POLICY provider_services_read_own ON public.provider_services;
CREATE POLICY provider_services_read_own ON public.provider_services FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(provider_services.provider_id,
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

DROP POLICY provider_service_areas_read_own ON public.provider_service_areas;
CREATE POLICY provider_service_areas_read_own ON public.provider_service_areas
  FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(provider_service_areas.provider_id,
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Businesses. `organizations` carries its own country.
-- ---------------------------------------------------------------------------
DROP POLICY organizations_read_member ON public.organizations;
CREATE POLICY organizations_read_member ON public.organizations FOR SELECT TO authenticated
  USING ((SELECT private.is_org_member(organizations.id))
         OR (SELECT private.admin_may_read_country(organizations.country_code,
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

DROP POLICY organization_members_read ON public.organization_members;
CREATE POLICY organization_members_read ON public.organization_members FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.is_org_member(organization_members.organization_id))
         OR (SELECT private.admin_may_read_country(
               (SELECT o.country_code FROM public.organizations o
                WHERE o.id = organization_members.organization_id),
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

DROP POLICY vehicles_read ON public.vehicles;
CREATE POLICY vehicles_read ON public.vehicles FOR SELECT TO authenticated
  USING (owner_user_id = (SELECT auth.uid())
         OR assigned_worker_id = (SELECT auth.uid())
         OR (organization_id IS NOT NULL AND (SELECT private.is_org_member(vehicles.organization_id)))
         OR (SELECT private.admin_may_read_country(
               coalesce((SELECT o.country_code FROM public.organizations o
                         WHERE o.id = vehicles.organization_id),
                        (SELECT p.country_code FROM public.profiles p
                         WHERE p.user_id = vehicles.owner_user_id)),
               ARRAY['support_agent', 'verification_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The marketplace. Everything here hangs off a request, which names its country.
-- ---------------------------------------------------------------------------
DROP POLICY requests_read_own ON public.requests;
CREATE POLICY requests_read_own ON public.requests FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_country(requests.country_code,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY offer_threads_read ON public.offer_threads;
CREATE POLICY offer_threads_read ON public.offer_threads FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offer_threads.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.admin_may_read_request(offer_threads.request_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY offers_read ON public.offers;
CREATE POLICY offers_read ON public.offers FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offers.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.admin_may_read_request(offers.request_id,
               ARRAY['support_agent']::public.admin_role[])));

DROP POLICY jobs_read_participant ON public.jobs;
CREATE POLICY jobs_read_participant ON public.jobs FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR worker_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = jobs.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.admin_may_read_request(jobs.request_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY proofs_read_participant ON public.proofs;
CREATE POLICY proofs_read_participant ON public.proofs FOR SELECT TO authenticated
  USING (uploaded_by = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = proofs.request_id AND r.customer_id = (SELECT auth.uid()))
         OR EXISTS (SELECT 1 FROM public.jobs j
                    WHERE j.request_id = proofs.request_id
                      AND (j.provider_id = (SELECT auth.uid())
                           OR j.worker_id = (SELECT auth.uid())))
         OR (SELECT private.admin_may_read_request(proofs.request_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

DROP POLICY ratings_read ON public.ratings;
CREATE POLICY ratings_read ON public.ratings FOR SELECT TO authenticated
  USING (rater_id = (SELECT auth.uid())
         OR (visible_at IS NOT NULL AND visible_at <= now() AND moderation_status <> 'rejected')
         OR (SELECT private.admin_may_read_request(ratings.request_id,
               ARRAY['support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Money.
-- ---------------------------------------------------------------------------
DROP POLICY payments_read_participant ON public.payments;
CREATE POLICY payments_read_participant ON public.payments FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(payments.request_id))
         OR (SELECT private.admin_may_read_request(payments.request_id,
               ARRAY['finance_officer', 'dispute_officer']::public.admin_role[])));

DROP POLICY refunds_read ON public.refunds;
CREATE POLICY refunds_read ON public.refunds FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(refunds.request_id))
         OR (SELECT private.admin_may_read_request(refunds.request_id,
               ARRAY['finance_officer', 'dispute_officer',
                     'support_agent']::public.admin_role[])));

DROP POLICY tips_read ON public.tips;
CREATE POLICY tips_read ON public.tips FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(tips.request_id))
         OR (SELECT private.admin_may_read_request(tips.request_id,
               ARRAY['finance_officer']::public.admin_role[])));

DROP POLICY promo_redemptions_read_own ON public.promo_redemptions;
CREATE POLICY promo_redemptions_read_own ON public.promo_redemptions FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_request(promo_redemptions.request_id,
               ARRAY['finance_officer']::public.admin_role[])));

DROP POLICY payout_accounts_read_own ON public.payout_accounts;
CREATE POLICY payout_accounts_read_own ON public.payout_accounts FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_country(payout_accounts.country_code,
               ARRAY['finance_officer']::public.admin_role[])));

DROP POLICY payouts_read_own ON public.payouts;
CREATE POLICY payouts_read_own ON public.payouts FOR SELECT TO authenticated
  USING (beneficiary_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(payouts.beneficiary_id,
               ARRAY['finance_officer']::public.admin_role[])));

DROP POLICY withdrawals_read_own ON public.withdrawals;
CREATE POLICY withdrawals_read_own ON public.withdrawals FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(withdrawals.user_id,
               ARRAY['finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Referrals and disputes.
-- ---------------------------------------------------------------------------
DROP POLICY referral_codes_read_own ON public.referral_codes;
CREATE POLICY referral_codes_read_own ON public.referral_codes FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_user(referral_codes.user_id,
               ARRAY['support_agent', 'finance_officer']::public.admin_role[])));

DROP POLICY referrals_read_own ON public.referrals;
CREATE POLICY referrals_read_own ON public.referrals FOR SELECT TO authenticated
  USING (referrer_id = (SELECT auth.uid()) OR referee_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_country(referrals.country_code,
               ARRAY['support_agent', 'finance_officer']::public.admin_role[])));

DROP POLICY referral_commissions_read_own ON public.referral_commissions;
CREATE POLICY referral_commissions_read_own ON public.referral_commissions
  FOR SELECT TO authenticated
  USING (referrer_id = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_request(referral_commissions.request_id,
               ARRAY['finance_officer']::public.admin_role[])));

DROP POLICY disputes_read ON public.disputes;
CREATE POLICY disputes_read ON public.disputes FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(disputes.request_id))
         OR (SELECT private.admin_may_read_request(disputes.request_id,
               ARRAY['dispute_officer', 'finance_officer',
                     'support_agent']::public.admin_role[])));

DROP POLICY dispute_evidence_read ON public.dispute_evidence;
CREATE POLICY dispute_evidence_read ON public.dispute_evidence FOR SELECT TO authenticated
  USING (submitted_by = (SELECT auth.uid())
         OR (SELECT private.admin_may_read_request(
               (SELECT d.request_id FROM public.disputes d WHERE d.id = dispute_evidence.dispute_id),
               ARRAY['dispute_officer', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- U.2 — a business could rename itself after it was verified.
--
-- The matrix says `U:org-owner(legal_name)` **before verification only**; the policy said any
-- time. A business verified as one company could become another without going back through the
-- queue, and `legal_name` is the only thing about it a customer ever sees — the registration
-- number is ciphertext nobody reads.
--
-- Refused rather than reset: the alternative, letting the rename through and sending the
-- organisation back to `pending`, is also defensible, but it is a policy decision about somebody
-- losing their ability to trade, and the matrix already states the stricter one.
-- ---------------------------------------------------------------------------
DROP POLICY organizations_update_owner ON public.organizations;
CREATE POLICY organizations_update_owner ON public.organizations FOR UPDATE TO authenticated
  USING ((SELECT private.org_role(organizations.id, (SELECT auth.uid()))) = 'owner'
         AND organizations.verification_status <> 'verified')
  WITH CHECK ((SELECT private.org_role(organizations.id, (SELECT auth.uid()))) = 'owner'
              AND organizations.verification_status <> 'verified');
