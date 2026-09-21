-- Phase 8, part 2: the admin verbs for configuration — country packs, feature flags and remote
-- config — and the four-eyes rule that guards them (spec phase 8 "country packs, settings";
-- RLS matrix §1 and §10; `docs/plan/infra-cicd.md` RB-11, RB-13).
--
-- The tables have existed since Phase 2 and **nothing could write to them**: `countries`,
-- `feature_flags` and `remote_config` grant `ALL` to `service_role` and `SELECT` to admins, so
-- every change so far has meant a migration or somebody holding the service key. That is the gap
-- this closes, and closing it is not "add an UPDATE policy": a commission rate and a kill switch
-- are exactly the settings that should need a second person.
--
-- **A change is a proposal, not a write.** `propose_config_change` records what somebody wants
-- to be true and what is true now; `review_config_change` is the second pair of eyes, and only
-- the last approval applies it. The `approvals` table already enforces "not the same person" in
-- its own CHECK; this adds "not the same person twice", which a CHECK cannot see, and reuses the
-- machinery `approve_withdrawal` proved.
--
-- **A country goes live only when its pack is complete.** The spec says so in one line — "a
-- country is live only when its pack is complete and approved" — and `private.country_pack_gaps`
-- is that line made mechanical: it returns what is missing, the admin UI can show it, and the
-- transition to `live` refuses while the list is non-empty. It is a gate on the verb, not a CHECK
-- on the table, because the four countries seeded as `beta` and the one seeded as `live` predate
-- the rule and are not made invalid by it.

CREATE TABLE public.config_changes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target             text NOT NULL,
  -- The country code, flag key or config key this change is about.
  target_key         text NOT NULL CHECK (length(target_key) BETWEEN 2 AND 120),
  -- NULL on a global flag or config row; the country it scopes to otherwise.
  country_code       char(2) REFERENCES public.countries (code),
  proposed           jsonb NOT NULL CHECK (jsonb_typeof(proposed) = 'object'),
  -- What the row looked like when this was proposed, so a reviewer sees the change and not just
  -- the destination — and so an approval that sat for a week is visibly stale.
  previous           jsonb,
  note               text CHECK (note IS NULL OR length(note) <= 1000),
  approvals_required smallint NOT NULL CHECK (approvals_required BETWEEN 1 AND 2),
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'applied', 'rejected', 'cancelled')),
  requested_by       uuid NOT NULL REFERENCES auth.users (id),
  reason_key         text CHECK (reason_key IS NULL OR reason_key ~ '^[a-z0-9_]{3,60}$'),
  created_at         timestamptz NOT NULL DEFAULT now(),
  decided_at         timestamptz,
  applied_at         timestamptz,
  -- Named, because a later migration widens it and an auto-generated name is a guess.
  CONSTRAINT config_changes_target CHECK (
    target IN ('country', 'feature_flag', 'remote_config')),
  CONSTRAINT config_changes_decided CHECK ((status = 'pending') = (decided_at IS NULL)),
  CONSTRAINT config_changes_applied CHECK ((status = 'applied') = (applied_at IS NOT NULL))
);
CREATE INDEX config_changes_pending ON public.config_changes (created_at)
  WHERE status = 'pending';
CREATE INDEX config_changes_target ON public.config_changes (target, target_key, created_at DESC);

ALTER TABLE public.config_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.config_changes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.config_changes FROM anon, authenticated;
GRANT SELECT ON public.config_changes TO authenticated;
GRANT ALL ON public.config_changes TO service_role;
-- Any admin may read the queue: a change to a kill switch is something support should be able to
-- see the moment they wonder why a feature vanished.
CREATE POLICY config_changes_admin_read ON public.config_changes FOR SELECT TO authenticated
  USING ((SELECT private.is_any_admin()));

CREATE TRIGGER config_changes_audit AFTER INSERT OR UPDATE ON public.config_changes
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('id');

