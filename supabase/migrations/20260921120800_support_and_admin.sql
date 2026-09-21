-- Phase 8, part 1: support tickets, and the scoping that makes the RLS matrix true (spec phase 8,
-- "Role-based permissions for the five admin roles enforced in RLS and functions" and "Admin
-- functions for users …"; ERD §10; RLS matrix §8 and §9; PRD SH-16 for the notifications).
--
-- **This migration closes a gap rather than only adding a feature.** The RLS matrix says support
-- reads a conversation "only when a ticket references it, not by browsing", and calls that a
-- data-minimisation control the DPIA relies on. The policies shipped in Phase 3 gave every
-- support agent blanket read of every conversation and every message, because the table that
-- makes scoping possible did not exist yet. It exists now, so the policies are replaced.
--
-- `dispute_officer` loses that blanket read here too, and does not get a scoped one: its scope is
-- the `disputes` table, which is Phase 5 work because a dispute ends in a refund. A role holding
-- unscoped access to everyone's chat while the mechanism that would scope it is unbuilt is the
-- same gap wearing a different name.
--
-- **Suspension lives here, not in the risk engine.** OD-25 says confirming a fraud flag records a
-- finding and nothing else; this is the separate, explicit, audited decision that may follow. It
-- is bounded: `suspend_provider` requires an end date, because a permanent ban with no appeal is
-- not a thing one function call should be able to do.

CREATE TYPE public.support_ticket_status AS ENUM
  ('open', 'waiting_on_user', 'waiting_on_support', 'resolved', 'closed');

CREATE TABLE public.support_tickets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  request_id  uuid REFERENCES public.requests (id) ON DELETE SET NULL,
  category    text NOT NULL CHECK (category IN
                ('payment', 'job', 'account', 'verification', 'safety', 'provider', 'other')),
  status      public.support_ticket_status NOT NULL DEFAULT 'open',
  -- 1 is most urgent. Set by a person or by triage; never by the person who opened the ticket,
  -- because everyone's problem is urgent to them.
  priority    smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 4),
  ai_triage   jsonb NOT NULL DEFAULT '{}'::jsonb,
  assignee_id uuid REFERENCES auth.users (id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);
CREATE INDEX support_tickets_user ON public.support_tickets (user_id, created_at DESC);
CREATE INDEX support_tickets_queue ON public.support_tickets (priority, created_at)
  WHERE status IN ('open', 'waiting_on_support');
CREATE INDEX support_tickets_request ON public.support_tickets (request_id)
  WHERE request_id IS NOT NULL;
CREATE TRIGGER support_tickets_touch BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_tickets FROM anon, authenticated;
GRANT SELECT ON public.support_tickets TO authenticated;
GRANT ALL ON public.support_tickets TO service_role;
CREATE POLICY support_tickets_read ON public.support_tickets FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

CREATE TABLE public.ticket_messages (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticket_id  uuid NOT NULL REFERENCES public.support_tickets (id) ON DELETE CASCADE,
  author_id  uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  body       text NOT NULL CHECK (length(body) BETWEEN 1 AND 4000),
  -- A staff note, not a reply. Without this, everything a colleague writes while working out what
  -- happened is addressed to the customer, so it either gets written somewhere unauditable or not
  -- written at all.
  internal   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ticket_messages_ticket ON public.ticket_messages (ticket_id, id);

ALTER TABLE public.ticket_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_messages FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.ticket_messages FROM anon, authenticated;
GRANT SELECT ON public.ticket_messages TO authenticated;
GRANT ALL ON public.ticket_messages TO service_role;
CREATE POLICY ticket_messages_read ON public.ticket_messages FOR SELECT TO authenticated
  USING ((NOT internal
          AND EXISTS (SELECT 1 FROM public.support_tickets t
                      WHERE t.id = ticket_messages.ticket_id
                        AND t.user_id = (SELECT auth.uid())))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The scope. A support agent reads a job's conversation because a ticket points at that job —
-- not because they are a support agent.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.support_ticket_scope(p_request_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_request_id IS NOT NULL
     AND private.has_admin_role(
           ARRAY['super_admin', 'support_agent']::public.admin_role[])
     AND EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.request_id = p_request_id);
$$;

REVOKE ALL ON FUNCTION private.support_ticket_scope(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.support_ticket_scope(uuid) TO authenticated;

DROP POLICY conversations_read_participant ON public.conversations;
CREATE POLICY conversations_read_participant ON public.conversations FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(conversations.request_id))
         OR (SELECT private.support_ticket_scope(conversations.request_id)));

DROP POLICY messages_read_participant ON public.messages;
CREATE POLICY messages_read_participant ON public.messages FOR SELECT TO authenticated
  USING (sender_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.conversations c
                    WHERE c.id = messages.conversation_id
                      AND ((moderation_status <> 'rejected'
                            AND (SELECT private.is_job_participant(c.request_id)))
                           OR (SELECT private.support_ticket_scope(c.request_id)))));

