-- Phase 7, part 2: the AI admin assistant's function surface
-- (`docs/plan/ai-design.md` §4.4; spec phase 7, "AI Admin Assistant with predefined analytics
-- functions on a read replica").
--
-- The spec's own wording is the design: **predefined analytics functions**, never free-form SQL.
-- An assistant that can write a query can be talked into writing any query, and the containment
-- ADR-0012 relies on is that the surface is finite and reviewable. So these eight are the whole
-- surface, and there is no ninth door.
--
-- Three rules hold across all of them.
--
-- **Aggregates only, and small cells are suppressed.** §4.4: any cell below ten is withheld,
-- because a narrow enough filter on a count is a lookup. The threshold is remote config, marked
-- `[A]` in the design pending the DPIA, and the suppression returns NULL rather than dropping the
-- row — a missing row looks like zero, and zero is a claim.
--
-- **Each is scoped by the caller's role *and* their country.** The role list is §4.4's own, and
-- the country scope is the one audit U.1 made real. An assistant is a faster way to ask, not a
-- wider thing to ask about.
--
-- **Money never crosses currencies.** `kpi_gmv` returns one row per currency and no total. A
-- single number across NGN, KES and GHS is an exchange-rate opinion wearing a fact's clothes.
--
-- **The read replica is not here yet.** §4.4 puts these on a replica with an `ai_admin_analytics`
-- role; that needs the Supabase project a deployed environment implies (timeline action 1). The
-- functions are written so the move is a connection string: every one is `STABLE`, reads nothing
-- outside `public` and `analytics`, and writes nothing at all.

CREATE FUNCTION private.kpi_suppress(p_value bigint)
RETURNS bigint
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  -- NULL, not zero: a suppressed cell and an empty one are different answers and a dashboard
  -- that conflates them will confidently report a market that does not exist.
  SELECT CASE WHEN p_value IS NULL THEN NULL
              WHEN p_value < coalesce(private.remote_config_int('ai.kpi_min_cell'), 10)
              THEN NULL ELSE p_value END;
$$;

-- The one guard every KPI runs. Returns the caller's country filter: NULL means the whole
-- platform, which only an unscoped admin gets.
CREATE FUNCTION private.kpi_guard(p_roles public.admin_role[], p_country char(2))
RETURNS char(2)[]
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[];
BEGIN
  IF NOT private.has_admin_role(p_roles) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  SELECT a.country_scope INTO v_scope FROM public.admin_users a
  WHERE a.user_id = auth.uid() AND a.disabled_at IS NULL;

  -- A super admin is not country-scoped, the same rule as everywhere else.
  IF private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    v_scope := NULL;
  END IF;

  IF p_country IS NOT NULL THEN
    IF v_scope IS NOT NULL AND NOT (p_country = ANY (v_scope)) THEN
      RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
        DETAIL = 'that country is not in your scope';
    END IF;
    RETURN ARRAY[p_country];
  END IF;
  RETURN v_scope;   -- NULL = everywhere, which only an unscoped admin reaches
END $$;

CREATE FUNCTION public.kpi_jobs_by_state(
  p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), status public.job_status, jobs bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(enum_range(NULL::public.admin_role), p_country);
BEGIN
  RETURN QUERY
  SELECT r.country_code, r.status, private.kpi_suppress(count(*))
  FROM public.requests r
  WHERE r.created_at >= p_from AND r.created_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;

CREATE FUNCTION public.kpi_gmv(
  p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), currency char(3), jobs bigint,
               gmv_minor bigint, commission_minor bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(
    ARRAY['super_admin', 'finance_officer']::public.admin_role[], p_country);
BEGIN
  -- One row per currency and **no total**: a single number across NGN, KES and GHS would be an
  -- exchange-rate opinion presented as a fact.
  RETURN QUERY
  SELECT r.country_code, j.currency, private.kpi_suppress(count(*)),
         sum(j.agreed_amount_minor)::bigint, sum(coalesce(j.commission_minor, 0))::bigint
  FROM public.jobs j
  JOIN public.requests r ON r.id = j.request_id
  WHERE j.confirmed_at IS NOT NULL
    AND j.confirmed_at >= p_from AND j.confirmed_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;

CREATE FUNCTION public.kpi_funnel(p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), published bigint, received_an_offer bigint,
               agreed bigint, paid bigint, confirmed bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(enum_range(NULL::public.admin_role), p_country);
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

CREATE FUNCTION public.kpi_verification_queue(p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), kind public.kyc_step_kind, waiting bigint,
               oldest_hours integer, p50_hours integer)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(
    ARRAY['super_admin', 'verification_officer']::public.admin_role[], p_country);
