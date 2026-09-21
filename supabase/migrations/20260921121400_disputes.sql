-- Phase 5, part 6: disputes (spec phase 5, "Refunds, cancellations, dispute freezes"; ERD §10;
-- RLS matrix §9; `docs/plan/money-flows.md` posting 6a).
--
-- Three places already say "that is a dispute, not a cancellation" — moderation, `cancel_job`
-- and the item float — and until now they pointed at a table that did not exist. So did the
-- `dispute_officer` role, which lost its blanket read of chat when support was scoped to tickets
-- and has had **no scoped access at all** since. This closes both.
--
-- **Opening a dispute freezes the money, it does not move it.** The job goes to `disputed` and
-- the settlement sweep stops picking it up, because money released while an argument is running
-- is money to be clawed back from somebody who has already spent it.
--
-- **The refund total is checked here, catchably.** The invariant on `refunds` is a deferred
-- constraint trigger, and a deferred abort cannot be caught and takes the whole transaction with
-- it (S-14). `cancel_job` could not breach it by construction; a partial refund decided by a
-- person can, so this is the first caller that has to check first. The trigger stays as the
-- backstop.

CREATE TYPE public.dispute_status AS ENUM
  ('open', 'under_review', 'resolved', 'withdrawn');

CREATE TABLE public.disputes (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id          uuid NOT NULL REFERENCES public.requests (id) ON DELETE RESTRICT,
  opened_by           uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  reason_code         text NOT NULL CHECK (reason_code ~ '^[a-z0-9_]{3,60}$'),
  -- The person's own account of it. Not a key: this is the one place where what somebody wants
  -- to say matters more than what a screen can render in their language.
  description         text CHECK (description IS NULL OR length(description) BETWEEN 1 AND 2000),
  status              public.dispute_status NOT NULL DEFAULT 'open',
  -- What the job was doing when the dispute froze it. Withdrawing has to put it back exactly
  -- there: assuming `confirmed` would mark unfinished work finished and release its money.
  frozen_from         public.job_status NOT NULL,
  assigned_officer_id uuid REFERENCES auth.users (id),
  sla_due_at          timestamptz NOT NULL,
  resolution_key      text CHECK (resolution_key IS NULL OR resolution_key ~ '^[a-z0-9_]{3,60}$'),
  resolution_note     text CHECK (resolution_note IS NULL OR length(resolution_note) <= 2000),
  refund_minor        bigint CHECK (refund_minor IS NULL OR refund_minor >= 0),
  resolved_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
-- One open dispute per job. Two arguments about the same job are one argument.
CREATE UNIQUE INDEX disputes_one_open ON public.disputes (request_id)
  WHERE status IN ('open', 'under_review');
CREATE INDEX disputes_queue ON public.disputes (sla_due_at)
  WHERE status IN ('open', 'under_review');
CREATE INDEX disputes_request ON public.disputes (request_id, created_at DESC);
CREATE TRIGGER disputes_touch BEFORE UPDATE ON public.disputes
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disputes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.disputes FROM anon, authenticated;
GRANT SELECT ON public.disputes TO authenticated;
GRANT ALL ON public.disputes TO service_role;
-- Both parties see it, because a dispute one side cannot see is not a process, it is a decision
-- taken about them (RLS matrix §9).
CREATE POLICY disputes_read ON public.disputes FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(disputes.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'dispute_officer', 'finance_officer',
                     'support_agent']::public.admin_role[])));

CREATE TYPE public.evidence_kind AS ENUM
  ('photo', 'receipt', 'message_range', 'location_range', 'call_record', 'pin_log', 'note');

CREATE TABLE public.dispute_evidence (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id   uuid NOT NULL REFERENCES public.disputes (id) ON DELETE CASCADE,
  kind         public.evidence_kind NOT NULL,
  storage_path text CHECK (storage_path IS NULL OR length(storage_path) BETWEEN 3 AND 512),
  -- Points at what already exists rather than copying it: a message range, a call record, a span
  -- of location samples. Evidence that duplicates the record can disagree with it.
  reference    jsonb NOT NULL DEFAULT '{}'::jsonb,
  note         text CHECK (note IS NULL OR length(note) <= 2000),
  submitted_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT evidence_has_something CHECK (
    storage_path IS NOT NULL OR note IS NOT NULL OR reference <> '{}'::jsonb)
);
CREATE INDEX dispute_evidence_dispute ON public.dispute_evidence (dispute_id, created_at);

