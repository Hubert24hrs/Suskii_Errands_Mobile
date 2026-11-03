-- The service catalogue as data: stored names, readable history, admin management (20261103120100).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(28);

INSERT INTO auth.users (id, phone) VALUES
  ('5c000000-0000-4000-8000-000000000001', '2348000006901'),   -- super admin
  ('5c000000-0000-4000-8000-000000000002', '2348000006902'),   -- support agent
  ('5c000000-0000-4000-8000-000000000003', '2348000006903'),   -- customer
  ('5c000000-0000-4000-8000-000000000004', '2348000006904');   -- provider
UPDATE public.profiles SET country_code = 'NG' WHERE user_id::text LIKE '5c000000-%';
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('5c000000-0000-4000-8000-000000000001', ARRAY['super_admin']::public.admin_role[]),
  ('5c000000-0000-4000-8000-000000000002', ARRAY['support_agent']::public.admin_role[]);

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)
     || CASE WHEN p_aal = 'aal2' THEN jsonb_build_object('amr', jsonb_build_array(
          jsonb_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::bigint)))
        ELSE '{}'::jsonb END)::text, true);
  SELECT NULL::void;
$fn$;

-- The existing 21 carry the apps' own names, unchanged.
SELECT is((SELECT count(*)::int FROM public.service_categories
           WHERE display_names ->> 'en' IS NOT NULL AND display_names ->> 'pcm' IS NOT NULL),
  (SELECT count(*)::int FROM public.service_categories), 'every service has a stored English and Pidgin name');
SELECT is((SELECT display_names FROM public.service_categories WHERE key = 'repairs'),
  '{"en": "Plumbing, electrical & repairs", "pcm": "Plumbing, electrical & repair"}'::jsonb,
  'word for word what the apps show');
SELECT is((SELECT name_key FROM public.service_categories WHERE key = 'repairs'), 'catRepairs',
  'and the translation key the current apps use is unchanged');
SELECT is((SELECT count(*)::int FROM public.service_categories WHERE descriptions ->> 'en' IS NULL),
  0, 'every service has a description');

-- A request that used a service, made before anything changes.
INSERT INTO public.requests (customer_id, country_code, category_id, description, pickup_label, currency)
VALUES ('5c000000-0000-4000-8000-000000000003', 'NG',
        (SELECT id FROM public.service_categories WHERE key = 'photography'),
        'Photos for a birthday', 'Yaba, Lagos', 'NGN');

-- Only a super admin manages the catalogue.
SELECT pg_temp.act('5c000000-0000-4000-8000-000000000002');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000001', 'pet_care',
                   '{"en": "Pet care"}')$$, '42501', 'ERR_PERMISSION_DENIED', 'a support agent cannot add a service');
SELECT throws_ok($$SELECT public.admin_set_service_active('photography', false, 'not offered')$$,
  '42501', 'ERR_PERMISSION_DENIED', 'or switch one off');
SELECT ok((SELECT count(*) FROM public.admin_service_catalogue()) > 0, 'but can read the catalogue page');
SELECT pg_temp.act('5c000000-0000-4000-8000-000000000001', 'aal1');
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000001', 'pet_care',
                   '{"en": "Pet care"}')$$, '42501', 'ERR_PERMISSION_DENIED', 'nor can a super admin without MFA');
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', '5c000000-0000-4000-8000-000000000001',
  'role', 'authenticated', 'aal', 'aal2', 'amr', jsonb_build_array(jsonb_build_object('method', 'totp',
  'timestamp', extract(epoch FROM now() - interval '10 minutes')::bigint)))::text, true);
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000001', 'pet_care',
                   '{"en": "Pet care"}')$$, 'P0001', 'ERR_REAUTH_REQUIRED',
  'or with a code entered more than five minutes ago');

-- Adding one: no app release needed, because the name travels with it.
SELECT pg_temp.act('5c000000-0000-4000-8000-000000000001');
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000002', 'pet_care',
                   '{"pcm": "Pet care"}')$$, '22023', 'ERR_INVALID_ARGUMENT', 'a name must exist in English');
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000003', 'Pet Care!',
                   '{"en": "Pet care"}')$$, '22023', 'ERR_INVALID_ARGUMENT', 'a key is lower-case letters, digits and _');
