-- Phase 8, part 3: analytics views and the BigQuery export seam (spec phase 8, "BigQuery export
-- and analytics views; operational dashboards"; `docs/plan/data-flow.md` row 24; C4 §BigQuery;
-- OD-15 residency).
--
-- **Aggregates, and only aggregates.** Data flow row 24 classifies this export as pseudonymised,
-- and the cheapest way to be pseudonymised is to carry no identifier at all: every view here
-- groups to a day, a country, a currency or a category, and not one of them selects a user id, a
-- name, a phone number, a free-text description or a coordinate. Nothing needs to be scrubbed
-- downstream because nothing personal leaves.
--
-- That is a real limit and it is worth naming: per-user cohort analysis is not possible from
-- these views. Doing it properly means a keyed pseudonym, the key lives in KMS under ADR-0007 and
-- not in SQL, and the worker that holds that key is the same one waiting on GCP billing as the
-- payout decryption. Row-level export is that worker's job when the key exists; this is not a
-- stopgap for it, it is the aggregate layer the dashboards actually run on.
--
-- **The export is a cursor, not a stream.** `analytics.exports` records how far each view has
-- been shipped; `analytics.due_exports` says what is outstanding; the worker reads the view for
-- that window, writes it to GCS and loads it into BigQuery, then calls `analytics.record_export`.
-- Complete days only — a partial day re-exported tomorrow would double-count in BigQuery, which
-- appends.

CREATE SCHEMA IF NOT EXISTS analytics;
REVOKE ALL ON SCHEMA analytics FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA analytics TO service_role;

-- ---------------------------------------------------------------------------
-- Marketplace shape.
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.requests_daily AS
SELECT date_trunc('day', r.created_at)::date AS day,
       r.country_code,
       r.urgency::text                        AS urgency,
       r.created_via::text                    AS channel,
       r.is_custom_category,
       count(*)::bigint                                                AS requests_created,
       count(*) FILTER (WHERE r.published_at IS NOT NULL)::bigint      AS requests_published,
       count(*) FILTER (WHERE r.status = 'cancelled')::bigint          AS requests_cancelled,
       count(*) FILTER (WHERE r.status = 'expired')::bigint            AS requests_expired,
       count(*) FILTER (WHERE r.scheduled_at IS NOT NULL)::bigint      AS requests_scheduled
FROM public.requests r
GROUP BY 1, 2, 3, 4, 5;

CREATE VIEW analytics.offers_daily AS
SELECT date_trunc('day', o.created_at)::date AS day,
       r.country_code,
       o.currency,
       count(*)::bigint                                              AS offers_made,
       count(*) FILTER (WHERE o.status = 'accepted')::bigint         AS offers_accepted,
       count(*) FILTER (WHERE o.status = 'declined')::bigint         AS offers_declined,
       count(*) FILTER (WHERE o.status = 'countered')::bigint        AS offers_countered,
       count(*) FILTER (WHERE o.status = 'expired')::bigint          AS offers_expired,
       count(DISTINCT o.request_id)::bigint                          AS requests_with_offers,
       -- Percentiles rather than an average: one 500,000 errand would move a mean and tells you
       -- nothing about the market.
       percentile_cont(0.5) WITHIN GROUP (ORDER BY o.amount_minor)::bigint AS median_offer_minor,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY o.amount_minor)::bigint AS p90_offer_minor,
       max(o.round)::integer                                         AS max_rounds
FROM public.offers o
JOIN public.requests r ON r.id = o.request_id
GROUP BY 1, 2, 3;

CREATE VIEW analytics.jobs_daily AS
SELECT date_trunc('day', j.created_at)::date AS day,
       r.country_code,
       j.currency,
       count(*)::bigint                                                   AS jobs_created,
       count(*) FILTER (WHERE j.completed_at IS NOT NULL)::bigint         AS jobs_completed,
       count(*) FILTER (WHERE j.confirmed_at IS NOT NULL)::bigint         AS jobs_confirmed,
       count(*) FILTER (WHERE j.auto_confirmed)::bigint                   AS jobs_auto_confirmed,
       count(*) FILTER (WHERE j.settled_at IS NOT NULL)::bigint           AS jobs_settled,
       count(*) FILTER (WHERE r.status = 'cancelled')::bigint             AS jobs_cancelled,
       count(*) FILTER (WHERE r.status = 'disputed')::bigint              AS jobs_disputed,
       sum(j.agreed_amount_minor)::bigint                                 AS gmv_minor,
       percentile_cont(0.5) WITHIN GROUP (
         ORDER BY extract(epoch FROM j.completed_at - j.assigned_at))::bigint AS median_seconds_to_complete