ALTER TABLE public.dispute_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispute_evidence FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.dispute_evidence FROM anon, authenticated;
GRANT SELECT ON public.dispute_evidence TO authenticated;
GRANT ALL ON public.dispute_evidence TO service_role;
-- A participant reads **their own** submissions (RLS matrix §9). Not the other side's: evidence
-- you can read before you answer it is evidence you can tailor a story around.
CREATE POLICY dispute_evidence_read ON public.dispute_evidence FOR SELECT TO authenticated
  USING (submitted_by = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'dispute_officer',
                     'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The scope `dispute_officer` lost. Same shape as `support_ticket_scope`, and for the same
-- reason: the role is not the reason, the case is.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.dispute_scope(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_request_id IS NOT NULL
     AND private.has_admin_role(
           ARRAY['super_admin', 'dispute_officer']::public.admin_role[])
     AND EXISTS (SELECT 1 FROM public.disputes d WHERE d.request_id = p_request_id);
$$;

REVOKE ALL ON FUNCTION private.dispute_scope(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.dispute_scope(uuid) TO authenticated;

DROP POLICY conversations_read_participant ON public.conversations;
CREATE POLICY conversations_read_participant ON public.conversations FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(conversations.request_id))
         OR (SELECT private.support_ticket_scope(conversations.request_id))
         OR (SELECT private.dispute_scope(conversations.request_id)));

DROP POLICY messages_read_participant ON public.messages;
CREATE POLICY messages_read_participant ON public.messages FOR SELECT TO authenticated
  USING (sender_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.conversations c
                    WHERE c.id = messages.conversation_id
                      AND ((moderation_status <> 'rejected'
                            AND (SELECT private.is_job_participant(c.request_id)))
                           OR (SELECT private.support_ticket_scope(c.request_id))
                           OR (SELECT private.dispute_scope(c.request_id)))));

DROP POLICY calls_read_participant ON public.calls;
CREATE POLICY calls_read_participant ON public.calls FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(calls.request_id))
         OR (SELECT private.support_ticket_scope(calls.request_id))
         OR (SELECT private.dispute_scope(calls.request_id)));

