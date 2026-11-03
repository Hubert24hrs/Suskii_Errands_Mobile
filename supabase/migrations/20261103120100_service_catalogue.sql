-- The service catalogue as data (feature 2 of the 2026-11-03 brief).
--
-- `service_categories` has been the one catalogue since Phase 3: every screen reads it, matching
-- joins it, and nothing else lists services. Three things kept it from being manageable:
--
--   * a service's name lived only in the apps' translation files, keyed by `name_key`, so a
--     service added in the database showed as "Something else" until an app release named it;
--   * the read policy hid inactive rows, so switching a service off would have blanked its name
--     on every past request that embeds it. Both apps already ask for `active = true` when they
--     build a picker, so the rows can be readable without reappearing anywhere they should not;
--   * nobody could change it except with a migration.
--
-- Names and descriptions are stored per language. The 21 existing services keep their keys, ids,
-- `name_key`s and order, so requests, provider services, matching and price guardrails are
-- untouched; their stored names are the apps' current English and Pidgin strings, word for word.
-- The descriptions are new copy, written for the picker, for the client to review.
--
-- No function deletes a service. One that requests or providers point at cannot be deleted by
-- the foreign keys either; it is switched off, and stays readable.

ALTER TABLE public.service_categories
  ADD COLUMN display_names jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(display_names) = 'object'),
  ADD COLUMN descriptions  jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(descriptions) = 'object');

DROP POLICY service_categories_read ON public.service_categories;
CREATE POLICY service_categories_read ON public.service_categories FOR SELECT TO anon, authenticated
  USING (true);

UPDATE public.service_categories sc
SET display_names = v.names, descriptions = v.descriptions
FROM (VALUES
  ('errands_delivery',    '{"en": "Errands & delivery", "pcm": "Errand & delivery"}'::jsonb,
   '{"en": "Pick up, drop off or run an errand across town."}'::jsonb),
  ('shopping',            '{"en": "Shopping", "pcm": "Shopping"}',
   '{"en": "Groceries, market runs and store purchases, bought and brought to you."}'),
  ('cleaning_laundry',    '{"en": "Cleaning & laundry", "pcm": "Cleaning & laundry"}',
   '{"en": "Home cleaning, washing and ironing."}'),
  ('moving',              '{"en": "Moving", "pcm": "Moving/ Carry load"}',
   '{"en": "Help moving house, furniture or heavy loads."}'),
  ('repairs',             '{"en": "Plumbing, electrical & repairs", "pcm": "Plumbing, electrical & repair"}',
   '{"en": "General fixes around the home or office."}'),
  ('personal_assistance', '{"en": "Personal assistance", "pcm": "Personal assistance"}',
   '{"en": "An extra pair of hands for queues, appointments and everyday tasks."}'),
  ('document_delivery',   '{"en": "Document delivery", "pcm": "Document delivery"}',
   '{"en": "Documents picked up and delivered, signed for on arrival."}'),
  ('food_pickup',         '{"en": "Food pickup", "pcm": "Food pickup"}',
   '{"en": "Collect a food order from a restaurant or vendor."}'),
  ('transportation',      '{"en": "Transportation assistance", "pcm": "Transport help"}',
   '{"en": "Getting people or things from one place to another."}'),
  ('tech_business',       '{"en": "Technical & business services", "pcm": "Tech & business service"}',
   '{"en": "Device setup, printing, registrations and office support."}'),
  ('event_assistance',    '{"en": "Event assistance", "pcm": "Event help"}',
   '{"en": "Setup, serving and running around on the day of an event."}'),
  ('mechanics',           '{"en": "Mechanics", "pcm": "Mechanic"}',
   '{"en": "Vehicle checks and repairs."}'),
  ('fashion_design',      '{"en": "Fashion design", "pcm": "Fashion design / tailoring"}',
   '{"en": "Tailoring, alterations and made-to-measure clothing."}'),
  ('beauty_hair',         '{"en": "Beauty & hair", "pcm": "Beauty & hair"}',
   '{"en": "Hair, makeup, nails and grooming."}'),
  ('plumbing',            '{"en": "Plumbing", "pcm": "Plumber"}',
   '{"en": "Leaks, pipes, taps and water systems."}'),
  ('electrical',          '{"en": "Electrical", "pcm": "Electrician"}',
   '{"en": "Wiring, sockets, lighting and electrical faults."}'),
  ('carpentry',           '{"en": "Carpentry", "pcm": "Carpenter"}',
   '{"en": "Furniture, doors and woodwork."}'),
  ('catering',            '{"en": "Catering & cooking", "pcm": "Catering & cooking"}',
   '{"en": "Meals cooked for your home or event."}'),
  ('photography',         '{"en": "Photography", "pcm": "Photographer"}',
   '{"en": "Photos for events, portraits and products."}'),
  ('tutoring',            '{"en": "Tutoring & lessons", "pcm": "Lesson teacher"}',
   '{"en": "Lessons at home or online."}'),
  ('custom',              '{"en": "Something else", "pcm": "Another thing"}',
   '{"en": "Describe what you need if it is not listed."}')
) AS v(key, names, descriptions)
WHERE sc.key = v.key AND sc.display_names = '{}'::jsonb;

