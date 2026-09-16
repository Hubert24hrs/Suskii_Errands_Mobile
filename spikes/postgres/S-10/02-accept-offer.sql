-- The function under test. Mirrors the rules the real one must follow:
-- lock the request row, guard the state, accept exactly one offer, expire the rest,
-- write the event, and make the whole thing idempotent — all in one transaction.

CREATE OR REPLACE FUNCTION accept_offer(p_request bigint, p_offer bigint, p_idem text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_prior   jsonb;
    v_status  text;
    v_offer   public.offers%ROWTYPE;
    v_result  jsonb;
BEGIN
    -- Replay of a key we have already answered: return the original outcome, act again never.
    SELECT result INTO v_prior FROM public.idempotency_keys WHERE key = p_idem;
    IF FOUND THEN
        RETURN v_prior || jsonb_build_object('replayed', true);
    END IF;

    -- Serialise concurrent accepts on this request.
    SELECT status INTO v_status FROM public.requests WHERE id = p_request FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REQUEST_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    IF v_status NOT IN ('PUBLISHED', 'OFFERS_RECEIVED', 'NEGOTIATING') THEN
        RAISE EXCEPTION 'ILLEGAL_TRANSITION_FROM_%', v_status USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_offer FROM public.offers WHERE id = p_offer AND request_id = p_request FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_offer.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'OFFER_NOT_ACTIVE_%', v_offer.status USING ERRCODE = 'P0001';
    END IF;
    IF v_offer.expires_at <= now() THEN
        RAISE EXCEPTION 'OFFER_EXPIRED' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.offers SET status = 'ACCEPTED' WHERE id = p_offer;
    UPDATE public.offers SET status = 'EXPIRED'
     WHERE request_id = p_request AND id <> p_offer AND status = 'ACTIVE';

    UPDATE public.requests
       SET status = 'PAYMENT_PENDING', accepted_offer = p_offer, version = version + 1
     WHERE id = p_request;

    INSERT INTO public.job_events (request_id, event, payload)
    VALUES (p_request, 'OFFER_ACCEPTED',
            jsonb_build_object('offer_id', p_offer, 'provider_id', v_offer.provider_id,
                               'amount_minor', v_offer.amount_minor, 'currency', v_offer.currency));

    v_result := jsonb_build_object('ok', true, 'request_id', p_request, 'offer_id', p_offer,
                                   'status', 'PAYMENT_PENDING', 'replayed', false);

    INSERT INTO public.idempotency_keys (key, result) VALUES (p_idem, v_result);
    RETURN v_result;
END $$;

-- Seed one request with 20 competing active offers, for the race script.
CREATE OR REPLACE FUNCTION seed_race(p_offers int DEFAULT 20)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r bigint;
BEGIN
    INSERT INTO public.requests (customer_id) VALUES (1) RETURNING id INTO r;
    INSERT INTO public.offers (request_id, provider_id, amount_minor)
    SELECT r, g, 500000 + g * 1000 FROM generate_series(1, p_offers) g;
    RETURN r;
END $$;
