-- Meet v5 M1, part 2 (`docs/plan/meet-v5-design.md` §2.3, §3.2.2, §3.3, §4.2, §4.3, §9 M1-PR2):
-- the contract skeleton. Every M1 client and admin RPC exists from here on with its final
-- arguments, return shape and grants, so contracts v1 carries the whole M1 surface on day one and
-- the app, website and console can be built against it while the backend fills it in.
--
--   Gating      `private.meet_flag_on` (the flag for this person in this country, testers-only
--               aware, every sub-flag under `meet.v5`), `private.meet_require_access` (the check
--               at the top of every client RPC) and `private.meet_not_built` (what a stub calls).
--   Testers     `private.meet_testers`: while `meet.v5` carries `{"testers_only": true}`, only
--               these accounts pass, whatever the rollout percentage says.
--   Readiness   `private.meet_readiness` and a guard on `public.feature_flags` (D23, OD-53): Meet
--               does not leave testers, and purchases (M2) do not start, until the checklist is
--               complete. The database refuses, so no console, script or service key can skip it.
--   Flags       the seven M1 flags, all off, and the M1 remote config (§3.3).
--   RPCs        46 client and 18 admin functions. 60 are stubs that raise ERR_FEATURE_UNAVAILABLE
--               until the PR named above each group replaces the body. The four readiness and
--               tester functions are built here, because the release cannot start without them.
--
-- **Return shapes are final.** Changing a return type later means DROP and CREATE, which changes
-- the contract under whoever built against it. Where §4 names the fields of a row set, the stub
-- returns TABLE with those columns, a card being one `profile jsonb` column as in
-- `contracts/v1/fixtures/meet/expiring-match.json`. Where §4 names an object (`→ {a, b}`), the stub
-- returns jsonb. Where §4 names no shape at all (a few admin queues and verbs), the stub returns
-- jsonb or SETOF jsonb, so the PR that builds it fixes the fields without a DROP.
--
-- **Stubs reference every parameter** through `meet_not_built(fn, jsonb_build_object(...))`, so
-- `db lint`'s unused-parameter check passes, and a stub with OUT columns ends in an empty RETURN
-- QUERY for the same reason. `meet_not_built` puts the argument names in the error detail and
-- never their values: a birth date or a message has no business in a log. Admin stubs already
-- check the role and the step-up the finished function will, so the generated catalogue lists
-- them and the console can be wired to the right permissions now.
--
-- **The public app 1.4.0 calls nothing here.** No existing function or enum changes; the one
-- change to an existing table is the readiness trigger on `feature_flags`, which looks at three
-- Meet keys and nothing else. The new flags appear in `get_bootstrap()`'s map, which 1.4.0
-- ignores; note that map evaluates each row on its own (no testers-only, no `meet.v5` umbrella),
-- so an app reads Meet's state from `meet_get_state()`, never from bootstrap (§6.2). Until M1-PR3
-- builds it, `meet_get_state()` is a stub too, and ERR_FEATURE_UNAVAILABLE from it means Meet v5
-- is off.

-- ---------------------------------------------------------------------------
-- Testers and readiness (§2.3). Private schema, no client grant: the functions are the only door.
-- ---------------------------------------------------------------------------
CREATE TABLE private.meet_testers (
  user_id  uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  note     text CHECK (length(note) <= 200),
  added_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  added_at timestamptz NOT NULL DEFAULT now()
);

-- `gates` is not in the design's column list. It says which enable an item holds back, because
-- two m1 items (the plan upgrade and backups) are also m2 items (D23: both before Meet leaves
-- testers and before purchases), and that belongs in the data rather than in a function's CASE.
--   m1          `meet.v5` for anybody other than testers
--   m2_testers  `meet.purchases` / `meet.vip` for testers
--   m2          `meet.purchases` / `meet.vip` for everybody
CREATE TABLE private.meet_readiness (
  item      text PRIMARY KEY CHECK (item ~ '^[a-z0-9_]{3,60}$'),
  milestone text NOT NULL CHECK (milestone IN ('m1', 'm2', 'm2_testers')),
  gates     text[] NOT NULL CHECK (cardinality(gates) > 0
                                   AND gates <@ ARRAY['m1', 'm2_testers', 'm2']
                                   AND milestone = ANY (gates)),
  done      boolean NOT NULL DEFAULT false,
  -- Decided by the database, never ticked by hand: `meet_moderators_staffed` is counted each time
  -- it is asked, and `rtdn_test_received` is set by `play-rtdn` (M2).
  auto      boolean NOT NULL DEFAULT false,
  note      text CHECK (length(note) <= 500),
  set_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  set_at    timestamptz
);

ALTER TABLE private.meet_testers ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.meet_testers FORCE ROW LEVEL SECURITY;
ALTER TABLE private.meet_readiness ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.meet_readiness FORCE ROW LEVEL SECURITY;
REVOKE ALL ON private.meet_testers, private.meet_readiness FROM PUBLIC, anon, authenticated;

