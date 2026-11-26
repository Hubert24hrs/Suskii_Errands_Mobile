-- Meet v5 M1, part 1 (`docs/plan/meet-v5-design.md` §3.1 item 2, §9 M1-PR1): new values on
-- three existing enums, and the any-admin gates the new staff role must not walk through.
--
-- The values come first and on their own. `ALTER TYPE ... ADD VALUE` may run inside a transaction,
-- but a value cannot be *used* until the transaction that added it commits (the reason
-- 20260921120400 put the call kinds in a file of their own). Nothing below names a new value: the
-- restated gates list the five roles that already existed, so this file is safe however the
-- migration runner groups its statements. The objects that use the values arrive in later files.
--
--   notification_kind  meet_like, meet_match, meet_message, meet_reminder, meet_account (§2.8).
--                      None is urgent, so quiet hours always apply; `notification_category` and
--                      the push gate for 1.4.0 come with M1-PR5.
--   admin_role         meet_moderator (D25, OD-41): Meet trust and safety, in country scope.
--   consent_kind       meet_terms (recorded with the 18+ gate) and meet_sensitive_data (the first
--                      time gender or "show me" is set, D5). Both written server-side in M1-PR3.

ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meet_like';
ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meet_match';
ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meet_message';
ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meet_reminder';
ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meet_account';

ALTER TYPE public.admin_role ADD VALUE IF NOT EXISTS 'meet_moderator';

ALTER TYPE public.consent_kind ADD VALUE IF NOT EXISTS 'meet_terms';
ALTER TYPE public.consent_kind ADD VALUE IF NOT EXISTS 'meet_sensitive_data';

-- ---------------------------------------------------------------------------
-- The gates that admit every admin role.
--
-- `private.is_any_admin()` is `has_admin_role(enum_range(NULL::public.admin_role))`, so it grows
-- with the enum: from this migration it admits meet_moderator, and so does every gate written
-- with it or with `enum_range` directly. That is the right meaning for the helper and the wrong
-- one for most of its callers. D25 makes dating trust and safety its own world so that errands
-- staff cannot read Meet; the same reasoning runs the other way. A meet moderator reads Meet
-- through the `admin_meet_*` functions (M1-PR2 onward) and otherwise only what every signed-in
-- person reads. Errands configuration and errands operations are not its remit.
--
-- The inventory, taken from the replayed schema on origin/main at bde98f7: every live policy and
-- function body that mentions `is_any_admin` or `enum_range(NULL::public.admin_role)`.
--
--   1. policy feature_flags_admin_read (20260916120500): every flag, server-only ones included.
--   2. policy remote_config_admin_read (20260916120500): every value, client_visible false too.
--   3. policy countries_admin_read (20260916120500): the whole pack, config.server (gateway and
--      SMS routing, thresholds) included.
--   4. policy config_changes_admin_read (20260922120000): every proposal, staff role grants,
--      promo budgets and commission rates included.
--   5. config_change_queue() (20260922120000): the same, pending only.
--   6. country_pack_readiness() (20260922120000): go-live gaps per country.
--   7. admin_overview() (20261013120000): the errands dashboard, by country.
--   8. kpi_jobs_by_state(), 9. kpi_funnel(), 10. kpi_supply_demand() (20260922121200): errands
--      KPIs, aggregates only.
--   11. private.config_proposal_problem() (20261013120000): checks role names in a staff change.
--
-- 1 to 10 exclude meet_moderator from here on. 11 admits it on purpose: it is how a super admin
-- grants the role, through the existing four-eyes staff change (`propose_config_change`, target
-- `admin_user`), and a validator that refused it would leave a migration or the service key as the
-- only way to staff Meet moderation.
--
-- The design counted fourteen uses of `is_any_admin`; that was a count of grep hits. Seven are not
-- gates: the definition, its REVOKE and GRANT, two comments in 20260922121400, and the old
-- `approvals` and `profiles` read policies, which 20260922121400 (W.1, W.2) already replaced with
-- scoped ones. The seven left are 1 to 7; 8 to 11 use `enum_range` without the helper.
--
-- Each of 1 to 10 is restated naming the five roles it admitted before this migration, so nothing
-- changes for any of them. Naming them also makes the next role fail closed instead of open, and
-- lets `generate_v1.py` put the role list in the RPC catalogue, which it cannot read off a helper.
-- `00_structure_test` now fails when a policy or function admits every role without being added to
-- its list, and `89_meet_admin_role_test` holds each gate to this inventory. `is_any_admin()` is
-- kept, unchanged and gating nothing, because its definition is still the right one.
-- ---------------------------------------------------------------------------

