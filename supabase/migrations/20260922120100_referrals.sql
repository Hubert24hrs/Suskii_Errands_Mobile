-- Phase 5, part 10: the referral programme — attribution, accrual, holds, clawbacks and
-- campaigns (spec `referral_program`; `docs/plan/money-flows.md` postings 1c, 6a, 7 and 9;
-- OD-01, OD-02, OD-03).
--
-- **The ledger has been carrying this since part 1.** `referral_earnings` and
-- `platform_referral_expense` are two of ADR-0011's thirteen accounts, and the worked example in
-- `28_ledger_test.sql` posts the spec's own 2.19 through them: a 100.00 job, 12.50 commission,
-- 87.50 net, 2.5% of that funded by the platform, leaving net platform revenue of 10.31. What was
-- missing was everything that decides *whose* 2.19 it is. Posting 9 — a referrer withdrawing —
-- was built in part 7 and has had nothing to withdraw.
--
-- **The states are the spec's, and each one is somewhere real.**
--
--   pending   the referee has a paid job in flight; nothing is owed yet
--   earned    the customer confirmed it
--   holding   the dispute window elapsed and earnings were recognised — **this is where the
--             ledger lines are written**, because money-flows 1c puts them there
--   available the fraud hold elapsed and no flag is open; withdrawable
--   reversed  a refund or chargeback took it back
--
-- Posting at `holding` rather than at `available` is deliberate and it is what the books say:
-- from the moment earnings are recognised the platform genuinely owes the referrer that money.
-- Withdrawability is a separate gate, so `private.available_minor` learns to subtract what is
-- posted but still holding — otherwise the fraud hold would be a label with nothing behind it.
--
-- **Single level, and nobody refers themselves.** No downline, per the spec's own note that
-- multi-level earnings invite a pyramid-scheme classification. Self-referral is blocked on the
-- signal the platform actually holds — a shared device fingerprint — and the rest of the
-- spec's list (face template, government ID hash, payout account, card fingerprint) is checked
-- where those live: `identity_documents` already carries a blind index and one identity may hold
-- one account, and `payout_accounts` already flags a shared bank account.
--
-- **OD-01, OD-02 and OD-03 are open, so every one of them is configuration.** The platform funds
-- the commission (OD-01 default); the duration and amount caps are `referral.*` remote config
-- per country (OD-02); the per-job referrer cap defaults to 2, which is OD-03's default of each
-- referrer earning 2.5% with a 5% ceiling. A client answer moves a row, not a migration.

-- ---------------------------------------------------------------------------
-- Codes and attributions.
-- ---------------------------------------------------------------------------
CREATE TABLE public.referral_codes (
  user_id    uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- Unambiguous alphabet: no O/0, I/1/L, so a code read down a phone line still works.
  code       text NOT NULL UNIQUE CHECK (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_codes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.referral_codes FROM anon, authenticated;
GRANT SELECT ON public.referral_codes TO authenticated;
GRANT ALL ON public.referral_codes TO service_role;
-- Own code only. Reading the table by code would turn it into a directory of who invited whom.
CREATE POLICY referral_codes_read_own ON public.referral_codes FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'finance_officer']::public.admin_role[])));

