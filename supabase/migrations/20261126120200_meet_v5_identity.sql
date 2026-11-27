-- Meet v5 M1, part 3 (`docs/plan/meet-v5-design.md` §2.7, §3.2.1, §4.2, §8.1, §8.5, §9 M1-PR3):
-- who may enter Meet, the Meet identity, and the photo pipeline.
--
--   Eligibility  `meet_eligibility`, one row per account, outside the deletable profile. The birth
--                date is taken once (`meet_check_in`) and the age computed in the person's own
--                time zone, a 29 February birthday falling on 1 March in other years. Somebody
--                under 18 gets a row saying so and **no birth date anywhere**: not in the row, not
--                in the idempotency hash (which is why the claim hashes "adult or not" rather than
--                the date: there are only about 36,000 dates in a century, so a hash of one is the
--                date), not in a log. Every device the account registered is barred for a year
--                (`meet_age_refusal_devices`, no user id), and the refusal is **returned, never
--                raised** (D24): a RAISE would roll the record back. A failed device-integrity
--                verdict is refused the same way. `meet_require_access` is restated whole with
--                eligibility, a barred device, the guidelines version and the profile.
--   Identity     `meet_profiles` (the opaque id is the only person id a client ever sees, and the
--                storage folder, D15), `meet_discovery_prefs` ("show me" stored apart, applied one
--                way, read only by the owner's own functions, consented through
--                `meet_sensitive_data`, D5), `meet_photos`, `meet_prompts`, and the interest and
--                prompt keys (reference data, so in a migration rather than the seed).
--   Screening    first name, bio and prompts pass `private.meet_screen_text` and then
--                `private.moderate_text`. A contact or solicitation hit raises and writes nothing;
--                a hold marks the text `held`. **`meet_screen_text` here is an interim body**:
--                phone and account numbers, emails, links and the design's blocked terms, nothing
--                else. M1-PR4 replaces it whole (same signature) with the normalisation, the
--                number words, handles and `meet_text_rules`, and opens a `meet_profile` case for a
--                hold once the moderation subject kinds allow one.
--   Media        three private buckets (`meet-inbox`, `meet-media`, `meet-verify`), the policies
--                and `private.meet_media_visible_to`; `meet-media-worker` added to
--                `private.invoke_edge_worker` and run every minute there is work; the
--                `gateway_meet_media_*` functions it reports through. No auth uid appears in any
--                path another person's app reads: `meet-media` is foldered by profile id, and a
--                CHECK holds every stored path to its own profile and photo id.
--   Legal        `legal_documents.type` gains `meet_guidelines`, `meet_terms`, `meet_reward_rules`
--                and `child_safety`. No row is inserted: each page gets its row when it is live,
--                which is a readiness item (`meet_guidelines_page_live`, `csae_page_live`).
--
-- Sixteen stubs from 20261126120100 get their bodies, with the same signatures and grants. Four
-- helpers stand in for tables later PRs create, each named there and replaced whole: suspension
-- and restrictions in `meet_get_state` and the safety-event log (M1-PR4), unread counts (M1-PR5,
-- M1-PR6). `private.meet_may_view` answers "discoverable to the viewer" until M1-PR5 adds a match,
-- an open conversation and today's set.
--
-- Review of PR #121 (rev. 2026-11-27):
--   * A declared under-18 age is recorded before anything else is decided, so a barred phone or a
--     failed integrity verdict cannot swallow it; a refused account bars the phones it registers
--     later too, for as long as the refusal's bar runs.
--   * Visibility follows access: somebody Meet refuses (a barred phone, outdated guidelines, out of
--     the rollout) is shown to nobody and reads nobody's media, and can still leave: pause, hide,
--     privacy, remove a photo or prompt, delete the profile (`private.meet_require_exit`).
--   * The interim screen strips every default-ignorable code point and lets any non-alphanumeric
--     character separate the digits of a run. Prompt answers are screened by a trigger.
--   * `meet-media` refuses to sign a URL for anybody but staff (`storage.operation`, [S]).
--   * The inbox is capped per person and swept daily; an underage-appearance rejection keeps its
--     files; account erasure removes the Meet profile and an adult's birth date.
--
-- **1.4.0 calls nothing here.** The only changes to shared objects are the `legal_documents` type
-- CHECK (widened), `invoke_edge_worker` (one more name on its list) and `erase_account` (restated
-- with the Meet profile and eligibility).

-- ---------------------------------------------------------------------------
-- Legal documents (§2.9): the four Meet page types. Widened from 20260916120500, its only
-- definition; every existing type stays.
-- ---------------------------------------------------------------------------
ALTER TABLE public.legal_documents DROP CONSTRAINT legal_documents_type_check;
ALTER TABLE public.legal_documents ADD CONSTRAINT legal_documents_type_check
  CHECK (type IN ('terms', 'privacy', 'biometric_consent', 'criminal_record_consent',
                  'provider_agreement', 'meet_guidelines', 'meet_terms', 'meet_reward_rules',
                  'child_safety'));

-- ---------------------------------------------------------------------------
-- Reference data (§3.2.1). Labels are l10n keys in the apps; nothing a client sees is free text.
-- ---------------------------------------------------------------------------
CREATE TABLE public.meet_interest_keys (
  key    text PRIMARY KEY CHECK (key ~ '^[a-z_]{2,30}$'),
  active boolean NOT NULL DEFAULT true,
  sort   smallint NOT NULL DEFAULT 0
);

CREATE TABLE public.meet_prompt_keys (
  key    text PRIMARY KEY CHECK (key ~ '^[a-z_]{2,40}$'),
  active boolean NOT NULL DEFAULT true,
  sort   smallint NOT NULL DEFAULT 0
);

-- Thirty interests and twenty prompts [A]: product copy, not a fact, and nothing in either list
-- names a gender, an orientation, money or a body (OD-38, §8.8).
INSERT INTO public.meet_interest_keys (key, sort) VALUES
  ('afrobeats', 1), ('music', 2), ('dancing', 3), ('karaoke', 4), ('cooking', 5), ('foodie', 6),
  ('coffee', 7), ('travel', 8), ('beach', 9), ('hiking', 10), ('nature', 11), ('fitness', 12),
  ('football', 13), ('basketball', 14), ('reading', 15), ('writing', 16), ('poetry', 17),
  ('movies', 18), ('nollywood', 19), ('series', 20), ('comedy', 21), ('gaming', 22), ('art', 23),
  ('photography', 24), ('fashion', 25), ('tech', 26), ('business', 27), ('faith', 28),
  ('volunteering', 29), ('pets', 30)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.meet_prompt_keys (key, sort) VALUES
  ('sunday', 1), ('green_flag', 2), ('red_flag', 3), ('perfect_weekend', 4), ('best_meal', 5),
  ('comfort_food', 6), ('travel_dream', 7), ('hidden_talent', 8), ('favourite_song', 9),
  ('first_date_idea', 10), ('makes_me_laugh', 11), ('proud_of', 12), ('never_without', 13),
  ('simple_pleasure', 14), ('learning_now', 15), ('dream_job', 16), ('unpopular_opinion', 17),
  ('together_we_could', 18), ('small_win', 19), ('best_advice', 20)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Eligibility (§3.2.1, §8.1). One row per account; deleting the Meet profile leaves it, so the
-- date stays set once and a refusal stays a refusal.
-- ---------------------------------------------------------------------------
CREATE TABLE public.meet_eligibility (
  user_id                uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  status                 text NOT NULL CHECK (status IN ('eligible', 'refused_minor', 'revoked')),
  -- Only an adult's date is ever stored.
  birth_date             date,
  method                 text NOT NULL DEFAULT 'self_declared'
                         CHECK (method IN ('self_declared', 'support_corrected', 'age_signal')),
  -- Seam for Play's Age Signals API (VERIFY-IN-RESEARCH, spike S-17). Nothing writes it yet.
  age_signal             jsonb,
  guidelines_version     integer NOT NULL CHECK (guidelines_version > 0),
  guidelines_accepted_at timestamptz NOT NULL DEFAULT now(),
  attested_at            timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  revoked_reason         text CHECK (length(revoked_reason) <= 200),
  CONSTRAINT meet_eligibility_birth_date_only_when_eligible
    CHECK ((status = 'eligible') = (birth_date IS NOT NULL))
);

-- A phone an under-18 refusal came from. No user id and no birth date: what is kept is that a
-- device was barred, and until when.
CREATE TABLE public.meet_age_refusal_devices (
  device_fingerprint_hash bytea PRIMARY KEY CHECK (length(device_fingerprint_hash) > 0),
  refused_at              timestamptz NOT NULL DEFAULT now(),
  expires_at              timestamptz NOT NULL
);
CREATE INDEX meet_age_refusal_devices_expiry ON public.meet_age_refusal_devices (expires_at);

-- ---------------------------------------------------------------------------
-- Profiles (§3.2.1).
-- ---------------------------------------------------------------------------
CREATE TABLE public.meet_profiles (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                   uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE CASCADE,
  country_code              char(2) NOT NULL REFERENCES public.countries (code),
  -- Letters, spaces, apostrophes and hyphens: no digit, @, _ or dot, so no handle fits. Up to two
  -- combining accents (U+0300-U+036F, less the invisible U+034F) may follow each character: NFC
  -- has no single code point for a tone mark over an underdotted vowel, so Yoruba's Folake
  -- spelled with its tones needs them; more would be stacking for effect.
  first_name                text NOT NULL
                            CHECK (first_name ~ '^[[:alpha:]][\u0300-\u034E\u0350-\u036F]{0,2}([[:alpha:] ''-][\u0300-\u034E\u0350-\u036F]{0,2}){0,29}$'),
  bio                       text CHECK (length(bio) BETWEEN 1 AND 300),
  intent                    text NOT NULL DEFAULT 'open'
                            CHECK (intent IN ('love', 'friendship', 'hangout', 'open')),
  gender                    text CHECK (gender IN ('woman', 'man')),
  show_gender               boolean NOT NULL DEFAULT false,
  interests                 text[] NOT NULL DEFAULT '{}' CHECK (cardinality(interests) <= 8),
  -- A ~4.9 km cell, its centroid and the nearest service-area city. Never the raw point (§8.6).
  area_geohash              text CHECK (area_geohash ~ '^[0-9b-hjkmnp-z]{5}$'),
  area_point                extensions.geography(Point, 4326),
  area_city_code            text,
  area_set_at               timestamptz,
  status                    text NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft', 'pending_review', 'active', 'removed')),
  text_moderation           text NOT NULL DEFAULT 'clean' CHECK (text_moderation IN ('clean', 'held')),
  discoverable              boolean NOT NULL DEFAULT false,
  paused_at                 timestamptz,
  hold_reason               text CHECK (hold_reason IN ('child_safety_report', 'underage_report',
                                                        'moderation')),
  hold_at                   timestamptz,
  hide_from_errand_contacts boolean NOT NULL DEFAULT true,
  read_receipts             boolean NOT NULL DEFAULT true,
  photo_verified_at         timestamptz,
  newcomer_until            timestamptz,
  last_active_on            date,
  version                   integer NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT meet_profiles_area_city FOREIGN KEY (country_code, area_city_code)
    REFERENCES public.cities (country_code, code),
  CONSTRAINT meet_profiles_area_whole
    CHECK ((area_geohash IS NULL) = (area_point IS NULL) AND (area_geohash IS NULL) = (area_set_at IS NULL)),
  CONSTRAINT meet_profiles_hold_whole CHECK ((hold_reason IS NULL) = (hold_at IS NULL))
);
CREATE INDEX meet_profiles_pool ON public.meet_profiles (country_code, area_geohash)
  WHERE status = 'active' AND discoverable AND paused_at IS NULL AND hold_reason IS NULL;
CREATE INDEX meet_profiles_pool_area ON public.meet_profiles USING gist (area_point)
  WHERE status = 'active' AND discoverable AND paused_at IS NULL AND hold_reason IS NULL;
CREATE INDEX meet_profiles_activity ON public.meet_profiles (country_code, last_active_on DESC);

