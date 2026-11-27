-- Structural guarantees that must hold for every migration, present and future.
-- When a new client-callable function or client-writable column is added deliberately,
-- extend the allowlists below in the same change, with the RLS matrix cell it implements.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(18);

-- Internal schemas are unreachable for client roles.
SELECT is(
  (SELECT count(*)::int FROM unnest(ARRAY['ledger', 'kyc', 'audit', 'analytics']) s,
          unnest(ARRAY['anon', 'authenticated']) r
   WHERE has_schema_privilege(r, s, 'USAGE')),
  0, 'anon and authenticated have no USAGE on ledger, kyc, audit or analytics');

-- RLS enabled and forced on every table in public (S-13 finding 5).
SELECT is(
  (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity),
  '{}'::text[], 'every public table has row level security enabled');

SELECT is(
  (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relforcerowsecurity),
  '{}'::text[], 'every public table forces row level security');

-- SECURITY DEFINER functions pin an empty search_path (CLAUDE.md non-negotiable).
SELECT is(
  (SELECT coalesce(array_agg(n.nspname || '.' || p.proname ORDER BY 1), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit', 'analytics')
     AND p.prosecdef
     AND NOT coalesce('search_path=""' = ANY (p.proconfig), false)),
  '{}'::text[], 'every SECURITY DEFINER function sets search_path to empty');

-- Nothing is callable by client roles unless it is on these allowlists.
SELECT is(
  (SELECT coalesce(array_agg(DISTINCT n.nspname || '.' || p.proname), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit', 'analytics')
     AND has_function_privilege('anon', p.oid, 'EXECUTE')
     AND n.nspname || '.' || p.proname NOT IN
       ('public.get_bootstrap', 'public.get_shared_trip')),
  '{}'::text[], 'anon can execute only allowlisted functions');

SELECT is(
  (SELECT coalesce(array_agg(DISTINCT n.nspname || '.' || p.proname), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'private', 'ledger', 'kyc', 'audit', 'analytics')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     AND n.nspname || '.' || p.proname NOT IN (
       'public.get_bootstrap', 'public.set_active_mode', 'public.register_device',
       -- First-run role selection and the catalogue as data (20261103120000, -120100).
       'public.select_initial_role', 'public.admin_save_service', 'public.admin_set_service_active',
       'public.admin_service_catalogue',
       -- Ask Suskii usage and cost control (20261103120200).
       'public.concierge_release_turn', 'public.my_ai_usage', 'public.admin_ai_usage_summary',
       'public.admin_ai_users', 'public.admin_set_ai_quota', 'public.admin_grant_ai_credits',
       'public.admin_set_ai_suspension', 'public.admin_set_ai_budget', 'public.admin_set_ai_tier',
       'public.admin_set_ai_enabled',
       'public.record_consent', 'public.request_integrity_nonce',
       'public.list_sessions', 'public.revoke_session', 'public.revoke_other_sessions',
       -- Account lifecycle (20260927120000): deletion with a grace period, and export.
       'public.request_account_deletion', 'public.cancel_account_deletion',
       'public.request_data_export',
       'public.create_request', 'public.publish_request', 'public.cancel_request',
       'public.create_offer', 'public.counter_offer', 'public.accept_offer',
       'public.decline_offer', 'public.withdraw_offer',
       'public.set_online', 'public.update_provider_services',
       'public.update_provider_service_areas', 'public.heartbeat',
       'public.provider_feed',
       'public.set_job_status', 'public.verify_pin', 'public.reveal_job_pin',
       'public.confirm_completion', 'public.confirm_hire', 'public.record_goods_receipt',
       'public.submit_proof', 'public.rate_job',
       'public.send_message', 'public.mark_read',
       'public.block_user', 'public.unblock_user', 'public.favorite_provider',
       'public.report_user',
       'public.register_organization', 'public.invite_member',
       'public.accept_organization_invite', 'public.remove_member',
       'public.set_member_options', 'public.register_vehicle',
       'public.dispatch_job', 'public.claim_job',
       'private.is_org_member', 'private.org_role',
       'public.mark_notifications_read',
       'public.add_trusted_contact', 'public.remove_trusted_contact',
       -- Saved places and access notes (20260929120100; matrix §2 `saved_places`: I:own,
       -- delete own, "access note via F only", and `reveal_access_note` for the provider).
       'public.add_saved_place', 'public.set_saved_place_access_note',
       'public.get_saved_place_access_note', 'public.remove_saved_place',
       'public.set_request_access_note', 'public.reveal_access_note',
       'public.raise_sos', 'public.update_sos_incident',
       'public.create_trip_share', 'public.revoke_trip_share',
       'public.get_shared_trip',
       'public.start_verification_session', 'public.submit_kyc_step',
       'public.submit_identity_document', 'public.submit_police_clearance',
       'public.get_my_kyc_profile', 'public.kyc_review_queue',
       'public.decide_kyc_step', 'public.request_document_access',
       'public.verification_summary',
       'public.moderation_queue', 'public.decide_moderation_case',
       'public.fraud_queue', 'public.review_fraud_flag',
       'public.start_call', 'public.answer_call', 'public.end_call',
       'public.request_pstn_fallback',
       'public.open_ticket', 'public.reply_to_ticket', 'public.ticket_queue',
       'public.update_ticket', 'public.suspend_provider', 'public.reinstate_provider',
       'private.support_ticket_scope',
       'public.my_balances', 'public.start_payment', 'public.cancel_job',
       'public.preview_promo', 'public.add_tip',
       'public.submit_float_receipt', 'public.approve_float_receipt',
       -- OD-04 float top-up (20261012120000): the provider asks, the customer answers.
       'public.request_float_top_up', 'public.respond_float_top_up',
       -- Kimi's change requests (20261012130100, -130200): KYC completeness and the three reads.
       'public.get_kyc_step_payload', 'public.submit_kyc_for_review',
       'public.my_wallet_transactions', 'public.my_pending_balance',
       'public.provider_home_summary',
       -- The admin console (20261013120000, audit Z.8).
       'public.admin_overview', 'public.audit_search', 'public.admin_staff_list',
       'public.admin_staff_lookup', 'public.dispute_resolution_quote', 'public.admin_promo_codes',
       -- The business console and provider tools (20261013120100, audit Z.9/Z.15).
       'public.my_organization', 'public.my_organization_members',
       'public.my_organization_invitations', 'public.invite_member_by_phone', 'public.assign_vehicle', 'public.org_assignable_jobs',
       'public.set_availability', 'public.set_earnings_goal', 'public.my_earnings_goal',
       'public.my_provider_insights', 'public.provider_demand_heatmap', 'public.nearby_providers',
       -- Social sign-up country and Suskii Meet (20261024120000, 20261024120100).
       'public.set_initial_country', 'public.create_meetup', 'public.list_meetups',
       'public.get_meetup', 'public.my_meetups', 'public.join_meetup', 'public.leave_meetup',
       'public.cancel_meetup', 'public.meetup_attendees',
       -- Ask Suskii, the concierge (20261026190000).
       'public.concierge_start', 'public.concierge_begin_turn', 'public.concierge_record_turn',
       -- Meet v5 M1 (20261126120100; matrix §11): every client and admin RPC of design §4.2 and
       -- §4.3. The skeleton built the last four and M1-PR3 (20261126120200) the first sixteen;
       -- the rest are stubs until their own PR lands.
       'public.meet_get_state', 'public.meet_check_in', 'public.meet_accept_guidelines',
       'public.meet_save_profile', 'public.meet_set_area', 'public.meet_set_discovery_prefs',
       'public.meet_get_my_profile', 'public.meet_submit_photo', 'public.meet_remove_photo',
       'public.meet_reorder_photos', 'public.meet_save_prompt', 'public.meet_remove_prompt',
       'public.meet_set_discoverable', 'public.meet_pause', 'public.meet_set_privacy',
       'public.meet_delete_profile', 'public.meet_daily_set', 'public.meet_get_profile',
       'public.meet_nearby', 'public.meet_swipe', 'public.meet_send_signal',
       'public.meet_likes_summary', 'public.meet_matches', 'public.meet_unmatch',
       'public.meet_conversations', 'public.meet_messages', 'public.meet_send_message',
       'public.meet_mark_read', 'public.meet_react_to_message', 'public.meet_post_status',
       'public.meet_delete_status', 'public.meet_status_ring', 'public.meet_view_status',
       'public.meet_status_viewers', 'public.meet_game_catalogue', 'public.meet_start_game',
       'public.meet_answer_game', 'public.meet_get_round', 'public.meet_daily_question',
       'public.meet_answer_daily_question', 'public.meet_report', 'public.meet_block',
       'public.meet_unblock', 'public.meet_blocked_profiles', 'public.meet_verification_pose',
       'public.meet_submit_verification',
       'public.admin_meet_moderation_queue', 'public.admin_meet_decide_case',
       'public.admin_meet_decide_photo', 'public.admin_meet_report_queue',
       'public.admin_meet_report_detail', 'public.admin_meet_resolve_report',
       'public.admin_meet_suspend', 'public.admin_meet_approve_ban',
       'public.admin_meet_lift_suspension', 'public.admin_meet_correct_birth_date',
       'public.admin_meet_user_summary', 'public.admin_meet_verification_queue',
       'public.admin_meet_decide_verification', 'public.admin_meet_verification_access',
       'public.admin_meet_readiness', 'public.admin_meet_set_readiness',
       'public.admin_meet_testers', 'public.admin_meet_set_tester',
       -- The meet-media read and Meet upload storage policies (20261126120200); each is a definer
       -- that answers only for auth.uid().
       'private.meet_media_visible_to', 'private.meet_upload_allowed',
       'public.open_dispute', 'public.submit_dispute_evidence', 'public.dispute_queue',
       'public.assign_dispute', 'public.resolve_dispute', 'public.withdraw_dispute',
       'private.dispute_scope',
       'public.add_payout_account', 'public.available_balance',
       'public.request_withdrawal', 'public.approve_withdrawal',
       'public.my_referral_code', 'public.claim_referral_code',
       'public.my_referral_summary', 'public.my_referrals',
       'public.propose_config_change', 'public.review_config_change',
       'public.config_change_queue', 'public.country_pack_readiness',
       'public.analytics_report', 'public.job_trail', 'public.get_provider_card',
       'public.get_price_band', 'public.get_availability_summary', 'public.rank_offers',
       'public.get_job_summary', 'public.get_category_requirements',
       'public.kpi_jobs_by_state', 'public.kpi_gmv', 'public.kpi_funnel',
       'public.kpi_verification_queue', 'public.kpi_disputes', 'public.kpi_payout_failures',
       'public.kpi_referral_campaign', 'public.kpi_supply_demand',
       'private.admin_scope_allows', 'private.admin_may_read_country',
       'private.admin_may_read_request', 'private.admin_may_read_user',
       'private.admin_scope_allows_any', 'private.admin_may_read_countries',
       'private.fraud_subject_countries', 'private.moderation_subject_countries',
       'private.is_assigned_job_provider', 'private.is_matched_provider',
       'private.approval_subject_country', 'public.get_payment_checkout',
       'public.business_verification_queue', 'public.decide_business_verification',
       'public.suspend_organization', 'public.reinstate_organization',
       'public.admin_organization_summary', 'public.admin_user_search',
       'public.admin_user_summary', 'public.admin_revoke_user_sessions',
       'private.staff_may_read_request_media',
       'private.chat_is_open', 'private.try_uuid', 'private.may_join_topic',
       'private.may_read_request_media', 'private.is_job_participant',
       'private.path_request_id',
       'private.has_admin_role', 'private.is_any_admin')),
  '{}'::text[], 'authenticated can execute only allowlisted functions');

-- A gate written with `is_any_admin()` or `enum_range(NULL::public.admin_role)` admits every
-- role the enum will ever have. meet_moderator (20261126120000) was the first role that must not
-- pass most of them, so those were restated with their roles named. A new one is added here in
-- the same change, with the reason the next role should pass it too. Every schema but the
-- system ones, so a gate in a schema added later (`meet_econ`, M2) is caught without a list here.
SELECT is(
  (SELECT coalesce(array_agg(n.nspname || '.' || p.proname ORDER BY n.nspname, p.proname), '{}')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
     AND p.prosrc ~* 'is_any_admin|enum_range\s*\(\s*NULL::(public\.)?admin_role'),
  ARRAY[
    -- Checks role names in a staff change; it is how meet_moderator is granted at all.
    'private.config_proposal_problem',
    'private.is_any_admin'],
  'only the role-name check and is_any_admin itself admit every admin role');

SELECT is(
  (SELECT coalesce(array_agg(schemaname || '.' || tablename || '.' || policyname
                             ORDER BY schemaname, tablename, policyname), '{}')
   FROM pg_policies
   WHERE coalesce(qual, '') || coalesce(with_check, '')
         ~* 'is_any_admin|enum_range\s*\(\s*NULL::(public\.)?admin_role'),
  '{}'::text[], 'no policy admits every admin role');

-- Money is integer minor units (spec money_rules; S-14).
SELECT is(
  (SELECT coalesce(array_agg(table_schema || '.' || table_name || '.' || column_name), '{}')
   FROM information_schema.columns
   WHERE table_schema IN ('public', 'ledger', 'private')
     AND column_name LIKE '%\_minor' AND data_type <> 'bigint'),
  '{}'::text[], 'every *_minor column is bigint');

SELECT is(
  (SELECT coalesce(array_agg(table_schema || '.' || table_name || '.' || column_name), '{}')
   FROM information_schema.columns
   WHERE table_schema IN ('public', 'ledger')
     AND data_type IN ('real', 'double precision', 'numeric', 'money')),
  '{}'::text[], 'no floating point, numeric or money columns in public or ledger');

-- Table-level write privileges: clients get column grants only (S-13 finding 1).
SELECT is(
  (SELECT coalesce(array_agg(c.relname::text || ':' || priv), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
        unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND has_table_privilege('anon', c.oid, priv)),
  '{}'::text[], 'anon has no table-level write privilege on any public table');

SELECT is(
  (SELECT coalesce(array_agg(c.relname::text || ':' || priv), '{}')
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
        unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND has_table_privilege('authenticated', c.oid, priv)
     AND c.relname::text || ':' || priv NOT IN ('notification_preferences:INSERT')),
  '{}'::text[], 'authenticated has table-level writes only where allowlisted');

-- Client-writable columns match the RLS matrix exactly.
SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.profiles'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.profiles'::regclass, attnum, 'UPDATE')$$,
  ARRAY['display_name', 'language', 'avatar_path', 'timezone'],
  'profiles: authenticated may update only display_name, language, avatar_path, timezone');

-- Every other table with a column-level write grant, for the same reason: the assertion claimed
-- to cover "client-writable columns" and covered two of the five tables that have any (U.4).
SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.requests'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.requests'::regclass, attnum, 'UPDATE')$$,
  ARRAY['description', 'urgency', 'pickup_label', 'pickup_landmark_note', 'destination_label',
        'destination_landmark_note', 'scheduled_at', 'preferred_price_minor', 'item_float_minor',
        'declared_value_minor'],
  'requests: a draft is edited in place, and status and the money snapshot stay server-owned');
SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.provider_profiles'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.provider_profiles'::regclass, attnum,
                               'UPDATE')$$,
  ARRAY['bio', 'vehicle_type', 'business_name'],
  'provider_profiles: never online, never suspended_until, never a reputation aggregate, never kind');
SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.organizations'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.organizations'::regclass, attnum,
                               'UPDATE')$$,
  ARRAY['legal_name'],
  'organizations: the owner renames it and nothing else — never its verification status');

SELECT set_eq(
  $$SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'public.notification_preferences'::regclass AND attnum > 0 AND NOT attisdropped
      AND has_column_privilege('authenticated', 'public.notification_preferences'::regclass, attnum, 'UPDATE')$$,
  ARRAY['enabled', 'quiet_start', 'quiet_end'],
  'notification_preferences: authenticated may update only enabled and quiet hours');

-- The audit log cannot be rewritten through any API role (RLS matrix §10).
SELECT is(
  (SELECT count(*)::int FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r,
          unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE']) priv
   WHERE has_table_privilege(r, 'audit.log', priv)),
  0, 'no API role may update, delete or truncate audit.log');

SELECT * FROM finish();
ROLLBACK;