-- The checklist, from §2.3 and §8.10. OD-39, OD-40 and OD-41 were decided by the owner on
-- 2026-11-26 (docs/OPEN-DECISIONS.md), so that item starts done; every other item is the owner's
-- or counsel's to complete.
INSERT INTO private.meet_readiness (item, milestone, gates, auto, done, note) VALUES
  ('play_restrict_minor_access',  'm1', ARRAY['m1'], false, false, NULL),
  ('play_child_safety_standards', 'm1', ARRAY['m1'], false, false, NULL),
  ('play_content_rating',         'm1', ARRAY['m1'], false, false, NULL),
  ('play_data_safety',            'm1', ARRAY['m1'], false, false, NULL),
  ('play_listing_meet_copy',      'm1', ARRAY['m1'], false, false, NULL),
  ('csae_page_live',              'm1', ARRAY['m1'], false, false, NULL),
  ('childsafety_contact_live',    'm1', ARRAY['m1'], false, false, NULL),
  ('meet_guidelines_page_live',   'm1', ARRAY['m1'], false, false, NULL),
  ('supabase_plan_upgraded',      'm1', ARRAY['m1', 'm2'], false, false, NULL),
  ('backups_running',             'm1', ARRAY['m1', 'm2'], false, false, NULL),
  ('counsel_od37_od38_od42',      'm1', ARRAY['m1'], false, false, NULL),
  ('owner_od39_od40_od41',        'm1', ARRAY['m1'], false, true,
   'Decided by the owner 2026-11-26: docs/OPEN-DECISIONS.md OD-39, OD-40, OD-41'),
  ('meet_moderators_staffed',     'm1', ARRAY['m1'], true, false, NULL),
  ('payments_profile_ok',         'm2_testers', ARRAY['m2_testers', 'm2'], false, false, NULL),
  ('products_created',            'm2_testers', ARRAY['m2_testers', 'm2'], false, false, NULL),
  ('billing_secret_set',          'm2_testers', ARRAY['m2_testers', 'm2'], false, false, NULL),
  ('rtdn_test_received',          'm2_testers', ARRAY['m2_testers', 'm2'], true, false, NULL),
  ('merchant_bank_tax_done',      'm2', ARRAY['m2'], false, false, NULL),
  ('license_tests_passed',        'm2', ARRAY['m2'], false, false, NULL),
  ('counsel_cowrie_terms',        'm2', ARRAY['m2'], false, false, NULL),
  ('owner_od51_revenue',          'm2', ARRAY['m2'], false, false, NULL)
ON CONFLICT (item) DO NOTHING;

-- OD-41: at least two meet moderators who can actually sign in to the console, which means a
-- verified second factor (every admin function requires aal2). Read from the factor itself, as
-- `admin_staff_list` does, because nothing sets `admin_users.mfa_enrolled_at`. Removing a
-- moderator undoes it.
CREATE FUNCTION private.meet_moderators_staffed()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT count(*) >= 2
  FROM public.admin_users a
  WHERE a.disabled_at IS NULL
    AND a.roles::text[] @> ARRAY['meet_moderator']
    AND EXISTS (SELECT 1 FROM auth.mfa_factors f
                WHERE f.user_id = a.user_id AND f.status = 'verified');
$$;

-- Every item as the guard sees it: an `auto` item with a live rule is answered by that rule.
CREATE FUNCTION private.meet_readiness_state()
RETURNS TABLE (item text, milestone text, gates text[], done boolean, auto boolean, note text,
               set_by uuid, set_at timestamptz)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT r.item, r.milestone, r.gates,
         CASE WHEN r.item = 'meet_moderators_staffed' THEN private.meet_moderators_staffed()
              ELSE r.done END,
         r.auto, r.note, r.set_by, r.set_at
  FROM private.meet_readiness r;
$$;

-- The items still open for a tier. A tier with no items at all is not complete: an empty
-- checklist is a broken migration, not a finished launch.
CREATE FUNCTION private.meet_readiness_missing(p_tier text)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN count(*) = 0 THEN ARRAY['no readiness items for ' || coalesce(p_tier, 'null')]
              ELSE coalesce(array_agg(s.item ORDER BY s.item) FILTER (WHERE NOT s.done),
                            '{}'::text[]) END
  FROM private.meet_readiness_state() s
  WHERE p_tier = ANY (s.gates);
$$;