CREATE TABLE public.referrals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- One referrer per referee, for ever: the UNIQUE is what makes "single level only" structural
  -- rather than a rule somebody has to remember.
  referee_id         uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE RESTRICT,
  code               text NOT NULL,
  country_code       char(2) REFERENCES public.countries (code),
  source             text NOT NULL DEFAULT 'manual'
                     CHECK (source IN ('manual', 'deep_link', 'install_referrer')),
  attributed_at      timestamptz NOT NULL DEFAULT now(),
  -- OD-02's duration cap. NULL is the spec's default: the lifetime of the referred account.
  expires_at         timestamptz,
  -- Set by anti-fraud. A blocked attribution keeps its row — the record is the point — and
  -- simply earns nothing.
  blocked_at         timestamptz,
  blocked_reason_key text CHECK (blocked_reason_key IS NULL
                                 OR blocked_reason_key ~ '^[a-z0-9_]{3,60}$'),
  CONSTRAINT referrals_not_self CHECK (referrer_id <> referee_id),
  CONSTRAINT referrals_blocked CHECK ((blocked_at IS NULL) = (blocked_reason_key IS NULL))
);
CREATE INDEX referrals_referrer ON public.referrals (referrer_id, attributed_at DESC);

ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.referrals FROM anon, authenticated;
GRANT SELECT ON public.referrals TO authenticated;
GRANT ALL ON public.referrals TO service_role;
-- Both ends may see the attribution: the referrer because it is their invitation, the referee
-- because being attributed to somebody is a fact about them they are entitled to know.
CREATE POLICY referrals_read_own ON public.referrals FOR SELECT TO authenticated
  USING (referrer_id = (SELECT auth.uid()) OR referee_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Campaigns. A boosted rate, time-boxed, per country, with a budget that cannot be exceeded.
-- ---------------------------------------------------------------------------
CREATE TABLE public.referral_campaigns (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code char(2) NOT NULL REFERENCES public.countries (code),
  name         text NOT NULL CHECK (length(name) BETWEEN 3 AND 120),
  rate_bps     integer NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
  currency     char(3) NOT NULL REFERENCES public.currencies (code),
  budget_minor bigint NOT NULL CHECK (budget_minor > 0),
  spent_minor  bigint NOT NULL DEFAULT 0 CHECK (spent_minor >= 0),
  starts_at    timestamptz NOT NULL,
  ends_at      timestamptz NOT NULL,
  active       boolean NOT NULL DEFAULT true,
  created_by   uuid REFERENCES auth.users (id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_campaigns_window CHECK (ends_at > starts_at),
  -- The spec's "budget caps enforced transactionally", as a constraint rather than a convention.
  -- `accrue` checks it first and raises catchably; this is what no future code path can route
  -- around.
  CONSTRAINT referral_campaigns_budget CHECK (spent_minor <= budget_minor)
);
CREATE INDEX referral_campaigns_live ON public.referral_campaigns (country_code, starts_at)
  WHERE active;

ALTER TABLE public.referral_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_campaigns FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.referral_campaigns FROM anon, authenticated;
-- Column-level, for the same reason as `promo_codes`: the rate and the window are what a user
-- needs to know, and the budget is not — knowing how much is left tells somebody when to hurry.
GRANT SELECT (id, country_code, name, rate_bps, currency, starts_at, ends_at, active)
  ON public.referral_campaigns TO authenticated;
GRANT ALL ON public.referral_campaigns TO service_role;
CREATE POLICY referral_campaigns_read_live ON public.referral_campaigns FOR SELECT TO authenticated
  USING ((active AND now() BETWEEN starts_at AND ends_at)
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

CREATE TRIGGER referral_campaigns_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.referral_campaigns
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('id');

-- ---------------------------------------------------------------------------
-- The commissions themselves.
-- ---------------------------------------------------------------------------
CREATE TABLE public.referral_commissions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id         uuid NOT NULL REFERENCES public.referrals (id) ON DELETE RESTRICT,
  referrer_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  referee_id          uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  request_id          uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  -- Which side of the job the referred person was on. Both can be true of one job for two
  -- different referrers, which is OD-03.
  referee_role        text NOT NULL CHECK (referee_role IN ('customer', 'provider')),
  -- The net the rate was applied to: gross minus commission, per the spec's formula.
  base_minor          bigint NOT NULL CHECK (base_minor >= 0),
  rate_bps            integer NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
  amount_minor        bigint NOT NULL CHECK (amount_minor >= 0),
  currency            char(3) NOT NULL REFERENCES public.currencies (code),
  campaign_id         uuid REFERENCES public.referral_campaigns (id),
  status              public.referral_commission_status NOT NULL DEFAULT 'pending',
  -- When `holding` ends. Set at accrual; the sweep reads it.
  available_at        timestamptz,
  posted_at           timestamptz,
  reversed_reason_key text CHECK (reversed_reason_key IS NULL
                                  OR reversed_reason_key ~ '^[a-z0-9_]{3,60}$'),
  created_at          timestamptz NOT NULL DEFAULT now(),
  -- One commission per referrer per job, which is what makes accrual re-runnable.
  UNIQUE (request_id, referrer_id),
  -- A reversal can catch a commission at either end of its life: one that was posted keeps its
  -- `posted_at`, one that never got there never had one. Both are legitimate `reversed` rows.
  CONSTRAINT referral_commissions_posted CHECK (
    CASE WHEN status IN ('pending', 'earned')   THEN posted_at IS NULL
         WHEN status IN ('holding', 'available') THEN posted_at IS NOT NULL
         ELSE true END),
  CONSTRAINT referral_commissions_parties CHECK (referrer_id <> referee_id)
);
CREATE INDEX referral_commissions_referrer
  ON public.referral_commissions (referrer_id, status, created_at DESC);
CREATE INDEX referral_commissions_maturing
  ON public.referral_commissions (available_at) WHERE status = 'holding';

ALTER TABLE public.referral_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_commissions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.referral_commissions FROM anon, authenticated;
GRANT SELECT ON public.referral_commissions TO authenticated;
GRANT ALL ON public.referral_commissions TO service_role;
-- The referrer sees their own earnings. The **referee does not**: what somebody else earned from
-- your job is not yours to see, and it would tell a referee exactly what their jobs are worth to
-- the person who invited them.
CREATE POLICY referral_commissions_read_own ON public.referral_commissions
  FOR SELECT TO authenticated
  USING (referrer_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'finance_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Rate resolution: a live campaign with budget left beats the country pack's rate.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.referral_rate(p_country char(2), p_currency char(3))
RETURNS TABLE (rate_bps integer, campaign_id uuid)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  -- One row, always: the country's own rate, overridden by the best live campaign that still has
  -- budget. A lateral rather than a union, because `ORDER BY … LIMIT` on a union branch belongs
  -- to the union and not to the branch.
  SELECT coalesce(camp.rate_bps, co.referral_rate_bps), camp.id
  FROM public.countries co
  LEFT JOIN LATERAL (
    SELECT c.rate_bps, c.id
    FROM public.referral_campaigns c
    WHERE c.country_code = co.code AND c.currency = p_currency AND c.active
      AND now() BETWEEN c.starts_at AND c.ends_at
      AND c.spent_minor < c.budget_minor
    ORDER BY c.rate_bps DESC, c.ends_at
    LIMIT 1
  ) camp ON true
  WHERE co.code = p_country;
$$;

-- What a referral has earned so far, for OD-02's amount cap.
CREATE FUNCTION private.referral_earned_minor(p_referral_id uuid)
RETURNS bigint
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(sum(rc.amount_minor), 0)::bigint
  FROM public.referral_commissions rc
  WHERE rc.referral_id = p_referral_id AND rc.status <> 'reversed';
$$;

-- ---------------------------------------------------------------------------
-- my_referral_code — created on first read, which is the only time anybody needs one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := private.require_user();
  v_code text;
  v_try  integer := 0;
BEGIN
  SELECT rc.code INTO v_code FROM public.referral_codes rc WHERE rc.user_id = v_uid;
  IF v_code IS NOT NULL THEN
    RETURN v_code;
  END IF;

  -- 32^8 codes against a few million users: a collision is rare and retrying is cheaper than
  -- reasoning about how rare.
  LOOP
    v_try := v_try + 1;
    v_code := (SELECT string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                                        1 + floor(random() * 32)::integer, 1), '')
               FROM generate_series(1, 8));
    BEGIN
      INSERT INTO public.referral_codes (user_id, code) VALUES (v_uid, v_code);
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      -- Two ways to get here: this code is taken, or this user already has one because a
      -- concurrent call won. The second is not an error.
      SELECT rc.code INTO v_code FROM public.referral_codes rc WHERE rc.user_id = v_uid;
      IF v_code IS NOT NULL THEN
        RETURN v_code;
      END IF;
      IF v_try >= 8 THEN
        RAISE EXCEPTION 'ERR_INTERNAL' USING ERRCODE = 'P0001',
          DETAIL = 'could not allocate a referral code';
      END IF;
    END;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- claim_referral_code — attribution, and the anti-fraud that belongs at attribution time.
--
-- A refusal and a block are different things on purpose. Something the person can see and fix,
-- or that is simply too late, is refused. Something that looks like fraud is **accepted and
-- silently blocked**: the row is kept because the record is the point, the risk engine is told,
-- and nobody gets a free oracle telling them which signal caught them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.claim_referral_code(p_idempotency_key text, p_code text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_code     text := upper(btrim(coalesce(p_code, '')));
  v_referrer uuid;
  v_country  char(2);
  v_months   integer;
  v_expires  timestamptz;
  v_shared   boolean;
  v_recent   integer;
  v_cap      integer;
  v_blocked  text;
  v_id       uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'claim_referral_code',
    jsonb_build_object('code', v_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'referral_id')::uuid;
  END IF;

  IF v_code !~ '^[A-HJ-NP-Z2-9]{8}$' THEN
    RAISE EXCEPTION 'ERR_REFERRAL_CODE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.referrals r WHERE r.referee_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_REFERRAL_ALREADY_ATTRIBUTED' USING ERRCODE = 'P0001';
  END IF;
  -- "A code can also be entered manually during signup (before first job only)" — the spec's
  -- own words. A code typed after a first job is somebody trying to backdate an invitation.
  IF EXISTS (SELECT 1 FROM public.requests r
             WHERE r.customer_id = v_uid AND r.status <> 'draft')
     OR EXISTS (SELECT 1 FROM public.jobs j
                WHERE j.provider_id = v_uid OR j.worker_id = v_uid) THEN
    RAISE EXCEPTION 'ERR_REFERRAL_TOO_LATE' USING ERRCODE = 'P0001';
  END IF;

  SELECT rc.user_id INTO v_referrer FROM public.referral_codes rc WHERE rc.code = v_code;
  IF v_referrer IS NULL THEN
    RAISE EXCEPTION 'ERR_REFERRAL_CODE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_referrer = v_uid THEN
    RAISE EXCEPTION 'ERR_REFERRAL_SELF' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;

  -- The spec's self-referral block, on the signal the platform actually holds. One handset that
  -- has been both accounts is one person, and the two-account trick is the whole of the fraud.
  v_shared := EXISTS (
    SELECT 1 FROM public.user_devices a
    JOIN public.user_devices b ON b.device_fingerprint_hash = a.device_fingerprint_hash
    WHERE a.user_id = v_uid AND b.user_id = v_referrer);

  v_cap := coalesce(private.remote_config_int('referral.max_signups_per_day'), 10);
  SELECT count(*)::integer INTO v_recent FROM public.referrals r
  WHERE r.referrer_id = v_referrer AND r.attributed_at > now() - interval '1 day';

  v_blocked := CASE WHEN v_shared THEN 'referral_shared_device'
                    WHEN v_recent >= v_cap THEN 'referral_velocity'
                    ELSE NULL END;

  v_months := coalesce(private.remote_config_int('referral.duration_months'), 0);
  v_expires := CASE WHEN v_months > 0 THEN now() + make_interval(months => v_months) END;

  INSERT INTO public.referrals (referrer_id, referee_id, code, country_code, source,
                                expires_at, blocked_at, blocked_reason_key)
  VALUES (v_referrer, v_uid, v_code, v_country, 'manual', v_expires,
          CASE WHEN v_blocked IS NOT NULL THEN now() END, v_blocked)
  RETURNING id INTO v_id;

  IF v_blocked IS NOT NULL THEN
    PERFORM private.raise_fraud_flag('user', v_referrer::text, v_blocked, 70::smallint,
      jsonb_build_object('referral_id', v_id, 'referee_id', v_uid,
                         'recent_signups', v_recent));
  ELSE
    PERFORM private.notify(v_referrer, 'system',
      'notification.referral.joined.title', 'notification.referral.joined.body',
      jsonb_build_object('referral_id', v_id), '/referrals');
  END IF;

  PERFORM private.emit_event('referral', v_id::text, 'referral.attributed',
    jsonb_build_object('referral_id', v_id, 'referrer_id', v_referrer, 'referee_id', v_uid,
                       'blocked_reason_key', v_blocked));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('referral_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- accrue_referrals — the ledger entries for money-flows 1c and 6a, and the rows behind them.
--
-- Returns a JSON array of entries for the caller to append to its own posting, and moves the
-- commissions to `holding`. It never posts anything itself: the referral lines belong inside the
-- transaction that recognised the earnings, because that is the event that made them owed.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.accrue_referrals(
  p_request_id uuid, p_net_minor bigint, p_currency char(3))
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_entries  jsonb := '[]'::jsonb;
  v_hold     integer := coalesce(private.remote_config_int('referral.hold_hours'), 72);
  v_maxrefs  integer := coalesce(private.remote_config_int('referral.max_referrers_per_job'), 2);
  v_maxearn  integer := coalesce(private.remote_config_int('referral.max_earned_minor'), 0);
  v_country  char(2);
  v_row      record;
  v_rate     integer;
  v_campaign uuid;
  v_amount   bigint;
  v_earned   bigint;
  v_used     integer := 0;
BEGIN
  -- A job refunded down to nothing shares nothing. Rather than returning here, the cap is set to
  -- zero so the loop exits at once and the cleanup at the end still runs: leaving a commission
  -- `pending` against a job that paid nobody is how it matures three days later.
  IF p_net_minor IS NULL OR p_net_minor <= 0 THEN
    v_maxrefs := 0;
  END IF;
  SELECT r.country_code INTO v_country FROM public.requests r WHERE r.id = p_request_id;

  FOR v_row IN
    -- Both sides of the job, each with their own referrer, and **one row per referrer**: somebody
    -- who introduced the customer and the provider earns one commission, not two. The UNIQUE on
    -- (request_id, referrer_id) already says so; without `DISTINCT ON` the loop would post twice
    -- against a row that can only hold one amount. Ordered so the result does not depend on
    -- physical row order when the per-job cap bites.
    SELECT * FROM (
      SELECT DISTINCT ON (ref.referrer_id)
             ref.id AS referral_id, ref.referrer_id, ref.referee_id,
             side.role AS referee_role, ref.attributed_at
      FROM (SELECT r.customer_id AS uid, 'customer'::text AS role FROM public.requests r
            WHERE r.id = p_request_id
            UNION ALL
            SELECT j.provider_id, 'provider'::text FROM public.jobs j
            WHERE j.request_id = p_request_id AND j.provider_id IS NOT NULL) side
      JOIN public.referrals ref ON ref.referee_id = side.uid
      WHERE ref.blocked_at IS NULL
        AND (ref.expires_at IS NULL OR ref.expires_at > now())
        -- A referrer who is also on this job would be paying themselves a finder's fee for their
        -- own work, which is the collusion case the risk engine already watches for.
        AND ref.referrer_id IS DISTINCT FROM (SELECT r2.customer_id FROM public.requests r2
                                              WHERE r2.id = p_request_id)
        AND ref.referrer_id IS DISTINCT FROM (SELECT j2.provider_id FROM public.jobs j2
                                              WHERE j2.request_id = p_request_id)
        -- Already posted, so there is nothing to post. Without this, a second call — a dispute
        -- resolved on a job whose earnings had somehow been recognised — would pay twice.
        AND NOT EXISTS (SELECT 1 FROM public.referral_commissions rc2
                        WHERE rc2.request_id = p_request_id
                          AND rc2.referrer_id = ref.referrer_id
                          AND rc2.status IN ('holding', 'available', 'reversed'))
      ORDER BY ref.referrer_id, side.role, ref.attributed_at
    ) picked
    ORDER BY picked.referee_role, picked.attributed_at
  LOOP
    EXIT WHEN v_used >= greatest(v_maxrefs, 0);

    SELECT rr.rate_bps, rr.campaign_id INTO v_rate, v_campaign
    FROM private.referral_rate(v_country, p_currency) rr;
    IF v_rate IS NULL OR v_rate = 0 THEN
      CONTINUE;
    END IF;

    v_amount := private.apply_bps(p_net_minor, v_rate);

    -- OD-02's amount cap, counted across this referral's whole history.
    IF v_maxearn > 0 THEN
      v_earned := private.referral_earned_minor(v_row.referral_id);
      v_amount := least(v_amount, greatest(v_maxearn - v_earned, 0));
    END IF;

    -- A campaign cannot overspend its budget. Checked before the write and raised catchably,
    -- because the CHECK that guarantees it is a constraint and an aborted transaction here would
    -- take the whole settlement with it (S-14's lesson, applied to a cheaper constraint).
    IF v_campaign IS NOT NULL THEN
      DECLARE
        v_left bigint;
      BEGIN
        SELECT c.budget_minor - c.spent_minor INTO v_left
        FROM public.referral_campaigns c WHERE c.id = v_campaign FOR UPDATE;
        v_amount := least(v_amount, greatest(coalesce(v_left, 0), 0));
        IF v_amount > 0 THEN
          UPDATE public.referral_campaigns c SET spent_minor = c.spent_minor + v_amount
          WHERE c.id = v_campaign;
        END IF;
      END;
    END IF;

    IF v_amount <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO public.referral_commissions (
      referral_id, referrer_id, referee_id, request_id, referee_role,
      base_minor, rate_bps, amount_minor, currency, campaign_id, status,
      available_at, posted_at)
    VALUES (v_row.referral_id, v_row.referrer_id, v_row.referee_id, p_request_id,
            v_row.referee_role, p_net_minor, v_rate, v_amount, p_currency, v_campaign,
            'holding', now() + make_interval(hours => v_hold), now())
    ON CONFLICT (request_id, referrer_id) DO UPDATE SET
      base_minor = excluded.base_minor,
      rate_bps = excluded.rate_bps,
      amount_minor = excluded.amount_minor,
      campaign_id = excluded.campaign_id,
      status = 'holding',
      available_at = excluded.available_at,
      posted_at = excluded.posted_at;

    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_referral_expense',
                         'amount_minor', v_amount),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_row.referrer_id,
                         'account_type', 'referral_earnings', 'amount_minor', -v_amount));

    PERFORM private.notify(v_row.referrer_id, 'system',
      'notification.referral.earned.title', 'notification.referral.earned.body',
      jsonb_build_object('request_id', p_request_id, 'amount_minor', v_amount,
                         'currency', p_currency), '/referrals');
    PERFORM private.emit_event('referral', v_row.referral_id::text, 'referral.commission_earned',
      jsonb_build_object('referral_id', v_row.referral_id, 'request_id', p_request_id,
                         'referrer_id', v_row.referrer_id, 'amount_minor', v_amount,
                         'currency', p_currency, 'campaign_id', v_campaign));
    v_used := v_used + 1;
  END LOOP;

  -- Anything still anticipated is now decided against: a referral that expired between the job
  -- and its settlement, one past OD-02's cap, one beyond the per-job ceiling, or a job refunded
  -- down to nothing. Left `pending` it would mature later against money nobody was paid.
  UPDATE public.referral_commissions rc
  SET status = 'reversed', reversed_reason_key = 'not_eligible_at_settlement'
  WHERE rc.request_id = p_request_id AND rc.status IN ('pending', 'earned');

  RETURN v_entries;
END $$;

-- ---------------------------------------------------------------------------
-- reverse_referrals — money-flows 7's referral lines. Everything posted for this job, undone.
-- The referrer's balance may go negative, which is the truthful position: they owe it, and the
-- spec says a clawback is offset against future earnings.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.reverse_referrals(p_request_id uuid, p_reason_key text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_entries jsonb := '[]'::jsonb;
  v_row     record;
BEGIN
  FOR v_row IN
    SELECT rc.id, rc.referrer_id, rc.amount_minor, rc.campaign_id
    FROM public.referral_commissions rc
    WHERE rc.request_id = p_request_id AND rc.status IN ('holding', 'available')
    FOR UPDATE
  LOOP
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_referral_expense',
                         'amount_minor', -v_row.amount_minor),
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_row.referrer_id,
                         'account_type', 'referral_earnings',
                         'amount_minor', v_row.amount_minor));
    UPDATE public.referral_commissions rc
    SET status = 'reversed', reversed_reason_key = p_reason_key
    WHERE rc.id = v_row.id;
    -- The budget gets it back: a campaign should not be charged for a job that was charged back.
    IF v_row.campaign_id IS NOT NULL THEN
      UPDATE public.referral_campaigns c
      SET spent_minor = greatest(c.spent_minor - v_row.amount_minor, 0)
      WHERE c.id = v_row.campaign_id;
    END IF;
    PERFORM private.emit_event('referral', v_row.id::text, 'referral.commission_reversed',
      jsonb_build_object('commission_id', v_row.id, 'request_id', p_request_id,
                         'amount_minor', v_row.amount_minor, 'reason_key', p_reason_key));
  END LOOP;

  -- Commissions that never made it to the ledger simply stop: there is nothing to reverse, but
  -- leaving them `pending` would have them mature later against a job that was charged back.
  UPDATE public.referral_commissions rc
  SET status = 'reversed', reversed_reason_key = p_reason_key
  WHERE rc.request_id = p_request_id AND rc.status IN ('pending', 'earned');

  RETURN v_entries;
