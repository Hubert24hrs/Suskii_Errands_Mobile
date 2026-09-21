-- Phase 5, part 9: the gateway seam's public surface.
--
-- Every function a payment worker needs lives in `private`, which PostgREST does not expose and
-- must not — the whole point of putting the money logic there is that no API client can reach it.
-- But a worker *is* an API client: an Edge Function holding the service key, talking to PostgREST
-- like anything else. So the seam needs a door in `public`, and these are it.
--
-- **Each one is granted to `service_role` and nothing else**, and each does nothing but delegate.
-- The same shape as `public.get_health`. Keeping them this thin is deliberate: a wrapper that
-- decided anything would be a second place where money logic lives, reachable by a key that
-- leaves the database.
--
-- Named `gateway_*` so that what they are is obvious in a grant listing and in a PostgREST log.

CREATE FUNCTION public.gateway_ingest_webhook(
  p_gateway text, p_event_id text, p_signature_valid boolean, p_payload jsonb)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.ingest_webhook(p_gateway, p_event_id, p_signature_valid, p_payload); $$;

CREATE FUNCTION public.gateway_confirm_payment(
  p_gateway text, p_gateway_reference text, p_amount_minor bigint, p_fee_minor bigint)
RETURNS public.job_status
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.confirm_payment(p_gateway, p_gateway_reference, p_amount_minor,
                                     p_fee_minor); $$;

CREATE FUNCTION public.gateway_record_checkout(
  p_payment_id uuid, p_gateway text, p_gateway_reference text, p_checkout_url text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_gateway_checkout(p_payment_id, p_gateway, p_gateway_reference,
                                             p_checkout_url); $$;

CREATE FUNCTION public.gateway_record_settlement(p_payment_id uuid, p_settled_minor bigint)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_gateway_settlement(p_payment_id, p_settled_minor); $$;

CREATE FUNCTION public.gateway_record_payout_result(
  p_payout_id uuid, p_status public.payout_status, p_gateway text DEFAULT NULL,
  p_gateway_reference text DEFAULT NULL, p_fee_minor bigint DEFAULT 0,
  p_reason_key text DEFAULT NULL)
RETURNS public.payout_status
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_payout_result(p_payout_id, p_status, p_gateway, p_gateway_reference,
                                          p_fee_minor, p_reason_key); $$;

CREATE FUNCTION public.gateway_record_account_verification(
  p_payout_account_id uuid, p_verified boolean, p_holder_name text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_payout_account_verification(p_payout_account_id, p_verified,
                                                        p_holder_name); $$;

CREATE FUNCTION public.gateway_record_chargeback(
  p_payment_id uuid, p_chargeback_fee_minor bigint, p_reason_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.record_chargeback(p_payment_id, p_chargeback_fee_minor, p_reason_key); $$;

CREATE FUNCTION public.gateway_claim_outbox(p_aggregates text[], p_limit integer DEFAULT 50)
RETURNS TABLE (id bigint, aggregate text, aggregate_id text, event_type text, payload jsonb,
               attempts smallint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT * FROM private.claim_outbox(p_aggregates, p_limit); $$;

CREATE FUNCTION public.gateway_complete_outbox(p_id bigint)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.complete_outbox(p_id); $$;

CREATE FUNCTION public.gateway_fail_outbox(
  p_id bigint, p_reason_key text, p_retry boolean DEFAULT true)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.fail_outbox(p_id, p_reason_key, p_retry); $$;

REVOKE ALL ON FUNCTION
  public.gateway_ingest_webhook(text, text, boolean, jsonb),
  public.gateway_confirm_payment(text, text, bigint, bigint),
  public.gateway_record_checkout(uuid, text, text, text),
  public.gateway_record_settlement(uuid, bigint),
  public.gateway_record_payout_result(uuid, public.payout_status, text, text, bigint, text),
  public.gateway_record_account_verification(uuid, boolean, text),
  public.gateway_record_chargeback(uuid, bigint, text),
  public.gateway_claim_outbox(text[], integer),
  public.gateway_complete_outbox(bigint),
  public.gateway_fail_outbox(bigint, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.gateway_ingest_webhook(text, text, boolean, jsonb),
  public.gateway_confirm_payment(text, text, bigint, bigint),
  public.gateway_record_checkout(uuid, text, text, text),
  public.gateway_record_settlement(uuid, bigint),
  public.gateway_record_payout_result(uuid, public.payout_status, text, text, bigint, text),
  public.gateway_record_account_verification(uuid, boolean, text),
  public.gateway_record_chargeback(uuid, bigint, text),
  public.gateway_claim_outbox(text[], integer),
  public.gateway_complete_outbox(bigint),
  public.gateway_fail_outbox(bigint, text, boolean)
  TO service_role;