-- The guard (D23). It runs on every write path into `feature_flags`, a `review_config_change`
-- apply included: that apply runs inside the reviewer's transaction, so the raise aborts the
-- review and the proposal stays pending with its signature unspent. Disabling never reaches it
-- (the trigger's WHEN), so the RB-13 kill switch always works. An update that keeps a flag on
-- beyond testers is checked again, so unticking an item later blocks a rollout change but switches
-- nothing off; switching off is the flag's job.
--
-- AFTER, where the design says BEFORE. `apply_config_change` writes a flag with
-- `INSERT ... ON CONFLICT DO UPDATE`, and a BEFORE INSERT trigger fires on the row the INSERT
-- would have written even when the conflict turns it into an update. A proposal of
-- `{"enabled": true}` builds that row with an empty payload, so a BEFORE guard would read the
-- release step "switch meet.v5 on, testers-only" as "switch it on for everybody" and refuse it.
-- An AFTER row trigger fires only for what was actually written. It is not deferred, so it still
-- raises inside the statement, where the caller's exception handler can catch it (S-14).
CREATE FUNCTION private.meet_flag_readiness_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_testers boolean := coalesce(NEW.payload ->> 'testers_only' = 'true', false);
  v_tier    text;
  v_missing text[];
BEGIN
  v_tier := CASE
    WHEN NEW.key = 'meet.v5' AND v_testers THEN NULL
    WHEN NEW.key = 'meet.v5' THEN 'm1'
    WHEN v_testers THEN 'm2_testers'
    ELSE 'm2' END;
  IF v_tier IS NULL THEN
    RETURN NULL;
  END IF;
  v_missing := private.meet_readiness_missing(v_tier);
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'ERR_MEET_NOT_READY' USING ERRCODE = 'P0001',
      DETAIL = format('%s needs readiness %s: %s', NEW.key, v_tier,
                      array_to_string(v_missing, ', '));
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER feature_flags_meet_readiness
  AFTER INSERT OR UPDATE ON public.feature_flags
  FOR EACH ROW
  WHEN (NEW.key IN ('meet.v5', 'meet.purchases', 'meet.vip') AND NEW.enabled)
  EXECUTE FUNCTION private.meet_flag_readiness_guard();

-- ---------------------------------------------------------------------------
-- Gating helpers (§2.3).
-- ---------------------------------------------------------------------------

-- A Meet flag for this person in this country, the way `concierge_enabled` reads one: the country
-- row over the global one, bucketed with `flag_on_for`, and off when there is no row. A row whose
-- payload says `testers_only` admits `private.meet_testers` and nobody else, whatever its rollout.
-- Every sub-flag also needs `meet.v5`, so the umbrella is read first.
CREATE FUNCTION private.meet_flag_on(p_key text, p_user uuid, p_country char(2))
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_key text;
  v_on  boolean;
BEGIN
  IF p_user IS NULL OR p_key IS NULL OR p_key !~ '^meet\.[a-z0-9_.]+$' THEN
    RETURN false;
  END IF;
  FOREACH v_key IN ARRAY CASE WHEN p_key = 'meet.v5' THEN ARRAY['meet.v5']
                              ELSE ARRAY['meet.v5', p_key] END LOOP
    SELECT f.enabled AND CASE
             WHEN f.payload ->> 'testers_only' = 'true' THEN
               EXISTS (SELECT 1 FROM private.meet_testers t WHERE t.user_id = p_user)
             ELSE private.flag_on_for(f.key, f.rollout_pct, p_user) END
    INTO v_on
    FROM public.feature_flags f
    WHERE f.key = v_key AND (f.country_code IS NULL OR f.country_code = p_country)
    ORDER BY f.country_code NULLS LAST
    LIMIT 1;
    IF NOT coalesce(v_on, false) THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END $$;

-- The check at the top of every Meet client RPC, in the design's order: the flag, the profile
-- country, eligibility, the guidelines version, suspension, and (when asked) an active profile.
-- Only the first two can be answered yet. Nobody can be eligible before M1-PR3 creates the
-- eligibility record, so the third refuses everybody who gets that far: if a later PR calls this
-- before it is restated, the answer is no rather than a pass for checks that never ran. M1-PR3
-- restates it whole with eligibility, guidelines, the profile and `last_active_on`, and M1-PR4
-- adds suspension. Every branch is a pure check, so raising is safe.
CREATE FUNCTION private.meet_require_access(p_user uuid, p_feature text, p_need_profile boolean)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
BEGIN
  IF p_user IS NULL OR p_feature IS NULL OR p_need_profile IS NULL
     OR p_feature !~ '^meet\.[a-z0-9_.]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = p_user;
  IF NOT private.meet_flag_on(p_feature, p_user, v_country) THEN
    RAISE EXCEPTION 'ERR_FEATURE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SET' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ERR_MEET_ELIGIBILITY_REQUIRED' USING ERRCODE = 'P0001';
END $$;

-- What every stub calls. Used only by the skeleton: a stub still calling it after its PR has
-- landed is a stub somebody forgot.
CREATE FUNCTION private.meet_not_built(p_fn text, p_args jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'ERR_FEATURE_UNAVAILABLE' USING ERRCODE = 'P0001',
    DETAIL = format('%s(%s) is not built yet', p_fn,
      (SELECT coalesce(string_agg(k, ', ' ORDER BY k), '')
       FROM jsonb_object_keys(coalesce(p_args, '{}'::jsonb)) k));
END $$;

REVOKE ALL ON FUNCTION
  private.meet_moderators_staffed(),
  private.meet_readiness_state(),
  private.meet_readiness_missing(text),
  private.meet_flag_readiness_guard(),
  private.meet_flag_on(text, uuid, char),
  private.meet_require_access(uuid, text, boolean),
  private.meet_not_built(text, jsonb)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Flags and remote config (§3.3). All flags off. `meet.v5` starts testers-only with a rollout of
-- 0, so leaving testers takes a deliberate percentage (RB-17's 5, 25, 100) as well as a complete
-- checklist; testers pass whatever the percentage.
-- ---------------------------------------------------------------------------
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible, payload)
VALUES
  ('meet.v5',                 NULL, false, 0,   true, '{"testers_only": true}'),
  ('meet.discovery',          NULL, false, 100, true, '{}'),
  ('meet.nearby',             NULL, false, 100, true, '{}'),
  ('meet.chat',               NULL, false, 100, true, '{}'),
  ('meet.statuses',           NULL, false, 100, true, '{}'),
  ('meet.games',              NULL, false, 100, true, '{}'),
  ('meet.photo_verification', NULL, false, 100, true, '{}')
ON CONFLICT (key, country_code) DO NOTHING;

-- Client-visible values reach every app through `get_bootstrap()`; the server ones never leave
-- the database. Functions read `meet.min_age` as greatest(18, value), so no row can lower it.
INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('meet.min_age',                               NULL, '18', true),
  ('meet.guidelines_version',                    NULL, '1', true),
  ('meet.min_client_version',                    NULL, '"1.5.0"', true),
  ('meet.require_device_integrity',              NULL, 'true', false),
  ('meet.discovery.daily_size',                  NULL,
   '{"member": 15, "vip": 25, "gold": 25, "platinum": 30, "captain": 30}', true),
  ('meet.discovery.admirer_slots',               NULL, '3', true),
  ('meet.discovery.distance_bands_km',           NULL, '[5, 10, 25, 50]', true),
  ('meet.discovery.pass_cooldown_days',          NULL, '30', true),
  ('meet.discovery.reshow_after_days',           NULL, '14', true),
  ('meet.nearby.page_size',                      NULL, '24', true),
  ('meet.nearby.max_per_day',                    NULL, '72', true),
  ('meet.limits.likes_per_day',                  NULL,
   '{"member": 50, "vip": 200, "ceiling": 300}', true),
  ('meet.limits.super_interest_free_per_day',    NULL, '1', true),
  ('meet.limits.winks_per_day',                  NULL,
   '{"member_free": 10, "vip": 100, "ceiling": 150}', true),
  ('meet.limits.pokes_per_day',                  NULL, '20', true),
  ('meet.limits.new_conversations_per_day',      NULL, '20', false),
  ('meet.limits.messages_per_minute',            NULL, '20', false),
  ('meet.limits.reports_per_day',                NULL, '20', false),
  ('meet.match.ttl_hours',                       NULL, '24', true),
  ('meet.match.reminder_hours_before',           NULL, '3', true),
  ('meet.photos.max',                            NULL, '6', true),
  ('meet.area.min_update_hours',                 NULL, '6', false),
  ('meet.contact_filter',                        NULL,
   '{"min_digits": 7, "tail_window_minutes": 10, "strike_window_hours": 24,
     "restrict_after": 3, "restrict_hours": 24, "review_after_7d": 5}', false),
  ('meet.status.post_min_card',                  NULL, '"member"', true),
  ('meet.status.photo_requires_verified',        NULL, 'true', true),
  ('meet.status.ttl_hours',                      NULL, '24', true),
  ('meet.status.max_per_day',                    NULL, '3', true),
  ('meet.games.round_ttl_hours',                 NULL, '24', true),
  ('meet.games.free_rounds_per_day',             NULL, '5', true),
  ('meet.retention',                             NULL,
   '{"closed_conversation_days": 30, "evidence_after_close_days": 90, "daily_set_days": 7,
     "view_counter_days": 30, "safety_event_months": 3, "verification_selfie_days": 30,
     "age_refusal_device_days": 365}', false),
  ('meet.notify.max_social_per_hour',            NULL, '6', false),
  ('meet.moderation.sla_hours',                  NULL,
   '{"child_safety": 2, "photo": 12, "report": 24, "text": 48}', false)
ON CONFLICT (key, country_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Readiness and testers, built for real (§4.3): super admin only, aal2 through `has_admin_role`,
-- a TOTP code in the last five minutes for a change, and an audit row before anything returns.
-- The super admin is never country-scoped (20260922120700), which is why only the tester verb,
-- the one that names a person, restates the scope.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_meet_readiness()
RETURNS TABLE (item text, milestone text, gates text[], done boolean, auto boolean, note text,
               set_by uuid, set_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.audit_write('meet.readiness.read', 'private.meet_readiness', NULL, NULL, NULL,
    NULL);
  RETURN QUERY
  SELECT s.item, s.milestone, s.gates, s.done, s.auto, s.note, s.set_by, s.set_at
  FROM private.meet_readiness_state() s
  ORDER BY array_position(ARRAY['m1', 'm2_testers', 'm2'], s.milestone), s.item;
END $$;

CREATE FUNCTION public.admin_meet_set_readiness(
  p_idempotency_key text, p_item text, p_done boolean, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_claim  jsonb;
  v_before private.meet_readiness%ROWTYPE;
  v_result jsonb;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  IF p_item IS NULL OR p_done IS NULL OR length(v_note) > 500 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'admin_meet_set_readiness',
    jsonb_build_object('item', p_item, 'done', p_done, 'note', v_note));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_before FROM private.meet_readiness r WHERE r.item = p_item FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'not a readiness item';
  END IF;
  IF v_before.auto THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'this item is set automatically';
  END IF;

  UPDATE private.meet_readiness r
  SET done = p_done, note = v_note, set_by = v_uid, set_at = now()
  WHERE r.item = p_item;

  PERFORM private.audit_write('meet.readiness.set', 'private.meet_readiness', p_item,
    jsonb_build_object('done', v_before.done, 'note', v_before.note),
    jsonb_build_object('done', p_done, 'note', v_note), NULL);

  v_result := jsonb_build_object('item', p_item, 'milestone', v_before.milestone,
                                 'done', p_done, 'note', v_note, 'set_at', now());
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

CREATE FUNCTION public.admin_meet_testers(p_limit integer DEFAULT 100)
RETURNS TABLE (user_id uuid, display_name text, country_code char(2), note text,
               added_by uuid, added_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.audit_write('meet.testers.read', 'private.meet_testers', NULL, NULL, NULL,
    NULL);
  RETURN QUERY
  SELECT t.user_id, p.display_name, p.country_code, t.note, t.added_by, t.added_at
  FROM private.meet_testers t
  LEFT JOIN public.profiles p ON p.user_id = t.user_id
  ORDER BY t.added_at, t.user_id
  LIMIT least(greatest(coalesce(p_limit, 100), 1), 500);
END $$;

CREATE FUNCTION public.admin_meet_set_tester(
  p_idempotency_key text, p_user_id uuid, p_on boolean, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_claim  jsonb;
  v_was    boolean;
  v_result jsonb;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  IF p_user_id IS NULL OR p_on IS NULL OR length(v_note) > 200 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF NOT private.admin_may_read_user(p_user_id, ARRAY['super_admin']::public.admin_role[])
     OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = p_user_id) THEN
    RAISE EXCEPTION 'ERR_PROFILE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'admin_meet_set_tester',
    jsonb_build_object('user_id', p_user_id, 'on', p_on, 'note', v_note));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  v_was := EXISTS (SELECT 1 FROM private.meet_testers t WHERE t.user_id = p_user_id);
  IF p_on THEN
    INSERT INTO private.meet_testers (user_id, note, added_by)
    VALUES (p_user_id, v_note, v_uid)
    ON CONFLICT (user_id) DO UPDATE SET note = EXCLUDED.note;
  ELSE
    DELETE FROM private.meet_testers t WHERE t.user_id = p_user_id;
  END IF;

  PERFORM private.audit_write(CASE WHEN p_on THEN 'meet.tester.added' ELSE 'meet.tester.removed' END,
    'private.meet_testers', p_user_id::text, jsonb_build_object('tester', v_was),
    jsonb_build_object('tester', p_on), NULL);

  v_result := jsonb_build_object('user_id', p_user_id, 'tester', p_on);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- ---------------------------------------------------------------------------
-- Client RPCs (§4.2). Stubs: each raises ERR_FEATURE_UNAVAILABLE until its PR lands.
-- ---------------------------------------------------------------------------

-- State, eligibility and profile: M1-PR3.
CREATE FUNCTION public.meet_get_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_get_state', '{}'::jsonb);
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_check_in(
  p_idempotency_key text, p_birth_date date, p_guidelines_version integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_check_in', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_birth_date', p_birth_date,
    'p_guidelines_version', p_guidelines_version));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_accept_guidelines(p_idempotency_key text, p_version integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_accept_guidelines', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_version', p_version));
END $$;

CREATE FUNCTION public.meet_save_profile(
  p_idempotency_key text, p_first_name text, p_bio text, p_intent text, p_gender text,
  p_show_gender boolean, p_interests text[], p_sensitive_consent boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_save_profile', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_first_name', p_first_name, 'p_bio', p_bio,
    'p_intent', p_intent, 'p_gender', p_gender, 'p_show_gender', p_show_gender,
    'p_interests', p_interests, 'p_sensitive_consent', p_sensitive_consent));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_set_area(
  p_idempotency_key text, p_lat double precision, p_lng double precision)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_set_area', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_lat', p_lat, 'p_lng', p_lng));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_set_discovery_prefs(
  p_idempotency_key text, p_seeking text, p_age_min integer, p_age_max integer,
  p_max_band_km integer, p_intents text[], p_sensitive_consent boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_set_discovery_prefs', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_seeking', p_seeking, 'p_age_min', p_age_min,
    'p_age_max', p_age_max, 'p_max_band_km', p_max_band_km, 'p_intents', p_intents,
    'p_sensitive_consent', p_sensitive_consent));