BEGIN
  RETURN QUERY
  SELECT p.country_code, s.kind, private.kpi_suppress(count(*)),
         (max(extract(epoch FROM now() - s.created_at)) / 3600)::integer,
         (percentile_cont(0.5) WITHIN GROUP (
            ORDER BY extract(epoch FROM now() - s.created_at)) / 3600)::integer
  FROM kyc.kyc_steps s
  JOIN public.profiles p ON p.user_id = s.user_id
  -- Waiting on a person: submitted and not yet decided.
  WHERE s.status IN ('in_review', 'in_progress')
    AND (v_scope IS NULL OR p.country_code = ANY (v_scope))
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;

CREATE FUNCTION public.kpi_disputes(p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), reason_code text, disputes bigint,
               with_refund bigint, p50_hours_to_resolve integer)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(
    ARRAY['super_admin', 'dispute_officer']::public.admin_role[], p_country);
BEGIN
  RETURN QUERY
  SELECT r.country_code, d.reason_code, private.kpi_suppress(count(*)),
         private.kpi_suppress(count(*) FILTER (WHERE coalesce(d.refund_minor, 0) > 0)),
         (percentile_cont(0.5) WITHIN GROUP (
            ORDER BY extract(epoch FROM d.resolved_at - d.created_at)) / 3600)::integer
  FROM public.disputes d
  JOIN public.requests r ON r.id = d.request_id
  WHERE d.created_at >= p_from AND d.created_at < p_to + 1
    AND (v_scope IS NULL OR r.country_code = ANY (v_scope))
  GROUP BY 1, 2
  ORDER BY 1, 2;
END $$;

CREATE FUNCTION public.kpi_payout_failures(p_from date, p_to date, p_country char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), currency char(3), failure_reason_key text, payouts bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(
    ARRAY['super_admin', 'finance_officer']::public.admin_role[], p_country);
BEGIN
  RETURN QUERY
  SELECT pr.country_code, po.currency,
         coalesce(po.failure_reason_key, 'unknown'), private.kpi_suppress(count(*))
  FROM public.payouts po
  JOIN public.profiles pr ON pr.user_id = po.beneficiary_id
  WHERE po.status IN ('failed', 'reversed')
    AND po.created_at >= p_from AND po.created_at < p_to + 1
    AND (v_scope IS NULL OR pr.country_code = ANY (v_scope))
  GROUP BY 1, 2, 3
  ORDER BY 1, 2, 3;
END $$;

CREATE FUNCTION public.kpi_referral_campaign(p_campaign_id uuid)
RETURNS TABLE (campaign_id uuid, country_code char(2), currency char(3),
               budget_minor bigint, spent_minor bigint, commissions bigint,
               open_fraud_flags bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
BEGIN
  SELECT c.country_code INTO v_country FROM public.referral_campaigns c WHERE c.id = p_campaign_id;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- The campaign's own country is the filter, so an officer scoped elsewhere is refused by the
  -- guard rather than shown an empty row that reads as "no spend". The guard's answer is not
  -- needed beyond that refusal: one campaign is one country.
  PERFORM private.kpi_guard(
    ARRAY['super_admin', 'finance_officer']::public.admin_role[], v_country);

  RETURN QUERY
  SELECT c.id, c.country_code, c.currency, c.budget_minor, c.spent_minor,
         (SELECT count(*) FROM public.referral_commissions rc
          WHERE rc.campaign_id = c.id AND rc.status <> 'reversed'),
         (SELECT count(*) FROM public.fraud_flags f
          WHERE f.status = 'open' AND f.rule_key LIKE 'referral%')
  FROM public.referral_campaigns c
  WHERE c.id = p_campaign_id;
END $$;

CREATE FUNCTION public.kpi_supply_demand(
  p_from date, p_to date, p_country char(2) DEFAULT NULL, p_category_id uuid DEFAULT NULL)
RETURNS TABLE (country_code char(2), hour_of_day integer, requests bigint,
               distinct_providers bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope char(2)[] := private.kpi_guard(enum_range(NULL::public.admin_role), p_country);
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

REVOKE ALL ON FUNCTION
  private.kpi_suppress(bigint),
  private.kpi_guard(public.admin_role[], char),
  public.kpi_jobs_by_state(date, date, char),
  public.kpi_gmv(date, date, char),
  public.kpi_funnel(date, date, char),
  public.kpi_verification_queue(char),
  public.kpi_disputes(date, date, char),
  public.kpi_payout_failures(date, date, char),
  public.kpi_referral_campaign(uuid),
  public.kpi_supply_demand(date, date, char, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.kpi_jobs_by_state(date, date, char),
  public.kpi_gmv(date, date, char),
  public.kpi_funnel(date, date, char),
  public.kpi_verification_queue(char),
  public.kpi_disputes(date, date, char),
  public.kpi_payout_failures(date, date, char),
  public.kpi_referral_campaign(uuid),
  public.kpi_supply_demand(date, date, char, uuid)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- §4.4's `[A]`: ten, pending the DPIA. Config rather than a constant, because the number is a
  -- privacy judgement and somebody else gets to make it.
  ('ai.kpi_min_cell', NULL, '10', false)
ON CONFLICT DO NOTHING;
