-- Marketplace, part 2: offer threads and negotiation (ERD §5; RLS matrix §6; the offer and
-- negotiation state machine; spike S-10).
--
-- The rules this migration enforces, each from that state machine:
--   * a thread is one provider negotiating on one request, and holds the round count;
--   * offers are append-only — a change is a new row, so the customer sees the whole history;
--   * the same side may not counter twice in a row, and the counterparty is the one who accepts;
--   * accepting locks the request row, expires every sibling offer and emits one event, in one
--     transaction — the S-10 shape, which survived 750 concurrent attempts with no double
--     acceptance;
--   * a provider never reads a rival's amount: RLS limits providers to their own thread.
--
-- Not here, deliberately: the job row and its money snapshot (commission rate, gateway fee, net)
-- are written when the job state machine lands, and the rate itself waits on OD-06. Acceptance
-- moves the request to `agreed` and stops there. Organisation-owned threads (`organization_id`
-- in the ERD) wait for the organisations table.

CREATE TYPE public.offer_thread_status AS ENUM ('open', 'closed');

-- ---------------------------------------------------------------------------
-- pricing_guardrails — the per-country, per-category bands from the country packs. The hard
-- maximum is a server-side fraud control; the soft band is advisory and the apps warn on it,
-- which is why clients may read this table. The pack values are placeholders to calibrate with
-- pilot data (OD-23), and a category with no row has no hard cap.
-- ---------------------------------------------------------------------------
CREATE TABLE public.pricing_guardrails (
  country_code   char(2) NOT NULL REFERENCES public.countries (code),
  category_id    uuid    NOT NULL REFERENCES public.service_categories (id) ON DELETE CASCADE,
  soft_min_minor bigint  NOT NULL CHECK (soft_min_minor > 0),
  soft_max_minor bigint  NOT NULL CHECK (soft_max_minor > 0),
  hard_max_minor bigint  NOT NULL CHECK (hard_max_minor > 0),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (country_code, category_id),
  CONSTRAINT pricing_guardrails_ordered
    CHECK (soft_min_minor <= soft_max_minor AND soft_max_minor <= hard_max_minor)
);
CREATE TRIGGER pricing_guardrails_touch BEFORE UPDATE ON public.pricing_guardrails
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.pricing_guardrails ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pricing_guardrails FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.pricing_guardrails FROM anon, authenticated;
GRANT SELECT ON public.pricing_guardrails TO authenticated;
GRANT ALL ON public.pricing_guardrails TO service_role;
-- Own country only: the band is shown in the price field, and nothing else needs it.
CREATE POLICY pricing_guardrails_read_own_country ON public.pricing_guardrails
  FOR SELECT TO authenticated
  USING (country_code = (SELECT p.country_code FROM public.profiles p
                         WHERE p.user_id = (SELECT auth.uid())));

-- ---------------------------------------------------------------------------
-- offer_threads
-- ---------------------------------------------------------------------------
CREATE TABLE public.offer_threads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id  uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  -- Every offer in the thread counts towards the limit, in both directions.
  round_count smallint NOT NULL DEFAULT 0 CHECK (round_count >= 0),
  status      public.offer_thread_status NOT NULL DEFAULT 'open',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, provider_id)
);
CREATE INDEX offer_threads_provider ON public.offer_threads (provider_id, created_at DESC);
CREATE TRIGGER offer_threads_touch BEFORE UPDATE ON public.offer_threads
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