END $$;

CREATE FUNCTION public.meet_get_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_get_my_profile', '{}'::jsonb);
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_submit_photo(
  p_idempotency_key text, p_inbox_path text, p_thumb_inbox_path text, p_position integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_submit_photo', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_inbox_path', p_inbox_path,
    'p_thumb_inbox_path', p_thumb_inbox_path, 'p_position', p_position));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_remove_photo(p_idempotency_key text, p_photo_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_remove_photo', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_photo_id', p_photo_id));
END $$;

CREATE FUNCTION public.meet_reorder_photos(p_idempotency_key text, p_photo_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_reorder_photos', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_photo_ids', p_photo_ids));
END $$;

CREATE FUNCTION public.meet_save_prompt(
  p_idempotency_key text, p_prompt_key text, p_answer text, p_position integer)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_save_prompt', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_prompt_key', p_prompt_key, 'p_answer', p_answer,
    'p_position', p_position));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_remove_prompt(p_idempotency_key text, p_prompt_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_remove_prompt', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_prompt_id', p_prompt_id));
END $$;

CREATE FUNCTION public.meet_set_discoverable(p_idempotency_key text, p_discoverable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_set_discoverable', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_discoverable', p_discoverable));
END $$;

CREATE FUNCTION public.meet_pause(p_idempotency_key text, p_paused boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_pause', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_paused', p_paused));
END $$;

