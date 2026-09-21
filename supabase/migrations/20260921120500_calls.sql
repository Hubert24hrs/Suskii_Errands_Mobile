-- Phase 6, part 1: call records and call state (spec phase 6, "LiveKit Cloud integration: token
-- minting Edge Function, call records, call state events" and "PSTN masked-number fallback";
-- ERD §8; RLS matrix §8; PRD SH-12, SH-14, SH-15).
--
-- **No recording column exists, and none may be added.** The spec says metadata only, and the
-- DPIA was written on that basis. Participants, times, duration, quality and whether the call
-- fell back to PSTN — nothing else. A column added here later is a change to what the app is,
-- not a schema change.
--
-- **The server decides who is called, not the caller.** `start_call` takes a request, works out
-- the other party from the job, and refuses outside the job window. A client that could name its
-- callee could ring anybody.
--
-- **One live call per job.** A partial unique index enforces it, and simultaneous attempts are
-- resolved into one call rather than refused: if the other party is already ringing you, you get
-- their call back and answer it.
--
-- What is *not* here: the LiveKit access token. Minting it needs the project's API key and
-- secret, which belong in the Edge Function's environment and not in SQL — and the client action
-- to open the LiveKit account has not happened (REPORT §6.1). `start_call` returns the room name
-- and the identity the token must carry; the function that signs it is the seam.

CREATE TYPE public.call_status AS ENUM
  ('ringing', 'active', 'ended', 'missed', 'declined', 'failed');

CREATE TABLE public.calls (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id    uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  -- Scoped to one job and salted, so a room name cannot be guessed from a request id alone.
  room_name     text NOT NULL UNIQUE CHECK (length(room_name) BETWEEN 8 AND 120),
  caller_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  callee_id     uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  status        public.call_status NOT NULL DEFAULT 'ringing',
  pstn_fallback boolean NOT NULL DEFAULT false,
  -- Client-reported jitter, loss and round trip. Advisory: it decides when to offer PSTN, never
  -- who may call whom.
  quality       jsonb,
  started_at    timestamptz NOT NULL DEFAULT now(),
  answered_at   timestamptz,
  ended_at      timestamptz,
  duration_s    integer CHECK (duration_s IS NULL OR duration_s >= 0),
  CONSTRAINT calls_not_self CHECK (caller_id <> callee_id)
);
CREATE UNIQUE INDEX calls_one_live ON public.calls (request_id)
  WHERE status IN ('ringing', 'active');
CREATE INDEX calls_request ON public.calls (request_id, started_at DESC);
CREATE INDEX calls_ringing ON public.calls (started_at) WHERE status = 'ringing';