ALTER TABLE public.offer_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offer_threads FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.offer_threads FROM anon, authenticated;
GRANT SELECT ON public.offer_threads TO authenticated;
GRANT ALL ON public.offer_threads TO service_role;
CREATE POLICY offer_threads_read ON public.offer_threads FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offer_threads.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- offers — append-only except `status`. `provider_id` is the thread's provider whichever side
-- wrote the row, so a provider's own thread is one index lookup.
-- ---------------------------------------------------------------------------
CREATE TABLE public.offers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id           uuid NOT NULL REFERENCES public.offer_threads (id) ON DELETE CASCADE,
  request_id          uuid NOT NULL REFERENCES public.requests (id) ON DELETE CASCADE,
  provider_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
  author_side         public.user_mode NOT NULL,
  amount_minor        bigint  NOT NULL CHECK (amount_minor > 0),
  currency            char(3) NOT NULL REFERENCES public.currencies (code),
  message             text CHECK (message IS NULL OR length(message) BETWEEN 1 AND 500),
  status              public.offer_status NOT NULL DEFAULT 'pending',
  status_reason       text CHECK (status_reason IS NULL OR length(status_reason) <= 60),
  round               smallint NOT NULL CHECK (round >= 1),
  expires_at          timestamptz NOT NULL,
  supersedes_offer_id uuid REFERENCES public.offers (id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  status_changed_at   timestamptz,
  UNIQUE (thread_id, round)
);
-- Backstop to the S-10 row lock: at most one accepted offer per request, ever.
CREATE UNIQUE INDEX offers_one_accepted_per_request ON public.offers (request_id)
  WHERE status = 'accepted';
CREATE INDEX offers_pending_expiry ON public.offers (expires_at) WHERE status = 'pending';
CREATE INDEX offers_request ON public.offers (request_id, created_at DESC);
CREATE INDEX offers_provider ON public.offers (provider_id, created_at DESC);