CREATE FUNCTION public.meet_set_privacy(p_idempotency_key text, p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_set_privacy', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_settings', p_settings));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_delete_profile(p_idempotency_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_delete_profile', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key));
END $$;

-- Discovery and matches: M1-PR5.
CREATE FUNCTION public.meet_daily_set()
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_daily_set', '{}'::jsonb);
  RETURN;
END $$;

CREATE FUNCTION public.meet_get_profile(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_get_profile', jsonb_build_object(
    'p_profile_id', p_profile_id));
  RETURN NULL;
END $$;

-- Rows are cards; at the day's cap the only row is a header carrying `refreshes_at` (§4.2).
CREATE FUNCTION public.meet_nearby(p_band text DEFAULT NULL, p_limit integer DEFAULT 24)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_nearby', jsonb_build_object(
    'p_band', p_band, 'p_limit', p_limit));
  RETURN;
END $$;

CREATE FUNCTION public.meet_swipe(
  p_idempotency_key text, p_profile_id uuid, p_action text, p_like_kind text DEFAULT 'like',
  p_expected_cost integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_swipe', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_profile_id', p_profile_id, 'p_action', p_action,
    'p_like_kind', p_like_kind, 'p_expected_cost', p_expected_cost));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_send_signal(
  p_idempotency_key text, p_profile_id uuid, p_kind text, p_expected_cost integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_send_signal', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_profile_id', p_profile_id, 'p_kind', p_kind,
    'p_expected_cost', p_expected_cost));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_likes_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_likes_summary', '{}'::jsonb);
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_matches()
RETURNS TABLE (match_id uuid, conversation_id uuid, profile jsonb, status text,
               expires_at timestamptz, engaged boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_matches', '{}'::jsonb);
  RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::jsonb, NULL::text, NULL::timestamptz,
                      NULL::boolean WHERE false;
END $$;

CREATE FUNCTION public.meet_unmatch(p_idempotency_key text, p_match_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_unmatch', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_match_id', p_match_id));
END $$;