-- ---------------------------------------------------------------------------
-- What a country pack still needs. Returns the missing pieces by key, so the admin UI can list
-- them and the `live` transition can refuse on the same answer rather than a second opinion.
--
-- Every item here is something the running system reads. `payment_providers` and
-- `payout_providers` are what `routesFromRows` parses; `sms_providers` is what the OTP sender
-- picks from; `accepted_id_types` is what the KYC screens offer; the legal documents are what
-- sign-up requires consent to. A country missing any of them is live in name only.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.country_pack_gaps(p_code char(2))
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(array_agg(gap ORDER BY gap), '{}'::text[])
  FROM (
    SELECT 'cities' AS gap WHERE NOT EXISTS (
      SELECT 1 FROM public.cities c WHERE c.country_code = p_code)
    UNION ALL
    SELECT 'legal.terms' WHERE NOT EXISTS (
      SELECT 1 FROM public.legal_documents d
      WHERE d.country_code = p_code AND d.type = 'terms'
        AND d.published_at IS NOT NULL AND d.published_at <= now())
    UNION ALL
    SELECT 'legal.privacy' WHERE NOT EXISTS (
      SELECT 1 FROM public.legal_documents d
      WHERE d.country_code = p_code AND d.type = 'privacy'
        AND d.published_at IS NOT NULL AND d.published_at <= now())
    UNION ALL
    SELECT 'config.client.accepted_id_types' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND jsonb_array_length(coalesce(c.config -> 'client' -> 'accepted_id_types',
                                        '[]'::jsonb)) > 0)
    UNION ALL
    SELECT 'config.server.sms_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND jsonb_array_length(coalesce(c.config -> 'server' -> 'sms_providers',
                                        '[]'::jsonb)) > 0)
    UNION ALL
    SELECT 'config.server.payment_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND jsonb_array_length(coalesce(c.config -> 'server' -> 'payment_providers',
                                        '[]'::jsonb)) > 0)
    UNION ALL
    SELECT 'config.server.payout_providers' WHERE NOT EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND jsonb_array_length(coalesce(c.config -> 'server' -> 'payout_providers',
                                        '[]'::jsonb)) > 0)
    UNION ALL
    -- A live country whose only payment provider is the development one would report a customer
    -- paid when nobody did. The Edge Function refuses it too; refusing it here means nobody has
    -- to find out that way.
    SELECT 'config.server.payment_providers.console_only' WHERE EXISTS (
      SELECT 1 FROM public.countries c
      WHERE c.code = p_code
        AND coalesce(c.config -> 'server' -> 'payment_providers', '[]'::jsonb) = '["console"]'::jsonb)
  ) gaps;
$$;

CREATE FUNCTION public.country_pack_readiness(p_code char(2) DEFAULT NULL)
RETURNS TABLE (country_code char(2), status public.country_status, gaps text[], ready boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_any_admin() THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.code, c.status, private.country_pack_gaps(c.code),
         cardinality(private.country_pack_gaps(c.code)) = 0
  FROM public.countries c
  WHERE p_code IS NULL OR c.code = p_code
  ORDER BY c.code;
END $$;

-- ---------------------------------------------------------------------------
-- How many people have to agree. A kill switch is one; money and going live are two.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.config_change_levels(
  p_target text, p_proposed jsonb, p_previous jsonb)
RETURNS smallint
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_target <> 'country' THEN 1
    -- Going live is irreversible in the only way that matters: people sign up.
    WHEN p_proposed ? 'status' AND p_proposed ->> 'status' = 'live'
         AND coalesce(p_previous ->> 'status', '') <> 'live' THEN 2
    WHEN p_proposed ? 'commission_rate_bps' OR p_proposed ? 'referral_rate_bps' THEN 2
    ELSE 1
  END::smallint;
$$;

-- ---------------------------------------------------------------------------
-- Applying a change. Called only by `review_config_change`, once, when the last approval lands.
-- Each branch writes exactly the keys the proposal named and leaves the rest of the row alone,
-- because a proposal is a diff and treating it as a replacement would silently blank fields the
-- proposer never mentioned.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.apply_config_change(p_change public.config_changes)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_gaps text[];
BEGIN
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
      -- A deep merge would make it impossible to remove a key; a replace would make it
      -- impossible to change one without restating the rest. `client` and `server` are merged
      -- separately, which is the grain people actually edit.
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

-- ---------------------------------------------------------------------------
-- propose_config_change — what somebody wants to be true, recorded with what is true now.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.propose_config_change(
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
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'propose_config_change',
    jsonb_build_object('target', p_target, 'target_key', p_target_key,
                       'country_code', p_country_code, 'proposed', p_proposed));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'change_id')::uuid;
  END IF;

  IF p_target NOT IN ('country', 'feature_flag', 'remote_config')
     OR p_proposed IS NULL OR jsonb_typeof(p_proposed) <> 'object'
     OR p_proposed = '{}'::jsonb THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_target = 'country' AND p_target_key !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a country change is keyed by its ISO code';
  END IF;
  IF p_target <> 'country' AND p_target_key !~ '^[a-z0-9_.]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'a flag or config key is lowercase, digits, underscore and dot';
  END IF;

  -- What it is now, for the reviewer. NULL when the row does not exist yet, which is itself
  -- information: this proposal creates something.
  v_previous := CASE p_target
    WHEN 'country' THEN
      (SELECT to_jsonb(c) - 'updated_at' FROM public.countries c
       WHERE c.code = p_target_key::char(2))
    WHEN 'feature_flag' THEN
      (SELECT to_jsonb(f) - 'updated_at' - 'id' FROM public.feature_flags f
       WHERE f.key = p_target_key AND f.country_code IS NOT DISTINCT FROM p_country_code)
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

