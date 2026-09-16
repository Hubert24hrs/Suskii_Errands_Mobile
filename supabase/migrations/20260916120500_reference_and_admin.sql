-- Reference configuration (country packs, cities, legal documents, feature flags, remote
-- config) and admin identity (admin users, four-eyes approvals). ERD §1, §12; RLS matrix §1, §10.

-- ---------------------------------------------------------------------------
-- Admin identity first: every other policy here depends on the admin helpers.
-- ---------------------------------------------------------------------------
CREATE TABLE public.admin_users (
  user_id         uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE RESTRICT,
  roles           public.admin_role[] NOT NULL CHECK (cardinality(roles) > 0),
  -- NULL means all countries; otherwise the ISO codes this staff member may act in.
  country_scope   char(2)[],
  mfa_enrolled_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  disabled_at     timestamptz
);

-- The JWT claim is a hint for the UI; this re-reads the table and requires MFA (aal2) on
-- the current session, so a stolen or stale token without MFA gets nothing (RLS matrix).
CREATE FUNCTION private.has_admin_role(p_roles public.admin_role[])
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
     AND EXISTS (
       SELECT 1 FROM public.admin_users a
       WHERE a.user_id = auth.uid()
         AND a.disabled_at IS NULL
         AND a.roles && p_roles
     );
$$;

CREATE FUNCTION private.is_any_admin()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT private.has_admin_role(enum_range(NULL::public.admin_role));
$$;

REVOKE ALL ON FUNCTION private.has_admin_role(public.admin_role[]), private.is_any_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.has_admin_role(public.admin_role[]), private.is_any_admin()
  TO authenticated, service_role;

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_users FROM anon, authenticated;
GRANT SELECT ON public.admin_users TO authenticated;
GRANT ALL ON public.admin_users TO service_role;
CREATE POLICY admin_users_super_admin_read ON public.admin_users FOR SELECT TO authenticated
  USING (private.has_admin_role(ARRAY['super_admin']::public.admin_role[]));

-- Four eyes means two different people, enforced by the table itself (RLS matrix §6).
CREATE TABLE public.approvals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_kind text        NOT NULL,
  subject_id   text        NOT NULL,
  action       text        NOT NULL,
  payload      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  requested_by uuid        NOT NULL REFERENCES auth.users (id),
  approved_by  uuid        REFERENCES auth.users (id),
  level        smallint    NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 2),
  status       text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  decided_at   timestamptz,
  CONSTRAINT approvals_four_eyes CHECK (approved_by IS NULL OR approved_by <> requested_by),
  CONSTRAINT approvals_decided CHECK ((status = 'pending') = (decided_at IS NULL))
);
CREATE INDEX approvals_pending ON public.approvals (subject_kind, created_at) WHERE status = 'pending';

ALTER TABLE public.approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approvals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.approvals FROM anon, authenticated;
GRANT SELECT ON public.approvals TO authenticated;
GRANT ALL ON public.approvals TO service_role;
CREATE POLICY approvals_read_own_or_admin ON public.approvals FOR SELECT TO authenticated
  USING (requested_by = auth.uid() OR private.is_any_admin());

-- ---------------------------------------------------------------------------
-- Country packs. The full row holds vendor routing and thresholds, so clients never select
-- it; they receive the client-safe subset from get_bootstrap() (draft review 1.7).
--   config.client  → safe to send to apps (e.g. accepted ID types, emergency numbers)
--   config.server  → never leaves the database (gateway routing, SMS routing, thresholds)
-- ---------------------------------------------------------------------------
CREATE TABLE public.countries (
  code                char(2) PRIMARY KEY CHECK (code ~ '^[A-Z]{2}$'),
  name                text    NOT NULL,
  status              public.country_status NOT NULL DEFAULT 'disabled',
  currency_code       char(3) NOT NULL REFERENCES public.currencies (code),
  -- ITU country calling code, digits only (e.g. 234). Used to refuse OTP to numbers
  -- outside live/beta countries (R-31).
  calling_code        text    NOT NULL CHECK (calling_code ~ '^[0-9]{1,4}$'),
  default_language    text    NOT NULL CHECK (default_language ~ '^[a-z]{2,3}$'),
  supported_languages text[]  NOT NULL CHECK (cardinality(supported_languages) > 0),
  commission_rate_bps integer NOT NULL DEFAULT 1250 CHECK (commission_rate_bps BETWEEN 0 AND 10000),
  referral_rate_bps   integer NOT NULL DEFAULT 250  CHECK (referral_rate_bps BETWEEN 0 AND 10000),
  config              jsonb   NOT NULL DEFAULT '{"client": {}, "server": {}}'::jsonb
                      CHECK (jsonb_typeof(config -> 'client') = 'object'
                         AND jsonb_typeof(config -> 'server') = 'object'),
  version             integer NOT NULL DEFAULT 1,
  approved_by         uuid REFERENCES auth.users (id),
  approved_at         timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT countries_default_language_supported CHECK (default_language = ANY (supported_languages))
);