-- Read only by the owner's own functions. Never in an admin function, an analytics view, a staff
-- export or anybody else's export (D5, §8.7).
CREATE TABLE public.meet_discovery_prefs (
  user_id     uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  seeking     text NOT NULL DEFAULT 'everyone' CHECK (seeking IN ('women', 'men', 'everyone')),
  age_min     smallint NOT NULL DEFAULT 18 CHECK (age_min BETWEEN 18 AND 99),
  age_max     smallint NOT NULL DEFAULT 60,
  max_band_km smallint NOT NULL DEFAULT 50 CHECK (max_band_km IN (5, 10, 25, 50, 100)),
  intents     text[] NOT NULL DEFAULT '{}'
              CHECK (intents <@ ARRAY['love', 'friendship', 'hangout', 'open']),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT meet_discovery_prefs_age_range CHECK (age_max BETWEEN age_min AND 99)
);

-- `failure_reason` is not in the design's column list: it is what the media worker could not do
-- with a file (wrong type, too small, unreadable), so the app can ask for another photo with a
-- reason rather than a shrug. `reason_code` stays a person's review decision.
CREATE TABLE public.meet_photos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id       uuid NOT NULL REFERENCES public.meet_profiles (id) ON DELETE CASCADE,
  position         smallint NOT NULL CHECK (position BETWEEN 0 AND 5),
  -- The uploader's own inbox folder. Read by the worker alone and cleared once it is done.
  inbox_path       text CHECK (inbox_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'),
  thumb_inbox_path text CHECK (thumb_inbox_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'),
  -- What other people's apps fetch: the profile's folder and this photo's id, nothing else.
  media_path       text,
  thumb_path       text,
  sha256           bytea CHECK (length(sha256) = 32),
  width            integer CHECK (width BETWEEN 1 AND 4096),
  height           integer CHECK (height BETWEEN 1 AND 4096),
  mime             text CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  status           text NOT NULL DEFAULT 'processing'
                   CHECK (status IN ('processing', 'pending_review', 'approved', 'rejected',
                                     'removed', 'failed')),
  reason_code      text CHECK (reason_code IN ('not_a_person', 'not_you', 'explicit',
                                               'underage_appearance', 'contact_details',
                                               'violence', 'low_quality', 'reused', 'other')),
  failure_reason   text CHECK (failure_reason IN ('not_found', 'bad_type', 'corrupt', 'animated',
                                                  'too_large', 'bad_dimensions')),
  reviewed_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reviewed_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT meet_photos_media_path_own
    CHECK (media_path IS NULL
           OR media_path ~ ('^' || profile_id::text || '/p/' || id::text || '\.(jpg|png|webp)$')),
  CONSTRAINT meet_photos_thumb_path_own
    CHECK (thumb_path IS NULL
           OR thumb_path ~ ('^' || profile_id::text || '/pt/' || id::text || '\.(jpg|png|webp)$')),
  CONSTRAINT meet_photos_ready_whole
    CHECK (status IN ('processing', 'failed', 'removed')
           OR (media_path IS NOT NULL AND thumb_path IS NOT NULL AND sha256 IS NOT NULL)),
  -- The design's UNIQUE (profile_id, position) over live photos, written as a deferrable
  -- exclusion constraint: a partial unique index cannot be deferred, and a deferrable constraint
  -- is checked at the end of the statement, which is what lets one UPDATE reorder the photos.
  CONSTRAINT meet_photos_position_once
    EXCLUDE USING btree (profile_id WITH =, position WITH =)
    WHERE (status IN ('processing', 'pending_review', 'approved'))
    DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX meet_photos_sha256 ON public.meet_photos (sha256) WHERE sha256 IS NOT NULL;
-- `meet_submit_photo` (an upload is submitted once) and the inbox sweep look photos up by these.
CREATE INDEX meet_photos_inbox_path ON public.meet_photos (inbox_path) WHERE inbox_path IS NOT NULL;
CREATE INDEX meet_photos_thumb_inbox_path ON public.meet_photos (thumb_inbox_path)
  WHERE thumb_inbox_path IS NOT NULL;

CREATE TABLE public.meet_prompts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id uuid NOT NULL REFERENCES public.meet_profiles (id) ON DELETE CASCADE,
  prompt_key text NOT NULL REFERENCES public.meet_prompt_keys (key),
  answer     text NOT NULL CHECK (length(answer) BETWEEN 1 AND 150),
  position   smallint NOT NULL CHECK (position BETWEEN 0 AND 2),
  moderation text NOT NULL DEFAULT 'clean' CHECK (moderation IN ('clean', 'held', 'removed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (profile_id, position)
);

-- Functions are the only door (§2.2): no client role holds any privilege on any of these.
ALTER TABLE public.meet_interest_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_interest_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_prompt_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_prompt_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_eligibility ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_eligibility FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_age_refusal_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_age_refusal_devices FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_discovery_prefs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_discovery_prefs FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_photos FORCE ROW LEVEL SECURITY;
ALTER TABLE public.meet_prompts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meet_prompts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.meet_interest_keys, public.meet_prompt_keys, public.meet_eligibility,
  public.meet_age_refusal_devices, public.meet_profiles, public.meet_discovery_prefs,
  public.meet_photos, public.meet_prompts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER meet_eligibility_touch BEFORE UPDATE ON public.meet_eligibility
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();
CREATE TRIGGER meet_profiles_touch BEFORE UPDATE ON public.meet_profiles
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();
CREATE TRIGGER meet_discovery_prefs_touch BEFORE UPDATE ON public.meet_discovery_prefs
  FOR EACH ROW EXECUTE FUNCTION private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Small pure helpers.
-- ---------------------------------------------------------------------------

-- Whole years from a birth date to a day, compared as (month, day). On 28 February of a year
-- without one, somebody born on 29 February has not had their birthday yet; on 1 March they have.
CREATE FUNCTION private.meet_age_on(p_birth date, p_on date)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT (extract(year FROM p_on) - extract(year FROM p_birth))::integer
       - CASE WHEN (extract(month FROM p_on), extract(day FROM p_on))
                   < (extract(month FROM p_birth), extract(day FROM p_birth))
              THEN 1 ELSE 0 END;
$$;

-- Today where the person is (`user_timezone`: their own zone, else their country's, else UTC).
CREATE FUNCTION private.meet_local_today(p_user uuid)
RETURNS date
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT (now() AT TIME ZONE private.user_timezone(p_user))::date;
$$;

-- `meet.min_age` can raise the bar and never lower it below 18 (§3.3).
CREATE FUNCTION private.meet_min_age()
RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT greatest(18, coalesce(private.remote_config_int('meet.min_age'), 18));
$$;

CREATE FUNCTION private.meet_guidelines_version()
RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT greatest(1, coalesce(private.remote_config_int('meet.guidelines_version'), 1));
$$;

-- A whole number of days from `meet.retention`, or the default when the key is missing.
CREATE FUNCTION private.meet_retention_days(p_key text, p_default integer)
RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT greatest(1, coalesce((private.remote_config_json('meet.retention') ->> p_key)::integer,
                              p_default));
$$;

-- The country's published Meet guidelines page at a version, preferring the person's language.
CREATE FUNCTION private.meet_guidelines_document(p_user uuid, p_country char(2), p_version integer)
RETURNS public.legal_documents
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT d.* FROM public.legal_documents d
  WHERE d.country_code = p_country AND d.type = 'meet_guidelines' AND d.version = p_version
    AND d.published_at <= now()
  ORDER BY d.locale = (SELECT p.language FROM public.profiles p WHERE p.user_id = p_user) DESC,
           d.locale = 'en' DESC, d.locale
  LIMIT 1;
$$;

-- A device this account uses was barred by an under-18 refusal that has not expired: one of the
-- phones the refusal came from, or one the refused account registered afterwards, while the
-- refusal is younger than the bar (`meet_check_in` can only bar the phones it sees). M1-PR4
-- restates this whole to add `meet_banned_devices`.
CREATE FUNCTION private.meet_device_refused(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_devices d
    JOIN public.meet_age_refusal_devices r ON r.device_fingerprint_hash = d.device_fingerprint_hash
    WHERE d.user_id = p_user AND r.expires_at > now())
  OR EXISTS (
    SELECT 1 FROM public.user_devices d
    JOIN public.user_devices other ON other.device_fingerprint_hash = d.device_fingerprint_hash
                                  AND other.user_id <> d.user_id
    JOIN public.meet_eligibility e ON e.user_id = other.user_id AND e.status = 'refused_minor'
    WHERE d.user_id = p_user
      AND e.updated_at > now() - make_interval(
            days => private.meet_retention_days('age_refusal_device_days', 365)));
$$;

-- L3 (§8.1): a device of this account failed Play Integrity or App Attest while
-- `meet.require_device_integrity` is on. `unevaluated` (no credentials) is not a failure.
CREATE FUNCTION private.meet_integrity_failed(p_user uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce((private.remote_config_json('meet.require_device_integrity') #>> '{}')::boolean,
                  true)
     AND EXISTS (SELECT 1 FROM public.user_devices d
                 WHERE d.user_id = p_user AND d.integrity_verdict ->> 'status' = 'fail');
$$;

-- Where M1-PR4 writes a `meet_safety_events` row (kind, surface and rule keys, never content).
-- That table is PR4's; until it exists this checks its arguments and records nothing, so the
-- callers here do not have to be restated when it lands.
CREATE FUNCTION private.meet_note_safety_event(
  p_user uuid, p_kind text, p_surface text, p_rule_keys text[])
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF p_user IS NULL OR p_surface IS NULL OR p_rule_keys IS NULL
     OR p_kind IS NULL OR p_kind NOT IN ('contact_blocked', 'solicitation_blocked',
                                         'platform_mention', 'rate_limited', 'age_refused',
                                         'device_refused', 'restricted') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
END $$;

-- What `meet_get_state` says about restrictions and a suspension. Neither table exists until
-- M1-PR4, which restates this whole; until then nobody has either.
CREATE FUNCTION private.meet_state_safety(p_user uuid)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object('restrictions', '[]'::jsonb, 'suspension', NULL::jsonb)
  WHERE p_user IS NOT NULL;
$$;

-- `meet_get_state.unread`. M1-PR5 (likes, matches) and M1-PR6 (chats) restate this whole.
CREATE FUNCTION private.meet_state_unread(p_profile_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object('chats', 0, 'likes', 0, 'matches', 0, 'requests', 0)
  WHERE p_profile_id IS NOT NULL;
$$;

-- A consent the Meet functions record for the person; `record_consent` refuses both Meet kinds
-- (20261126120000), so this is the only way either is written.
CREATE FUNCTION private.meet_record_consent(
  p_user uuid, p_kind public.consent_kind, p_legal_document_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.consents (user_id, kind, granted, legal_document_id, country_code)
  VALUES (p_user, p_kind, true, p_legal_document_id,
          (SELECT p.country_code FROM public.profiles p WHERE p.user_id = p_user))
  RETURNING id INTO v_id;
  PERFORM private.emit_event('consent', p_user::text, 'consent.granted',
    jsonb_build_object('kind', p_kind, 'consent_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- The access check (§2.3), restated whole from 20261126120100 with the checks that could not be
-- answered there: eligibility and a barred device, the guidelines version and the active
-- profile. M1-PR4 restates it again to add the suspension. `meet_access_refusal` answers the
-- question without raising or writing, so a storage policy can ask it too.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.meet_access_refusal(p_user uuid, p_feature text, p_need_profile boolean)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
  v_status  text;
  v_version integer;
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = p_user;
  IF NOT private.meet_flag_on(p_feature, p_user, v_country) THEN
    RETURN 'ERR_FEATURE_UNAVAILABLE';
  END IF;
  IF v_country IS NULL THEN
    RETURN 'ERR_COUNTRY_NOT_SET';
  END IF;
  SELECT e.status, e.guidelines_version INTO v_status, v_version
  FROM public.meet_eligibility e WHERE e.user_id = p_user;
  IF private.meet_device_refused(p_user) OR v_status IN ('refused_minor', 'revoked') THEN
    RETURN 'ERR_MEET_UNAVAILABLE';
  END IF;
  IF v_status IS NULL THEN
    RETURN 'ERR_MEET_ELIGIBILITY_REQUIRED';
  END IF;
  IF v_version < private.meet_guidelines_version() THEN
    RETURN 'ERR_MEET_GUIDELINES_OUTDATED';
  END IF;
  IF p_need_profile AND NOT EXISTS (SELECT 1 FROM public.meet_profiles mp
                                    WHERE mp.user_id = p_user AND mp.status = 'active') THEN
    RETURN 'ERR_MEET_PROFILE_INCOMPLETE';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION private.meet_require_access(
  p_user uuid, p_feature text, p_need_profile boolean)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_refusal text;
  v_today   date;
BEGIN
  IF p_user IS NULL OR p_feature IS NULL OR p_need_profile IS NULL
     OR p_feature !~ '^meet\.[a-z0-9_.]+$' THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_refusal := private.meet_access_refusal(p_user, p_feature, p_need_profile);
  IF v_refusal IS NOT NULL THEN
    RAISE EXCEPTION '%', v_refusal USING ERRCODE = 'P0001';
  END IF;
  -- Day granularity only ("Active today"); written once a day, never per call.
  v_today := private.meet_local_today(p_user);
  UPDATE public.meet_profiles mp SET last_active_on = v_today
  WHERE mp.user_id = p_user AND mp.last_active_on IS DISTINCT FROM v_today;
END $$;

-- The check for the verbs that only take somebody out of view: pause, hide, the privacy switches,
-- removing a photo or a prompt, deleting the profile. Somebody shut out by a barred phone, a
-- revocation or outdated guidelines must still be able to leave; the flag and the country still
-- apply, and nothing here counts as being active.
CREATE FUNCTION private.meet_require_exit(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_refusal text;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_refusal := private.meet_access_refusal(p_user, 'meet.v5', false);
  IF v_refusal NOT IN ('ERR_MEET_UNAVAILABLE', 'ERR_MEET_GUIDELINES_OUTDATED') THEN
    RAISE EXCEPTION '%', v_refusal USING ERRCODE = 'P0001';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Text screening (§8.2). The interim screen, replaced whole by M1-PR4; the signature is final.
-- It blocks what is unambiguous on every surface: a run of seven or more digits (a phone or
-- account number; times, ages and prices stay shorter), an email address, a link, and the terms
-- §8.2 blocks everywhere, with the category `contact_filter_cases.json` assigns each. No hold
-- comes from here yet, and nothing reads the conversation or the sender until the digit tail.
-- Every Unicode default-ignorable code point is removed first (soft hyphen, the joiners, the
-- direction marks and isolates, the invisible operators, the fillers, the variation selectors
-- and the tag characters), because each renders as nothing and would otherwise split a number or
-- an address that reads whole. Inside a run, anything that is not a letter or a digit is a
-- separator; a look-alike letter from another script counts as one too, which fails closed.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.meet_screen_text(
  p_text text, p_country char(2), p_surface text, p_conversation_id uuid DEFAULT NULL,
  p_sender uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_text     text;
  v_keys     text[] := ARRAY[]::text[];
  v_category text;
  v_rule     record;
BEGIN
  IF p_surface IS NULL OR p_surface NOT IN ('message', 'bio', 'first_name', 'prompt', 'status',
                                            'game_answer', 'reach_note')
     OR (p_conversation_id IS NOT NULL AND p_sender IS NULL)
     OR (p_country IS NOT NULL AND p_country !~ '^[A-Z]{2}$') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_text := lower(normalize(coalesce(p_text, ''), NFKC));
  v_text := regexp_replace(v_text,
    '[\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F\u200B-\u200F\u202A-\u202E\u2060-\u206F\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF0-\uFFF8\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A\U000E0000-\U000E0FFF]',
    '', 'g');

  IF v_text ~ '[0-9]([^a-z0-9]*[0-9]){6,}' THEN
    v_keys := array_append(v_keys, 'interim_digit_run');
  END IF;
  IF v_text ~ '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+' THEN
    v_keys := array_append(v_keys, 'interim_email');
  END IF;
  IF v_text ~ '(https?://|www\.|\m(wa|t)\.me/|\m[a-z0-9-]+\.(com|net|org|ng|me|io|co|app|ly|link|ee|gg|tv)\M)' THEN
    v_keys := array_append(v_keys, 'interim_link');
  END IF;
  IF cardinality(v_keys) > 0 THEN
    RETURN jsonb_build_object('action', 'block', 'category', 'contact', 'rule_keys', to_jsonb(v_keys));
  END IF;

  FOR v_rule IN
    SELECT r.term, r.category
    FROM (VALUES
      ('sugar daddy', 'solicitation'), ('sugar mummy', 'solicitation'),
      ('sugar mommy', 'solicitation'), ('sugar baby', 'solicitation'), ('pay me', 'solicitation'),
      ('send me money', 'solicitation'), ('send money first', 'solicitation'),
      ('transport fare', 'solicitation'), ('tf first', 'solicitation'),
      ('allowance', 'solicitation'), ('send gift first', 'solicitation'),
      ('gift card', 'scam'), ('itunes card', 'scam'), ('steam card', 'scam'),
      ('bank details', 'scam'), ('account number', 'scam'),
      ('sex for money', 'sexual'), ('escort', 'sexual'), ('price list', 'sexual')) r (term, category)
    WHERE v_text ~ ('(^|[^a-z0-9])' || r.term || '([^a-z0-9]|$)')
  LOOP
    v_category := coalesce(v_category, v_rule.category);
    v_keys := array_append(v_keys, 'interim_' || replace(v_rule.term, ' ', '_'));
  END LOOP;
  IF v_category IS NOT NULL THEN
    RETURN jsonb_build_object('action', 'block', 'category', v_category, 'rule_keys', to_jsonb(v_keys));
  END IF;
  RETURN jsonb_build_object('action', 'allow', 'category', NULL, 'rule_keys', '[]'::jsonb);
END $$;

-- A profile surface (first name, bio, prompt) through both screens (§8.2 "Outcome by surface").
-- A block raises and nothing is written; no strike is recorded for a profile field, because the
-- person sees the refusal and edits. Returns 'held' when either screen holds, else 'clean'.
CREATE FUNCTION private.meet_screen_field(p_text text, p_country char(2), p_surface text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_screen jsonb;
  v_moderation jsonb;
BEGIN
  IF p_text IS NULL THEN
    RETURN 'clean';
  END IF;
  v_screen := private.meet_screen_text(p_text, p_country, p_surface);
  IF v_screen ->> 'action' = 'block' THEN
    IF v_screen ->> 'category' = 'contact' THEN
      RAISE EXCEPTION 'ERR_MEET_CONTACT_NOT_ALLOWED' USING ERRCODE = 'P0001',
        DETAIL = p_surface;
    ELSIF v_screen ->> 'category' IN ('solicitation', 'scam', 'sexual') THEN
      RAISE EXCEPTION 'ERR_MEET_SOLICITATION_NOT_ALLOWED' USING ERRCODE = 'P0001',
        DETAIL = p_surface;
    END IF;
    RAISE EXCEPTION 'ERR_CONTENT_NOT_ALLOWED' USING ERRCODE = 'P0001', DETAIL = p_surface;
  END IF;
  -- Blocked text never reaches the errands screen; what passed goes through it (§8.2).
  v_moderation := private.moderate_text(p_text, p_country);
  IF v_moderation ->> 'action' = 'block' THEN
    RAISE EXCEPTION 'ERR_CONTENT_NOT_ALLOWED' USING ERRCODE = 'P0001',
      DETAIL = coalesce(v_moderation -> 'labels' -> 0 ->> 'rule_key', 'restricted');
  END IF;
  RETURN CASE WHEN v_screen ->> 'action' = 'hold' OR v_moderation ->> 'action' = 'hold'
              THEN 'held' ELSE 'clean' END;
END $$;

-- First name and bio are screened on every write path, not only by `meet_save_profile`. Only the
-- fields that changed are screened, so a moderator's decision on a field nobody touched is not
-- undone by an unrelated edit; a held profile whose changed fields are clean is re-screened in
-- full and cleared only if nothing holds any more.
CREATE FUNCTION private.meet_profiles_screen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_first boolean := TG_OP = 'INSERT' OR NEW.first_name IS DISTINCT FROM OLD.first_name;
  v_bio   boolean := TG_OP = 'INSERT' OR NEW.bio IS DISTINCT FROM OLD.bio;
  v_held  boolean := false;
BEGIN
  IF v_first AND private.meet_screen_field(NEW.first_name, NEW.country_code, 'first_name') = 'held' THEN
    v_held := true;
  END IF;
  IF v_bio AND private.meet_screen_field(NEW.bio, NEW.country_code, 'bio') = 'held' THEN
    v_held := true;
  END IF;
  IF v_held THEN
    NEW.text_moderation := 'held';
  ELSIF TG_OP = 'UPDATE' AND OLD.text_moderation = 'held' AND (v_first OR v_bio) THEN
    IF NOT v_first AND private.meet_screen_field(NEW.first_name, NEW.country_code, 'first_name') = 'held' THEN
      RETURN NEW;
    END IF;
    IF NOT v_bio AND private.meet_screen_field(NEW.bio, NEW.country_code, 'bio') = 'held' THEN
      RETURN NEW;
    END IF;
    NEW.text_moderation := 'clean';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER meet_profiles_screen
  BEFORE INSERT OR UPDATE OF first_name, bio ON public.meet_profiles
  FOR EACH ROW EXECUTE FUNCTION private.meet_profiles_screen();

-- Prompt answers the same way, on every write path. An answer that did not change keeps the
-- moderation it has, so re-saving the same words does not undo a moderator's decision on them.
CREATE FUNCTION private.meet_prompts_screen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.answer IS NOT DISTINCT FROM OLD.answer THEN
    NEW.moderation := OLD.moderation;
    RETURN NEW;
  END IF;
  NEW.moderation := private.meet_screen_field(NEW.answer,
    (SELECT mp.country_code FROM public.meet_profiles mp WHERE mp.id = NEW.profile_id), 'prompt');
  RETURN NEW;
END $$;

CREATE TRIGGER meet_prompts_screen
  BEFORE INSERT OR UPDATE OF answer ON public.meet_prompts
  FOR EACH ROW EXECUTE FUNCTION private.meet_prompts_screen();

-- Every interest is a key that exists and is active when it is added. A key retired later stays
-- on the profiles that already carry it.
CREATE FUNCTION private.meet_profiles_check_interests()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF cardinality(NEW.interests) <> (SELECT count(DISTINCT k) FROM unnest(NEW.interests) k)
     OR EXISTS (
       SELECT 1 FROM unnest(NEW.interests) i (k)
       WHERE NOT (TG_OP = 'UPDATE' AND i.k = ANY (OLD.interests))
         AND NOT EXISTS (SELECT 1 FROM public.meet_interest_keys mk
                         WHERE mk.key = i.k AND mk.active)) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'interests';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER meet_profiles_check_interests
  BEFORE INSERT OR UPDATE OF interests ON public.meet_profiles
  FOR EACH ROW EXECUTE FUNCTION private.meet_profiles_check_interests();

-- ---------------------------------------------------------------------------
-- Profile state. `active` means a clean first name and bio, at least one approved photo and an
-- area: what discovery and turning discovery on need (§4.2). `pending_review` is a profile with
-- photos that is not active yet (waiting for a person, or for its area). A profile that stops
-- being active stops being discoverable, which is the design's "removing the last approved photo
-- makes the profile undiscoverable", and its first activation starts the 24-hour newcomer
-- spotlight. M1-PR4's photo and text decisions call this after each decision.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.meet_refresh_profile(p_profile_id uuid)
RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_profile  public.meet_profiles%ROWTYPE;
  v_approved integer;
  v_any      integer;
  v_status   text;
BEGIN
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.id = p_profile_id FOR UPDATE;
  IF NOT FOUND OR v_profile.status = 'removed' THEN
    RETURN v_profile.status;
  END IF;
  SELECT (count(*) FILTER (WHERE ph.status = 'approved'))::integer,
         (count(*) FILTER (WHERE ph.status IN ('processing', 'pending_review', 'approved')))::integer
  INTO v_approved, v_any
  FROM public.meet_photos ph WHERE ph.profile_id = p_profile_id;
  v_status := CASE
    WHEN v_profile.text_moderation = 'clean' AND v_approved > 0
         AND v_profile.area_geohash IS NOT NULL THEN 'active'
    WHEN v_any > 0 THEN 'pending_review'
    ELSE 'draft' END;
  IF v_status IS DISTINCT FROM v_profile.status
     OR (v_profile.discoverable AND v_status <> 'active')
     OR (v_status = 'active' AND v_profile.newcomer_until IS NULL) THEN
    UPDATE public.meet_profiles mp
    SET status = v_status,
        discoverable = mp.discoverable AND v_status = 'active',
        newcomer_until = CASE WHEN v_status = 'active'
                              THEN coalesce(mp.newcomer_until, now() + interval '24 hours')
                              ELSE mp.newcomer_until END
    WHERE mp.id = p_profile_id;
  END IF;
  RETURN v_status;
END $$;

-- The steps still open, for the completeness meter (§6.3 MePage). `photo` means no approved
-- photo yet; the rest are optional but count.
CREATE FUNCTION private.meet_profile_completeness(p_profile_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(jsonb_agg(step ORDER BY n), '[]'::jsonb)
  FROM public.meet_profiles mp,
       LATERAL (VALUES
         (1, 'photo', NOT EXISTS (SELECT 1 FROM public.meet_photos ph
                                  WHERE ph.profile_id = mp.id AND ph.status = 'approved')),
         (2, 'area', mp.area_geohash IS NULL),
         (3, 'bio', mp.bio IS NULL),
         (4, 'interests', cardinality(mp.interests) = 0),
         (5, 'prompt', NOT EXISTS (SELECT 1 FROM public.meet_prompts pr
                                   WHERE pr.profile_id = mp.id AND pr.moderation <> 'removed')))
         s (n, step, missing)
  WHERE mp.id = p_profile_id AND s.missing;
$$;

-- The owner's own view of their profile: everything they set, and the state the app routes on.
-- Never shown to anybody else; the card others see is M1-PR5's.
CREATE FUNCTION private.meet_own_profile_json(p_profile_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', mp.id,
    'first_name', mp.first_name,
    'bio', mp.bio,
    'intent', mp.intent,
    'gender', mp.gender,
    'show_gender', mp.show_gender,
    'interests', to_jsonb(mp.interests),
    'area', CASE WHEN mp.area_geohash IS NULL THEN NULL
                 ELSE jsonb_build_object('label', c.name, 'city_code', mp.area_city_code,
                                         'set_at', mp.area_set_at) END,
    'status', mp.status,
    'discoverable', mp.discoverable,
    'paused', mp.paused_at IS NOT NULL,
    'verified', mp.photo_verified_at IS NOT NULL,
    'held', mp.hold_reason IS NOT NULL OR mp.text_moderation = 'held',
    'text_moderation', mp.text_moderation,
    'completeness', private.meet_profile_completeness(mp.id),
    'version', mp.version)
  FROM public.meet_profiles mp
  LEFT JOIN public.cities c ON c.country_code = mp.country_code AND c.code = mp.area_city_code
  WHERE mp.id = p_profile_id;
$$;

-- ---------------------------------------------------------------------------
-- Visibility (§2.2). Profile ids in, never auth uids.
-- ---------------------------------------------------------------------------

-- Two people who have done an errand together, either way round.
CREATE FUNCTION private.meet_errand_contacts(p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.requests r JOIN public.jobs j ON j.request_id = r.id
                 WHERE r.customer_id = p_a AND (j.provider_id = p_b OR j.worker_id = p_b))
      OR EXISTS (SELECT 1 FROM public.requests r JOIN public.jobs j ON j.request_id = r.id
                 WHERE r.customer_id = p_b AND (j.provider_id = p_a OR j.worker_id = p_a));
$$;

-- The discovery predicate. The target is eligible, active, discoverable, not paused and not on
-- hold; both are in one country and neither has blocked the other; the cells are within the
-- viewer's distance; each is within the other's age range; the viewer's "show me" is applied one
-- way (it narrows what they see and never who sees them); and two people who have done an errand
-- together see each other only if both have switched "hide me from errand contacts" off.
-- Both must also pass the access check as it stands now: somebody Meet refuses (a barred phone,
-- outdated guidelines, out of the rollout, a revocation) is shown to nobody and sees nobody, so
-- visibility never outlasts access. M1-PR4 adds the suspension to `meet_access_refusal`, which
-- this then follows; M1-PR5 builds the set-based discovery on the same rules.
CREATE FUNCTION private.meet_discoverable_to(p_viewer uuid, p_target uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.meet_profiles v
    JOIN public.meet_profiles t ON t.id = p_target AND t.id <> v.id
    JOIN public.meet_eligibility ve ON ve.user_id = v.user_id AND ve.status = 'eligible'
    JOIN public.meet_eligibility te ON te.user_id = t.user_id AND te.status = 'eligible'
    LEFT JOIN public.meet_discovery_prefs vp ON vp.user_id = v.user_id
    LEFT JOIN public.meet_discovery_prefs tp ON tp.user_id = t.user_id
    WHERE v.id = p_viewer
      AND v.status = 'active'
      AND t.status = 'active' AND t.discoverable AND t.paused_at IS NULL AND t.hold_reason IS NULL
      AND t.country_code = v.country_code
      AND NOT private.is_blocked_pair(v.user_id, t.user_id)
      AND extensions.ST_DWithin(v.area_point, t.area_point,
                                coalesce(vp.max_band_km, 50) * 1000.0)
      AND private.meet_age_on(te.birth_date, current_date)
            BETWEEN coalesce(vp.age_min, 18) AND coalesce(vp.age_max, 60)
      AND private.meet_age_on(ve.birth_date, current_date)
            BETWEEN coalesce(tp.age_min, 18) AND coalesce(tp.age_max, 60)
      AND (coalesce(vp.seeking, 'everyone') = 'everyone'
           OR (vp.seeking = 'women' AND t.gender = 'woman')
           OR (vp.seeking = 'men' AND t.gender = 'man'))
      AND ((NOT v.hide_from_errand_contacts AND NOT t.hide_from_errand_contacts)
           OR NOT private.meet_errand_contacts(v.user_id, t.user_id))
      AND private.meet_access_refusal(v.user_id, 'meet.v5', false) IS NULL
      AND private.meet_access_refusal(t.user_id, 'meet.v5', false) IS NULL);
$$;

-- Whether a viewer may see a profile's approved content. M1-PR5 restates this whole: connected
-- (a pending or active match, an open conversation) or in the viewer's daily set, nearby list or
-- revealed likers for today, with blocks and holds re-checked at read time.
CREATE FUNCTION private.meet_may_view(p_viewer uuid, p_target uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT private.meet_discoverable_to(p_viewer, p_target);
$$;

-- The `meet-media` read policy (§2.7). Index lookups only. Admits the owner (pending and rejected
-- photos too, so they can see what is waiting and why), a moderator or super admin in the
-- profile's country (signed URLs of at most 300 s in the console), and anybody else only for an
-- approved photo of a profile `meet_may_view` lets them see, while Meet would let them in.
-- Statuses (`s/`) arrive with M1-PR7 and report copies (`e/`) with M1-PR4; until then neither is
-- readable. The viewer must be the caller: the policy never asks on somebody else's behalf.
--
-- Only staff may sign a URL. Storage's sign endpoints need nothing but this SELECT, take an expiry
-- the caller chooses, and the URL they return works without a session, so a viewer could mint a
-- link that outlives a block (§8.5: "no shareable URLs"). Storage names the operation it is
-- running in the `storage.operation` setting [S: supabase/storage `0024-operation-function.sql`
-- and `src/http/routes/operations.ts`: `storage.object.sign`, `storage.object.sign_many`],
-- checked against the real Storage API by `supabase/tests/e2e/meet_storage_e2e.sh`. Unset, as
-- in a plain SQL session, nothing is refused on that ground. The console's 300 s limit on its own
-- signed URLs is the console's, not the database's.
CREATE FUNCTION private.meet_media_visible_to(p_name text, p_viewer uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_parts   text[];
  v_profile public.meet_profiles%ROWTYPE;
  v_status  text;
  v_viewer  public.meet_profiles%ROWTYPE;
  v_signing boolean := coalesce(current_setting('storage.operation', true), '')
                         IN ('storage.object.sign', 'storage.object.sign_many', 'object.sign',
                             'object.sign_many');
BEGIN
  IF p_viewer IS NULL OR p_viewer IS DISTINCT FROM auth.uid()
     OR p_name IS NULL OR p_name !~ '^[0-9a-f-]{36}/(p|pt)/[0-9a-f-]{36}\.(jpg|png|webp)$' THEN
    RETURN false;
  END IF;
  v_parts := string_to_array(p_name, '/');
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.id = private.try_uuid(v_parts[1]);
  IF NOT FOUND OR v_profile.status = 'removed' THEN
    RETURN false;
  END IF;
  SELECT ph.status INTO v_status FROM public.meet_photos ph
  WHERE ph.id = private.try_uuid(split_part(v_parts[3], '.', 1))
    AND ph.profile_id = v_profile.id
    AND (ph.media_path = p_name OR ph.thumb_path = p_name);
  IF v_status IS NULL THEN
    RETURN false;
  END IF;
  IF private.admin_may_read_country(v_profile.country_code,
                                    ARRAY['meet_moderator']::public.admin_role[]) THEN
    RETURN v_status IN ('pending_review', 'approved', 'rejected');
  END IF;
  IF v_signing THEN
    RETURN false;
  END IF;
  IF v_profile.user_id = p_viewer THEN
    RETURN v_status IN ('pending_review', 'approved', 'rejected');
  END IF;
  IF v_status <> 'approved' THEN
    RETURN false;
  END IF;
  SELECT * INTO v_viewer FROM public.meet_profiles mp WHERE mp.user_id = p_viewer;
  RETURN FOUND
     AND private.meet_access_refusal(p_viewer, 'meet.v5', false) IS NULL
     AND private.meet_may_view(v_viewer.id, v_profile.id);
END $$;

-- The upload policies for `meet-inbox` and `meet-verify`: the caller's own folder, a file named
-- by a uuid in a type the bucket stores, and the caller passes the Meet access check (eligible,
-- current guidelines, no barred device). Uploading a selfie also needs `meet.photo_verification`.
-- The inbox holds at most two files (photo and thumbnail) per allowed photo, plus one pair, per
-- person at a time: the worker empties it within a minute, so only a script reaches the cap, and
-- on the Free plan's 1 GB an uncapped 8 MB bucket is one script from full. What is abandoned there
-- the daily sweep removes (`private.meet_sweep_inbox`).
CREATE FUNCTION private.meet_upload_allowed(p_bucket text, p_name text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR p_name IS NULL THEN
    RETURN false;
  END IF;
  IF p_bucket = 'meet-inbox'
     AND p_name ~ ('^' || v_uid::text || '/[0-9a-f-]{36}\.(jpg|png|webp)$') THEN
    RETURN private.meet_access_refusal(v_uid, 'meet.v5', false) IS NULL
       AND (SELECT count(*) FROM storage.objects o
            WHERE o.bucket_id = 'meet-inbox' AND o.name LIKE v_uid::text || '/%')
           < 2 * (least(greatest(coalesce(private.remote_config_int('meet.photos.max'), 6), 1), 6) + 1);
  END IF;
  IF p_bucket = 'meet-verify' AND p_name ~ ('^' || v_uid::text || '/[0-9a-f-]{36}\.jpg$') THEN
    RETURN private.meet_access_refusal(v_uid, 'meet.photo_verification', false) IS NULL;
  END IF;
  RETURN false;
END $$;

-- ---------------------------------------------------------------------------
-- Buckets (§2.7). All private.
--   meet-inbox/<uid>/<uuid>.<ext>                  uploads waiting for the worker; nobody reads
--   meet-media/<profile_id>/(p|pt|s)/<id>.<ext>    what apps fetch through the authenticated
--                                                  object endpoint, per request, under the policy
--   meet-verify/<uid>/<verification_id>.jpg        verification selfies, write-only for clients
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('meet-inbox', 'meet-inbox', false),
       ('meet-media', 'meet-media', false),
       ('meet-verify', 'meet-verify', false)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'file_size_limit') THEN
    UPDATE storage.buckets SET file_size_limit = 8 * 1024 * 1024 WHERE id = 'meet-inbox';
    UPDATE storage.buckets SET file_size_limit = 5 * 1024 * 1024 WHERE id = 'meet-media';
    UPDATE storage.buckets SET file_size_limit = 5 * 1024 * 1024 WHERE id = 'meet-verify';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'allowed_mime_types') THEN
    -- One statement per bucket: `contracts/tools/generate_v1.py` reads `WHERE id = '<bucket>'`.
    UPDATE storage.buckets SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
    WHERE id = 'meet-inbox';
    UPDATE storage.buckets SET allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
    WHERE id = 'meet-media';
    UPDATE storage.buckets SET allowed_mime_types = ARRAY['image/jpeg'] WHERE id = 'meet-verify';
  END IF;
END $$;

-- No client SELECT, UPDATE or DELETE on the inbox or the selfies, the owner included: only the
-- worker (service role) reads either, so a uid in those paths leaks nothing.
CREATE POLICY meet_inbox_own_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'meet-inbox'
              AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text
              AND (SELECT private.meet_upload_allowed('meet-inbox', name)));

CREATE POLICY meet_verify_own_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'meet-verify'
              AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text
              AND (SELECT private.meet_upload_allowed('meet-verify', name)));

-- Read only. Nothing but the worker writes to meet-media.
CREATE POLICY meet_media_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'meet-media'
         AND (SELECT private.meet_media_visible_to(name, (SELECT auth.uid()))));

-- ---------------------------------------------------------------------------
-- The worker (§2.4). `private.invoke_edge_worker` restated whole from 20261026120000, its only
-- definition, with `meet-media-worker` added to the list; nothing else changes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.invoke_edge_worker(p_function text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_url text;
  v_key text;
BEGIN
  -- A fixed list: this posts a secret key, and it posts it only to our own workers.
  IF p_function IS NULL OR p_function NOT IN ('notifications-worker', 'storage-worker',
                                               'payments-worker', 'meet-media-worker') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  SELECT s.decrypted_secret INTO v_url FROM vault.decrypted_secrets s WHERE s.name = 'edge_functions_url';
  SELECT s.decrypted_secret INTO v_key FROM vault.decrypted_secrets s WHERE s.name = 'worker_api_key';
  IF v_url IS NULL OR v_key IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_net') THEN
    RETURN NULL;
  END IF;
  RETURN net.http_post(
    url := rtrim(v_url, '/') || '/' || p_function,
    body := '{}'::jsonb,
    headers := jsonb_build_object('apikey', v_key, 'content-type', 'application/json'),
    timeout_milliseconds := 30000
  );
END $$;

REVOKE ALL ON FUNCTION private.invoke_edge_worker(text) FROM PUBLIC, anon, authenticated;

-- Every minute, but only when the worker has something it could claim: an idle minute costs one
-- index probe rather than an Edge Function invocation, which the Free plan counts. The predicate
-- is `claim_outbox`'s (20260921121600, with `gateway_claim_outbox`'s defaults: 8 attempts, a claim
-- stale after 5 minutes), so an event that has used its attempts, or one a running worker holds,
-- does not call the worker every minute for nothing.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('meet-media-dispatch', '* * * * *',
      $cron$SELECT private.invoke_edge_worker('meet-media-worker')
            WHERE EXISTS (SELECT 1 FROM private.outbox o
                          WHERE o.aggregate = 'meet_media' AND o.dispatched_at IS NULL
                            AND o.attempts < 8
                            AND (o.claimed_at IS NULL
                                 OR o.claimed_at < now() - interval '5 minutes'))$cron$);
  END IF;
END $$;

-- What is left in the inbox: an upload never submitted, or one whose submission was refused. A
-- file waiting for the worker belongs to a `processing` photo and stays, however long the worker
-- is down. Anything else older than a day is queued for the storage worker, a bounded batch a
-- run; an erase queued twice is harmless.
CREATE FUNCTION private.meet_sweep_inbox()
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_n integer := 0;
  v_object record;
BEGIN
  FOR v_object IN
    SELECT o.name FROM storage.objects o
    WHERE o.bucket_id = 'meet-inbox'
      AND o.name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'
      AND o.created_at < now() - interval '24 hours'
      AND NOT EXISTS (SELECT 1 FROM public.meet_photos ph
                      WHERE ph.status = 'processing'
                        AND (ph.inbox_path = o.name OR ph.thumb_inbox_path = o.name))
    ORDER BY o.created_at
    LIMIT 1000
  LOOP
    PERFORM private.emit_event('storage', split_part(v_object.name, '/', 1), 'storage.erase_object',
      jsonb_build_object('bucket', 'meet-inbox', 'path', v_object.name));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('meet-inbox-sweep', '25 2 * * *',
      $cron$SELECT private.meet_sweep_inbox()$cron$);
  END IF;
END $$;

-- What a photo's files are, queued for the storage worker to remove one by one (§2.7): the
-- stored copies under the profile's folder, and the inbox copies under the uploader's. A photo a
-- person rejected as appearing under 18 is child-safety evidence (§8.3, RB-17): the uploader
-- removing or replacing it marks the row removed and leaves its files, which M1-PR4 moves into
-- the evidence it keeps. Deleting the whole profile still empties its folder; M1-PR4's decision
-- copies such a photo to evidence first, before any deletion can reach it.
CREATE FUNCTION private.meet_erase_photo_files(p_photo_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_photo public.meet_photos%ROWTYPE;
  v_owner uuid;
  v_path  text;
BEGIN
  SELECT ph.* INTO v_photo FROM public.meet_photos ph WHERE ph.id = p_photo_id;
  IF v_photo.reason_code = 'underage_appearance' THEN
    RETURN;
  END IF;
  SELECT mp.user_id INTO v_owner FROM public.meet_profiles mp WHERE mp.id = v_photo.profile_id;
  FOREACH v_path IN ARRAY array_remove(ARRAY[v_photo.media_path, v_photo.thumb_path], NULL) LOOP
    PERFORM private.emit_event('storage', v_photo.profile_id::text, 'storage.erase_object',
      jsonb_build_object('bucket', 'meet-media', 'path', v_path));
  END LOOP;
  FOREACH v_path IN ARRAY array_remove(ARRAY[v_photo.inbox_path, v_photo.thumb_inbox_path], NULL) LOOP
    PERFORM private.emit_event('storage', v_owner::text, 'storage.erase_object',
      jsonb_build_object('bucket', 'meet-inbox', 'path', v_path));
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- The media worker's two reports (§4.4), service role only.
--
-- Ingested: the stored files are in place, so the photo goes to `pending_review` and waits for a
-- person (OD-41). Idempotent: the same report again answers `accepted` without touching the row,
-- so a worker retrying after a partial run does no harm. A photo no longer `processing` (removed
-- while it waited, or its profile deleted) is answered `accepted: false`, and the worker deletes
-- what it wrote. The same picture on somebody else's profile raises a fraud flag; perceptual
-- hashing is not available, so this catches exact copies only (§8.5). M1-PR4 opens the
-- `meet_photo` moderation case for the new photo once the subject kind exists.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.meet_media_ingested(
  p_kind text, p_id uuid, p_media_path text, p_thumb_path text, p_sha256 text, p_width integer,
  p_height integer, p_mime text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_photo   public.meet_photos%ROWTYPE;
  v_owner   uuid;
  v_ext     text := CASE p_mime WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png'
                                WHEN 'image/webp' THEN 'webp' END;
BEGIN
  IF p_kind IS DISTINCT FROM 'photo' OR p_id IS NULL OR v_ext IS NULL
     OR p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$'
     OR p_width IS NULL OR p_height IS NULL OR p_width NOT BETWEEN 1 AND 4096
     OR p_height NOT BETWEEN 1 AND 4096 OR p_media_path IS NULL OR p_thumb_path IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  SELECT ph.* INTO v_photo FROM public.meet_photos ph WHERE ph.id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted', false);
  END IF;
  IF p_media_path <> v_photo.profile_id::text || '/p/' || p_id::text || '.' || v_ext
     OR p_thumb_path !~ ('^' || v_photo.profile_id::text || '/pt/' || p_id::text || '\.(jpg|png|webp)$') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'path';
  END IF;
  IF v_photo.status IN ('pending_review', 'approved', 'rejected')
     AND v_photo.media_path = p_media_path AND v_photo.thumb_path = p_thumb_path THEN
    RETURN jsonb_build_object('accepted', true);
  END IF;
  IF v_photo.status <> 'processing' THEN
    RETURN jsonb_build_object('accepted', false);
  END IF;

  UPDATE public.meet_photos ph
  SET status = 'pending_review', media_path = p_media_path, thumb_path = p_thumb_path,
      sha256 = decode(p_sha256, 'hex'), width = p_width, height = p_height, mime = p_mime,
      inbox_path = NULL, thumb_inbox_path = NULL, failure_reason = NULL
  WHERE ph.id = p_id;

  SELECT mp.user_id INTO v_owner FROM public.meet_profiles mp WHERE mp.id = v_photo.profile_id;
  IF EXISTS (SELECT 1 FROM public.meet_photos other
             JOIN public.meet_profiles op ON op.id = other.profile_id
             WHERE other.sha256 = decode(p_sha256, 'hex') AND op.user_id <> v_owner) THEN
    -- Opaque ids only: the fraud queue is read by errands staff (D25).
    PERFORM private.raise_fraud_flag('user', v_owner::text, 'meet_photo_reuse', 60::smallint,
      jsonb_build_object('source', 'meet', 'photo_id', p_id));
  END IF;

  PERFORM private.meet_refresh_profile(v_photo.profile_id);
  RETURN jsonb_build_object('accepted', true);
END $$;

CREATE FUNCTION private.meet_media_failed(p_kind text, p_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  IF p_kind IS DISTINCT FROM 'photo' OR p_id IS NULL
     OR p_reason IS NULL OR p_reason NOT IN ('not_found', 'bad_type', 'corrupt', 'animated',
                                             'too_large', 'bad_dimensions') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  UPDATE public.meet_photos ph
  SET status = 'failed', failure_reason = p_reason, inbox_path = NULL, thumb_inbox_path = NULL
  WHERE ph.id = p_id AND ph.status = 'processing'
  RETURNING ph.profile_id INTO v_profile_id;
  IF v_profile_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false);
  END IF;
  PERFORM private.meet_refresh_profile(v_profile_id);
  RETURN jsonb_build_object('recorded', true);
END $$;

CREATE FUNCTION public.gateway_meet_media_ingested(
  p_kind text, p_id uuid, p_media_path text, p_thumb_path text, p_sha256 text, p_width integer,
  p_height integer, p_mime text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.meet_media_ingested(p_kind, p_id, p_media_path, p_thumb_path, p_sha256,
                                         p_width, p_height, p_mime); $$;

CREATE FUNCTION public.gateway_meet_media_failed(p_kind text, p_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT private.meet_media_failed(p_kind, p_id, p_reason); $$;

-- ---------------------------------------------------------------------------
-- State and eligibility (§4.2), replacing the 20261126120100 stubs.
-- ---------------------------------------------------------------------------

-- Works with Meet off: `v5: false` and nothing else is the answer the app routes on, rather than
-- an error. With it on, the caller needs a country, as every other Meet function does.
CREATE OR REPLACE FUNCTION public.meet_get_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := private.require_user();
  v_country  char(2);
  v_elig     public.meet_eligibility%ROWTYPE;
  v_profile  public.meet_profiles%ROWTYPE;
  v_required integer := private.meet_guidelines_version();
  v_safety   jsonb;
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF NOT private.meet_flag_on('meet.v5', v_uid, v_country) THEN
    RETURN jsonb_build_object('v5', false, 'features', '[]'::jsonb, 'eligibility', NULL,
      'guidelines', NULL, 'profile', NULL, 'restrictions', '[]'::jsonb, 'suspension', NULL,
      'unread', NULL);
  END IF;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SET' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_elig FROM public.meet_eligibility e WHERE e.user_id = v_uid;
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid;
  v_safety := private.meet_state_safety(v_uid);
  RETURN jsonb_build_object(
    'v5', true,
    'features', (SELECT coalesce(jsonb_agg(f.name ORDER BY f.n), '[]'::jsonb)
                 FROM unnest(ARRAY['discovery', 'nearby', 'chat', 'statuses', 'games',
                                   'photo_verification']) WITH ORDINALITY f (name, n)
                 WHERE private.meet_flag_on('meet.' || f.name, v_uid, v_country)),
    'eligibility', CASE
      WHEN v_elig.status = 'refused_minor' THEN 'refused'
      WHEN v_elig.status = 'revoked' OR private.meet_device_refused(v_uid) THEN 'unavailable'
      WHEN v_elig.status = 'eligible' THEN 'eligible'
      ELSE 'none' END,
    'guidelines', jsonb_build_object(
      'required_version', v_required,
      'accepted_version', v_elig.guidelines_version,
      'url', (private.meet_guidelines_document(v_uid, v_country, v_required)).url),
    'profile', CASE WHEN v_profile.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_profile.id,
      'status', v_profile.status,
      'discoverable', v_profile.discoverable,
      'paused', v_profile.paused_at IS NOT NULL,
      'verified', v_profile.photo_verified_at IS NOT NULL,
      'held', v_profile.hold_reason IS NOT NULL OR v_profile.text_moderation = 'held',
      'completeness', private.meet_profile_completeness(v_profile.id)) END,
    'restrictions', coalesce(v_safety -> 'restrictions', '[]'::jsonb),
    'suspension', v_safety -> 'suspension',
    'unread', private.meet_state_unread(v_profile.id));
END $$;

-- The 18+ gate (§8.1 L2, L3). Pure checks first, then the key, then one of three answers, each
-- recorded with the key: eligible (the date, the guidelines and a `meet_terms` consent),
-- refused (no date, every device barred) or unavailable (an earlier refusal on this account, a
-- barred device, or a failed integrity verdict). Refused and unavailable are returned, never
-- raised, so what they record survives (D24). A second check-in on an eligible account is
-- ERR_MEET_AGE_ALREADY_SET: the date is set once, and a correction is a support decision with
-- evidence (`admin_meet_correct_birth_date`).
-- An under-18 date is recorded whatever else is true: on a barred phone, or one that failed
-- integrity, the account is still marked refused and every phone barred, and the answer is the
-- `unavailable` that phone gives for any date, so trying dates there teaches nothing. Otherwise
-- the refusal would be lost, and the same account could come back with an adult's date once the
-- verdict or the bar changed.
CREATE OR REPLACE FUNCTION public.meet_check_in(
  p_idempotency_key text, p_birth_date date, p_guidelines_version integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_country char(2);
  v_today   date;
  v_age     integer;
  v_claim   jsonb;
  v_status  text;
  v_quiet   boolean;
  v_result  jsonb;
BEGIN
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = v_uid;
  IF NOT private.meet_flag_on('meet.v5', v_uid, v_country) THEN
    RAISE EXCEPTION 'ERR_FEATURE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  IF v_country IS NULL THEN
    RAISE EXCEPTION 'ERR_COUNTRY_NOT_SET' USING ERRCODE = 'P0001';
  END IF;
  IF p_birth_date IS NULL OR NOT isfinite(p_birth_date) OR p_guidelines_version IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_today := private.meet_local_today(v_uid);
  v_age := private.meet_age_on(p_birth_date, v_today);
  -- A date in the future, or an age over 99 (the oldest a discovery preference can name).
  IF p_birth_date > v_today OR v_age > 99 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_guidelines_version <> private.meet_guidelines_version() THEN
    RAISE EXCEPTION 'ERR_MEET_GUIDELINES_OUTDATED' USING ERRCODE = 'P0001';
  END IF;

  -- Never the date: the key's request hash is kept for a day, and a hash of a date is the date.
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_check_in',
    jsonb_build_object('adult', v_age >= private.meet_min_age(),
                       'guidelines_version', p_guidelines_version));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('meet_check_in:' || v_uid::text, 0));
  SELECT e.status INTO v_status FROM public.meet_eligibility e WHERE e.user_id = v_uid;
  IF v_status = 'eligible' THEN
    RAISE EXCEPTION 'ERR_MEET_AGE_ALREADY_SET' USING ERRCODE = 'P0001';
  END IF;

  v_quiet := private.meet_device_refused(v_uid) OR private.meet_integrity_failed(v_uid);
  IF v_status IS NOT NULL THEN
    PERFORM private.meet_note_safety_event(v_uid, 'age_refused', 'check_in', '{}'::text[]);
    v_result := jsonb_build_object('status', 'unavailable', 'age', NULL);
  ELSIF v_age < private.meet_min_age() THEN
    INSERT INTO public.meet_eligibility (user_id, status, birth_date, guidelines_version)
    VALUES (v_uid, 'refused_minor', NULL, p_guidelines_version);
    INSERT INTO public.meet_age_refusal_devices (device_fingerprint_hash, expires_at)
    SELECT DISTINCT d.device_fingerprint_hash,
           now() + make_interval(days => private.meet_retention_days('age_refusal_device_days', 365))
    FROM public.user_devices d WHERE d.user_id = v_uid
    ON CONFLICT (device_fingerprint_hash) DO UPDATE
      SET refused_at = EXCLUDED.refused_at,
          expires_at = greatest(public.meet_age_refusal_devices.expires_at, EXCLUDED.expires_at);
    PERFORM private.meet_note_safety_event(v_uid, 'age_refused', 'check_in', '{}'::text[]);
    v_result := jsonb_build_object('status', CASE WHEN v_quiet THEN 'unavailable' ELSE 'refused' END,
                                   'age', NULL);
  ELSIF v_quiet THEN
    PERFORM private.meet_note_safety_event(v_uid, 'device_refused', 'check_in', '{}'::text[]);
    v_result := jsonb_build_object('status', 'unavailable', 'age', NULL);
  ELSE
    INSERT INTO public.meet_eligibility (user_id, status, birth_date, guidelines_version)
    VALUES (v_uid, 'eligible', p_birth_date, p_guidelines_version);
    PERFORM private.meet_record_consent(v_uid, 'meet_terms'::public.consent_kind,
      (private.meet_guidelines_document(v_uid, v_country, p_guidelines_version)).id);
    v_result := jsonb_build_object('status', 'eligible', 'age', v_age);
  END IF;

  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- Accepting a new version of the guidelines: the one Meet function an outdated acceptance may
-- reach, so it asks the access check for everything but that.
CREATE OR REPLACE FUNCTION public.meet_accept_guidelines(p_idempotency_key text, p_version integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_refusal text := private.meet_access_refusal(v_uid, 'meet.v5', false);
  v_claim   jsonb;
BEGIN
  IF v_refusal IS NOT NULL AND v_refusal <> 'ERR_MEET_GUIDELINES_OUTDATED' THEN
    RAISE EXCEPTION '%', v_refusal USING ERRCODE = 'P0001';
  END IF;
  IF p_version IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF p_version <> private.meet_guidelines_version() THEN
    RAISE EXCEPTION 'ERR_MEET_GUIDELINES_OUTDATED' USING ERRCODE = 'P0001';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_accept_guidelines',
    jsonb_build_object('version', p_version));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;

  UPDATE public.meet_eligibility e
  SET guidelines_version = p_version, guidelines_accepted_at = now()
  WHERE e.user_id = v_uid AND e.guidelines_version < p_version;
  IF FOUND THEN
    PERFORM private.meet_record_consent(v_uid, 'meet_terms'::public.consent_kind,
      (private.meet_guidelines_document(v_uid,
         (SELECT p.country_code FROM public.profiles p WHERE p.user_id = v_uid), p_version)).id);
  END IF;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- Profile (§4.2).
-- ---------------------------------------------------------------------------

-- Creates the profile on the first call (a first name is then required) and edits it after.
-- NULL leaves a field alone; an empty bio or gender clears it. Setting a gender the first time
-- needs `p_sensitive_consent`, which records `meet_sensitive_data` (D5). Screening happens in the
-- table's trigger, so a refusal raises before anything is written.
CREATE OR REPLACE FUNCTION public.meet_save_profile(
  p_idempotency_key text, p_first_name text, p_bio text, p_intent text, p_gender text,
  p_show_gender boolean, p_interests text[], p_sensitive_consent boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  -- NFC, so a name typed with combining accents is stored the way it is compared.
  v_first   text := nullif(btrim(normalize(p_first_name, NFC)), '');
  v_bio     text := btrim(normalize(p_bio, NFC));
  v_gender  text := btrim(p_gender);
  v_claim   jsonb;
  v_profile public.meet_profiles%ROWTYPE;
  v_result  jsonb;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  IF (p_first_name IS NOT NULL AND (v_first IS NULL
        OR v_first !~ '^[[:alpha:]][\u0300-\u034E\u0350-\u036F]{0,2}([[:alpha:] ''-][\u0300-\u034E\u0350-\u036F]{0,2}){0,29}$'))
     OR length(v_bio) > 300
     OR (p_intent IS NOT NULL AND p_intent NOT IN ('love', 'friendship', 'hangout', 'open'))
     OR (v_gender IS NOT NULL AND v_gender NOT IN ('', 'woman', 'man'))
     OR cardinality(p_interests) > 8 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;

  -- Two first saves at once would otherwise both insert.
  PERFORM pg_advisory_xact_lock(hashtextextended('meet_profile:' || v_uid::text, 0));
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF NOT FOUND AND v_first IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'first_name';
  END IF;
  IF v_gender IN ('woman', 'man')
     AND NOT private.has_consent(v_uid, 'meet_sensitive_data'::public.consent_kind)
     AND NOT coalesce(p_sensitive_consent, false) THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_save_profile',
    jsonb_build_object('first_name', v_first, 'bio', v_bio, 'intent', p_intent,
                       'gender', v_gender, 'show_gender', p_show_gender,
                       'interests', p_interests, 'sensitive_consent', p_sensitive_consent));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  IF v_gender IN ('woman', 'man')
     AND NOT private.has_consent(v_uid, 'meet_sensitive_data'::public.consent_kind) THEN
    PERFORM private.meet_record_consent(v_uid, 'meet_sensitive_data'::public.consent_kind, NULL);
  END IF;

  IF v_profile.id IS NULL THEN
    INSERT INTO public.meet_profiles (user_id, country_code, first_name, bio, intent, gender,
                                      show_gender, interests)
    VALUES (v_uid, (SELECT p.country_code FROM public.profiles p WHERE p.user_id = v_uid),
            v_first, nullif(v_bio, ''), coalesce(p_intent, 'open'), nullif(v_gender, ''),
            coalesce(p_show_gender, false), coalesce(p_interests, '{}'))
    RETURNING * INTO v_profile;
  ELSE
    UPDATE public.meet_profiles mp
    SET first_name  = coalesce(v_first, mp.first_name),
        bio         = CASE WHEN v_bio IS NULL THEN mp.bio ELSE nullif(v_bio, '') END,
        intent      = coalesce(p_intent, mp.intent),
        gender      = CASE WHEN v_gender IS NULL THEN mp.gender ELSE nullif(v_gender, '') END,
        show_gender = coalesce(p_show_gender, mp.show_gender),
        interests   = coalesce(p_interests, mp.interests),
        version     = mp.version + 1
    WHERE mp.id = v_profile.id;
  END IF;
  PERFORM private.meet_refresh_profile(v_profile.id);

  v_result := private.meet_own_profile_json(v_profile.id);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- The Meet area (§8.6): a ~4.9 km geohash cell, its centroid and the nearest service-area city
-- in the person's country. The coordinates exist only inside this call: neither the row nor the
-- idempotency hash (which is taken over the cell) keeps them. Once every `meet.area.min_update_hours`.
-- [A] A point counts as in the country when the nearest service-area city of any country is in
-- it and within 1,000 km: Nigeria's are its 36 state capitals and Abuja, and the other packs have
-- one city each, so a tighter rule would refuse most of Kenya.
CREATE OR REPLACE FUNCTION public.meet_set_area(
  p_idempotency_key text, p_lat double precision, p_lng double precision)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile public.meet_profiles%ROWTYPE;
  v_cell    text;
  v_centre  extensions.geography;
  v_city    public.cities%ROWTYPE;
  v_claim   jsonb;
  v_result  jsonb;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90
     OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_cell := extensions.ST_GeoHash(
    extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326), 5);
  v_centre := extensions.ST_SetSRID(extensions.ST_PointFromGeoHash(v_cell), 4326)::extensions.geography;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_set_area',
    jsonb_build_object('cell', v_cell));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  IF NOT private.has_consent(v_uid, 'location'::public.consent_kind) THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_profile.area_set_at > now() - make_interval(
       hours => greatest(coalesce((private.remote_config_json('meet.area.min_update_hours')
                                   #>> '{}')::integer, 6), 0)) THEN
    RAISE EXCEPTION 'ERR_MEET_RATE_LIMITED' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.* INTO v_city FROM public.cities c
  WHERE c.center IS NOT NULL
  ORDER BY extensions.ST_Distance(c.center, v_centre), c.code
  LIMIT 1;
  IF v_city.country_code IS DISTINCT FROM v_profile.country_code
     OR extensions.ST_Distance(v_city.center, v_centre) > 1000000 THEN
    RAISE EXCEPTION 'ERR_LOCATION_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.meet_profiles mp
  SET area_geohash = v_cell, area_point = v_centre, area_city_code = v_city.code,
      area_set_at = now()
  WHERE mp.id = v_profile.id;
  PERFORM private.meet_refresh_profile(v_profile.id);

  v_result := jsonb_build_object('area_label', v_city.name, 'city_code', v_city.code);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- "Show me" and the ranges (§8.7). NULL leaves a value alone. The first "show me" that is not
-- 'everyone' needs `p_sensitive_consent` and records `meet_sensitive_data`.
CREATE OR REPLACE FUNCTION public.meet_set_discovery_prefs(
  p_idempotency_key text, p_seeking text, p_age_min integer, p_age_max integer,
  p_max_band_km integer, p_intents text[], p_sensitive_consent boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_seeking text;
  v_age_min integer;
  v_age_max integer;
  v_band    integer;
  v_intents text[];
  v_claim   jsonb;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  SELECT coalesce(p_seeking, dp.seeking), coalesce(p_age_min, dp.age_min),
         coalesce(p_age_max, dp.age_max), coalesce(p_max_band_km, dp.max_band_km),
         coalesce(p_intents, dp.intents)
  INTO v_seeking, v_age_min, v_age_max, v_band, v_intents
  FROM (SELECT v_uid AS user_id) me
  LEFT JOIN public.meet_discovery_prefs dp ON dp.user_id = me.user_id;
  v_seeking := coalesce(v_seeking, 'everyone');
  v_age_min := coalesce(v_age_min, private.meet_min_age());
  v_age_max := coalesce(v_age_max, 60);
  v_band := coalesce(v_band, 50);
  v_intents := coalesce(v_intents, '{}');
  IF v_seeking NOT IN ('women', 'men', 'everyone')
     OR v_age_min NOT BETWEEN private.meet_min_age() AND 99
     OR v_age_max NOT BETWEEN v_age_min AND 99
     OR v_band NOT IN (5, 10, 25, 50, 100)
     OR NOT v_intents <@ ARRAY['love', 'friendship', 'hangout', 'open']
     OR cardinality(v_intents) <> (SELECT count(DISTINCT i) FROM unnest(v_intents) i) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF v_seeking <> 'everyone'
     AND NOT private.has_consent(v_uid, 'meet_sensitive_data'::public.consent_kind)
     AND NOT coalesce(p_sensitive_consent, false) THEN
    RAISE EXCEPTION 'ERR_CONSENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_set_discovery_prefs',
    jsonb_build_object('seeking', p_seeking, 'age_min', p_age_min, 'age_max', p_age_max,
                       'max_band_km', p_max_band_km, 'intents', p_intents,
                       'sensitive_consent', p_sensitive_consent));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;

  IF v_seeking <> 'everyone'
     AND NOT private.has_consent(v_uid, 'meet_sensitive_data'::public.consent_kind) THEN
    PERFORM private.meet_record_consent(v_uid, 'meet_sensitive_data'::public.consent_kind, NULL);
  END IF;
  INSERT INTO public.meet_discovery_prefs (user_id, seeking, age_min, age_max, max_band_km, intents)
  VALUES (v_uid, v_seeking, v_age_min::smallint, v_age_max::smallint, v_band::smallint, v_intents)
  ON CONFLICT (user_id) DO UPDATE
    SET seeking = EXCLUDED.seeking, age_min = EXCLUDED.age_min, age_max = EXCLUDED.age_max,
        max_band_km = EXCLUDED.max_band_km, intents = EXCLUDED.intents;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- Everything the owner set, and nothing anybody else can see. `catalogue` is not in the design's
-- shape: the interest and prompt keys are functions-only reference data, and the onboarding
-- screens need to know which are offered.
CREATE OR REPLACE FUNCTION public.meet_get_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile public.meet_profiles%ROWTYPE;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid;
  RETURN jsonb_build_object(
    'profile', private.meet_own_profile_json(v_profile.id),
    'photos', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'id', ph.id, 'position', ph.position, 'status', ph.status,
                 -- An underage-appearance rejection opens a child-safety review (RB-17); naming
                 -- it would tell the person what was noticed.
                 'reason_code', CASE WHEN ph.reason_code = 'underage_appearance' THEN 'other'
                                     ELSE ph.reason_code END,
                 'failure_reason', ph.failure_reason,
                 'media_path', ph.media_path, 'thumb_path', ph.thumb_path)
                 ORDER BY ph.position, ph.created_at), '[]'::jsonb)
               FROM public.meet_photos ph
               WHERE ph.profile_id = v_profile.id AND ph.status <> 'removed'),
    'prompts', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', pr.id, 'prompt_key', pr.prompt_key, 'answer', pr.answer,
                  'position', pr.position, 'moderation', pr.moderation)
                  ORDER BY pr.position), '[]'::jsonb)
                FROM public.meet_prompts pr
                WHERE pr.profile_id = v_profile.id AND pr.moderation <> 'removed'),
    'prefs', (SELECT jsonb_build_object('seeking', coalesce(dp.seeking, 'everyone'),
                       'age_min', coalesce(dp.age_min, private.meet_min_age()),
                       'age_max', coalesce(dp.age_max, 60),
                       'max_band_km', coalesce(dp.max_band_km, 50),
                       'intents', to_jsonb(coalesce(dp.intents, '{}'::text[])))
              FROM (SELECT v_uid AS user_id) me
              LEFT JOIN public.meet_discovery_prefs dp ON dp.user_id = me.user_id),
    'privacy', jsonb_build_object(
      'hide_from_errand_contacts', coalesce(v_profile.hide_from_errand_contacts, true),
      'show_gender', coalesce(v_profile.show_gender, false),
      'read_receipts', coalesce(v_profile.read_receipts, true)),
    'catalogue', jsonb_build_object(
      'interests', (SELECT coalesce(jsonb_agg(k.key ORDER BY k.sort, k.key), '[]'::jsonb)
                    FROM public.meet_interest_keys k WHERE k.active),
      'prompts', (SELECT coalesce(jsonb_agg(k.key ORDER BY k.sort, k.key), '[]'::jsonb)
                  FROM public.meet_prompt_keys k WHERE k.active)));
END $$;

-- A photo the app has put in its inbox folder, with its thumbnail (§2.7 step 2). The worker
-- takes it from here; the answer is `processing`. Submitting to a position whose photo was
-- rejected or failed replaces that photo.
CREATE OR REPLACE FUNCTION public.meet_submit_photo(
  p_idempotency_key text, p_inbox_path text, p_thumb_inbox_path text, p_position integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_max     integer := least(greatest(coalesce(private.remote_config_int('meet.photos.max'), 6), 1), 6);
  v_shape   text;
  v_profile public.meet_profiles%ROWTYPE;
  v_claim   jsonb;
  v_old     uuid;
  v_id      uuid;
  v_result  jsonb;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  v_shape := '^' || v_uid::text || '/[0-9a-f-]{36}\.(jpg|png|webp)$';
  IF p_inbox_path IS NULL OR p_thumb_inbox_path IS NULL OR p_position IS NULL
     OR p_inbox_path !~ v_shape OR p_thumb_inbox_path !~ v_shape
     OR p_inbox_path = p_thumb_inbox_path OR p_position NOT BETWEEN 0 AND v_max - 1 THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM storage.objects o
      WHERE o.bucket_id = 'meet-inbox' AND o.name IN (p_inbox_path, p_thumb_inbox_path)) <> 2 THEN
    RAISE EXCEPTION 'ERR_UPLOAD_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_submit_photo',
    jsonb_build_object('inbox_path', p_inbox_path, 'thumb_inbox_path', p_thumb_inbox_path,
                       'position', p_position));
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.meet_photos ph
             WHERE ph.inbox_path IN (p_inbox_path, p_thumb_inbox_path)
                OR ph.thumb_inbox_path IN (p_inbox_path, p_thumb_inbox_path)) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'already submitted';
  END IF;
  IF (SELECT count(*) FROM public.meet_photos ph
      WHERE ph.profile_id = v_profile.id
        AND ph.status IN ('processing', 'pending_review', 'approved')) >= v_max THEN
    RAISE EXCEPTION 'ERR_MEET_PHOTO_LIMIT' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.meet_photos ph
             WHERE ph.profile_id = v_profile.id AND ph.position = p_position
               AND ph.status IN ('processing', 'pending_review', 'approved')) THEN
    RAISE EXCEPTION 'ERR_MEET_PHOTO_LIMIT' USING ERRCODE = 'P0001', DETAIL = 'position taken';
  END IF;

  FOR v_old IN
    SELECT ph.id FROM public.meet_photos ph
    WHERE ph.profile_id = v_profile.id AND ph.position = p_position
      AND ph.status IN ('rejected', 'failed')
  LOOP
    PERFORM private.meet_erase_photo_files(v_old);
    UPDATE public.meet_photos ph SET status = 'removed' WHERE ph.id = v_old;
  END LOOP;

  INSERT INTO public.meet_photos (profile_id, position, inbox_path, thumb_inbox_path)
  VALUES (v_profile.id, p_position, p_inbox_path, p_thumb_inbox_path)
  RETURNING id INTO v_id;
  PERFORM private.emit_event('meet_media', v_profile.id::text, 'meet.media.ingest',
    jsonb_build_object('kind', 'photo', 'id', v_id, 'profile_id', v_profile.id,
                       'inbox_path', p_inbox_path, 'thumb_inbox_path', p_thumb_inbox_path));
  PERFORM private.meet_refresh_profile(v_profile.id);

  v_result := jsonb_build_object('photo_id', v_id, 'status', 'processing');
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- Removing a photo queues its files for erasure; the row stays as `removed` and is never
-- returned again. Removing the last approved photo takes the profile out of discovery. A way
-- out, so somebody Meet has shut out can still do it.
CREATE OR REPLACE FUNCTION public.meet_remove_photo(p_idempotency_key text, p_photo_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile uuid;
  v_claim   jsonb;
BEGIN
  PERFORM private.meet_require_exit(v_uid);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_remove_photo',
    jsonb_build_object('photo_id', p_photo_id));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT ph.profile_id INTO v_profile
  FROM public.meet_photos ph JOIN public.meet_profiles mp ON mp.id = ph.profile_id
  WHERE ph.id = p_photo_id AND mp.user_id = v_uid AND ph.status <> 'removed'
  FOR UPDATE OF ph;
  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'ERR_MEET_PHOTO_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.meet_erase_photo_files(p_photo_id);
  UPDATE public.meet_photos ph SET status = 'removed' WHERE ph.id = p_photo_id;
  PERFORM private.meet_refresh_profile(v_profile);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- The new order of every live photo, first to last. One statement, so two photos can swap.
CREATE OR REPLACE FUNCTION public.meet_reorder_photos(p_idempotency_key text, p_photo_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile uuid;
  v_claim   jsonb;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  IF p_photo_ids IS NULL OR cardinality(p_photo_ids) = 0 OR array_position(p_photo_ids, NULL) IS NOT NULL
     OR cardinality(p_photo_ids) <> (SELECT count(DISTINCT i) FROM unnest(p_photo_ids) i) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_reorder_photos',
    jsonb_build_object('photo_ids', p_photo_ids));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT mp.id INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF EXISTS (SELECT 1 FROM unnest(p_photo_ids) i (id)
             WHERE NOT EXISTS (SELECT 1 FROM public.meet_photos ph
                               WHERE ph.id = i.id AND ph.profile_id = v_profile
                                 AND ph.status IN ('processing', 'pending_review', 'approved'))) THEN
    RAISE EXCEPTION 'ERR_MEET_PHOTO_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM public.meet_photos ph
      WHERE ph.profile_id = v_profile
        AND ph.status IN ('processing', 'pending_review', 'approved')) <> cardinality(p_photo_ids) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'every photo, once';
  END IF;
  UPDATE public.meet_photos ph SET position = (o.n - 1)::smallint
  FROM unnest(p_photo_ids) WITH ORDINALITY o (id, n)
  WHERE ph.id = o.id AND ph.position IS DISTINCT FROM (o.n - 1)::smallint;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- A prompt and its answer at a position (0-2), screened like a bio. Saving to a taken position
-- replaces that prompt and keeps its id.
CREATE OR REPLACE FUNCTION public.meet_save_prompt(
  p_idempotency_key text, p_prompt_key text, p_answer text, p_position integer)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_answer  text := btrim(p_answer);
  v_profile public.meet_profiles%ROWTYPE;
  v_claim   jsonb;
  v_id      uuid;
BEGIN
  PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  IF v_answer IS NULL OR length(v_answer) NOT BETWEEN 1 AND 150
     OR p_position IS NULL OR p_position NOT BETWEEN 0 AND 2
     OR NOT EXISTS (SELECT 1 FROM public.meet_prompt_keys k WHERE k.key = p_prompt_key AND k.active) THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_save_prompt',
    jsonb_build_object('prompt_key', p_prompt_key, 'answer', v_answer, 'position', p_position));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim #>> '{}')::uuid;
  END IF;

  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.meet_prompts pr
             WHERE pr.profile_id = v_profile.id AND pr.prompt_key = p_prompt_key
               AND pr.position <> p_position AND pr.moderation <> 'removed') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'prompt already used';
  END IF;
  -- The table's trigger screens the answer. An update, then an insert, rather than ON CONFLICT,
  -- so it screens once; the profile row locked above keeps two saves from racing.
  UPDATE public.meet_prompts pr
  SET prompt_key = p_prompt_key, answer = v_answer, created_at = now()
  WHERE pr.profile_id = v_profile.id AND pr.position = p_position
  RETURNING pr.id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO public.meet_prompts (profile_id, prompt_key, answer, position)
    VALUES (v_profile.id, p_prompt_key, v_answer, p_position)
    RETURNING id INTO v_id;
  END IF;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, to_jsonb(v_id));
  RETURN v_id;
END $$;

-- A way out, like removing a photo.
CREATE OR REPLACE FUNCTION public.meet_remove_prompt(p_idempotency_key text, p_prompt_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
BEGIN
  PERFORM private.meet_require_exit(v_uid);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_remove_prompt',
    jsonb_build_object('prompt_id', p_prompt_id));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;
  DELETE FROM public.meet_prompts pr
  USING public.meet_profiles mp
  WHERE pr.id = p_prompt_id AND mp.id = pr.profile_id AND mp.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023', DETAIL = 'no such prompt';
  END IF;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- Visible in discovery or not. Turning it on needs an active profile: a clean first name, at
-- least one approved photo and an area. Turning it off is a way out, open to somebody Meet has
-- shut out; turning it on is not.
CREATE OR REPLACE FUNCTION public.meet_set_discoverable(p_idempotency_key text, p_discoverable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_profile public.meet_profiles%ROWTYPE;
  v_claim   jsonb;
BEGIN
  IF p_discoverable = false THEN
    PERFORM private.meet_require_exit(v_uid);
  ELSE
    PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  END IF;
  IF p_discoverable IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_set_discoverable',
    jsonb_build_object('discoverable', p_discoverable));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;
  SELECT * INTO v_profile FROM public.meet_profiles mp WHERE mp.user_id = v_uid FOR UPDATE;
  IF NOT FOUND OR (p_discoverable AND v_profile.status <> 'active') THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.meet_profiles mp SET discoverable = p_discoverable WHERE mp.id = v_profile.id;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- A break: hidden from discovery until unpaused. Free for everybody (D6). Pausing is a way out;
-- coming back needs the full access check.
CREATE OR REPLACE FUNCTION public.meet_pause(p_idempotency_key text, p_paused boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
BEGIN
  IF p_paused THEN
    PERFORM private.meet_require_exit(v_uid);
  ELSE
    PERFORM private.meet_require_access(v_uid, 'meet.v5', false);
  END IF;
  IF p_paused IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_pause',
    jsonb_build_object('paused', p_paused));
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;
  UPDATE public.meet_profiles mp
  SET paused_at = CASE WHEN p_paused THEN coalesce(mp.paused_at, now()) END
  WHERE mp.user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- The M1 privacy switches, each free (D6). A key M1 does not know, or a value that is not a
-- boolean, is refused rather than ignored, so a client cannot believe it set something it did
-- not. M2 adds `incognito`, `hide_last_active` and `hide_distance` behind a card. Open to
-- somebody Meet has shut out: nobody sees their profile meanwhile, so no switch exposes anything.
CREATE OR REPLACE FUNCTION public.meet_set_privacy(p_idempotency_key text, p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := private.require_user();
  v_claim   jsonb;
  v_profile public.meet_profiles%ROWTYPE;
  v_result  jsonb;
BEGIN
  PERFORM private.meet_require_exit(v_uid);
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object'
     OR p_settings = '{}'::jsonb
     OR EXISTS (SELECT 1 FROM jsonb_each(p_settings) s
                WHERE s.key NOT IN ('hide_from_errand_contacts', 'show_gender', 'read_receipts')
                   OR jsonb_typeof(s.value) <> 'boolean') THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_set_privacy', p_settings);
  IF v_claim IS NOT NULL THEN
    RETURN v_claim;
  END IF;
  UPDATE public.meet_profiles mp
  SET hide_from_errand_contacts = coalesce((p_settings ->> 'hide_from_errand_contacts')::boolean,
                                           mp.hide_from_errand_contacts),
      show_gender = coalesce((p_settings ->> 'show_gender')::boolean, mp.show_gender),
      read_receipts = coalesce((p_settings ->> 'read_receipts')::boolean, mp.read_receipts)
  WHERE mp.user_id = v_uid
  RETURNING * INTO v_profile;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MEET_PROFILE_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  v_result := jsonb_build_object('hide_from_errand_contacts', v_profile.hide_from_errand_contacts,
                                 'show_gender', v_profile.show_gender,
                                 'read_receipts', v_profile.read_receipts);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, v_result);
  RETURN v_result;
END $$;

-- What deleting a Meet profile removes, for `meet_delete_profile` and for account erasure: the
-- profile, its photos and prompts (by cascade), the discovery preferences, and every stored file,
-- which the storage worker erases by folder: the profile's folder in `meet-media` and the
-- person's inbox folder. The eligibility record is not touched here. Later PRs add their own rows
-- to what goes (swipes, matches, conversations, statuses) and to what stays (suspensions, report
-- evidence) in this one place, so both callers follow.
CREATE FUNCTION private.meet_erase_profile(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_profile uuid;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'ERR_INVALID_ARGUMENT' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.meet_profiles mp WHERE mp.user_id = p_user RETURNING mp.id INTO v_profile;
  DELETE FROM public.meet_discovery_prefs dp WHERE dp.user_id = p_user;
  IF v_profile IS NOT NULL THEN
    PERFORM private.emit_event('storage', v_profile::text, 'storage.erase_prefix',
      jsonb_build_object('bucket', 'meet-media', 'prefix', v_profile::text || '/'));
  END IF;
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'meet-inbox', 'prefix', p_user::text || '/'));
END $$;