FROM public.jobs j
JOIN public.requests r ON r.id = j.request_id
GROUP BY 1, 2, 3;

-- The funnel the PRD asks about, on the day the request was published rather than the day each
-- step happened — otherwise the stages belong to different cohorts and the ratios are fiction.
CREATE VIEW analytics.funnel_daily AS
SELECT date_trunc('day', r.published_at)::date AS day,
       r.country_code,
       count(*)::bigint                                                    AS published,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.offers o
                                      WHERE o.request_id = r.id))::bigint  AS received_an_offer,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.jobs j
                                      WHERE j.request_id = r.id))::bigint  AS agreed,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.payments p
                                      WHERE p.request_id = r.id
                                        AND p.status = 'held'))::bigint    AS paid,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.jobs j
                                      WHERE j.request_id = r.id
                                        AND j.confirmed_at IS NOT NULL))::bigint AS confirmed
FROM public.requests r
WHERE r.published_at IS NOT NULL
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- Money. Counts of people are deliberately absent; these are sums of minor units.
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.payments_daily AS
SELECT date_trunc('day', p.created_at)::date AS day,
       r.country_code,
       p.currency,
       p.kind::text                 AS kind,
       coalesce(p.gateway, 'none')  AS gateway,
       coalesce(p.method, 'none')   AS method,
       count(*)::bigint                                              AS payments,
       count(*) FILTER (WHERE p.status = 'held')::bigint             AS payments_held,
       count(*) FILTER (WHERE p.status = 'failed')::bigint           AS payments_failed,
       count(*) FILTER (WHERE p.status IN ('refunded',
                                           'partially_refunded'))::bigint AS payments_refunded,
       sum(p.amount_minor)::bigint                                   AS charged_minor,
       sum(coalesce(p.fee_minor, 0))::bigint                         AS gateway_fee_minor,
       sum(coalesce(p.discount_minor, 0))::bigint                    AS discount_minor,
       sum(coalesce(p.float_minor, 0))::bigint                       AS float_minor
FROM public.payments p
JOIN public.requests r ON r.id = p.request_id
GROUP BY 1, 2, 3, 4, 5, 6;

-- The ledger, by account, by day. This is the one view finance reconciles against: it is derived
-- from `ledger.entries`, which is the truth, not from `ledger.balances`, which is a convenience.
CREATE VIEW analytics.ledger_daily AS
SELECT date_trunc('day', t.created_at)::date AS day,
       t.currency,
       t.kind::text         AS transaction_kind,
       a.account_type::text AS account_type,
       count(DISTINCT t.id)::bigint                                     AS transactions,
       sum(e.amount_minor) FILTER (WHERE e.amount_minor > 0)::bigint    AS debit_minor,
       -sum(e.amount_minor) FILTER (WHERE e.amount_minor < 0)::bigint   AS credit_minor,
       sum(e.amount_minor)::bigint                                      AS net_minor
FROM ledger.entries e
JOIN ledger.transactions t ON t.id = e.transaction_id
JOIN ledger.accounts a ON a.id = e.account_id
GROUP BY 1, 2, 3, 4;

CREATE VIEW analytics.refunds_daily AS
SELECT date_trunc('day', rf.created_at)::date AS day,
       r.country_code,
       rf.currency,
       rf.reason_code,
       count(*)::bigint                                         AS refunds,
       count(*) FILTER (WHERE rf.status = 'failed')::bigint     AS refunds_failed,
       sum(rf.amount_minor)::bigint                             AS refunded_minor
FROM public.refunds rf
JOIN public.requests r ON r.id = rf.request_id
GROUP BY 1, 2, 3, 4;

CREATE VIEW analytics.payouts_daily AS
SELECT date_trunc('day', p.created_at)::date AS day,
       p.currency,
       p.source_account,
       p.status::text AS status,
       count(*)::bigint                            AS payouts,
       sum(p.amount_minor)::bigint                 AS amount_minor,
       sum(coalesce(p.fee_minor, 0))::bigint       AS fee_minor
FROM public.payouts p
GROUP BY 1, 2, 3, 4;

-- ---------------------------------------------------------------------------
-- Referrals. The programme's own dashboard runs on this: how many attributions, how many were
-- blocked before they earned anything, and what the platform funded.
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.referrals_daily AS
SELECT date_trunc('day', ref.attributed_at)::date AS day,
       ref.country_code,
       ref.source,
       count(*)::bigint                                              AS attributions,
       count(*) FILTER (WHERE ref.blocked_at IS NOT NULL)::bigint    AS attributions_blocked
