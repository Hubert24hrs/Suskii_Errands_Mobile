-- Money primitives: the currency exponent table and half-even rounding.
-- Amounts are integer minor units + ISO 4217 code everywhere (spec money_rules).

CREATE TABLE public.currencies (
  code     char(3)  PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  exponent smallint NOT NULL CHECK (exponent BETWEEN 0 AND 4),
  name     text     NOT NULL
);

-- Reference data every environment needs, so it lives in the migration, not the seed.
-- ISO 4217 minor units; UGX has none, which is what breaks a hardcoded /100 (S-14).
INSERT INTO public.currencies (code, exponent, name) VALUES
  ('NGN', 2, 'Nigerian naira'),
  ('KES', 2, 'Kenyan shilling'),
  ('GHS', 2, 'Ghanaian cedi'),
  ('ZAR', 2, 'South African rand'),
  ('UGX', 0, 'Ugandan shilling'),
  ('USD', 2, 'United States dollar');

ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.currencies FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.currencies FROM anon, authenticated;
GRANT SELECT ON public.currencies TO anon, authenticated;
GRANT SELECT ON public.currencies TO service_role;
CREATE POLICY currencies_read ON public.currencies FOR SELECT TO anon, authenticated USING (true);

-- PostgreSQL's round() on numeric rounds half away from zero; the spec requires half-even.
CREATE FUNCTION private.round_half_even(v numeric)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path = ''
AS $$
DECLARE
  floored numeric := floor(v);
  diff    numeric := v - floor(v);
BEGIN
  IF diff > 0.5 OR (diff = 0.5 AND mod(floored, 2) <> 0) THEN
    RETURN floored + 1;
  END IF;
  RETURN floored;
END $$;

-- Applies a basis-point rate to a minor-unit amount: round_half_even(amount × bps / 10000).
-- Used for commission and referral amounts; rates are stored as *_bps integers (ERD).
CREATE FUNCTION private.apply_bps(amount_minor bigint, rate_bps integer)
RETURNS bigint
LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path = ''
AS $$
BEGIN
  IF rate_bps < 0 OR rate_bps > 10000 THEN
    RAISE EXCEPTION 'ERR_INVALID_RATE' USING ERRCODE = '22023',
      DETAIL = 'rate_bps must be between 0 and 10000, got ' || rate_bps::text;
  END IF;
  RETURN private.round_half_even(amount_minor::numeric * rate_bps / 10000)::bigint;
END $$;

CREATE FUNCTION private.currency_exponent(currency_code char(3))
RETURNS smallint
LANGUAGE plpgsql STABLE STRICT
SET search_path = ''
AS $$
DECLARE
  e smallint;
BEGIN
  SELECT c.exponent INTO e FROM public.currencies c WHERE c.code = currency_code;
  IF e IS NULL THEN
    RAISE EXCEPTION 'ERR_UNKNOWN_CURRENCY' USING ERRCODE = '22023',
      DETAIL = format('currency %s is not in public.currencies', currency_code);
  END IF;
  RETURN e;
END $$;

REVOKE ALL ON FUNCTION private.round_half_even(numeric), private.apply_bps(bigint, integer),
  private.currency_exponent(char) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.round_half_even(numeric), private.apply_bps(bigint, integer),
  private.currency_exponent(char) TO service_role;
