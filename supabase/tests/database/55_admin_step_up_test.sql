-- Step-up for the sensitive admin verbs (audit 2026-10-13, Z.11). `aal2` says a session passed a
-- second factor once; these five also want the TOTP code entered in the last five minutes, read
-- from the JWT's `amr` the way GoTrue writes it: `{"method": "totp", "timestamp": <unix>}`.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(36);

INSERT INTO auth.users (id, email) VALUES
  ('d1111111-1111-4111-8111-555555555555', 'stepup.super@suskii.test'),
  ('d2222222-2222-4222-8222-555555555555', 'stepup.customer@suskii.test');
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('d1111111-1111-4111-8111-555555555555', 'd2222222-2222-4222-8222-555555555555');
INSERT INTO public.admin_users (user_id, roles, country_scope) VALUES
  ('d1111111-1111-4111-8111-555555555555', ARRAY['super_admin']::public.admin_role[], NULL);

-- Speak as p_user at aal2, with p_amr as the session's authentication methods.
CREATE FUNCTION pg_temp.act(p_user text, p_amr jsonb) RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal2')
     || CASE WHEN p_amr IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('amr', p_amr) END)::text,
    true);
  SELECT NULL::void;
$fn$;

CREATE FUNCTION pg_temp.totp_at(p_ago interval) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('method', 'totp', 'timestamp', extract(epoch FROM now() - p_ago)::bigint),
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch FROM now() - p_ago)::bigint));
$fn$;

-- The error a statement raises, or 'ok'. A gate that passed shows the function's own complaint.
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $fn$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text) TO authenticated;

CREATE TEMP TABLE verbs (name text PRIMARY KEY, stmt text);
GRANT SELECT ON verbs TO authenticated;
INSERT INTO verbs VALUES
  ('propose_config_change',
   $$SELECT public.propose_config_change('key-su-propose-0000001', 'no_such_target', 'x',
       '{}'::jsonb, NULL, 'step-up test')$$),
  ('review_config_change',
   $$SELECT public.review_config_change('key-su-review-00000001',
       '00000000-0000-4000-8000-000000000055', true, NULL)$$),
  ('approve_withdrawal',
   $$SELECT public.approve_withdrawal('key-su-withdraw-000001',
       '00000000-0000-4000-8000-000000000055', true, NULL)$$),
  ('resolve_dispute',
   $$SELECT public.resolve_dispute('key-su-resolve-0000001',
       '00000000-0000-4000-8000-000000000055', 'full_refund', 100, 'step-up test')$$),
  ('request_document_access',
   $$SELECT public.request_document_access(
       'd2222222-2222-4222-8222-555555555555/id-front.jpg', 'review')$$);

-- ---------------------------------------------------------------------------
-- Refused without a recent code, for each of the five.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', NULL);
SELECT is(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': an aal2 session with no amr')
FROM verbs ORDER BY name;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', pg_temp.totp_at('6 minutes'));
SELECT is(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': a code entered six minutes ago')
FROM verbs ORDER BY name;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555',
  jsonb_build_array(jsonb_build_object('method', 'password',
                                       'timestamp', extract(epoch FROM now())::bigint)));
SELECT is(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': a fresh password is not a code')
FROM verbs ORDER BY name;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', '["totp", "password"]'::jsonb);
SELECT is(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': an amr with no timestamps')
FROM verbs ORDER BY name;

-- ---------------------------------------------------------------------------
-- Through the gate with a recent code: each function's own answer comes back instead.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', pg_temp.totp_at('4 minutes'));
SELECT isnt(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': a code entered four minutes ago')
FROM verbs ORDER BY name;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', pg_temp.totp_at('0 seconds'));
SELECT isnt(pg_temp.err(stmt), 'ERR_REAUTH_REQUIRED', name || ': a code entered just now')
FROM verbs ORDER BY name;
SELECT is(pg_temp.err(
    $$SELECT public.request_document_access(
        'd2222222-2222-4222-8222-555555555555/id-front.jpg', 'review')$$), 'ok',
  'and with it the document access is granted and recorded');

-- ---------------------------------------------------------------------------
-- The order of the checks, and what is not guarded.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('d2222222-2222-4222-8222-555555555555', pg_temp.totp_at('0 seconds'));
SELECT is(pg_temp.err(stmt), 'ERR_PERMISSION_DENIED',
  name || ': somebody with no role is told that, not asked for a code')
FROM verbs WHERE name IN ('approve_withdrawal', 'resolve_dispute') ORDER BY name;

SELECT pg_temp.act('d1111111-1111-4111-8111-555555555555', NULL);
SELECT is(pg_temp.err($$SELECT count(*) FROM public.kyc_review_queue()$$), 'ok',
  'reading a queue needs aal2 and no step-up');
SELECT is(pg_temp.err($$SELECT count(*) FROM public.admin_overview()$$), 'ok',
  'nor does the dashboard');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM audit.kyc_access
           WHERE officer_id = 'd1111111-1111-4111-8111-555555555555'), 3,
  'only the three stepped-up document requests were recorded');

SELECT * FROM finish();
ROLLBACK;