FROM public.referrals ref
GROUP BY 1, 2, 3;

CREATE VIEW analytics.referral_commissions_daily AS
SELECT date_trunc('day', rc.created_at)::date AS day,
       rc.currency,
       rc.status::text AS status,
       rc.referee_role,
       (rc.campaign_id IS NOT NULL) AS from_campaign,
       count(*)::bigint                    AS commissions,
       sum(rc.amount_minor)::bigint        AS amount_minor,
       sum(rc.base_minor)::bigint          AS base_minor
FROM public.referral_commissions rc
GROUP BY 1, 2, 3, 4, 5;

-- ---------------------------------------------------------------------------
-- Trust, safety and support.
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.disputes_daily AS
SELECT date_trunc('day', d.created_at)::date AS day,
       r.country_code,
       d.reason_code,
       d.status::text AS status,
       count(*)::bigint                                                     AS disputes,
       count(*) FILTER (WHERE d.refund_minor > 0)::bigint                   AS with_refund,
       sum(coalesce(d.refund_minor, 0))::bigint                             AS refund_minor,
       percentile_cont(0.5) WITHIN GROUP (
         ORDER BY extract(epoch FROM d.resolved_at - d.created_at))::bigint AS median_seconds_to_resolve
FROM public.disputes d
JOIN public.requests r ON r.id = d.request_id
GROUP BY 1, 2, 3, 4;

CREATE VIEW analytics.support_daily AS
SELECT date_trunc('day', t.created_at)::date AS day,
       t.category,
       t.status::text AS status,
       count(*)::bigint AS tickets,
       percentile_cont(0.5) WITHIN GROUP (
         ORDER BY extract(epoch FROM t.resolved_at - t.created_at))::bigint AS median_seconds_to_close
FROM public.support_tickets t
GROUP BY 1, 2, 3;

CREATE VIEW analytics.moderation_daily AS
SELECT date_trunc('day', m.created_at)::date AS day,
       m.subject_kind,
       m.action::text AS action,
       m.source,
       m.status::text AS status,
       count(*)::bigint                                         AS cases,
       count(*) FILTER (WHERE m.reviewed_at IS NOT NULL)::bigint AS reviewed
FROM public.moderation_cases m
GROUP BY 1, 2, 3, 4, 5;

CREATE VIEW analytics.fraud_daily AS
SELECT date_trunc('day', f.created_at)::date AS day,
       f.subject_kind,
       f.rule_key,
       f.status::text AS status,
       count(*)::bigint   AS flags,
       avg(f.score)::numeric(6, 2) AS mean_score
FROM public.fraud_flags f
GROUP BY 1, 2, 3, 4;

CREATE VIEW analytics.ratings_daily AS
SELECT date_trunc('day', rt.created_at)::date AS day,
       r.country_code,
       rt.direction::text AS direction,
       count(*)::bigint            AS ratings,
       avg(rt.stars)::numeric(4, 3) AS mean_stars
FROM public.ratings rt
JOIN public.requests r ON r.id = rt.request_id
GROUP BY 1, 2, 3;

-- Supply, without naming anybody: how many distinct providers worked on a given day, not which.
CREATE VIEW analytics.providers_daily AS
SELECT date_trunc('day', j.assigned_at)::date AS day,
       r.country_code,
       count(DISTINCT j.provider_id)::bigint AS active_providers,
       count(*)::bigint                      AS assignments
FROM public.jobs j
JOIN public.requests r ON r.id = j.request_id
WHERE j.assigned_at IS NOT NULL
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- The export cursor.
-- ---------------------------------------------------------------------------
CREATE TABLE analytics.exports (
  view_name        text PRIMARY KEY,
  -- The last complete day shipped. NULL means nothing has been, which is where every view starts.
  exported_through date,
  -- The column each view's window is filtered on. Every one of them is `day`; it is a column so
  -- that a later view with a different grain does not have to be a special case in the worker.
  day_column       text NOT NULL DEFAULT 'day',
  enabled          boolean NOT NULL DEFAULT true,
  last_run_at      timestamptz,
  last_row_count   bigint,
  last_error       text
);

REVOKE ALL ON ALL TABLES IN SCHEMA analytics FROM PUBLIC, anon, authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO service_role;
GRANT INSERT, UPDATE ON analytics.exports TO service_role;

INSERT INTO analytics.exports (view_name) VALUES
  ('requests_daily'), ('offers_daily'), ('jobs_daily'), ('funnel_daily'),
  ('payments_daily'), ('ledger_daily'), ('refunds_daily'), ('payouts_daily'),
  ('referrals_daily'), ('referral_commissions_daily'),
  ('disputes_daily'), ('support_daily'), ('moderation_daily'), ('fraud_daily'),
  ('ratings_daily'), ('providers_daily')