-- Names and descriptions as one validated shape: an object of language code to text, English
-- required for names because it is what every other language falls back to.
CREATE FUNCTION private.valid_service_texts(p_texts jsonb, p_max integer, p_require_en boolean)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT jsonb_typeof(p_texts) = 'object'
     AND (NOT p_require_en OR length(btrim(coalesce(p_texts ->> 'en', ''))) >= 2)
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_each(p_texts) e
       WHERE e.key !~ '^[a-z]{2,3}$'
          OR jsonb_typeof(e.value) <> 'string'
          OR length(btrim(e.value #>> '{}')) NOT BETWEEN 1 AND p_max);
$$;
REVOKE ALL ON FUNCTION private.valid_service_texts(jsonb, integer, boolean) FROM PUBLIC, anon, authenticated;

-- Create a service, or change one. The key is the service's identity on the wire (requests and
-- provider services name it), so it is set once and never renamed; the name shown is what moves.
CREATE FUNCTION public.admin_save_service(
  p_idempotency_key  text,
  p_key              text,
  p_display_names    jsonb,
  p_descriptions     jsonb DEFAULT '{}'::jsonb,
  p_icon_key         text DEFAULT NULL,
  p_requires_vehicle boolean DEFAULT NULL,
  p_sort_order       integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_before public.service_categories%ROWTYPE;
  v_row    public.service_categories%ROWTYPE;
  v_out    jsonb;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'admin_save_service',
    jsonb_build_object('key', p_key, 'names', p_display_names, 'descriptions', p_descriptions,
                       'icon', p_icon_key, 'vehicle', p_requires_vehicle, 'sort', p_sort_order));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  IF p_key IS NULL OR p_key !~ '^[a-z0-9_]{2,40}$'
     OR NOT private.valid_service_texts(p_display_names, 80, true)
     OR NOT private.valid_service_texts(coalesce(p_descriptions, '{}'::jsonb), 200, false)
     OR (p_icon_key IS NOT NULL AND p_icon_key !~ '^[a-z_]{2,30}$')
     OR (p_sort_order IS NOT NULL AND p_sort_order NOT BETWEEN 1 AND 32000) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_before FROM public.service_categories sc WHERE sc.key = p_key FOR UPDATE;
  IF FOUND THEN
    UPDATE public.service_categories sc
    SET display_names    = p_display_names,
        descriptions     = coalesce(p_descriptions, '{}'::jsonb),
        icon_key         = coalesce(p_icon_key, sc.icon_key),
        requires_vehicle = coalesce(p_requires_vehicle, sc.requires_vehicle),
        sort_order       = coalesce(p_sort_order, sc.sort_order)
    WHERE sc.id = v_before.id
    RETURNING * INTO v_row;
  ELSE
    -- A new service has no translation-file entry; `name_key` names that absence, and the apps
    -- show the stored name.
    INSERT INTO public.service_categories (key, name_key, icon_key, requires_vehicle, sort_order,
                                           display_names, descriptions)
    VALUES (p_key, 'svc_' || p_key, coalesce(p_icon_key, 'magic'), coalesce(p_requires_vehicle, false),
            coalesce(p_sort_order,
                     (SELECT coalesce(max(sc.sort_order), 0) + 10 FROM public.service_categories sc
                      WHERE sc.key <> 'custom')),
            p_display_names, coalesce(p_descriptions, '{}'::jsonb))
    RETURNING * INTO v_row;
  END IF;

  PERFORM private.audit_write(
    CASE WHEN v_before.id IS NULL THEN 'service.created' ELSE 'service.updated' END,
    'public.service_categories', v_row.id::text,
    CASE WHEN v_before.id IS NULL THEN NULL ELSE jsonb_build_object(
      'display_names', v_before.display_names, 'descriptions', v_before.descriptions,
      'icon_key', v_before.icon_key, 'requires_vehicle', v_before.requires_vehicle,
      'sort_order', v_before.sort_order) END,
    jsonb_build_object('key', v_row.key, 'display_names', v_row.display_names,
      'descriptions', v_row.descriptions, 'icon_key', v_row.icon_key,
      'requires_vehicle', v_row.requires_vehicle, 'sort_order', v_row.sort_order), NULL);

  v_out := jsonb_build_object('id', v_row.id, 'key', v_row.key, 'active', v_row.active,
    'display_names', v_row.display_names, 'descriptions', v_row.descriptions,
    'icon_key', v_row.icon_key, 'requires_vehicle', v_row.requires_vehicle,
    'sort_order', v_row.sort_order, 'created', v_before.id IS NULL);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_out);
  RETURN v_out;