-- Chat: M1-PR6.
CREATE FUNCTION public.meet_conversations(
  p_before timestamptz DEFAULT NULL, p_limit integer DEFAULT 30)
RETURNS TABLE (conversation_id uuid, profile jsonb, status text, origin text,
               last_message jsonb, unread integer, match_expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_conversations', jsonb_build_object(
    'p_before', p_before, 'p_limit', p_limit));
  RETURN QUERY SELECT NULL::uuid, NULL::jsonb, NULL::text, NULL::text, NULL::jsonb,
                      NULL::integer, NULL::timestamptz WHERE false;
END $$;

-- `peer_last_read_id` repeats on every row and is NULL unless the peer has read receipts on.
CREATE FUNCTION public.meet_messages(
  p_conversation_id uuid, p_before_id bigint DEFAULT NULL, p_limit integer DEFAULT 50)
RETURNS TABLE (id bigint, from_me boolean, kind text, body text, payload jsonb,
               reactions jsonb, created_at timestamptz, removed boolean,
               peer_last_read_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_messages', jsonb_build_object(
    'p_conversation_id', p_conversation_id, 'p_before_id', p_before_id, 'p_limit', p_limit));
  RETURN QUERY SELECT NULL::bigint, NULL::boolean, NULL::text, NULL::text, NULL::jsonb,
                      NULL::jsonb, NULL::timestamptz, NULL::boolean, NULL::bigint WHERE false;
END $$;

CREATE FUNCTION public.meet_send_message(
  p_idempotency_key text, p_conversation_id uuid, p_body text, p_kind text DEFAULT 'text')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_send_message', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_conversation_id', p_conversation_id,
    'p_body', p_body, 'p_kind', p_kind));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_mark_read(p_conversation_id uuid, p_last_message_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_mark_read', jsonb_build_object(
    'p_conversation_id', p_conversation_id, 'p_last_message_id', p_last_message_id));
END $$;

CREATE FUNCTION public.meet_react_to_message(
  p_idempotency_key text, p_conversation_id uuid, p_message_id bigint, p_emoji text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_react_to_message', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_conversation_id', p_conversation_id,
    'p_message_id', p_message_id, 'p_emoji', p_emoji));
END $$;

-- Statuses and games: M1-PR7.
CREATE FUNCTION public.meet_post_status(
  p_idempotency_key text, p_kind text, p_body text, p_background_key text, p_inbox_path text,
  p_thumb_inbox_path text, p_audience text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_post_status', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_kind', p_kind, 'p_body', p_body,
    'p_background_key', p_background_key, 'p_inbox_path', p_inbox_path,
    'p_thumb_inbox_path', p_thumb_inbox_path, 'p_audience', p_audience));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_delete_status(p_idempotency_key text, p_status_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_delete_status', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_status_id', p_status_id));
END $$;

CREATE FUNCTION public.meet_status_ring()
RETURNS TABLE (profile jsonb, is_me boolean, statuses jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_status_ring', '{}'::jsonb);
  RETURN QUERY SELECT NULL::jsonb, NULL::boolean, NULL::jsonb WHERE false;
END $$;

CREATE FUNCTION public.meet_view_status(p_status_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_view_status', jsonb_build_object(
    'p_status_id', p_status_id));
END $$;

CREATE FUNCTION public.meet_status_viewers(p_status_id uuid)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_status_viewers', jsonb_build_object(
    'p_status_id', p_status_id));
  RETURN;
END $$;

CREATE FUNCTION public.meet_game_catalogue()
RETURNS TABLE (key text, available boolean, locked_reason text, free_rounds_left integer,
               cost integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_game_catalogue', '{}'::jsonb);
  RETURN QUERY SELECT NULL::text, NULL::boolean, NULL::text, NULL::integer, NULL::integer
               WHERE false;
END $$;

CREATE FUNCTION public.meet_start_game(
  p_idempotency_key text, p_conversation_id uuid, p_game_key text,
  p_expected_cost integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_start_game', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_conversation_id', p_conversation_id,
    'p_game_key', p_game_key, 'p_expected_cost', p_expected_cost));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_answer_game(p_idempotency_key text, p_round_id uuid, p_answer jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_answer_game', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_round_id', p_round_id, 'p_answer', p_answer));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_get_round(p_round_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_get_round', jsonb_build_object('p_round_id', p_round_id));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_daily_question()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_daily_question', '{}'::jsonb);
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_answer_daily_question(p_idempotency_key text, p_answer jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_answer_daily_question', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_answer', p_answer));
END $$;

-- Safety: M1-PR4. Verification: M1-PR9.
CREATE FUNCTION public.meet_report(
  p_idempotency_key text, p_subject_kind text, p_subject_id text, p_reason_code text,
  p_details text DEFAULT NULL, p_block boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_report', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_subject_kind', p_subject_kind,
    'p_subject_id', p_subject_id, 'p_reason_code', p_reason_code, 'p_details', p_details,
    'p_block', p_block));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_block(p_idempotency_key text, p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_block', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_profile_id', p_profile_id));
END $$;

CREATE FUNCTION public.meet_unblock(p_idempotency_key text, p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_unblock', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_profile_id', p_profile_id));
END $$;