-- Deleting the Meet profile. The eligibility record stays, so the birth date is still set once
-- and a refusal is still a refusal. A way out, so somebody Meet has shut out can still do it.
CREATE OR REPLACE FUNCTION public.meet_delete_profile(p_idempotency_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := private.require_user();
  v_claim jsonb;
BEGIN
  PERFORM private.meet_require_exit(v_uid);
  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'meet_delete_profile', '{}'::jsonb);
  IF v_claim IS NOT NULL THEN
    RETURN;
  END IF;
  PERFORM private.meet_erase_profile(v_uid);
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key, NULL);
END $$;

-- ---------------------------------------------------------------------------
-- Account erasure reaches Meet now, not at M1-PR8: the profile, its photos and files, and an
-- adult's birth date, which are personal data the moment this migration creates the tables. A
-- refusal's row stays: it holds no date, and it is what bars the phones the refused account
-- registered after its refusal (`meet_device_refused`). Restated whole from its latest version,
-- 20261126120100_meet_v5_contract (M1-PR2), with only the marked lines added. M1-PR8 restates it
-- again, from this one, for the tables M1-PR4 to M1-PR7 create; `collect_personal_data` waits for
-- M1-PR8 as planned.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.erase_account(p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = '', avatar_path = NULL, timezone = NULL
  WHERE user_id = p_user;

  DELETE FROM public.trusted_contacts WHERE user_id = p_user;
  DELETE FROM public.saved_places WHERE user_id = p_user;
  -- Concierge history goes with the account; its turns were redacted, and nothing needs them.
  DELETE FROM public.ai_conversations WHERE user_id = p_user;
  -- Meet-ups the person hosted are their words and their chosen place; attendance is who they
  -- met. Both go, and anybody still going to an upcoming one is told it is off.
  PERFORM private.notify(a.user_id, 'system', 'notification.meetup.cancelled.title',
    'notification.meetup.cancelled.body', jsonb_build_object('meetup_id', m.id))
  FROM public.meetups m JOIN public.meetup_attendees a ON a.meetup_id = m.id
  WHERE m.host_id = p_user AND m.status = 'published' AND m.ends_at > now();
  DELETE FROM public.meetups WHERE host_id = p_user;
  DELETE FROM public.meetup_attendees WHERE user_id = p_user;
  -- Meet v5 M1-PR2: the tester row and its staff note. `auth.users` is updated below, never
  -- deleted, so the row's ON DELETE CASCADE would not fire.
  DELETE FROM private.meet_testers WHERE user_id = p_user;
  -- Meet v5 M1-PR3: the Meet profile, its photos, prompts, "show me" and stored files, and an
  -- adult's eligibility row with its birth date. A refusal (no date) stays.
  PERFORM private.meet_erase_profile(p_user);
  DELETE FROM public.meet_eligibility WHERE user_id = p_user AND status = 'eligible';
  DELETE FROM private.request_access_notes n
  USING public.requests r
  WHERE r.id = n.request_id AND r.customer_id = p_user;
  DELETE FROM public.favorites WHERE customer_id = p_user OR provider_id = p_user;
  -- Device rows are referenced by consents, which are the record of what was agreed; the
  -- addresses a push could still reach are what identify the handset, so those go.
  UPDATE public.user_devices SET push_token = NULL, voip_token = NULL WHERE user_id = p_user;
  UPDATE public.provider_profiles SET online = false WHERE user_id = p_user;

  DELETE FROM auth.sessions WHERE user_id = p_user;
  DELETE FROM auth.identities WHERE user_id = p_user;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user;
  UPDATE auth.users
  SET phone = NULL, email = NULL, encrypted_password = NULL,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = 'infinity', deleted_at = now()
  WHERE id = p_user;

  -- The user's folder in `avatars` (one folder per user, named by id).
  PERFORM private.emit_event('storage', p_user::text, 'storage.erase_prefix',
    jsonb_build_object('bucket', 'avatars', 'prefix', p_user::text || '/'));

  PERFORM private.audit_write('account.erased', 'auth.users', p_user::text, NULL, NULL,
    'deletion_grace_elapsed');
END $$;

-- ---------------------------------------------------------------------------
-- Grants. The 16 client functions keep the grants 20261126120100 gave them (CREATE OR REPLACE
-- leaves them). Every private helper is revoked from the client roles; the two a storage policy
-- calls are granted back to `authenticated`, since a policy runs as the requester and each is a
-- definer that answers only for `auth.uid()`. The gateway functions are the service role's.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  private.meet_age_on(date, date),
  private.meet_local_today(uuid),
  private.meet_min_age(),
  private.meet_guidelines_version(),
  private.meet_retention_days(text, integer),
  private.meet_guidelines_document(uuid, char, integer),
  private.meet_device_refused(uuid),
  private.meet_integrity_failed(uuid),
  private.meet_note_safety_event(uuid, text, text, text[]),
  private.meet_state_safety(uuid),
  private.meet_state_unread(uuid),
  private.meet_record_consent(uuid, public.consent_kind, uuid),
  private.meet_access_refusal(uuid, text, boolean),
  private.meet_require_access(uuid, text, boolean),
  private.meet_require_exit(uuid),
  private.meet_screen_text(text, char, text, uuid, uuid),
  private.meet_screen_field(text, char, text),
  private.meet_profiles_screen(),
  private.meet_prompts_screen(),
  private.meet_profiles_check_interests(),
  private.meet_refresh_profile(uuid),
  private.meet_profile_completeness(uuid),
  private.meet_own_profile_json(uuid),
  private.meet_errand_contacts(uuid, uuid),
  private.meet_discoverable_to(uuid, uuid),
  private.meet_may_view(uuid, uuid),
  private.meet_media_visible_to(text, uuid),
  private.meet_upload_allowed(text, text),
  private.meet_erase_photo_files(uuid),
  private.meet_sweep_inbox(),
  private.meet_erase_profile(uuid),
  private.meet_media_ingested(text, uuid, text, text, text, integer, integer, text),
  private.meet_media_failed(text, uuid, text),
  public.gateway_meet_media_ingested(text, uuid, text, text, text, integer, integer, text),
  public.gateway_meet_media_failed(text, uuid, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  private.meet_media_visible_to(text, uuid),
  private.meet_upload_allowed(text, text)
TO authenticated;
GRANT EXECUTE ON FUNCTION
  public.gateway_meet_media_ingested(text, uuid, text, text, text, integer, integer, text),
  public.gateway_meet_media_failed(text, uuid, text)
TO service_role;