ALTER TABLE public.offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offers FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.offers FROM anon, authenticated;
GRANT SELECT ON public.offers TO authenticated;
GRANT ALL ON public.offers TO service_role;
-- The competitive invariant (RLS matrix §6): the customer sees every thread on their request; a
-- provider sees only their own. Nothing here relies on the client filtering.
CREATE POLICY offers_read ON public.offers FOR SELECT TO authenticated
  USING (provider_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.requests r
                    WHERE r.id = offers.request_id AND r.customer_id = (SELECT auth.uid()))
         OR (SELECT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- Shared guards
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.offer_guardrail_check(
  p_country char(2), p_category uuid, p_amount_minor bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_hard_max bigint;
BEGIN
  SELECT g.hard_max_minor INTO v_hard_max FROM public.pricing_guardrails g
  WHERE g.country_code = p_country AND g.category_id = p_category;
  IF v_hard_max IS NOT NULL AND p_amount_minor > v_hard_max THEN
    RAISE EXCEPTION 'ERR_PRICE_OUT_OF_RANGE' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- A request whose last live offer just went away is open for business again, so it goes back to
-- `published` rather than sitting in `offers_received` with nothing in it.
CREATE FUNCTION private.reopen_request_if_idle(p_request_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.requests r
  SET status = 'published', version = r.version + 1
  WHERE r.id = p_request_id
    AND r.status IN ('offers_received', 'negotiating')
    AND NOT EXISTS (SELECT 1 FROM public.offers o
                    WHERE o.request_id = r.id AND o.status = 'pending');
END $$;

-- ---------------------------------------------------------------------------
-- create_offer — a provider's first (or next, after withdrawing) offer on a request.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.create_offer(
  p_idempotency_key text,
  p_request_id uuid,
  p_amount_minor bigint,
  p_message text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_request public.requests%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_country char(2);
  v_ttl     integer;
  v_max     smallint;
  v_round   smallint;
  v_expires timestamptz;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'create_offer',
    jsonb_build_object('request_id', p_request_id, 'amount_minor', p_amount_minor,
                       'message', p_message));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'offer_id')::uuid;
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.customer_id = v_uid THEN
    RAISE EXCEPTION 'ERR_SELF_DEALING_BLOCKED' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status NOT IN ('published', 'offers_received', 'negotiating')
     OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= now()) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.country_code INTO v_country FROM public.profiles p
  WHERE p.user_id = v_uid AND p.provider_verification = 'verified';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
  END IF;
  -- The feed is country-scoped, so an offer from another country is a bug or an attack.
  IF v_country IS DISTINCT FROM v_request.country_code THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SUPPORTED' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.offer_guardrail_check(v_request.country_code, v_request.category_id,
                                        p_amount_minor);

  SELECT sc.offer_ttl_seconds, sc.max_counter_rounds INTO v_ttl, v_max
  FROM public.service_categories sc WHERE sc.id = v_request.category_id;

  SELECT * INTO v_thread FROM public.offer_threads t
  WHERE t.request_id = p_request_id AND t.provider_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.offer_threads (request_id, provider_id) VALUES (p_request_id, v_uid)
    RETURNING * INTO v_thread;
  ELSE
    IF v_thread.status <> 'open' THEN
      RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.offers o
               WHERE o.thread_id = v_thread.id AND o.status = 'pending') THEN
      RAISE EXCEPTION 'ERR_OFFER_ALREADY_PENDING' USING ERRCODE = 'P0001';
    END IF;
    IF v_thread.round_count >= v_max THEN
      RAISE EXCEPTION 'ERR_OFFER_ROUNDS_EXHAUSTED' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_round := v_thread.round_count + 1;
  v_expires := now() + make_interval(secs => v_ttl);
  INSERT INTO public.offers (thread_id, request_id, provider_id, author_side, amount_minor,
                             currency, message, round, expires_at)
  VALUES (v_thread.id, p_request_id, v_uid, 'provider', p_amount_minor, v_request.currency,
          p_message, v_round, v_expires)
  RETURNING id INTO v_id;
  UPDATE public.offer_threads t SET round_count = v_round WHERE t.id = v_thread.id;

  IF v_request.status = 'published' THEN
    UPDATE public.requests r SET status = 'offers_received', version = r.version + 1
    WHERE r.id = p_request_id;
  END IF;

  PERFORM private.emit_event('request', p_request_id::text, 'offer.created',
    jsonb_build_object('offer_id', v_id, 'thread_id', v_thread.id, 'provider_id', v_uid,
                       'amount_minor', p_amount_minor, 'currency', v_request.currency,
                       'round', v_round, 'expires_at', v_expires));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('offer_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- counter_offer — the counterparty answers with a new amount. Alternation is the rule: the side
-- that wrote the pending offer cannot counter itself; it withdraws and re-offers, which stays
-- visible in the history.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.counter_offer(
  p_idempotency_key text,
  p_offer_id uuid,
  p_amount_minor bigint,
  p_message text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_offer   public.offers%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_side    public.user_mode;
  v_ttl     integer;
  v_max     smallint;
  v_round   smallint;
  v_expires timestamptz;
  v_id      uuid;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'counter_offer',
    jsonb_build_object('offer_id', p_offer_id, 'amount_minor', p_amount_minor,
                       'message', p_message));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'offer_id')::uuid;
  END IF;

  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- Lock request, then thread, then offer — the same order in every function here, so
  -- concurrent calls queue instead of deadlocking.
  SELECT * INTO v_request FROM public.requests r WHERE r.id = v_offer.request_id FOR UPDATE;
  SELECT * INTO v_thread FROM public.offer_threads t WHERE t.id = v_offer.thread_id FOR UPDATE;
  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id FOR UPDATE;

  -- Who is calling. Anyone else is told the offer does not exist, rather than that it does.
  IF v_uid = v_request.customer_id THEN
    v_side := 'customer'::public.user_mode;
  ELSIF v_uid = v_thread.provider_id THEN
    v_side := 'provider'::public.user_mode;
  ELSE
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_side = v_offer.author_side THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_YOUR_TURN' USING ERRCODE = 'P0001';
  END IF;

  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
  IF v_offer.expires_at <= now() THEN
    RAISE EXCEPTION 'ERR_OFFER_EXPIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_thread.status <> 'open'
     OR v_request.status NOT IN ('published', 'offers_received', 'negotiating')
     OR (v_request.expires_at IS NOT NULL AND v_request.expires_at <= now()) THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  SELECT sc.offer_ttl_seconds, sc.max_counter_rounds INTO v_ttl, v_max
  FROM public.service_categories sc WHERE sc.id = v_request.category_id;
  IF v_thread.round_count >= v_max THEN
    RAISE EXCEPTION 'ERR_OFFER_ROUNDS_EXHAUSTED' USING ERRCODE = 'P0001';
  END IF;

  PERFORM private.offer_guardrail_check(v_request.country_code, v_request.category_id,
                                        p_amount_minor);

  UPDATE public.offers o SET status = 'countered', status_changed_at = now()
  WHERE o.id = p_offer_id;

  v_round := v_thread.round_count + 1;
  -- The counterparty needs time to answer, so the offer TTL restarts. The request TTL does not:
  -- a slow negotiation must not keep a stale request alive for ever.
  v_expires := now() + make_interval(secs => v_ttl);
  INSERT INTO public.offers (thread_id, request_id, provider_id, author_side, amount_minor,
                             currency, message, round, expires_at, supersedes_offer_id)
  VALUES (v_thread.id, v_request.id, v_thread.provider_id, v_side, p_amount_minor,
          v_request.currency, p_message, v_round, v_expires, p_offer_id)
  RETURNING id INTO v_id;
  UPDATE public.offer_threads t SET round_count = v_round WHERE t.id = v_thread.id;

  IF v_request.status <> 'negotiating' THEN
    UPDATE public.requests r SET status = 'negotiating', version = r.version + 1
    WHERE r.id = v_request.id;
  END IF;

  PERFORM private.emit_event('request', v_request.id::text, 'offer.countered',
    jsonb_build_object('offer_id', v_id, 'supersedes_offer_id', p_offer_id,
                       'thread_id', v_thread.id, 'provider_id', v_thread.provider_id,
                       'author_side', v_side, 'amount_minor', p_amount_minor,
                       'currency', v_request.currency, 'round', v_round,
                       'expires_at', v_expires));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('offer_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- accept_offer — the S-10 transaction. The counterparty accepts: the customer accepts a
-- provider's offer, and the provider accepts the customer's counter. Siblings expire here, in
-- the same transaction, so no provider ever sees an offer as live after losing.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.accept_offer(p_idempotency_key text, p_offer_id uuid)
RETURNS public.job_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_offer   public.offers%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_side    public.user_mode;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'accept_offer',
    jsonb_build_object('offer_id', p_offer_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.job_status;
  END IF;

  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = v_offer.request_id FOR UPDATE;
  SELECT * INTO v_thread FROM public.offer_threads t WHERE t.id = v_offer.thread_id FOR UPDATE;
  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id FOR UPDATE;

  IF v_uid = v_request.customer_id THEN
    v_side := 'customer'::public.user_mode;
  ELSIF v_uid = v_thread.provider_id THEN
    v_side := 'provider'::public.user_mode;
  ELSE
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_side = v_offer.author_side THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_YOUR_TURN' USING ERRCODE = 'P0001';
  END IF;

  -- The offer's own state first: a caller who lost the race is told "this offer is no longer
  -- live", which the apps turn into "another provider was just selected" (S-10 finding 3),
  -- rather than a transition error about a request they may not be able to see.
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;
  IF v_offer.expires_at <= now() THEN
    RAISE EXCEPTION 'ERR_OFFER_EXPIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_request.status NOT IN ('published', 'offers_received', 'negotiating') THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;
  -- The provider must still be eligible at the moment of acceptance, not only when they offered.
  IF NOT EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.user_id = v_thread.provider_id
                   AND p.provider_verification = 'verified') THEN
    RAISE EXCEPTION 'ERR_PROVIDER_NOT_VERIFIED' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.offers o SET status = 'accepted', status_changed_at = now()
  WHERE o.id = p_offer_id;

  -- Every other live offer on this request loses, in this transaction.
  WITH lost AS (
    UPDATE public.offers o
    SET status = 'expired', status_reason = 'sibling_accepted', status_changed_at = now()
    WHERE o.request_id = v_request.id AND o.status = 'pending' AND o.id <> p_offer_id
    RETURNING o.id, o.provider_id
  )
  INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload)
  SELECT 'request', v_request.id::text, 'offer.expired',
         jsonb_build_object('offer_id', l.id, 'provider_id', l.provider_id,
                            'reason', 'sibling_accepted')
  FROM lost l;

  UPDATE public.offer_threads t SET status = 'closed' WHERE t.request_id = v_request.id;
  UPDATE public.requests r
  SET status = 'agreed', expires_at = NULL, version = r.version + 1
  WHERE r.id = v_request.id;

  -- One event per acceptance: payment, notifications and analytics all hang off it, so a double
  -- fire would double-charge (S-10 invariant 3).
  PERFORM private.emit_event('request', v_request.id::text, 'offer.accepted',
    jsonb_build_object('offer_id', p_offer_id, 'thread_id', v_thread.id,
                       'provider_id', v_thread.provider_id, 'customer_id', v_request.customer_id,
                       'amount_minor', v_offer.amount_minor, 'currency', v_offer.currency,
                       'accepted_by', v_side));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'agreed', 'offer_id', p_offer_id));
  RETURN 'agreed'::public.job_status;