ALTER TABLE public.countries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.countries FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.countries FROM anon, authenticated;
GRANT SELECT ON public.countries TO authenticated;
GRANT ALL ON public.countries TO service_role;
CREATE POLICY countries_admin_read ON public.countries FOR SELECT TO authenticated
  USING (private.is_any_admin());

CREATE TABLE public.cities (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code char(2) NOT NULL REFERENCES public.countries (code),
  code         text    NOT NULL CHECK (code ~ '^[a-z0-9-]+$'),
  name         text    NOT NULL,
  timezone     text    NOT NULL,
  center       extensions.geography(Point, 4326),
  UNIQUE (country_code, code)
);

ALTER TABLE public.cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cities FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.cities FROM anon, authenticated;
GRANT SELECT ON public.cities TO anon, authenticated;
GRANT ALL ON public.cities TO service_role;
CREATE POLICY cities_read ON public.cities FOR SELECT TO anon, authenticated USING (true);

CREATE TABLE public.legal_documents (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code char(2) NOT NULL REFERENCES public.countries (code),
  type         text    NOT NULL CHECK (type IN ('terms', 'privacy', 'biometric_consent',
                                                'criminal_record_consent', 'provider_agreement')),
  version      integer NOT NULL CHECK (version > 0),
  locale       text    NOT NULL CHECK (locale ~ '^[a-z]{2,3}$'),
  url          text    NOT NULL,
  published_at timestamptz,
  UNIQUE (country_code, type, version, locale)
);

ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_documents FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.legal_documents FROM anon, authenticated;
GRANT SELECT ON public.legal_documents TO anon, authenticated;
GRANT ALL ON public.legal_documents TO service_role;
CREATE POLICY legal_documents_read_published ON public.legal_documents FOR SELECT TO anon, authenticated
  USING (published_at IS NOT NULL AND published_at <= now());

-- ---------------------------------------------------------------------------
-- Feature flags and remote config (kill switches, forced update, model routes — RB-11, RB-13).
-- country_code NULL = global default; a country row overrides it.
-- ---------------------------------------------------------------------------
CREATE TABLE public.feature_flags (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text     NOT NULL CHECK (key ~ '^[a-z0-9_.]+$'),
  country_code char(2)  REFERENCES public.countries (code),
  enabled      boolean  NOT NULL DEFAULT false,
  rollout_pct  smallint NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 0 AND 100),
  -- Only these keys are sent to clients; server-only flags stay out of bootstrap.
  client_visible boolean NOT NULL DEFAULT true,
  payload      jsonb    NOT NULL DEFAULT '{}'::jsonb,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (key, country_code)
);

CREATE TABLE public.remote_config (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key            text    NOT NULL CHECK (key ~ '^[a-z0-9_.]+$'),
  country_code   char(2) REFERENCES public.countries (code),
  value          jsonb   NOT NULL,
  client_visible boolean NOT NULL DEFAULT false,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (key, country_code)
);

ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feature_flags FORCE ROW LEVEL SECURITY;
ALTER TABLE public.remote_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.remote_config FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.feature_flags, public.remote_config FROM anon, authenticated;
GRANT SELECT ON public.feature_flags, public.remote_config TO authenticated;
GRANT ALL ON public.feature_flags, public.remote_config TO service_role;
CREATE POLICY feature_flags_admin_read ON public.feature_flags FOR SELECT TO authenticated
  USING (private.is_any_admin());
CREATE POLICY remote_config_admin_read ON public.remote_config FOR SELECT TO authenticated
  USING (private.is_any_admin());

CREATE TRIGGER countries_touch BEFORE UPDATE ON public.countries
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();
CREATE TRIGGER feature_flags_touch BEFORE UPDATE ON public.feature_flags
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();
CREATE TRIGGER remote_config_touch BEFORE UPDATE ON public.remote_config
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

-- Every change to these tables is audited.
CREATE TRIGGER countries_audit AFTER INSERT OR UPDATE OR DELETE ON public.countries
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('code');
CREATE TRIGGER feature_flags_audit AFTER INSERT OR UPDATE OR DELETE ON public.feature_flags
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('key');
CREATE TRIGGER remote_config_audit AFTER INSERT OR UPDATE OR DELETE ON public.remote_config
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('key');
CREATE TRIGGER admin_users_audit AFTER INSERT OR UPDATE OR DELETE ON public.admin_users
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('user_id');
CREATE TRIGGER approvals_audit AFTER INSERT OR UPDATE ON public.approvals
  FOR EACH ROW EXECUTE FUNCTION private.audit_row_change('id');