END $$;

-- ---------------------------------------------------------------------------
-- The two states before the money moves, tracked where the job already announces itself.
--
-- A trigger rather than four more function replacements: `job_events` is written by every
-- transition, and `pending` and `earned` are facts about a transition. It must never raise —
-- it runs inside `job_transition`, inside everything — so it only inserts and updates, and
-- anything it cannot compute it simply skips.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.referral_track_job()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job      public.jobs%ROWTYPE;
  v_country  char(2);
  v_rate     integer;
  v_campaign uuid;
  v_row      record;
BEGIN
  IF NEW.to_status = 'confirmed' THEN
    UPDATE public.referral_commissions rc
    SET status = 'earned'
    WHERE rc.request_id = NEW.request_id AND rc.status = 'pending';
    RETURN NULL;
  END IF;

  IF NEW.to_status <> 'paid_held' THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = NEW.request_id;
  IF NOT FOUND OR v_job.net_minor IS NULL OR v_job.net_minor <= 0 THEN
    RETURN NULL;
  END IF;
  SELECT r.country_code INTO v_country FROM public.requests r WHERE r.id = NEW.request_id;
  SELECT rr.rate_bps, rr.campaign_id INTO v_rate, v_campaign
  FROM private.referral_rate(v_country, v_job.currency) rr;
  IF v_rate IS NULL OR v_rate = 0 THEN
    RETURN NULL;
  END IF;

  FOR v_row IN
    SELECT ref.id AS referral_id, ref.referrer_id, ref.referee_id, side.role AS referee_role
    FROM (SELECT r.customer_id AS uid, 'customer'::text AS role FROM public.requests r
          WHERE r.id = NEW.request_id
          UNION ALL
          SELECT j.provider_id, 'provider'::text FROM public.jobs j
          WHERE j.request_id = NEW.request_id AND j.provider_id IS NOT NULL) side
    JOIN public.referrals ref ON ref.referee_id = side.uid
    WHERE ref.blocked_at IS NULL
      AND (ref.expires_at IS NULL OR ref.expires_at > now())
      AND ref.referrer_id IS DISTINCT FROM v_job.provider_id
      AND ref.referrer_id IS DISTINCT FROM (SELECT r2.customer_id FROM public.requests r2
                                            WHERE r2.id = NEW.request_id)
  LOOP
    -- An anticipated amount, not a promise: `accrue_referrals` recomputes it against whatever
    -- the job finally settles at, which a partial refund can change.
    INSERT INTO public.referral_commissions (
      referral_id, referrer_id, referee_id, request_id, referee_role,
      base_minor, rate_bps, amount_minor, currency, campaign_id, status)
    VALUES (v_row.referral_id, v_row.referrer_id, v_row.referee_id, NEW.request_id,
            v_row.referee_role, v_job.net_minor, v_rate,
            private.apply_bps(v_job.net_minor, v_rate), v_job.currency, v_campaign, 'pending')
    ON CONFLICT (request_id, referrer_id) DO NOTHING;
  END LOOP;
  RETURN NULL;