END $$;

-- ---------------------------------------------------------------------------
-- decline_offer — the counterparty says no. The thread closes; other threads are untouched.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.decline_offer(
  p_idempotency_key text, p_offer_id uuid, p_reason_code text DEFAULT NULL)
RETURNS public.offer_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_offer   public.offers%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_side    public.user_mode;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'decline_offer',
    jsonb_build_object('offer_id', p_offer_id, 'reason', p_reason_code));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.offer_status;
  END IF;

  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = v_offer.request_id FOR UPDATE;
  SELECT * INTO v_thread FROM public.offer_threads t WHERE t.id = v_offer.thread_id FOR UPDATE;
  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id FOR UPDATE;

  IF v_uid = v_request.customer_id THEN
    v_side := 'customer'::public.user_mode;
  ELSIF v_uid = v_thread.provider_id THEN
    v_side := 'provider'::public.user_mode;
  ELSE
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_side = v_offer.author_side THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_YOUR_TURN' USING ERRCODE = 'P0001';
  END IF;
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.offers o
  SET status = 'declined', status_reason = p_reason_code, status_changed_at = now()
  WHERE o.id = p_offer_id;
  UPDATE public.offer_threads t SET status = 'closed' WHERE t.id = v_thread.id;
  PERFORM private.reopen_request_if_idle(v_request.id);

  PERFORM private.emit_event('request', v_request.id::text, 'offer.declined',
    jsonb_build_object('offer_id', p_offer_id, 'thread_id', v_thread.id,
                       'provider_id', v_thread.provider_id, 'declined_by', v_side,
                       'reason', p_reason_code));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'declined'));
  RETURN 'declined'::public.offer_status;
