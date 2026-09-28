-- A new profile's country, when the app did not send one (audit 2026-09-27 Y.27).
--
-- `create_request` refuses a profile with no country (ERR_PROFILE_NOT_FOUND), and no client grant
-- can set `profiles.country_code`, so a sign-up that arrived without `country_code` metadata could
-- never post a request. The app now sends it; this is the server's half, so an older build or a
-- sign-up from another surface still lands in a country. The phone is the evidence: the
-- before-user-created hook has already refused every number outside a beta or live country, so
-- the longest matching calling code is the country the number belongs to. Metadata still wins
-- when it names a beta or live country, because that is the user's own choice.

CREATE OR REPLACE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_country  char(2);
  v_language text;
  v_phone    text := regexp_replace(coalesce(NEW.phone, ''), '[^0-9]', '', 'g');
BEGIN
  SELECT c.code INTO v_country
  FROM public.countries c
  WHERE c.code = upper(NEW.raw_user_meta_data ->> 'country_code')
    AND c.status IN ('beta', 'live');

  IF v_country IS NULL AND v_phone <> '' THEN
    SELECT c.code INTO v_country
    FROM public.countries c
    WHERE c.status IN ('beta', 'live') AND v_phone LIKE c.calling_code || '%'
    ORDER BY length(c.calling_code) DESC
    LIMIT 1;
  END IF;

  SELECT l INTO v_language
  FROM public.countries c, unnest(c.supported_languages) AS l
  WHERE c.code = v_country AND l = lower(NEW.raw_user_meta_data ->> 'language');

  INSERT INTO public.profiles (user_id, country_code, language)
  VALUES (NEW.id, v_country,
          coalesce(v_language,
                   (SELECT c.default_language FROM public.countries c WHERE c.code = v_country),
                   'en'));
  RETURN NEW;
END $$;