-- ---------------------------------------------------------------------------
-- open_dispute — either party, while there is still money to argue about.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.open_dispute(
  p_idempotency_key text, p_request_id uuid, p_reason_code text,
  p_description text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_job     public.jobs%ROWTYPE;
  v_hours   integer;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'open_dispute',
    jsonb_build_object('request_id', p_request_id, 'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'dispute_id')::uuid;
  END IF;
  IF p_reason_code IS NULL OR p_reason_code !~ '^[a-z0-9_]{3,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND OR NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_job FROM public.jobs j WHERE j.request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- There has to be money still held. Once it has been paid out, the remedy is a chargeback or a
  -- clawback, not a dispute — and saying so is kinder than opening a case that cannot do
  -- anything.
  IF v_request.status NOT IN ('paid_held', 'assigned', 'en_route', 'arrived', 'in_progress',
                              'completed_by_provider', 'confirmed', 'disputed') THEN
    RAISE EXCEPTION 'ERR_DISPUTE_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.disputes d
             WHERE d.request_id = p_request_id AND d.status IN ('open', 'under_review')) THEN
    RAISE EXCEPTION 'ERR_DISPUTE_ALREADY_OPEN' USING ERRCODE = 'P0001';
  END IF;

  v_hours := coalesce(private.remote_config_int('dispute_sla_hours'), 72);
  INSERT INTO public.disputes (request_id, opened_by, reason_code, description, sla_due_at,
                               frozen_from)
  VALUES (p_request_id, v_uid, p_reason_code, nullif(btrim(coalesce(p_description, '')), ''),
          now() + make_interval(hours => v_hours), v_request.status)
  RETURNING id INTO v_id;

  -- The freeze. `recognise_due_earnings` only picks up `confirmed` jobs, so moving off it is
  -- what stops the money while the argument runs.
  IF v_request.status <> 'disputed' THEN
    PERFORM private.job_transition(p_request_id, v_request.status, 'disputed', v_uid,
      CASE WHEN v_request.customer_id = v_uid THEN 'customer' ELSE 'provider' END
        ::public.job_actor_kind,
      p_reason_code, p_idempotency_key, jsonb_build_object('dispute_id', v_id));
  END IF;

  -- Both sides are told, including the one who opened it: a dispute is not a complaint made
  -- behind somebody's back.
  PERFORM private.notify(v_request.customer_id, 'job_status',
    'notification.dispute.opened.title', 'notification.dispute.opened.body',
    jsonb_build_object('request_id', p_request_id, 'dispute_id', v_id,
                       'reason_key', p_reason_code), '/disputes/' || v_id::text);
  PERFORM private.notify(v_job.provider_id, 'job_status',
    'notification.dispute.opened.title', 'notification.dispute.opened.body',
    jsonb_build_object('request_id', p_request_id, 'dispute_id', v_id,
                       'reason_key', p_reason_code), '/disputes/' || v_id::text);
  PERFORM private.emit_event('dispute', v_id::text, 'dispute.opened',
    jsonb_build_object('dispute_id', v_id, 'request_id', p_request_id, 'opened_by', v_uid,
                       'reason_code', p_reason_code, 'sla_due_at',
                       now() + make_interval(hours => v_hours)));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('dispute_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.submit_dispute_evidence(
  p_idempotency_key text, p_dispute_id uuid, p_kind public.evidence_kind,
  p_storage_path text DEFAULT NULL, p_reference jsonb DEFAULT '{}'::jsonb,
  p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_dispute public.disputes%ROWTYPE;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'submit_dispute_evidence',
    jsonb_build_object('dispute_id', p_dispute_id, 'kind', p_kind));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'evidence_id')::uuid;
  END IF;

  SELECT * INTO v_dispute FROM public.disputes d WHERE d.id = p_dispute_id;
  IF NOT FOUND OR NOT (private.is_job_participant(v_dispute.request_id)
                       OR private.has_admin_role(
                            ARRAY['super_admin', 'dispute_officer']::public.admin_role[])) THEN
    RAISE EXCEPTION 'ERR_DISPUTE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_dispute.status NOT IN ('open', 'under_review') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  IF p_storage_path IS NULL AND nullif(btrim(coalesce(p_note, '')), '') IS NULL
     AND coalesce(p_reference, '{}'::jsonb) = '{}'::jsonb THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'evidence has to be something';
  END IF;
  IF p_storage_path IS NOT NULL
     AND p_storage_path NOT LIKE (v_dispute.request_id::text || '/%') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023',
      DETAIL = 'evidence lives under this job''s own folder';
  END IF;

  INSERT INTO public.dispute_evidence (dispute_id, kind, storage_path, reference, note,
                                       submitted_by)
  VALUES (p_dispute_id, p_kind, p_storage_path, coalesce(p_reference, '{}'::jsonb),
          nullif(btrim(coalesce(p_note, '')), ''), v_uid)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('dispute', p_dispute_id::text, 'dispute.evidence_submitted',
    jsonb_build_object('dispute_id', p_dispute_id, 'evidence_id', v_id, 'kind', p_kind,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('evidence_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- The officer's desk.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.dispute_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.disputes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.disputes d WHERE d.status IN ('open', 'under_review')
  ORDER BY d.sla_due_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE FUNCTION public.assign_dispute(
  p_idempotency_key text, p_dispute_id uuid, p_officer_id uuid)
RETURNS public.dispute_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_dispute public.disputes%ROWTYPE;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'assign_dispute',
    jsonb_build_object('dispute_id', p_dispute_id, 'officer_id', p_officer_id));
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
  -- An officer who cannot work the queue would make the case disappear from it.
  IF NOT EXISTS (SELECT 1 FROM public.admin_users a
                 WHERE a.user_id = p_officer_id
                   AND a.roles && ARRAY['super_admin',
                                        'dispute_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- Nobody adjudicates a job they were on. This is about the officer being assigned, not the
  -- person doing the assigning — `resolve_dispute` checks the caller separately.
  IF EXISTS (SELECT 1 FROM public.jobs j WHERE j.request_id = v_dispute.request_id
               AND p_officer_id IN (j.provider_id, j.worker_id))
     OR EXISTS (SELECT 1 FROM public.requests r WHERE r.id = v_dispute.request_id
                  AND r.customer_id = p_officer_id) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501',
      DETAIL = 'an officer cannot take a dispute about a job they were on';
  END IF;

  UPDATE public.disputes d
  SET assigned_officer_id = p_officer_id, status = 'under_review'
  WHERE d.id = p_dispute_id;

  PERFORM private.audit_write('dispute.assign', 'public.disputes', p_dispute_id::text,
    jsonb_build_object('assigned_officer_id', v_dispute.assigned_officer_id),
    jsonb_build_object('assigned_officer_id', p_officer_id), NULL);
  PERFORM private.emit_event('dispute', p_dispute_id::text, 'dispute.assigned',
    jsonb_build_object('dispute_id', p_dispute_id, 'officer_id', p_officer_id, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'under_review'));
  RETURN 'under_review'::public.dispute_status;
END $$;

-- ---------------------------------------------------------------------------
-- resolve_dispute — money-flows 6a. The refund the officer decides, the commission on what is
-- kept, and the provider paid for the rest.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.resolve_dispute(
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

-- The person who opened it can drop it, while nobody has decided anything.
CREATE FUNCTION public.withdraw_dispute(p_idempotency_key text, p_dispute_id uuid)
RETURNS public.dispute_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_dispute public.disputes%ROWTYPE;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'withdraw_dispute',
    jsonb_build_object('dispute_id', p_dispute_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.dispute_status;
  END IF;

  SELECT * INTO v_dispute FROM public.disputes d WHERE d.id = p_dispute_id FOR UPDATE;
  IF NOT FOUND OR v_dispute.opened_by <> v_uid THEN
    RAISE EXCEPTION 'ERR_DISPUTE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_dispute.status <> 'open' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001',
      DETAIL = 'once an officer has it, withdrawing is their decision to record';
  END IF;

  UPDATE public.disputes d SET status = 'withdrawn', resolved_at = now() WHERE d.id = p_dispute_id;
  -- Back to exactly where it was frozen. A job disputed at `in_progress` resumes at
  -- `in_progress`; only one that was already `confirmed` returns to the settlement sweep.
  PERFORM private.job_transition(v_dispute.request_id, 'disputed', v_dispute.frozen_from, v_uid,
    CASE WHEN (SELECT r.customer_id FROM public.requests r WHERE r.id = v_dispute.request_id)
              = v_uid THEN 'customer' ELSE 'provider' END::public.job_actor_kind,
    'dispute_withdrawn', p_idempotency_key);

  PERFORM private.emit_event('dispute', p_dispute_id::text, 'dispute.withdrawn',
    jsonb_build_object('dispute_id', p_dispute_id, 'request_id', v_dispute.request_id,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'withdrawn'));
  RETURN 'withdrawn'::public.dispute_status;
END $$;

-- A dispute nobody has picked up by its SLA. Escalation is an event, not a status: the queue is
-- already ordered by `sla_due_at`, and a breached case should be shouted about, not re-filed.
CREATE FUNCTION private.escalate_overdue_disputes()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT d.id, d.request_id, d.sla_due_at FROM public.disputes d
    WHERE d.status IN ('open', 'under_review') AND d.sla_due_at < now()
      AND NOT EXISTS (SELECT 1 FROM private.outbox o
                      WHERE o.aggregate = 'dispute' AND o.aggregate_id = d.id::text
                        AND o.event_type = 'dispute.sla_breached')
  LOOP
    PERFORM private.emit_event('dispute', v_row.id::text, 'dispute.sla_breached',
      jsonb_build_object('dispute_id', v_row.id, 'request_id', v_row.request_id,
                         'sla_due_at', v_row.sla_due_at));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION
  public.open_dispute(text, uuid, text, text),
  public.submit_dispute_evidence(text, uuid, public.evidence_kind, text, jsonb, text),
  public.dispute_queue(integer),
  public.assign_dispute(text, uuid, uuid),
  public.resolve_dispute(text, uuid, text, bigint, text),
  public.withdraw_dispute(text, uuid),
  private.escalate_overdue_disputes()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.open_dispute(text, uuid, text, text),
  public.submit_dispute_evidence(text, uuid, public.evidence_kind, text, jsonb, text),
  public.dispute_queue(integer),
  public.assign_dispute(text, uuid, uuid),
  public.resolve_dispute(text, uuid, text, bigint, text),
  public.withdraw_dispute(text, uuid)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('dispute_sla_hours', NULL, '72', true)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('dispute-sla', '11 * * * *',
      $cron$SELECT private.escalate_overdue_disputes()$cron$);
  END IF;
END $$;