END $$;

-- ---------------------------------------------------------------------------
-- withdraw_offer — the author pulls their own offer. The thread stays open, so a provider may
-- re-offer at a different price; the withdrawn row stays in the history.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.withdraw_offer(p_idempotency_key text, p_offer_id uuid)
RETURNS public.offer_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_offer   public.offers%ROWTYPE;
  v_thread  public.offer_threads%ROWTYPE;
  v_request public.requests%ROWTYPE;
  v_side    public.user_mode;
BEGIN
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'withdraw_offer',
    jsonb_build_object('offer_id', p_offer_id));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.offer_status;
  END IF;

  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_request FROM public.requests r WHERE r.id = v_offer.request_id FOR UPDATE;
  SELECT * INTO v_thread FROM public.offer_threads t WHERE t.id = v_offer.thread_id FOR UPDATE;
  SELECT * INTO v_offer FROM public.offers o WHERE o.id = p_offer_id FOR UPDATE;

  IF v_uid = v_request.customer_id THEN
    v_side := 'customer'::public.user_mode;
  ELSIF v_uid = v_thread.provider_id THEN
    v_side := 'provider'::public.user_mode;
  ELSE
    RAISE EXCEPTION 'ERR_OFFER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_side <> v_offer.author_side THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_YOUR_TURN' USING ERRCODE = 'P0001';
  END IF;
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'ERR_OFFER_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.offers o SET status = 'withdrawn', status_changed_at = now()
  WHERE o.id = p_offer_id;
  PERFORM private.reopen_request_if_idle(v_request.id);

  PERFORM private.emit_event('request', v_request.id::text, 'offer.withdrawn',
    jsonb_build_object('offer_id', p_offer_id, 'thread_id', v_thread.id,
                       'provider_id', v_thread.provider_id, 'withdrawn_by', v_side));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', 'withdrawn'));
  RETURN 'withdrawn'::public.offer_status;