CREATE FUNCTION public.meet_blocked_profiles()
RETURNS TABLE (profile_id uuid, first_name text, blocked_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_blocked_profiles', '{}'::jsonb);
  RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::timestamptz WHERE false;
END $$;

CREATE FUNCTION public.meet_verification_pose(p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_verification_pose', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key));
  RETURN NULL;
END $$;

CREATE FUNCTION public.meet_submit_verification(
  p_idempotency_key text, p_verification_id uuid, p_selfie_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  PERFORM private.meet_not_built('meet_submit_verification', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_verification_id', p_verification_id,
    'p_selfie_path', p_selfie_path));
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- Admin RPCs (§4.3). Stubs, with the finished function's role check and, for a change, its
-- step-up. Moderation, reports, suspensions, bans, birth-date corrections and the user summary:
-- M1-PR4. Verification: M1-PR9.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_meet_moderation_queue(
  p_kind text DEFAULT NULL, p_limit integer DEFAULT 50)
RETURNS TABLE (case_id uuid, subject_kind text, subject_id text, priority smallint,
               labels text[], sla_due_at timestamptz, author_profile_id uuid, content jsonb,
               context jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.meet_not_built('admin_meet_moderation_queue', jsonb_build_object(
    'p_kind', p_kind, 'p_limit', p_limit));
  RETURN QUERY SELECT NULL::uuid, NULL::text, NULL::text, NULL::smallint, NULL::text[],
                      NULL::timestamptz, NULL::uuid, NULL::jsonb, NULL::jsonb WHERE false;
END $$;

CREATE FUNCTION public.admin_meet_decide_case(
  p_idempotency_key text, p_case_id uuid, p_uphold boolean, p_reason_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_decide_case', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_case_id', p_case_id, 'p_uphold', p_uphold,
    'p_reason_code', p_reason_code));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_decide_photo(
  p_idempotency_key text, p_photo_id uuid, p_approve boolean, p_reason_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_decide_photo', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_photo_id', p_photo_id, 'p_approve', p_approve,
    'p_reason_code', p_reason_code));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_report_queue(
  p_status text DEFAULT 'open', p_limit integer DEFAULT 50)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.meet_not_built('admin_meet_report_queue', jsonb_build_object(
    'p_status', p_status, 'p_limit', p_limit));
  RETURN;
END $$;

CREATE FUNCTION public.admin_meet_report_detail(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.meet_not_built('admin_meet_report_detail', jsonb_build_object(
    'p_report_id', p_report_id));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_resolve_report(
  p_idempotency_key text, p_report_id uuid, p_outcome text, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_resolve_report', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_report_id', p_report_id, 'p_outcome', p_outcome,
    'p_note', p_note));
  RETURN NULL;
END $$;

-- `{suspension_id, approval_id}`; a permanent ban returns the approval it is waiting on (§4.3).
CREATE FUNCTION public.admin_meet_suspend(
  p_idempotency_key text, p_user_id uuid, p_until timestamptz, p_reason_code text,
  p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_suspend', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_user_id', p_user_id, 'p_until', p_until,
    'p_reason_code', p_reason_code, 'p_note', p_note));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_approve_ban(p_idempotency_key text, p_approval_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_approve_ban', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_approval_id', p_approval_id));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_lift_suspension(
  p_idempotency_key text, p_suspension_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['meet_moderator', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_lift_suspension', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_suspension_id', p_suspension_id,
    'p_note', p_note));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_correct_birth_date(
  p_idempotency_key text, p_user_id uuid, p_birth_date date, p_evidence_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_correct_birth_date', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_user_id', p_user_id,
    'p_birth_date', p_birth_date, 'p_evidence_note', p_evidence_note));
  RETURN NULL;
END $$;

-- A support agent gets `{has_profile, status, suspended_until}` and nothing else (§4.3).
CREATE FUNCTION public.admin_meet_user_summary(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['meet_moderator', 'super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.meet_not_built('admin_meet_user_summary', jsonb_build_object(
    'p_user_id', p_user_id));
  RETURN NULL;
END $$;

CREATE FUNCTION public.admin_meet_verification_queue(p_limit integer DEFAULT 50)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'meet_moderator',
       'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.meet_not_built('admin_meet_verification_queue', jsonb_build_object(
    'p_limit', p_limit));
  RETURN;
END $$;

CREATE FUNCTION public.admin_meet_decide_verification(
  p_idempotency_key text, p_verification_id uuid, p_approve boolean, p_reason_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'meet_moderator',
       'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_decide_verification', jsonb_build_object(
    'p_idempotency_key', p_idempotency_key, 'p_verification_id', p_verification_id,
    'p_approve', p_approve, 'p_reason_code', p_reason_code));
  RETURN NULL;
END $$;