-- 1 to 3: restated from 20260916120500_reference_and_admin, the only definition of each.
DROP POLICY feature_flags_admin_read ON public.feature_flags;
CREATE POLICY feature_flags_admin_read ON public.feature_flags FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(ARRAY['super_admin', 'verification_officer',
            'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[])));

DROP POLICY remote_config_admin_read ON public.remote_config;
CREATE POLICY remote_config_admin_read ON public.remote_config FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(ARRAY['super_admin', 'verification_officer',
            'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[])));

DROP POLICY countries_admin_read ON public.countries;
CREATE POLICY countries_admin_read ON public.countries FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(ARRAY['super_admin', 'verification_officer',
            'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[])));

-- 4: restated from 20260922120000_admin_config, its only definition. The reason it was open to
-- every admin still holds for the five: support should see why a feature vanished.
DROP POLICY config_changes_admin_read ON public.config_changes;
CREATE POLICY config_changes_admin_read ON public.config_changes FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(ARRAY['super_admin', 'verification_officer',
            'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[])));

-- 5: restated whole from 20260922120000_admin_config, its latest definition; only the gate
-- changed.
CREATE OR REPLACE FUNCTION public.config_change_queue(p_limit integer DEFAULT 100)
RETURNS TABLE (
  id uuid, target text, target_key text, country_code char(2),
  proposed jsonb, previous jsonb, note text,
  approvals_required smallint, approvals_given integer,
  requested_by uuid, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'verification_officer', 'support_agent',
       'finance_officer', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, c.target, c.target_key, c.country_code, c.proposed, c.previous, c.note,
         c.approvals_required,
         (SELECT count(*)::integer FROM public.approvals a
          WHERE a.subject_kind = 'config_change' AND a.subject_id = c.id::text
            AND a.status = 'approved'),
         c.requested_by, c.created_at
  FROM public.config_changes c
  WHERE c.status = 'pending'
  ORDER BY c.created_at
  LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END $$;

-- 6: restated whole from 20260922120000_admin_config, its latest definition; only the gate
-- changed.
CREATE OR REPLACE FUNCTION public.country_pack_readiness(p_code char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), status public.country_status, gaps text[], ready boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'verification_officer', 'support_agent',
       'finance_officer', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.code, c.status, private.country_pack_gaps(c.code),
         cardinality(private.country_pack_gaps(c.code)) = 0
  FROM public.countries c
  WHERE p_code IS NULL OR c.code = p_code
  ORDER BY c.code;
END $$;

-- 7: restated whole from 20261013120000_admin_console, its latest definition; only the gate
-- changed.
CREATE OR REPLACE FUNCTION public.admin_overview()
RETURNS TABLE (
  country_code char(2), currency char(3), active_users integer, active_jobs integer,
  offers_per_request numeric, gmv_30d_minor bigint, held_minor bigint,
  open_disputes integer, open_sos integer)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_super boolean;
  v_money boolean;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin', 'verification_officer', 'support_agent',
       'finance_officer', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  v_super := private.has_admin_role(ARRAY['super_admin']::public.admin_role[]);
  v_money := private.has_admin_role(ARRAY['super_admin', 'finance_officer']::public.admin_role[]);

  RETURN QUERY
  SELECT c.code, c.currency_code,
         (SELECT count(DISTINCT d.user_id)::integer
          FROM public.user_devices d
          JOIN public.profiles p ON p.user_id = d.user_id
          WHERE p.country_code = c.code AND d.last_seen_at >= now() - interval '24 hours'),
         (SELECT count(*)::integer FROM public.requests r
          WHERE r.country_code = c.code
            AND r.status IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                             'completed_by_provider')),
         (SELECT round(avg(x.n), 1)
          FROM (SELECT count(o.id) AS n
                FROM public.requests r
                LEFT JOIN public.offers o ON o.request_id = r.id
                WHERE r.country_code = c.code AND r.published_at >= now() - interval '7 days'
                GROUP BY r.id) x),
         CASE WHEN v_money THEN
           (SELECT coalesce(sum(j.agreed_amount_minor), 0)::bigint
            FROM public.jobs j JOIN public.requests r ON r.id = j.request_id
            WHERE r.country_code = c.code AND j.currency = c.currency_code
              AND j.confirmed_at >= now() - interval '30 days')
         END,
         CASE WHEN v_money THEN
           (SELECT coalesce(sum(p.job_amount_minor), 0)::bigint
            FROM public.payments p JOIN public.requests r ON r.id = p.request_id
            WHERE r.country_code = c.code AND p.currency = c.currency_code
              AND p.kind = 'job' AND p.status = 'held')
         END,
         (SELECT count(*)::integer FROM public.disputes d
          JOIN public.requests r ON r.id = d.request_id
          WHERE r.country_code = c.code AND d.status IN ('open', 'under_review')),
         (SELECT count(*)::integer FROM public.sos_incidents s
          LEFT JOIN public.requests r ON r.id = s.request_id
          LEFT JOIN public.profiles p ON p.user_id = s.raised_by
          WHERE coalesce(r.country_code, p.country_code) = c.code
            AND s.status IN ('open', 'acknowledged', 'dispatched'))
  FROM public.countries c
  WHERE c.status <> 'disabled'
    AND (v_super OR private.admin_scope_allows(c.code))
  ORDER BY c.code;
END $$;

-- 8 to 10: restated whole from 20260922121200_ai_admin_kpis, the latest definition of each; only
-- the role list passed to `kpi_guard` changed. ai-design §4.4 gives these three to "all" roles,
-- written when there were five; it now says so.
CREATE OR REPLACE FUNCTION public.kpi_jobs_by_state(
  p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), status public.job_status, jobs bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(ARRAY['super_admin', 'verification_officer',
    'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[], p_country);
BEGIN
  RETURN QUERY
  SELECT r.country_code, r.status, private.kpi_suppress(count(*))
  FROM public.requests r
  WHERE r.created_at >= p_from AND r.created_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;

CREATE OR REPLACE FUNCTION public.kpi_funnel(p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), published bigint, received_an_offer bigint,
               agreed bigint, paid bigint, confirmed bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(ARRAY['super_admin', 'verification_officer',
    'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[], p_country);
BEGIN
  -- Cohorted on the day the request was published, so the stages are the same requests rather
  -- than five populations that happen to share a date.
  RETURN QUERY
  SELECT r.country_code,
         private.kpi_suppress(count(*)),
         private.kpi_suppress(count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.offers o WHERE o.request_id = r.id))),
         private.kpi_suppress(count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.jobs j WHERE j.request_id = r.id))),
         private.kpi_suppress(count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.payments p
           WHERE p.request_id = r.id AND p.status = 'held'))),
         private.kpi_suppress(count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.jobs j
           WHERE j.request_id = r.id AND j.confirmed_at IS NOT NULL)))
  FROM public.requests r
  WHERE r.published_at IS NOT NULL
    AND r.published_at >= p_from AND r.published_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
  GROUP BY 1
  ORDER BY 1;
END $$;

CREATE OR REPLACE FUNCTION public.kpi_supply_demand(
  p_from date, p_to date, p_country char(2) DEFAULT NULL, p_category_id uuid DEFAULT NULL)
RETURNS TABLE (country_code char(2), hour_of_day integer, requests bigint,
               distinct_providers bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(ARRAY['super_admin', 'verification_officer',
    'support_agent', 'finance_officer', 'dispute_officer']::public.admin_role[], p_country);
BEGIN
  -- Demand by hour against the supply that actually answered it. Providers are counted, never
  -- named: this is a staffing question, not a performance review.
  RETURN QUERY
  SELECT r.country_code,
         extract(hour FROM r.published_at)::integer,
         private.kpi_suppress(count(*)),
         private.kpi_suppress(count(DISTINCT o.provider_id))
  FROM public.requests r
  LEFT JOIN public.offers o ON o.request_id = r.id
  WHERE r.published_at IS NOT NULL
    AND r.published_at >= p_from AND r.published_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
    AND (p_category_id IS NULL OR r.category_id = p_category_id)
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;