DROP POLICY calls_read_participant ON public.calls;
CREATE POLICY calls_read_participant ON public.calls FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(calls.request_id))
         OR (SELECT private.support_ticket_scope(calls.request_id)));

-- ---------------------------------------------------------------------------
-- The ticket verbs.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.open_ticket(
  p_idempotency_key text, p_category text, p_body text, p_request_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_id    uuid;
  v_body  text := nullif(btrim(coalesce(p_body, '')), '');
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'open_ticket',
    jsonb_build_object('category', p_category, 'request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'ticket_id')::uuid;
  END IF;

  IF v_body IS NULL OR length(v_body) > 4000 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  -- A ticket may name a job, but only one of yours: the request id is what widens a support
  -- agent's reach, so it cannot be a number somebody guessed.
  IF p_request_id IS NOT NULL AND NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.support_tickets (user_id, request_id, category)
  VALUES (v_uid, p_request_id, p_category)
  RETURNING id INTO v_id;

  INSERT INTO public.ticket_messages (ticket_id, author_id, body) VALUES (v_id, v_uid, v_body);

  PERFORM private.emit_event('support', v_id::text, 'ticket.opened',
    jsonb_build_object('ticket_id', v_id, 'user_id', v_uid, 'category', p_category,
                       'request_id', p_request_id));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('ticket_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.reply_to_ticket(
  p_idempotency_key text, p_ticket_id uuid, p_body text, p_internal boolean DEFAULT false)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_ticket public.support_tickets%ROWTYPE;
  v_staff  boolean;
  v_id     bigint;
  v_body   text := nullif(btrim(coalesce(p_body, '')), '');
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'reply_to_ticket',
    jsonb_build_object('ticket_id', p_ticket_id, 'internal', p_internal));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'message_id')::bigint;
  END IF;

  IF v_body IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_ticket FROM public.support_tickets t WHERE t.id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_TICKET_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_staff := private.has_admin_role(
    ARRAY['super_admin', 'support_agent']::public.admin_role[]);
  IF NOT v_staff AND v_ticket.user_id <> v_uid THEN
    RAISE EXCEPTION 'ERR_TICKET_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_ticket.status = 'closed' THEN
    RAISE EXCEPTION 'ERR_TICKET_CLOSED' USING ERRCODE = 'P0001';
  END IF;
  -- Only staff write staff notes. A user setting the flag would hide their own message from the
  -- only people who can act on it.
  IF p_internal AND NOT v_staff THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.ticket_messages (ticket_id, author_id, body, internal)
  VALUES (p_ticket_id, v_uid, v_body, p_internal AND v_staff)
  RETURNING id INTO v_id;

  -- A note to a colleague is not an answer to the customer, so it does not move the ticket.
  IF NOT p_internal THEN
    UPDATE public.support_tickets t
    -- Cast: a CASE resolves to text, which will not assign to an enum column.
    SET status = (CASE WHEN v_staff THEN 'waiting_on_user'
                       ELSE 'waiting_on_support' END)::public.support_ticket_status,
        resolved_at = NULL
    WHERE t.id = p_ticket_id;

    IF v_staff THEN
      PERFORM private.notify(v_ticket.user_id, 'system',
        'notification.support.reply.title', 'notification.support.reply.body',
        jsonb_build_object('ticket_id', p_ticket_id), '/support/' || p_ticket_id::text);
    END IF;
  END IF;

  PERFORM private.emit_event('support', p_ticket_id::text, 'ticket.replied',
    jsonb_build_object('ticket_id', p_ticket_id, 'message_id', v_id, 'by', v_uid,
                       'internal', p_internal AND v_staff));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('message_id', v_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.ticket_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.support_tickets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.support_tickets t
  WHERE t.status IN ('open', 'waiting_on_support')
  ORDER BY t.priority, t.created_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE FUNCTION public.update_ticket(
  p_idempotency_key text, p_ticket_id uuid,
  p_status public.support_ticket_status DEFAULT NULL,
  p_assignee_id uuid DEFAULT NULL,
  p_priority smallint DEFAULT NULL)
RETURNS public.support_ticket_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_ticket public.support_tickets%ROWTYPE;
  v_status public.support_ticket_status;
BEGIN
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'update_ticket',
    jsonb_build_object('ticket_id', p_ticket_id, 'status', p_status,
                       'assignee_id', p_assignee_id, 'priority', p_priority));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.support_ticket_status;
  END IF;

  SELECT * INTO v_ticket FROM public.support_tickets t WHERE t.id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_TICKET_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- An assignee has to be somebody who can work the queue, or the ticket disappears.
  IF p_assignee_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.admin_users a
                     WHERE a.user_id = p_assignee_id
                       AND a.roles && ARRAY['super_admin',
                                            'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_status := coalesce(p_status, v_ticket.status);
  UPDATE public.support_tickets t
  SET status = v_status,
      assignee_id = coalesce(p_assignee_id, t.assignee_id),
      priority = coalesce(p_priority, t.priority),
      resolved_at = CASE WHEN v_status IN ('resolved', 'closed') THEN now() ELSE NULL END
  WHERE t.id = p_ticket_id;

  PERFORM private.audit_write('support.update_ticket', 'public.support_tickets',
    p_ticket_id::text,
    jsonb_build_object('status', v_ticket.status, 'assignee_id', v_ticket.assignee_id),
    jsonb_build_object('status', v_status, 'assignee_id',
                       coalesce(p_assignee_id, v_ticket.assignee_id)), NULL);
  PERFORM private.emit_event('support', p_ticket_id::text, 'ticket.updated',
    jsonb_build_object('ticket_id', p_ticket_id, 'status', v_status, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- ---------------------------------------------------------------------------
-- Suspension: the explicit decision OD-25 keeps out of the risk engine.
--
-- Bounded on purpose. An end date means somebody has to decide how long, and a provider whose
-- livelihood this is gets a date rather than silence. Permanence is not on offer through a
-- function call.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.suspend_provider(
  p_idempotency_key text, p_user_id uuid, p_reason_key text, p_until timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_before timestamptz;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$'
     OR p_until IS NULL OR p_until <= now() OR p_until > now() + interval '365 days' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'suspend_provider',
    jsonb_build_object('user_id', p_user_id, 'reason_key', p_reason_key, 'until', p_until));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'until')::timestamptz;
  END IF;

  SELECT pp.suspended_until INTO v_before FROM public.provider_profiles pp
  WHERE pp.user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.provider_profiles pp
  SET suspended_until = p_until, suspension_reason_key = p_reason_key, online = false
  WHERE pp.user_id = p_user_id;

  -- Told, with a reason key and a date. Being cut off with no explanation is how a provider
  -- concludes the platform is arbitrary.
  PERFORM private.notify(p_user_id, 'system',
    'notification.account.suspended.title', 'notification.account.suspended.body',
    jsonb_build_object('reason_key', p_reason_key, 'until', p_until), '/account');
  PERFORM private.audit_write('admin.suspend_provider', 'public.provider_profiles',
    p_user_id::text, jsonb_build_object('suspended_until', v_before),
    jsonb_build_object('suspended_until', p_until), p_reason_key);
  PERFORM private.emit_event('admin', p_user_id::text, 'provider.suspended',
    jsonb_build_object('user_id', p_user_id, 'until', p_until, 'reason_key', p_reason_key,
                       'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('until', p_until));
  RETURN p_until;
END $$;

CREATE FUNCTION public.reinstate_provider(
  p_idempotency_key text, p_user_id uuid, p_reason_key text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_before timestamptz;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_reason_key IS NULL OR p_reason_key !~ '^[a-z0-9_]{3,60}$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'reinstate_provider',
    jsonb_build_object('user_id', p_user_id, 'reason_key', p_reason_key));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'reinstated')::boolean;
  END IF;

  SELECT pp.suspended_until INTO v_before FROM public.provider_profiles pp
  WHERE pp.user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.provider_profiles pp
  SET suspended_until = NULL, suspension_reason_key = NULL
  WHERE pp.user_id = p_user_id;

  PERFORM private.notify(p_user_id, 'system',
    'notification.account.reinstated.title', 'notification.account.reinstated.body',
    jsonb_build_object('reason_key', p_reason_key), '/account');
  PERFORM private.audit_write('admin.reinstate_provider', 'public.provider_profiles',
    p_user_id::text, jsonb_build_object('suspended_until', v_before),
    jsonb_build_object('suspended_until', NULL), p_reason_key);
  PERFORM private.emit_event('admin', p_user_id::text, 'provider.reinstated',
    jsonb_build_object('user_id', p_user_id, 'reason_key', p_reason_key, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('reinstated', true));
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION
  public.open_ticket(text, text, text, uuid),
  public.reply_to_ticket(text, uuid, text, boolean),
  public.ticket_queue(integer),
  public.update_ticket(text, uuid, public.support_ticket_status, uuid, smallint),
  public.suspend_provider(text, uuid, text, timestamptz),
  public.reinstate_provider(text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.open_ticket(text, text, text, uuid),
  public.reply_to_ticket(text, uuid, text, boolean),
  public.ticket_queue(integer),
  public.update_ticket(text, uuid, public.support_ticket_status, uuid, smallint),
  public.suspend_provider(text, uuid, text, timestamptz),
  public.reinstate_provider(text, uuid, text)
  TO authenticated;