ON CONFLICT (view_name) DO NOTHING;

-- What is outstanding. Complete days only: re-exporting a partial day would double-count in
-- BigQuery, which appends rather than merges.
CREATE FUNCTION analytics.due_exports(p_lag_days integer DEFAULT 1)
RETURNS TABLE (view_name text, day_column text, export_from date, export_to date)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT e.view_name, e.day_column,
         coalesce(e.exported_through + 1, current_date - 90),
         current_date - greatest(coalesce(p_lag_days, 1), 1)
  FROM analytics.exports e
  WHERE e.enabled
    AND coalesce(e.exported_through, date '1970-01-01')
        < current_date - greatest(coalesce(p_lag_days, 1), 1)
  ORDER BY e.view_name;
$$;

CREATE FUNCTION analytics.record_export(
  p_view text, p_through date, p_rows bigint, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM analytics.exports e WHERE e.view_name = p_view) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = format('%s is not an exported view', p_view);
  END IF;
  -- A failed run records the failure and **does not move the cursor**: the window it could not
  -- ship is still outstanding, which is the whole point of holding a cursor rather than a clock.
  UPDATE analytics.exports e
  SET exported_through = CASE WHEN p_error IS NULL THEN p_through ELSE e.exported_through END,
      last_run_at = now(),
      last_row_count = CASE WHEN p_error IS NULL THEN p_rows ELSE e.last_row_count END,
      last_error = p_error
  WHERE e.view_name = p_view;
END $$;

-- Ops: an export that has stopped is invisible until somebody asks a question of a dashboard and
-- gets a stale answer, so it is a health check like any other.
CREATE FUNCTION analytics.export_health(p_max_lag_days integer DEFAULT 3)
RETURNS TABLE (view_name text, exported_through date, lag_days integer, last_error text)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT e.view_name, e.exported_through,
         (current_date - coalesce(e.exported_through, current_date - 90))::integer,
         e.last_error
  FROM analytics.exports e
  WHERE e.enabled
    AND (e.last_error IS NOT NULL
         OR coalesce(e.exported_through, date '1970-01-01')
            < current_date - greatest(coalesce(p_max_lag_days, 3), 1))
  ORDER BY e.view_name;
$$;

CREATE FUNCTION analytics.record_export_health()
RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_max   integer := coalesce(private.remote_config_int('ops.analytics_max_lag_days'), 3);
  v_stale integer;
  v_status text;
BEGIN
  SELECT count(*)::integer INTO v_stale FROM analytics.export_health(v_max);
  v_status := CASE WHEN v_stale = 0 THEN 'ok' ELSE 'warn' END;
  PERFORM private.record_health_check('analytics_export', v_status,
    jsonb_build_object('stale_views', v_stale, 'max_lag_days', v_max));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- The dashboard surface. One function rather than sixteen grants: the views live in a schema no
-- client role can reach, and this is the vetted door through it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.analytics_report(
  p_view text, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_limit integer DEFAULT 400)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_from date := coalesce(p_from, current_date - 30);
  v_to   date := coalesce(p_to, current_date);
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'finance_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- The registry is the allowlist, so a view name can never be anything this migration did not
  -- put there — which is what makes the `format` below safe.
  IF NOT EXISTS (SELECT 1 FROM analytics.exports e WHERE e.view_name = p_view AND e.enabled) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = format('%s is not an analytics view', p_view);
  END IF;
  IF v_to < v_from THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the window ends before it starts';
  END IF;

  RETURN QUERY EXECUTE format(
    'SELECT to_jsonb(v) FROM analytics.%I v WHERE v.day BETWEEN $1 AND $2 '
    || 'ORDER BY v.day DESC LIMIT $3', p_view)
  USING v_from, v_to, least(greatest(coalesce(p_limit, 400), 1), 5000);
END $$;

REVOKE ALL ON FUNCTION
  analytics.due_exports(integer),
  analytics.record_export(text, date, bigint, text),
  analytics.export_health(integer),
  analytics.record_export_health(),
  public.analytics_report(text, date, date, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  analytics.due_exports(integer),
  analytics.record_export(text, date, bigint, text),
  analytics.export_health(integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.analytics_report(text, date, date, integer) TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('ops.analytics_max_lag_days', NULL, '3', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('analytics-export-health', '11 7 * * *',
      $cron$SELECT analytics.record_export_health()$cron$);
  END IF;
END $$;