END $$;

-- Switching a service off removes it from both pickers and from new requests (`create_request`
-- and `update_provider_services` already accept only active services). Requests that used it keep
-- it, providers who offered it keep the row, and the name stays readable on both.
CREATE FUNCTION public.admin_set_service_active(p_key text, p_active boolean, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.service_categories%ROWTYPE;
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(ARRAY['super_admin']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  IF p_active IS NULL OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.service_categories sc WHERE sc.key = p_key FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_row.active IS DISTINCT FROM p_active THEN
    UPDATE public.service_categories SET active = p_active WHERE id = v_row.id;
    PERFORM private.audit_write(
      CASE WHEN p_active THEN 'service.activated' ELSE 'service.deactivated' END,
      'public.service_categories', v_row.id::text,
      jsonb_build_object('active', v_row.active), jsonb_build_object('active', p_active),
      left(btrim(p_reason), 300));
  END IF;
  RETURN jsonb_build_object('key', v_row.key, 'active', p_active);
END $$;

-- The admin page's list: every service, active or not, with how much points at it, so the person
-- switching one off can see what that touches.
CREATE FUNCTION public.admin_service_catalogue()
RETURNS TABLE (id uuid, key text, active boolean, display_names jsonb, descriptions jsonb,
               icon_key text, requires_vehicle boolean, allows_custom boolean, sort_order smallint,
               request_count bigint, open_request_count bigint, provider_count bigint,
               updated_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_user();
  IF NOT private.has_admin_role(
       ARRAY['super_admin', 'support_agent', 'verification_officer']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT sc.id, sc.key, sc.active, sc.display_names, sc.descriptions, sc.icon_key,
         sc.requires_vehicle, sc.allows_custom, sc.sort_order,
         (SELECT count(*) FROM public.requests r WHERE r.category_id = sc.id),
         (SELECT count(*) FROM public.requests r WHERE r.category_id = sc.id
            AND r.status IN ('published', 'offers_received', 'negotiating', 'agreed',
                             'payment_pending', 'paid_held', 'assigned', 'en_route', 'arrived',
                             'in_progress', 'completed_by_provider', 'disputed')),
         (SELECT count(*) FROM public.provider_services ps WHERE ps.category_id = sc.id),
         sc.updated_at
  FROM public.service_categories sc
  ORDER BY sc.sort_order, sc.key;
END $$;

REVOKE ALL ON FUNCTION
  public.admin_save_service(text, text, jsonb, jsonb, text, boolean, integer),
  public.admin_set_service_active(text, boolean, text),
  public.admin_service_catalogue()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.admin_save_service(text, text, jsonb, jsonb, text, boolean, integer),
  public.admin_set_service_active(text, boolean, text),
  public.admin_service_catalogue()
  TO authenticated;