-- The selfie's `meet-verify` path, for `kyc-document-url` to sign (300 s).
CREATE FUNCTION public.admin_meet_verification_access(p_verification_id uuid, p_reason_code text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'meet_moderator',
       'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  PERFORM private.meet_not_built('admin_meet_verification_access', jsonb_build_object(
    'p_verification_id', p_verification_id, 'p_reason_code', p_reason_code));
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- Grants: authenticated only, never anon. Each function decides who may use it.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.meet_get_state(),
  public.meet_check_in(text, date, integer),
  public.meet_accept_guidelines(text, integer),
  public.meet_save_profile(text, text, text, text, text, boolean, text[], boolean),
  public.meet_set_area(text, double precision, double precision),
  public.meet_set_discovery_prefs(text, text, integer, integer, integer, text[], boolean),
  public.meet_get_my_profile(),
  public.meet_submit_photo(text, text, text, integer),
  public.meet_remove_photo(text, uuid),
  public.meet_reorder_photos(text, uuid[]),
  public.meet_save_prompt(text, text, text, integer),
  public.meet_remove_prompt(text, uuid),
  public.meet_set_discoverable(text, boolean),
  public.meet_pause(text, boolean),
  public.meet_set_privacy(text, jsonb),
  public.meet_delete_profile(text),
  public.meet_daily_set(),
  public.meet_get_profile(uuid),
  public.meet_nearby(text, integer),
  public.meet_swipe(text, uuid, text, text, integer),
  public.meet_send_signal(text, uuid, text, integer),
  public.meet_likes_summary(),
  public.meet_matches(),
  public.meet_unmatch(text, uuid),
  public.meet_conversations(timestamptz, integer),
  public.meet_messages(uuid, bigint, integer),
  public.meet_send_message(text, uuid, text, text),
  public.meet_mark_read(uuid, bigint),
  public.meet_react_to_message(text, uuid, bigint, text),
  public.meet_post_status(text, text, text, text, text, text, text),
  public.meet_delete_status(text, uuid),
  public.meet_status_ring(),
  public.meet_view_status(uuid),
  public.meet_status_viewers(uuid),
  public.meet_game_catalogue(),
  public.meet_start_game(text, uuid, text, integer),
  public.meet_answer_game(text, uuid, jsonb),
  public.meet_get_round(uuid),
  public.meet_daily_question(),
  public.meet_answer_daily_question(text, jsonb),
  public.meet_report(text, text, text, text, text, boolean),
  public.meet_block(text, uuid),
  public.meet_unblock(text, uuid),
  public.meet_blocked_profiles(),
  public.meet_verification_pose(text),
  public.meet_submit_verification(text, uuid, text),
  public.admin_meet_moderation_queue(text, integer),
  public.admin_meet_decide_case(text, uuid, boolean, text),
  public.admin_meet_decide_photo(text, uuid, boolean, text),
  public.admin_meet_report_queue(text, integer),
  public.admin_meet_report_detail(uuid),
  public.admin_meet_resolve_report(text, uuid, text, text),
  public.admin_meet_suspend(text, uuid, timestamptz, text, text),
  public.admin_meet_approve_ban(text, uuid),
  public.admin_meet_lift_suspension(text, uuid, text),
  public.admin_meet_correct_birth_date(text, uuid, date, text),
  public.admin_meet_user_summary(uuid),
  public.admin_meet_verification_queue(integer),
  public.admin_meet_decide_verification(text, uuid, boolean, text),
  public.admin_meet_verification_access(uuid, text),
  public.admin_meet_readiness(),
  public.admin_meet_set_readiness(text, text, boolean, text),
  public.admin_meet_testers(integer),
  public.admin_meet_set_tester(text, uuid, boolean, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.meet_get_state(),
  public.meet_check_in(text, date, integer),
  public.meet_accept_guidelines(text, integer),
  public.meet_save_profile(text, text, text, text, text, boolean, text[], boolean),
  public.meet_set_area(text, double precision, double precision),
  public.meet_set_discovery_prefs(text, text, integer, integer, integer, text[], boolean),
  public.meet_get_my_profile(),
  public.meet_submit_photo(text, text, text, integer),
  public.meet_remove_photo(text, uuid),
  public.meet_reorder_photos(text, uuid[]),
  public.meet_save_prompt(text, text, text, integer),
  public.meet_remove_prompt(text, uuid),
  public.meet_set_discoverable(text, boolean),
  public.meet_pause(text, boolean),
  public.meet_set_privacy(text, jsonb),
  public.meet_delete_profile(text),
  public.meet_daily_set(),
  public.meet_get_profile(uuid),
  public.meet_nearby(text, integer),
  public.meet_swipe(text, uuid, text, text, integer),
  public.meet_send_signal(text, uuid, text, integer),
  public.meet_likes_summary(),
  public.meet_matches(),
  public.meet_unmatch(text, uuid),
  public.meet_conversations(timestamptz, integer),
  public.meet_messages(uuid, bigint, integer),
  public.meet_send_message(text, uuid, text, text),
  public.meet_mark_read(uuid, bigint),
  public.meet_react_to_message(text, uuid, bigint, text),
  public.meet_post_status(text, text, text, text, text, text, text),
  public.meet_delete_status(text, uuid),
  public.meet_status_ring(),
  public.meet_view_status(uuid),
  public.meet_status_viewers(uuid),
  public.meet_game_catalogue(),
  public.meet_start_game(text, uuid, text, integer),
  public.meet_answer_game(text, uuid, jsonb),
  public.meet_get_round(uuid),
  public.meet_daily_question(),
  public.meet_answer_daily_question(text, jsonb),
  public.meet_report(text, text, text, text, text, boolean),
  public.meet_block(text, uuid),
  public.meet_unblock(text, uuid),
  public.meet_blocked_profiles(),
  public.meet_verification_pose(text),
  public.meet_submit_verification(text, uuid, text),
  public.admin_meet_moderation_queue(text, integer),
  public.admin_meet_decide_case(text, uuid, boolean, text),
  public.admin_meet_decide_photo(text, uuid, boolean, text),
  public.admin_meet_report_queue(text, integer),
  public.admin_meet_report_detail(uuid),
  public.admin_meet_resolve_report(text, uuid, text, text),
  public.admin_meet_suspend(text, uuid, timestamptz, text, text),
  public.admin_meet_approve_ban(text, uuid),
  public.admin_meet_lift_suspension(text, uuid, text),
  public.admin_meet_correct_birth_date(text, uuid, date, text),
  public.admin_meet_user_summary(uuid),
  public.admin_meet_verification_queue(integer),
  public.admin_meet_decide_verification(text, uuid, boolean, text),
  public.admin_meet_verification_access(uuid, text),
  public.admin_meet_readiness(),
  public.admin_meet_set_readiness(text, text, boolean, text),
  public.admin_meet_testers(integer),
  public.admin_meet_set_tester(text, uuid, boolean, text)
TO authenticated;