SELECT throws_ok($$SELECT public.admin_save_service('key-svc-save-0000000004', 'pet_care',
                   '{"en": "Pet care"}', '{"en": 5}')$$, '22023', 'ERR_INVALID_ARGUMENT',
  'a description is text');
SELECT is((public.admin_save_service('key-svc-save-0000000005', 'pet_care',
           '{"en": "Pet care", "pcm": "Pet care"}', '{"en": "Walking, feeding and sitting."}',
           'paw') ->> 'created'), 'true', 'a new service is added');
SELECT is((public.admin_save_service('key-svc-save-0000000005', 'pet_care',
           '{"en": "Pet care", "pcm": "Pet care"}', '{"en": "Walking, feeding and sitting."}',
           'paw') ->> 'created'), 'true', 'and a retry with the same key replays it');
SELECT is((SELECT count(*)::int FROM public.service_categories WHERE key = 'pet_care'), 1,
  'without a second row');
SELECT ok((SELECT sort_order < (SELECT sort_order FROM public.service_categories WHERE key = 'custom')
           FROM public.service_categories WHERE key = 'pet_care'),
  'it is listed before Something else');
SELECT is((SELECT name_key FROM public.service_categories WHERE key = 'pet_care'), 'svc_pet_care',
  'with a translation key no app has, so the stored name is shown');

-- Changing one: the name moves, the identity does not.
SELECT is((public.admin_save_service('key-svc-save-0000000006', 'photography',
           '{"en": "Photography & video", "pcm": "Photographer"}', '{"en": "Photos and video."}')
           ->> 'created'), 'false', 'an existing service is updated, not duplicated');
RESET ROLE;
SELECT is((SELECT r.category_id FROM public.requests r
           WHERE r.customer_id = '5c000000-0000-4000-8000-000000000003'),
  (SELECT id FROM public.service_categories WHERE key = 'photography'),
  'and the request that used it still points at it');

-- Switching one off.
SELECT pg_temp.act('5c000000-0000-4000-8000-000000000001');
SET LOCAL ROLE authenticated;
SELECT is((public.admin_set_service_active('photography', false, 'Paused for the pilot') ->> 'active'),
  'false', 'a service is switched off');
SELECT is((SELECT open_request_count FROM public.admin_service_catalogue() WHERE key = 'photography'),
  0::bigint, 'the catalogue page counts what is still open on it');
SELECT is((SELECT request_count FROM public.admin_service_catalogue() WHERE key = 'photography'),
  1::bigint, 'and what used it');

SELECT pg_temp.act('5c000000-0000-4000-8000-000000000003', 'aal1');
SELECT is((SELECT sc.display_names ->> 'en' FROM public.requests r
           JOIN public.service_categories sc ON sc.id = r.category_id
           WHERE r.customer_id = '5c000000-0000-4000-8000-000000000003'),
  'Photography & video', 'the customer still sees the name on their old request');
SELECT is((SELECT count(*)::int FROM public.service_categories WHERE key = 'photography' AND active),
  0, 'and the picker, which asks for active services, no longer lists it');
SELECT throws_ok($$SELECT public.create_request('key-svc-request-00000001', 'photography',
                   'More photos', 'Yaba, Lagos')$$,
  'P0001', 'ERR_CATEGORY_NOT_FOUND', 'a new request cannot use it');

SELECT pg_temp.act('5c000000-0000-4000-8000-000000000004', 'aal1');
SELECT throws_ok($$SELECT public.update_provider_services(ARRAY['photography'])$$,
  'P0001', 'ERR_CATEGORY_NOT_FOUND', 'nor can a provider start offering it');
RESET ROLE;

SELECT is((SELECT array_agg(action ORDER BY id) FROM audit.log
           WHERE target_table = 'public.service_categories'),
  ARRAY['service.created', 'service.updated', 'service.deactivated'],
  'each change is in the audit log');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname ~ 'service' AND p.proname ~ 'delete'),
  0, 'and nothing deletes a service');

SELECT * FROM finish();
ROLLBACK;
