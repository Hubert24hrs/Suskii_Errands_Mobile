-- `countries.approved_by` named the proposer.
--
-- (Written as 20261026160000; renamed 2026-10-26 before anything applied it, because it merged after
-- 20261026170000 had reached staging and `db push` refuses an older migration behind a newer one.)
--
-- Found rehearsing RB-08 on staging (2026-10-26) with a fake country taken disabled -> beta -> live
-- -> disabled through the four-eyes flow: every step applied correctly, and every one stamped the
-- country with the person who *asked*, because the apply copied `requested_by`. Somebody reading the
-- row to see who signed a country live would find the one person the rule says cannot be enough.
-- `approvals` has always held the real signatures; this makes the column agree with them.
--
-- The whole function is restated because a plpgsql body cannot be patched; the one line that
-- changes is marked.

CREATE OR REPLACE FUNCTION private.apply_config_change(p_change public.config_changes)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_gaps  text[];
  v_user  uuid;
  v_roles public.admin_role[];
  v_scope char(2)[];
BEGIN
  IF p_change.target = 'admin_user' THEN
    v_user := p_change.target_key::uuid;
    IF p_change.proposed ? 'roles' THEN
      v_roles := ARRAY(SELECT jsonb_array_elements_text(p_change.proposed -> 'roles'))
                   ::public.admin_role[];
    END IF;
    IF jsonb_typeof(p_change.proposed -> 'country_scope') = 'array' THEN
      v_scope := ARRAY(SELECT jsonb_array_elements_text(p_change.proposed -> 'country_scope'))
                   ::char(2)[];
    END IF;
    -- An existing row is updated field by field; a new one is inserted. Not one upsert, because
    -- the insert half would be checked for NOT NULL roles even when the row already exists.
    UPDATE public.admin_users a SET
      roles = coalesce(v_roles, a.roles),
      country_scope = CASE WHEN p_change.proposed ? 'country_scope' THEN v_scope
                           ELSE a.country_scope END,
      disabled_at = CASE
        WHEN NOT p_change.proposed ? 'active' THEN a.disabled_at
        WHEN (p_change.proposed ->> 'active')::boolean THEN NULL
        ELSE coalesce(a.disabled_at, now()) END
    WHERE a.user_id = v_user;
    IF NOT FOUND THEN
      INSERT INTO public.admin_users (user_id, roles, country_scope, disabled_at)
      VALUES (v_user, v_roles, v_scope,
              CASE WHEN (p_change.proposed ->> 'active')::boolean IS FALSE THEN now() END);
    END IF;
    -- Disabling is immediate: every admin function re-reads `admin_users`, and the sessions go
    -- too, so a token minted before the change does not outlive it.
    IF (p_change.proposed ->> 'active')::boolean IS FALSE THEN
      DELETE FROM auth.sessions s WHERE s.user_id = v_user;
    END IF;
    RETURN;
  END IF;

  IF p_change.target = 'promo_code' THEN
    INSERT INTO public.promo_codes (id, code, country_code, currency, discount_kind,
                                    discount_value, max_discount_minor, budget_minor, max_uses,
                                    per_user_limit, stacks_with_referral, starts_at, ends_at,
                                    active)
    VALUES (coalesce(nullif(p_change.target_key, 'new')::uuid, gen_random_uuid()),
            p_change.proposed ->> 'code',
            p_change.country_code,
            coalesce((p_change.proposed ->> 'currency')::char(3),
                     (SELECT c.currency_code FROM public.countries c
                      WHERE c.code = p_change.country_code)),
            (p_change.proposed ->> 'discount_kind')::public.discount_kind,
            (p_change.proposed ->> 'discount_value')::bigint,
            (p_change.proposed ->> 'max_discount_minor')::bigint,
            (p_change.proposed ->> 'budget_minor')::bigint,
            (p_change.proposed ->> 'max_uses')::integer,
            coalesce((p_change.proposed ->> 'per_user_limit')::smallint, 1::smallint),
            coalesce((p_change.proposed ->> 'stacks_with_referral')::boolean, false),
            coalesce((p_change.proposed ->> 'starts_at')::timestamptz, now()),
            (p_change.proposed ->> 'ends_at')::timestamptz,
            coalesce((p_change.proposed ->> 'active')::boolean, true))
    ON CONFLICT (id) DO UPDATE SET
      active = coalesce((p_change.proposed ->> 'active')::boolean, promo_codes.active),
      -- Never below what has been spent; the table's CHECK and `spent_minor` have the last word.
      budget_minor = CASE WHEN p_change.proposed ? 'budget_minor'
                          THEN (p_change.proposed ->> 'budget_minor')::bigint
                          ELSE promo_codes.budget_minor END,
      ends_at = CASE WHEN p_change.proposed ? 'ends_at'
                     THEN (p_change.proposed ->> 'ends_at')::timestamptz
                     ELSE promo_codes.ends_at END,
      max_uses = CASE WHEN p_change.proposed ? 'max_uses'
                      THEN (p_change.proposed ->> 'max_uses')::integer
                      ELSE promo_codes.max_uses END,
      max_discount_minor = CASE WHEN p_change.proposed ? 'max_discount_minor'
                                THEN (p_change.proposed ->> 'max_discount_minor')::bigint
                                ELSE promo_codes.max_discount_minor END;
    RETURN;
  END IF;

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
      -- The last signature, not the proposal: this runs inside that reviewer's
      -- review_config_change, the only caller.
      approved_by = auth.uid(),
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