END $$;

CREATE TRIGGER referral_track_job
  AFTER INSERT ON public.job_events
  FOR EACH ROW EXECUTE FUNCTION private.referral_track_job();

-- ---------------------------------------------------------------------------
-- mature — `holding` to `available`, once the hold has passed and nothing is open against the
-- referrer. A flag raised after the money was posted is exactly the case the hold exists for.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.mature_referral_commissions(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH due AS (
    SELECT rc.id FROM public.referral_commissions rc
    WHERE rc.status = 'holding'
      AND rc.available_at IS NOT NULL AND rc.available_at <= now()
      AND NOT EXISTS (SELECT 1 FROM public.fraud_flags f
                      WHERE f.status = 'open' AND f.subject_kind = 'user'
                        AND f.subject_id = rc.referrer_id::text)
      -- An open dispute on the job means the amount may still change.
      AND NOT EXISTS (SELECT 1 FROM public.disputes d
                      WHERE d.request_id = rc.request_id
                        AND d.status IN ('open', 'under_review'))
    ORDER BY rc.available_at
    LIMIT least(greatest(coalesce(p_limit, 500), 1), 2000)
  )
  UPDATE public.referral_commissions rc SET status = 'available'
  FROM due WHERE rc.id = due.id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- available_minor, replaced: a commission that is posted but still holding is on the books and
-- is not yet withdrawable. Without this the fraud hold would be a label with nothing behind it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.available_minor(
  p_user uuid, p_account ledger.account_type, p_currency char(3))
RETURNS bigint
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce((SELECT -b.balance_minor FROM ledger.balances b
                   JOIN ledger.accounts a ON a.id = b.account_id
                   WHERE a.owner_kind = 'user' AND a.owner_id = p_user
                     AND a.account_type = p_account AND a.currency = p_currency), 0)
       - coalesce((SELECT sum(w.amount_minor)::bigint FROM public.withdrawals w
                   -- `source_account` is text on the table and an enum here, so say which.
                   WHERE w.user_id = p_user AND w.source_account = p_account::text
                     AND w.currency = p_currency
                     AND w.status IN ('requested', 'awaiting_approval', 'approved',
                                      'processing')), 0)
       - CASE WHEN p_account = 'referral_earnings' THEN
           coalesce((SELECT sum(rc.amount_minor)::bigint
                     FROM public.referral_commissions rc
                     WHERE rc.referrer_id = p_user AND rc.currency = p_currency
                       AND rc.status = 'holding'), 0)
         ELSE 0 END;
$$;

-- ---------------------------------------------------------------------------
-- recognise_earnings, replaced whole: money-flows 1c now has its referral lines. Everything else
-- is part 5's version unchanged — the job's hold, the commission, the fee the provider bears and
-- the promo the platform funded.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.recognise_earnings(p_request_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_job     public.jobs%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_fee     bigint;
  v_net     bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = p_request_id AND p.kind = 'job' AND p.status = 'held';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_job.commission_minor IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'the money was never snapshotted on this job';
  END IF;
  IF v_payment.float_minor > 0 AND v_job.item_float_approved_at IS NULL THEN
    RAISE EXCEPTION 'ERR_ITEM_FLOAT_PENDING' USING ERRCODE = 'P0001';
  END IF;

  v_fee := coalesce(v_job.actual_gateway_fee_minor, 0);
  v_net := v_job.net_minor - v_fee;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.job_amount_minor),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', -v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', -v_net));
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', -v_fee));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', v_payment.discount_minor));
  END IF;
  -- The referral is 2.5% of net — gross minus commission, before the gateway fee — because the
  -- spec's formula says so, and the platform funds it (OD-01 default) so the provider's share is
  -- untouched by it.
  v_entries := v_entries || private.accrue_referrals(p_request_id, v_job.net_minor,
                                                     v_job.currency);

  PERFORM private.job_transition(p_request_id, 'confirmed', 'settlement_pending', NULL, 'system');
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.earnings.released.title', 'notification.earnings.released.body',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', v_net,
                       'currency', v_job.currency), '/earnings');

  RETURN ledger.post('earnings_recognised', v_job.currency,
    'earnings:' || p_request_id::text, v_entries, p_request_id, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- resolve_dispute, replaced whole: money-flows 6a's referral lines. Everything else is part 6's
-- version unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_dispute(
  p_idempotency_key text, p_dispute_id uuid, p_resolution_key text,
  p_refund_minor bigint, p_note text)
RETURNS public.dispute_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := private.require_user();
  v_claim     jsonb;
  v_dispute   public.disputes%ROWTYPE;
  v_job       public.jobs%ROWTYPE;
  v_payment   public.payments%ROWTYPE;
  v_refunded  bigint;
  v_kept      bigint;
  v_comm      bigint;
  v_fee       bigint;
  v_provider  bigint;
  v_entries   jsonb;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_resolution_key IS NULL OR p_resolution_key !~ '^[a-z0-9_]{3,60}$'
     OR nullif(btrim(coalesce(p_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a resolution needs a key and a written reason';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'resolve_dispute',
    jsonb_build_object('dispute_id', p_dispute_id, 'resolution', p_resolution_key,
                       'refund_minor', p_refund_minor));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.dispute_status;
  END IF;

  SELECT * INTO v_dispute FROM public.disputes d WHERE d.id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_DISPUTE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_dispute.status NOT IN ('open', 'under_review') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- And nobody decides a job they were on, however senior they are.
  IF private.is_job_participant(v_dispute.request_id) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you were on this job';
  END IF;

  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_dispute.request_id FOR UPDATE;
  SELECT * INTO v_payment FROM public.payments p
  WHERE p.request_id = v_dispute.request_id AND p.kind = 'job' AND p.status = 'held' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF p_refund_minor IS NULL OR p_refund_minor < 0
     OR p_refund_minor > v_payment.job_amount_minor THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'the refund cannot exceed what is held for the job';
  END IF;

  -- **Checked here, catchably.** The `refunds` invariant is a deferred constraint trigger, whose
  -- abort cannot be caught and would take this whole transaction — the audit row, the events,
  -- everything — with it (S-14). A partial refund decided by a person is the first thing in the
  -- system that can actually breach it.
  SELECT coalesce(sum(r.amount_minor), 0)::bigint INTO v_refunded
  FROM public.refunds r WHERE r.payment_id = v_payment.id AND r.status <> 'failed';
  IF v_refunded + p_refund_minor > v_payment.amount_minor THEN
    RAISE EXCEPTION 'ERR_REFUND_EXCEEDS_PAYMENT' USING ERRCODE = 'P0001',
      DETAIL = format('%s already refunded against a payment of %s',
                      v_refunded, v_payment.amount_minor);
  END IF;

  v_kept := v_payment.job_amount_minor - p_refund_minor;
  v_comm := private.apply_bps(v_kept, coalesce(v_job.commission_rate_bps, 1250));
  v_fee  := coalesce(v_job.actual_gateway_fee_minor, 0);
  -- The provider still bears the collection fee on the original charge (ADR-0003), even when
  -- most of it goes back: the gateway kept it either way.
  v_provider := v_kept - v_comm - v_fee;

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'held_funds',
                       'amount_minor', v_payment.job_amount_minor));
  IF p_refund_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'refunds_payable',
                         'amount_minor', -p_refund_minor));
  END IF;
  IF v_comm <> 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                         'amount_minor', -v_comm));
  END IF;
  IF v_fee <> 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', -v_fee));
  END IF;
  IF v_provider <> 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                         'account_type', 'provider_earnings', 'amount_minor', -v_provider));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', v_payment.discount_minor));
  END IF;

  -- money-flows 6a's last two lines: the referral is **recalculated**, not reversed. The job
  -- still happened and the referrer still introduced somebody; what changed is how much the job
  -- was worth, so 2.5% of the reduced net is what is owed. Nothing was posted for it before now,
  -- because a dispute freezes settlement before `recognise_earnings` ever runs.
  v_entries := v_entries || private.accrue_referrals(v_dispute.request_id, v_kept - v_comm,
                                                     v_payment.currency);

  PERFORM ledger.post('refund', v_payment.currency, 'dispute:' || p_dispute_id::text,
    v_entries, v_dispute.request_id, v_uid);

  IF p_refund_minor > 0 THEN
    INSERT INTO public.refunds (payment_id, request_id, amount_minor, currency, reason_code,
                                requested_by, approved_by)
    VALUES (v_payment.id, v_dispute.request_id, p_refund_minor, v_payment.currency,
            p_resolution_key, v_dispute.opened_by, v_uid);
  END IF;

  UPDATE public.payments p
  SET status = CASE WHEN p_refund_minor >= p.job_amount_minor THEN 'refunded'
                    WHEN p_refund_minor > 0 THEN 'partially_refunded'
                    ELSE p.status END::public.payment_status
  WHERE p.id = v_payment.id;

  UPDATE public.disputes d
  SET status = 'resolved', resolution_key = p_resolution_key,
      resolution_note = btrim(p_note), refund_minor = p_refund_minor, resolved_at = now(),
      assigned_officer_id = coalesce(d.assigned_officer_id, v_uid)
  WHERE d.id = p_dispute_id;

  PERFORM private.job_transition(v_dispute.request_id, 'disputed',
    CASE WHEN v_kept > 0 THEN 'settlement_pending' ELSE 'refunded' END::public.job_status,
    v_uid, 'admin', p_resolution_key, p_idempotency_key,
    jsonb_build_object('dispute_id', p_dispute_id, 'refund_minor', p_refund_minor));

  PERFORM private.notify(v_dispute.opened_by, 'job_status',
    'notification.dispute.resolved.title', 'notification.dispute.resolved.body',
    jsonb_build_object('dispute_id', p_dispute_id, 'resolution_key', p_resolution_key,
                       'refund_minor', p_refund_minor, 'currency', v_payment.currency),
    '/disputes/' || p_dispute_id::text);
  PERFORM private.notify(
    CASE WHEN v_dispute.opened_by = v_job.provider_id
         THEN (SELECT r.customer_id FROM public.requests r WHERE r.id = v_dispute.request_id)
         ELSE v_job.provider_id END,
    'job_status',
    'notification.dispute.resolved.title', 'notification.dispute.resolved.body',
    jsonb_build_object('dispute_id', p_dispute_id, 'resolution_key', p_resolution_key,
                       'refund_minor', p_refund_minor, 'currency', v_payment.currency),
    '/disputes/' || p_dispute_id::text);

  PERFORM private.audit_write('dispute.resolve', 'public.disputes', p_dispute_id::text,
    jsonb_build_object('status', v_dispute.status),
    jsonb_build_object('status', 'resolved', 'refund_minor', p_refund_minor,
                       'resolution_key', p_resolution_key), p_resolution_key);
  PERFORM private.emit_event('dispute', p_dispute_id::text, 'dispute.resolved',
    jsonb_build_object('dispute_id', p_dispute_id, 'request_id', v_dispute.request_id,
                       'refund_minor', p_refund_minor, 'resolution_key', p_resolution_key,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'resolved'));
  RETURN 'resolved'::public.dispute_status;