ALTER TABLE public.calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calls FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.calls FROM anon, authenticated;
GRANT SELECT ON public.calls TO authenticated;
GRANT ALL ON public.calls TO service_role;
-- Metadata, to the two people on the job and to the desks that have a reason (RLS matrix §8).
CREATE POLICY calls_read_participant ON public.calls FOR SELECT TO authenticated
  USING ((SELECT private.is_job_participant(calls.request_id))
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent', 'dispute_officer']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- masked_numbers — the PSTN fallback's allocation record (SH-14).
--
-- The table ships **empty** and stays empty until a telephony provider is contracted: Infobip is
-- the recommendation and Africa's Talking the alternative (REPORT §6.3), neither is signed, and
-- allocating a number is an API call that cannot happen in SQL. `private.record_masked_number`
-- is where the worker that does it writes the answer back — the same shape as the KYC vendor
-- seam, for the same reason.
-- ---------------------------------------------------------------------------
CREATE TABLE public.masked_numbers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id   uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  country_code char(2) NOT NULL REFERENCES public.countries (code),
  -- E.164. Neither party's real number is ever stored here; this is the proxy both of them dial.
  proxy_number text NOT NULL CHECK (proxy_number ~ '^\+[1-9][0-9]{6,14}$'),
  vendor       text NOT NULL CHECK (vendor IN ('infobip', 'africas_talking')),
  vendor_ref   text CHECK (vendor_ref IS NULL OR length(vendor_ref) <= 200),
  expires_at   timestamptz NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX masked_numbers_request ON public.masked_numbers (request_id, expires_at DESC);

ALTER TABLE public.masked_numbers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.masked_numbers FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.masked_numbers FROM anon, authenticated;
GRANT SELECT ON public.masked_numbers TO authenticated;
GRANT ALL ON public.masked_numbers TO service_role;
-- Participants reach their number through `request_pstn_fallback`, never by selecting: the row
-- also names the vendor and the window, which is nobody's business but ours (RLS matrix §8).
CREATE POLICY masked_numbers_read_admin ON public.masked_numbers FOR SELECT TO authenticated
  USING ((SELECT private.has_admin_role(ARRAY['super_admin']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The call window is the chat window. SH-12 says assignment until a day after completion, and
-- that is `private.chat_is_open` to the letter — so it is that function, not a second copy of
-- the same rule drifting away from it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.call_counterparty(p_request_id uuid, p_actor uuid)
RETURNS uuid
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
           WHEN r.customer_id = p_actor THEN coalesce(j.worker_id, j.provider_id)
           WHEN j.worker_id = p_actor OR j.provider_id = p_actor THEN r.customer_id
         END
  FROM public.requests r
  JOIN public.jobs j ON j.request_id = r.id
  WHERE r.id = p_request_id;
$$;

-- A missed call is a system message in the job chat and a push (SH-15). Written here rather than
-- through `send_message`, which is a client verb and refuses `system` on purpose.
CREATE FUNCTION private.record_missed_call(p_call public.calls)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_conv uuid;
BEGIN
  SELECT c.id INTO v_conv FROM public.conversations c WHERE c.request_id = p_call.request_id;
  IF NOT FOUND THEN
    INSERT INTO public.conversations (request_id) VALUES (p_call.request_id)
    ON CONFLICT (request_id) DO UPDATE SET request_id = excluded.request_id
    RETURNING id INTO v_conv;
  END IF;

  -- No body: the type says what happened and the app renders it. A sentence here would be
  -- English in somebody else's language.
  INSERT INTO public.messages (conversation_id, sender_id, type, body)
  VALUES (v_conv, p_call.caller_id, 'system', NULL);

  PERFORM private.notify(p_call.callee_id, 'call_missed',
    'notification.call.missed.title', 'notification.call.missed.body',
    jsonb_build_object('request_id', p_call.request_id, 'call_id', p_call.id),
    '/jobs/' || p_call.request_id::text);
END $$;

-- ---------------------------------------------------------------------------
-- start_call — the only way a call record is created.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.start_call(p_idempotency_key text, p_request_id uuid)
RETURNS TABLE (call_id uuid, room_name text, identity text, counterparty_id uuid,
               status public.call_status, is_caller boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_other  uuid;
  v_live   public.calls%ROWTYPE;
  v_id     uuid;
  v_room   text;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'start_call',
    jsonb_build_object('request_id', p_request_id));
  IF v_claim IS NOT NULL THEN
    RETURN QUERY SELECT (v_claim ->> 'call_id')::uuid, v_claim ->> 'room_name',
                        v_claim ->> 'identity', (v_claim ->> 'counterparty_id')::uuid,
                        (v_claim ->> 'status')::public.call_status,
                        (v_claim ->> 'is_caller')::boolean;
    RETURN;
  END IF;

  IF NOT private.is_job_participant(p_request_id) THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.chat_is_open(p_request_id) THEN
    RAISE EXCEPTION 'ERR_CALL_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  v_other := private.call_counterparty(p_request_id, v_uid);
  IF v_other IS NULL OR v_other = v_uid THEN
    RAISE EXCEPTION 'ERR_JOB_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- Simultaneous attempts. Whoever got there first owns the call; the second caller is handed
  -- the same room and told they are the callee, so their screen becomes "answer" rather than a
  -- second ring nobody wanted.
  SELECT * INTO v_live FROM public.calls c
  WHERE c.request_id = p_request_id AND c.status IN ('ringing', 'active')
  FOR UPDATE;
  IF FOUND THEN
    PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
      jsonb_build_object('call_id', v_live.id, 'room_name', v_live.room_name,
                         'identity', v_uid::text,
                         'counterparty_id',
                         CASE WHEN v_live.caller_id = v_uid THEN v_live.callee_id
                              ELSE v_live.caller_id END,
                         'status', v_live.status, 'is_caller', v_live.caller_id = v_uid));
    RETURN QUERY SELECT v_live.id, v_live.room_name, v_uid::text,
                        CASE WHEN v_live.caller_id = v_uid THEN v_live.callee_id
                             ELSE v_live.caller_id END,
                        v_live.status, v_live.caller_id = v_uid;
    RETURN;
  END IF;

  v_room := 'job-' || replace(p_request_id::text, '-', '') || '-'
            || encode(extensions.gen_random_bytes(6), 'hex');
  INSERT INTO public.calls (request_id, room_name, caller_id, callee_id)
  VALUES (p_request_id, v_room, v_uid, v_other)
  RETURNING id INTO v_id;

  PERFORM private.notify(v_other, 'call_incoming',
    'notification.call.incoming.title', 'notification.call.incoming.body',
    jsonb_build_object('request_id', p_request_id, 'call_id', v_id, 'room_name', v_room),
    '/calls/' || v_id::text);
  -- The ring itself: a VoIP push is the reliable path, but a participant with the app open
  -- should not wait for APNs to round-trip.
  PERFORM private.broadcast('job:' || p_request_id::text, 'call.incoming',
    jsonb_build_object('call_id', v_id, 'room_name', v_room, 'caller_id', v_uid,
                       'callee_id', v_other));
  PERFORM private.emit_event('call', v_id::text, 'call.started',
    jsonb_build_object('call_id', v_id, 'request_id', p_request_id, 'room_name', v_room,
                       'caller_id', v_uid, 'callee_id', v_other));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('call_id', v_id, 'room_name', v_room, 'identity', v_uid::text,
                       'counterparty_id', v_other, 'status', 'ringing', 'is_caller', true));

  RETURN QUERY SELECT v_id, v_room, v_uid::text, v_other,
                      'ringing'::public.call_status, true;
END $$;

CREATE FUNCTION public.answer_call(p_idempotency_key text, p_call_id uuid)
RETURNS public.call_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
  v_call  public.calls%ROWTYPE;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'answer_call',
    jsonb_build_object('call_id', p_call_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.call_status;
  END IF;

  SELECT * INTO v_call FROM public.calls c WHERE c.id = p_call_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CALL_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- Only the person being called answers. The caller "answering" their own ring would end the
  -- timeout that makes a missed call missed.
  IF v_call.callee_id <> v_uid THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF v_call.status <> 'ringing' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.calls c SET status = 'active', answered_at = now() WHERE c.id = p_call_id;
  PERFORM private.broadcast('job:' || v_call.request_id::text, 'call.answered',
    jsonb_build_object('call_id', p_call_id));
  PERFORM private.emit_event('call', p_call_id::text, 'call.answered',
    jsonb_build_object('call_id', p_call_id, 'request_id', v_call.request_id, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'active'));
  RETURN 'active'::public.call_status;
END $$;

-- end_call — the outcome is derived, not declared. A caller hanging up on a ring is a missed
-- call; the callee doing it is a decline; either of them on a live call is an ordinary end. A
-- client that chose its own label would let one party rewrite the other's call history.
CREATE FUNCTION public.end_call(
  p_idempotency_key text, p_call_id uuid, p_quality jsonb DEFAULT NULL,
  p_failed boolean DEFAULT false)
RETURNS public.call_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_call   public.calls%ROWTYPE;
  v_status public.call_status;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'end_call',
    jsonb_build_object('call_id', p_call_id, 'failed', p_failed));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.call_status;
  END IF;

  SELECT * INTO v_call FROM public.calls c WHERE c.id = p_call_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CALL_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_uid NOT IN (v_call.caller_id, v_call.callee_id) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF v_call.status NOT IN ('ringing', 'active') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE
                WHEN p_failed THEN 'failed'
                WHEN v_call.status = 'active' THEN 'ended'
                WHEN v_uid = v_call.callee_id THEN 'declined'
                ELSE 'missed'
              END::public.call_status;

  UPDATE public.calls c
  SET status = v_status, ended_at = now(),
      quality = coalesce(p_quality, c.quality),
      duration_s = CASE WHEN c.answered_at IS NULL THEN 0
                        ELSE greatest(0, extract(epoch FROM now() - c.answered_at)::integer) END
  WHERE c.id = p_call_id;

  IF v_status = 'missed' THEN
    SELECT * INTO v_call FROM public.calls c WHERE c.id = p_call_id;
    PERFORM private.record_missed_call(v_call);
  END IF;

  PERFORM private.broadcast('job:' || v_call.request_id::text, 'call.ended',
    jsonb_build_object('call_id', p_call_id, 'status', v_status));
  PERFORM private.emit_event('call', p_call_id::text, 'call.ended',
    jsonb_build_object('call_id', p_call_id, 'request_id', v_call.request_id,
                       'status', v_status, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

-- A ring nobody answers. Runs every minute, which is finer than the timeout it enforces.
CREATE FUNCTION private.expire_calls()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_secs  integer := coalesce(private.remote_config_int('call_ring_timeout_seconds'), 45);
  v_count integer := 0;
  v_call  public.calls%ROWTYPE;
BEGIN
  FOR v_call IN
    UPDATE public.calls c
    SET status = 'missed', ended_at = now(), duration_s = 0
    WHERE c.status = 'ringing'
      AND c.started_at < now() - make_interval(secs => v_secs)
    RETURNING c.*
  LOOP
    PERFORM private.record_missed_call(v_call);
    PERFORM private.broadcast('job:' || v_call.request_id::text, 'call.ended',
      jsonb_build_object('call_id', v_call.id, 'status', 'missed'));
    PERFORM private.emit_event('call', v_call.id::text, 'call.ended',
      jsonb_build_object('call_id', v_call.id, 'request_id', v_call.request_id,
                         'status', 'missed', 'by', NULL));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- PSTN fallback (SH-14). Offered when the data call is failing; connects both parties through a
-- proxy number and reveals neither real one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.record_masked_number(
  p_request_id uuid, p_proxy_number text, p_vendor text, p_vendor_ref text,
  p_ttl_minutes integer DEFAULT 120)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
  v_id      uuid;
BEGIN
  SELECT r.country_code INTO v_country FROM public.requests r WHERE r.id = p_request_id;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.masked_numbers
    (request_id, country_code, proxy_number, vendor, vendor_ref, expires_at)
  VALUES (p_request_id, v_country, p_proxy_number, p_vendor, p_vendor_ref,
          now() + make_interval(mins => least(greatest(coalesce(p_ttl_minutes, 120), 1), 1440)))
  RETURNING id INTO v_id;

  PERFORM private.broadcast('job:' || p_request_id::text, 'call.pstn_ready',
    jsonb_build_object('request_id', p_request_id));
  RETURN v_id;
END $$;

CREATE FUNCTION public.request_pstn_fallback(p_idempotency_key text, p_call_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_call   public.calls%ROWTYPE;
  v_number text;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'request_pstn_fallback',
    jsonb_build_object('call_id', p_call_id));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim ->> 'proxy_number';
  END IF;

  SELECT * INTO v_call FROM public.calls c WHERE c.id = p_call_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CALL_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_uid NOT IN (v_call.caller_id, v_call.callee_id) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  -- Same window as the in-app call: a proxy number that outlived the job would be a permanent
  -- line between two strangers.
  IF NOT private.chat_is_open(v_call.request_id) THEN
    RAISE EXCEPTION 'ERR_CALL_WINDOW_CLOSED' USING ERRCODE = 'P0001';
  END IF;

  SELECT m.proxy_number INTO v_number FROM public.masked_numbers m
  WHERE m.request_id = v_call.request_id AND m.expires_at > now()
  ORDER BY m.expires_at DESC LIMIT 1;

  IF v_number IS NULL THEN
    -- No telephony provider is contracted (REPORT §6.3): Infobip is the recommendation, Africa's
    -- Talking the alternative, and neither is signed. The event is emitted anyway so the seam is
    -- exercised and the demand is measurable before anybody pays for numbers.
    PERFORM private.emit_event('call', p_call_id::text, 'call.pstn_requested',
      jsonb_build_object('call_id', p_call_id, 'request_id', v_call.request_id,
                         'requested_by', v_uid));
    RAISE EXCEPTION 'ERR_PSTN_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.calls c SET pstn_fallback = true WHERE c.id = p_call_id;
  PERFORM private.emit_event('call', p_call_id::text, 'call.pstn_used',
    jsonb_build_object('call_id', p_call_id, 'request_id', v_call.request_id));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('proxy_number', v_number));
  RETURN v_number;
END $$;

REVOKE ALL ON FUNCTION
  public.start_call(text, uuid),
  public.answer_call(text, uuid),
  public.end_call(text, uuid, jsonb, boolean),
  public.request_pstn_fallback(text, uuid),
  private.call_counterparty(uuid, uuid),
  private.record_missed_call(public.calls),
  private.record_masked_number(uuid, text, text, text, integer),
  private.expire_calls()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.start_call(text, uuid),
  public.answer_call(text, uuid),
  public.end_call(text, uuid, jsonb, boolean),
  public.request_pstn_fallback(text, uuid)
  TO authenticated;

INSERT INTO public.remote_config (key, country_code, value, client_visible) VALUES
  ('call_ring_timeout_seconds', NULL, '45', true),
  ('call_pstn_number_ttl_minutes', NULL, '120', false)
ON CONFLICT DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('call-ring-timeout', '* * * * *',
      $cron$SELECT private.expire_calls()$cron$);
  END IF;
END $$;
