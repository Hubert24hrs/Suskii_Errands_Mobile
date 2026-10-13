-- Step-up for the admin actions that move money, decide a case, change access or open a
-- person's documents (audit 2026-10-13, Z.11). `has_admin_role` asks for `aal2`, which says the
-- session passed a second factor once; a session stolen an hour later is still `aal2`. These
-- five also want the TOTP code to have been entered in the last five minutes, which the console
-- has asked for since it was built and the server never checked.
--
-- The time comes from the JWT's `amr`: GoTrue writes `{"method": "totp", "timestamp": <unix>}`
-- and moves the timestamp forward when the same session verifies again, so a step-up is a fresh
-- `challengeAndVerify` and needs no state here. Checked against GoTrue in the local stack before
-- relying on it.
--
-- Guarded: `approve_withdrawal`, `resolve_dispute`, `request_document_access` (here) and
-- `propose_config_change`, `review_config_change` (in 20261013120000). The check sits after the
-- role check, so a caller with no role is told that, not asked for a code.

CREATE FUNCTION private.require_recent_mfa(p_max_age interval DEFAULT interval '5 minutes')
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_amr  jsonb := auth.jwt() -> 'amr';
  v_last timestamptz;
BEGIN
  IF jsonb_typeof(v_amr) = 'array' THEN
    SELECT max(to_timestamp((e ->> 'timestamp')::double precision)) INTO v_last
    FROM jsonb_array_elements(v_amr) e
    WHERE jsonb_typeof(e) = 'object' AND e ->> 'method' = 'totp'
      AND (e ->> 'timestamp') ~ '^[0-9]{1,12}(\.[0-9]+)?$';
  END IF;
  IF v_last IS NULL OR v_last < now() - p_max_age THEN
    RAISE EXCEPTION 'ERR_REAUTH_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
END $$;

REVOKE ALL ON FUNCTION private.require_recent_mfa(interval) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.approve_withdrawal(
  p_idempotency_key text, p_withdrawal_id uuid, p_approve boolean,
  p_reason_key text DEFAULT NULL)
RETURNS public.withdrawal_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_claim    jsonb;
  v_w        public.withdrawals%ROWTYPE;
  v_pending  uuid;
  v_left     integer;
  v_status   public.withdrawal_status;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'finance_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'approve_withdrawal',
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'approve', p_approve));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.withdrawal_status;
  END IF;

  SELECT * INTO v_w FROM public.withdrawals w WHERE w.id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_WITHDRAWAL_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_w.status <> 'awaiting_approval' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- Four eyes. The table's own CHECK refuses `approved_by = requested_by`; this refuses the same
  -- approver twice, which the CHECK cannot see.
  IF EXISTS (SELECT 1 FROM public.approvals a
             WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
               AND a.approved_by = v_uid) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'you have already signed this one';
  END IF;

  SELECT a.id INTO v_pending FROM public.approvals a
  WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
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
    UPDATE public.withdrawals w
    SET status = 'rejected', rejection_reason_key = p_reason_key, decided_at = now()
    WHERE w.id = p_withdrawal_id;
    UPDATE public.approvals a SET status = 'cancelled', decided_at = now()
    WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
      AND a.status = 'pending';
    PERFORM private.notify(v_w.user_id, 'system',
      'notification.withdrawal.rejected.title', 'notification.withdrawal.rejected.body',
      jsonb_build_object('withdrawal_id', p_withdrawal_id, 'reason_key', p_reason_key),
      '/earnings');
  ELSE
    SELECT count(*)::integer INTO v_left FROM public.approvals a
    WHERE a.subject_kind = 'withdrawal' AND a.subject_id = p_withdrawal_id::text
      AND a.status = 'pending';
    v_status := CASE WHEN v_left = 0 THEN 'approved' ELSE 'awaiting_approval' END
                  ::public.withdrawal_status;
    IF v_left = 0 THEN
      UPDATE public.withdrawals w SET status = 'approved', decided_at = now()
      WHERE w.id = p_withdrawal_id;
    END IF;
  END IF;

  PERFORM private.audit_write('withdrawal.approve', 'public.withdrawals',
    p_withdrawal_id::text, jsonb_build_object('status', v_w.status),
    jsonb_build_object('status', v_status, 'approved', p_approve), p_reason_key);
  PERFORM private.emit_event('withdrawal', p_withdrawal_id::text,
    CASE WHEN p_approve THEN 'withdrawal.approved' ELSE 'withdrawal.rejected' END,
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'by', v_uid, 'status', v_status));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;


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
  PERFORM private.require_recent_mfa();
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


CREATE OR REPLACE FUNCTION public.request_document_access(p_upload_ref text, p_reason_code text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_subject uuid;
BEGIN
  IF NOT private.has_admin_role(ARRAY['verification_officer', 'super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_recent_mfa();
  IF p_upload_ref IS NULL OR p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_subject := private.try_uuid((string_to_array(p_upload_ref, '/'))[1]);
  IF v_subject IS NULL OR v_subject = v_uid THEN
    -- The folder is the subject's user id, and an officer may not fetch their own documents
    -- through the review path.
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  INSERT INTO audit.kyc_access (officer_id, subject_id, upload_ref, reason_code)
  VALUES (v_uid, v_subject, p_upload_ref, p_reason_code);
  PERFORM private.audit_write('kyc.document_access', 'storage.objects', p_upload_ref,
    NULL, jsonb_build_object('subject_id', v_subject), p_reason_code);
  RETURN p_upload_ref;
END $$;