END $$;

-- ---------------------------------------------------------------------------
-- expire_offers — the scheduled half of the state machine (transition 6). A request left with
-- no live offer goes back to `published`, so it stays in the feed rather than looking busy.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.expire_offers(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_requests uuid[];
  v_count    integer;
BEGIN
  WITH due AS (
    SELECT o.id FROM public.offers o
    WHERE o.status = 'pending' AND o.expires_at <= now()
    ORDER BY o.expires_at
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), expired AS (
    UPDATE public.offers o
    SET status = 'expired', status_reason = 'ttl', status_changed_at = now()
    FROM due WHERE o.id = due.id
    RETURNING o.id, o.request_id, o.provider_id
  ), events AS (
    INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload)
    SELECT 'request', e.request_id::text, 'offer.expired',
           jsonb_build_object('offer_id', e.id, 'provider_id', e.provider_id, 'reason', 'ttl')
    FROM expired e
    RETURNING 1
  )
  SELECT count(*)::int, coalesce(array_agg(DISTINCT e.request_id), '{}'::uuid[])
  INTO v_count, v_requests
  FROM expired e;

  -- A separate statement: the CTE above cannot see its own updates.
  UPDATE public.requests r
  SET status = 'published', version = r.version + 1
  WHERE r.id = ANY (v_requests)
    AND r.status IN ('offers_received', 'negotiating')
    AND NOT EXISTS (SELECT 1 FROM public.offers o
                    WHERE o.request_id = r.id AND o.status = 'pending');
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- A request that ends without an agreement takes its live offers with it, whichever path closed
-- it — a cancellation, the expiry job, or an admin. A trigger rather than a line in each
-- function, so the next function cannot forget the invariant.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.requests_close_offers()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_reason text := 'request_' || NEW.status::text;
BEGIN
  WITH lost AS (
    UPDATE public.offers o
    SET status = 'expired', status_reason = v_reason, status_changed_at = now()
    WHERE o.request_id = NEW.id AND o.status = 'pending'
    RETURNING o.id, o.provider_id
  )
  INSERT INTO private.outbox (aggregate, aggregate_id, event_type, payload)
  SELECT 'request', NEW.id::text, 'offer.expired',
         jsonb_build_object('offer_id', l.id, 'provider_id', l.provider_id, 'reason', v_reason)
  FROM lost l;

  UPDATE public.offer_threads t SET status = 'closed'
  WHERE t.request_id = NEW.id AND t.status = 'open';
  RETURN NEW;
END $$;

CREATE TRIGGER requests_close_offers AFTER UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status IN ('cancelled', 'expired') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION private.requests_close_offers();

REVOKE ALL ON FUNCTION
  public.create_offer(text, uuid, bigint, text),
  public.counter_offer(text, uuid, bigint, text),
  public.accept_offer(text, uuid),
  public.decline_offer(text, uuid, text),
  public.withdraw_offer(text, uuid),
  private.offer_guardrail_check(char, uuid, bigint),
  private.reopen_request_if_idle(uuid),
  private.expire_offers(integer),
  private.requests_close_offers()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.create_offer(text, uuid, bigint, text),
  public.counter_offer(text, uuid, bigint, text),
  public.accept_offer(text, uuid),
  public.decline_offer(text, uuid, text),
  public.withdraw_offer(text, uuid)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('offers-expire', '* * * * *',
      $cron$SELECT private.expire_offers()$cron$);
  END IF;
END $$;