-- ---------------------------------------------------------------------------
-- review_config_change — the second pair of eyes, and the only thing that writes config.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.review_config_change(
  p_idempotency_key text, p_change_id uuid, p_approve boolean,
  p_reason_key text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_change  public.config_changes%ROWTYPE;
  v_pending uuid;
  v_left    integer;
  v_status  text;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'review_config_change',
    jsonb_build_object('change_id', p_change_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim ->> 'status';
  END IF;

  SELECT * INTO v_change FROM public.config_changes c WHERE c.id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CONFIG_CHANGE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_change.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- Four eyes. The `approvals` CHECK refuses `approved_by = requested_by`; this refuses the same
  -- approver signing twice, which the CHECK cannot see.
  IF v_change.requested_by = v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you proposed this one';
  END IF;
  IF EXISTS (SELECT 1 FROM public.approvals a
             WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
               AND a.approved_by = v_uid) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you have already signed this one';
  END IF;

  SELECT a.id INTO v_pending FROM public.approvals a
  WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
    AND a.status = 'pending'
  ORDER BY a.level LIMIT 1;
  IF v_pending IS NULL THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.approvals a
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
      approved_by = v_uid, decided_at = now()
  WHERE a.id = v_pending;

  IF NOT p_approve THEN
    v_status := 'rejected';
    UPDATE public.approvals a SET status = 'cancelled', decided_at = now()
    WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
      AND a.status = 'pending';
    UPDATE public.config_changes c
    SET status = 'rejected', decided_at = now(), reason_key = p_reason_key
    WHERE c.id = p_change_id;
  ELSE
    SELECT count(*)::integer INTO v_left FROM public.approvals a
    WHERE a.subject_kind = 'config_change' AND a.subject_id = p_change_id::text
      AND a.status = 'pending';
    IF v_left > 0 THEN
      v_status := 'pending';
    ELSE
      v_status := 'applied';
      -- The write itself. If it raises — a pack that is not complete, a country that does not
      -- exist — the whole review rolls back and the change stays pending, which is right: the
      -- proposal was not applied, so it should not say it was.
      PERFORM private.apply_config_change(v_change);
      UPDATE public.config_changes c
      SET status = 'applied', decided_at = now(), applied_at = now(), reason_key = p_reason_key
      WHERE c.id = p_change_id;
    END IF;
  END IF;

  PERFORM private.audit_write('config.review', 'public.config_changes', p_change_id::text,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', v_status, 'approve', p_approve), p_reason_key);
  PERFORM private.emit_event('config', p_change_id::text, 'config.change_' || v_status,
    jsonb_build_object('change_id', p_change_id, 'target', v_change.target,
                       'target_key', v_change.target_key, 'status', v_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

CREATE FUNCTION public.config_change_queue(p_limit integer DEFAULT 100)
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
  IF NOT private.is_any_admin() THEN
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

REVOKE ALL ON FUNCTION
  private.country_pack_gaps(char),
  private.config_change_levels(text, jsonb, jsonb),
  private.apply_config_change(public.config_changes),
  public.country_pack_readiness(char),
  public.propose_config_change(text, text, text, jsonb, char, text),
  public.review_config_change(text, uuid, boolean, text),
  public.config_change_queue(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.country_pack_readiness(char),
  public.propose_config_change(text, text, text, jsonb, char, text),
  public.review_config_change(text, uuid, boolean, text),
  public.config_change_queue(integer)
  TO authenticated;