END $$;

-- ---------------------------------------------------------------------------
-- record_chargeback, replaced whole: money-flows 7 reverses the referral with everything else.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.record_chargeback(
  p_payment_id uuid, p_chargeback_fee_minor bigint, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_fee     bigint := greatest(coalesce(p_chargeback_fee_minor, 0), 0);
  v_net     bigint;
  v_entries jsonb;
BEGIN
  SELECT * INTO v_payment FROM public.payments p WHERE p.id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = v_payment.request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_payment.float_minor > 0 THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'a chargeback on a job with an item float needs a person';
  END IF;

  v_net := v_job.net_minor - coalesce(v_job.actual_gateway_fee_minor, 0);

  v_entries := jsonb_build_array(
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_revenue',
                       'amount_minor', v_job.commission_minor),
    jsonb_build_object('owner_kind', 'user', 'owner_id', v_job.provider_id,
                       'account_type', 'provider_earnings', 'amount_minor', v_net),
    jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_available',
                       'amount_minor', -(v_payment.job_amount_minor + v_fee)));
  IF coalesce(v_job.actual_gateway_fee_minor, 0) > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'gateway_fees',
                         'amount_minor', v_job.actual_gateway_fee_minor));
  END IF;
  IF v_payment.discount_minor > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'platform_promo_expense',
                         'amount_minor', -v_payment.discount_minor));
  END IF;
  IF v_fee > 0 THEN
    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object('owner_kind', 'platform', 'account_type', 'chargeback_losses',
                         'amount_minor', v_fee));
  END IF;
  v_entries := v_entries || private.reverse_referrals(v_payment.request_id,
                                                      coalesce(p_reason_key, 'chargeback'));

  UPDATE public.payments p SET status = 'refunded' WHERE p.id = p_payment_id;
  PERFORM private.raise_fraud_flag('user', v_payment.payer_id::text, 'payment_chargeback',
    80::smallint, jsonb_build_object('payment_id', p_payment_id, 'reason_key', p_reason_key));
  PERFORM private.emit_event('payment', p_payment_id::text, 'payment.charged_back',
    jsonb_build_object('payment_id', p_payment_id, 'request_id', v_payment.request_id,
                       'fee_minor', v_fee, 'reason_key', p_reason_key));

  RETURN ledger.post('chargeback', v_payment.currency, 'chargeback:' || p_payment_id::text,
    v_entries, v_payment.request_id, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- The referrer's own view. Amounts by status, and the list behind them.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.my_referral_summary()
RETURNS TABLE (
  currency char(3), status public.referral_commission_status,
  commissions integer, amount_minor bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY
  SELECT rc.currency, rc.status, count(*)::integer, sum(rc.amount_minor)::bigint
  FROM public.referral_commissions rc
  WHERE rc.referrer_id = v_uid
  GROUP BY rc.currency, rc.status
  ORDER BY rc.currency, rc.status;
END $$;

CREATE FUNCTION public.my_referrals(p_limit integer DEFAULT 100)
RETURNS TABLE (
  referral_id uuid, display_name text, joined_at timestamptz, expires_at timestamptz,
  jobs integer, earned_minor bigint, currency char(3))
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := private.require_user();
BEGIN
  RETURN QUERY
  SELECT ref.id, p.display_name, ref.attributed_at, ref.expires_at,
         (SELECT count(*)::integer FROM public.referral_commissions rc
          WHERE rc.referral_id = ref.id AND rc.status <> 'reversed'),
         (SELECT coalesce(sum(rc.amount_minor), 0)::bigint FROM public.referral_commissions rc
          WHERE rc.referral_id = ref.id AND rc.status <> 'reversed'),
         (SELECT rc.currency FROM public.referral_commissions rc
          WHERE rc.referral_id = ref.id ORDER BY rc.created_at LIMIT 1)
  FROM public.referrals ref
  JOIN public.profiles p ON p.user_id = ref.referee_id
  -- A blocked attribution is not shown: it earns nothing, and listing it would tell the
  -- referrer which of their invitations tripped a fraud rule.
  WHERE ref.referrer_id = v_uid AND ref.blocked_at IS NULL
  ORDER BY ref.attributed_at DESC
  LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END $$;

-- ---------------------------------------------------------------------------
-- Campaigns are a config change like any other, so they go through the same four eyes: money
-- leaves the platform on somebody's say-so, and one person should not be that somebody.
-- ---------------------------------------------------------------------------
ALTER TABLE public.config_changes DROP CONSTRAINT config_changes_target;
ALTER TABLE public.config_changes ADD CONSTRAINT config_changes_target
  CHECK (target IN ('country', 'feature_flag', 'remote_config', 'referral_campaign'));

CREATE OR REPLACE FUNCTION private.config_change_levels(
  p_target text, p_proposed jsonb, p_previous jsonb)
RETURNS smallint
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    -- A campaign is a budget. Two people.
    WHEN p_target = 'referral_campaign' THEN 2
    WHEN p_target <> 'country' THEN 1
    WHEN p_proposed ? 'status' AND p_proposed ->> 'status' = 'live'
         AND coalesce(p_previous ->> 'status', '') <> 'live' THEN 2
    WHEN p_proposed ? 'commission_rate_bps' OR p_proposed ? 'referral_rate_bps' THEN 2
    ELSE 1
  END::smallint;
$$;

CREATE OR REPLACE FUNCTION private.apply_config_change(p_change public.config_changes)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_gaps text[];
BEGIN
  IF p_change.target = 'referral_campaign' THEN
    INSERT INTO public.referral_campaigns (id, country_code, name, rate_bps, currency,
                                           budget_minor, starts_at, ends_at, active, created_by)
    VALUES (coalesce(nullif(p_change.target_key, 'new')::uuid, gen_random_uuid()),
            p_change.country_code,
            p_change.proposed ->> 'name',
            (p_change.proposed ->> 'rate_bps')::integer,
            (p_change.proposed ->> 'currency')::char(3),
            (p_change.proposed ->> 'budget_minor')::bigint,
            (p_change.proposed ->> 'starts_at')::timestamptz,
            (p_change.proposed ->> 'ends_at')::timestamptz,
            coalesce((p_change.proposed ->> 'active')::boolean, true),
            p_change.requested_by)
    ON CONFLICT (id) DO UPDATE SET
      name = coalesce(p_change.proposed ->> 'name', referral_campaigns.name),
      rate_bps = coalesce((p_change.proposed ->> 'rate_bps')::integer,
                          referral_campaigns.rate_bps),
      -- A budget may be raised or lowered but never below what has already been spent, which
      -- the table's own CHECK is the last word on.
      budget_minor = coalesce((p_change.proposed ->> 'budget_minor')::bigint,
                              referral_campaigns.budget_minor),
      ends_at = coalesce((p_change.proposed ->> 'ends_at')::timestamptz,
                         referral_campaigns.ends_at),
      active = coalesce((p_change.proposed ->> 'active')::boolean, referral_campaigns.active);
    RETURN;
  END IF;

  IF p_change.target = 'country' THEN
    IF p_change.proposed ->> 'status' = 'live' THEN
      v_gaps := private.country_pack_gaps(p_change.target_key::char(2));
      IF cardinality(v_gaps) > 0 THEN
        RAISE EXCEPTION 'ERR_COUNTRY_PACK_INCOMPLETE' USING ERRCODE = 'P0001',
          DETAIL = array_to_string(v_gaps, ', ');
      END IF;
    END IF;
    UPDATE public.countries c SET
      status = coalesce((p_change.proposed ->> 'status')::public.country_status, c.status),
      commission_rate_bps = coalesce((p_change.proposed ->> 'commission_rate_bps')::integer,
                                     c.commission_rate_bps),
      referral_rate_bps = coalesce((p_change.proposed ->> 'referral_rate_bps')::integer,
                                   c.referral_rate_bps),
      config = jsonb_build_object(
        'client', coalesce(p_change.proposed -> 'config' -> 'client', c.config -> 'client'),
        'server', coalesce(p_change.proposed -> 'config' -> 'server', c.config -> 'server')),
      version = c.version + 1,
      approved_by = p_change.requested_by,
      approved_at = now()
    WHERE c.code = p_change.target_key::char(2);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
    END IF;

  ELSIF p_change.target = 'feature_flag' THEN
    INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible,
                                      payload)
    VALUES (p_change.target_key, p_change.country_code,
            coalesce((p_change.proposed ->> 'enabled')::boolean, false),
            coalesce((p_change.proposed ->> 'rollout_pct')::smallint, 100::smallint),
            coalesce((p_change.proposed ->> 'client_visible')::boolean, true),
            coalesce(p_change.proposed -> 'payload', '{}'::jsonb))
    ON CONFLICT (key, country_code) DO UPDATE SET
      enabled = coalesce((p_change.proposed ->> 'enabled')::boolean, feature_flags.enabled),
      rollout_pct = coalesce((p_change.proposed ->> 'rollout_pct')::smallint,
                             feature_flags.rollout_pct),
      client_visible = coalesce((p_change.proposed ->> 'client_visible')::boolean,
                                feature_flags.client_visible),
      payload = coalesce(p_change.proposed -> 'payload', feature_flags.payload);

  ELSIF p_change.target = 'remote_config' THEN
    IF NOT (p_change.proposed ? 'value') THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a remote_config change must name a value';
    END IF;
    INSERT INTO public.remote_config (key, country_code, value, client_visible)
    VALUES (p_change.target_key, p_change.country_code,
            p_change.proposed -> 'value',
            coalesce((p_change.proposed ->> 'client_visible')::boolean, false))
    ON CONFLICT (key, country_code) DO UPDATE SET
      value = p_change.proposed -> 'value',
      client_visible = coalesce((p_change.proposed ->> 'client_visible')::boolean,
                                remote_config.client_visible);

  ELSE
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = format('no apply path for target %s', p_change.target);
  END IF;
END $$;

-- `propose_config_change` validates the target against its own list, so it learns the new one
-- here rather than in a CHECK it cannot see.
CREATE OR REPLACE FUNCTION public.propose_config_change(
  p_idempotency_key text,
  p_target text,
  p_target_key text,
  p_proposed jsonb,
  p_country_code char(2) DEFAULT NULL,
  p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_previous jsonb;
  v_levels   smallint;
  v_id       uuid;
BEGIN
  IF NOT private.has_admin_role(
       CASE WHEN p_target = 'referral_campaign'
            THEN ARRAY['super_admin', 'finance_officer']::public.admin_role[]
            ELSE ARRAY['super_admin']::public.admin_role[] END) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'propose_config_change',
    jsonb_build_object('target', p_target, 'target_key', p_target_key,
                       'country_code', p_country_code, 'proposed', p_proposed));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'change_id')::uuid;
  END IF;

  IF p_target NOT IN ('country', 'feature_flag', 'remote_config', 'referral_campaign')
     OR p_proposed IS NULL OR jsonb_typeof(p_proposed) <> 'object'
     OR p_proposed = '{}'::jsonb THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_target = 'country' AND p_target_key !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a country change is keyed by its ISO code';
  END IF;
  IF p_target = 'referral_campaign' THEN
    IF p_country_code IS NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a campaign belongs to a country';
    END IF;
    IF p_target_key <> 'new' AND private.try_uuid(p_target_key) IS NULL THEN
      RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
        DETAIL = 'a campaign change names an existing id or the word new';
    END IF;
  ELSIF p_target <> 'country' AND p_target_key !~ '^[a-z0-9_.]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a flag or config key is lowercase, digits, underscore and dot';
  END IF;

  v_previous := CASE p_target
    WHEN 'country' THEN
      (SELECT to_jsonb(c) - 'updated_at' FROM public.countries c
       WHERE c.code = p_target_key::char(2))
    WHEN 'feature_flag' THEN
      (SELECT to_jsonb(f) - 'updated_at' - 'id' FROM public.feature_flags f
       WHERE f.key = p_target_key AND f.country_code IS NOT DISTINCT FROM p_country_code)
    WHEN 'referral_campaign' THEN
      (SELECT to_jsonb(rc) - 'created_at' FROM public.referral_campaigns rc
       WHERE rc.id = private.try_uuid(p_target_key))
    ELSE
      (SELECT to_jsonb(r) - 'updated_at' - 'id' FROM public.remote_config r
       WHERE r.key = p_target_key AND r.country_code IS NOT DISTINCT FROM p_country_code)
  END;

  v_levels := private.config_change_levels(p_target, p_proposed, v_previous);

  INSERT INTO public.config_changes (target, target_key, country_code, proposed, previous, note,
                                     approvals_required, requested_by)
  VALUES (p_target, p_target_key,
          CASE WHEN p_target = 'country' THEN p_target_key::char(2) ELSE p_country_code END,
          p_proposed, v_previous, nullif(btrim(coalesce(p_note, '')), ''), v_levels, v_uid)
  RETURNING id INTO v_id;

  INSERT INTO public.approvals (subject_kind, subject_id, action, payload, requested_by, level)
  SELECT 'config_change', v_id::text, p_target || '.apply',
         jsonb_build_object('target_key', p_target_key, 'country_code', p_country_code),
         v_uid, lvl
  FROM generate_series(1, v_levels) lvl;

  PERFORM private.audit_write('config.propose', 'public.config_changes', v_id::text,
    v_previous, p_proposed, NULL);
  PERFORM private.emit_event('config', v_id::text, 'config.change_proposed',
    jsonb_build_object('change_id', v_id, 'target', p_target, 'target_key', p_target_key,
                       'approvals_required', v_levels));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('change_id', v_id));
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION
  private.referral_rate(char, char),
  private.referral_earned_minor(uuid),
  private.accrue_referrals(uuid, bigint, char),
  private.reverse_referrals(uuid, text),
  private.referral_track_job(),
  private.mature_referral_commissions(integer),
  public.my_referral_code(),
  public.claim_referral_code(text, text),
  public.my_referral_summary(),
  public.my_referrals(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.my_referral_code(),
  public.claim_referral_code(text, text),
  public.my_referral_summary(),
  public.my_referrals(integer)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  -- OD-02 is open. The spec's default is the lifetime of the referred account, so zero months,
  -- and no amount cap; both are here so that a client answer is an UPDATE.
  ('referral.duration_months', NULL, '0', false),
  ('referral.max_earned_minor', NULL, '0', false),
  -- OD-03's default: two referrers on one job, 2.5% each, a 5% ceiling.
  ('referral.max_referrers_per_job', NULL, '2', false),
  ('referral.hold_hours', NULL, '72', false),
  ('referral.max_signups_per_day', NULL, '10', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('mature-referrals', '37 * * * *',
      $cron$SELECT private.mature_referral_commissions()$cron$);
  END IF;
END $$;
