-- Phase 4, part 3: restricted items and moderation rules (ERD §1 and §8; ai-design §6 and §8;
-- country packs `restricted.*`; OD-21).
--
-- **The deterministic rules run first and the model cannot overrule them** (ai-design §8). That
-- ordering is the whole design: a keyword list is auditable, explainable and cheap, and a model
-- that disagrees with "no firearms" is wrong. The LLM pass comes later and may only *add* labels.
--
-- **Moderation never bans anyone** (ai-design §6). It labels, it can hold content back, and it
-- produces a queue item for a person to decide. Nothing here suspends an account.
--
-- **Fail open, per OD-21.** A request or a review publishes and enters the queue; a chat message
-- delivers. The only thing refused outright is a `block`-severity match — a listing for a gun is
-- not a moderation opinion, it is a thing we will not carry — and that refusal is deterministic,
-- so it can be explained to the person it happened to.
--
-- Evidence: every country pack tags `restricted: assumption`, so counsel has not signed these
-- lists off. Every rule below is `[A]`, and every one of them is data an operator can change
-- without a release.

CREATE TYPE public.moderation_action AS ENUM ('allow', 'hold', 'block');

CREATE TYPE public.moderation_category AS ENUM (
  'harassment', 'sexual', 'violence', 'restricted_item', 'off_platform_payment',
  'pii_exposure', 'spam');

-- ---------------------------------------------------------------------------
-- prohibited_items — the rule table. `country_code IS NULL` means everywhere.
--
-- The baseline is the union of the five country packs' `prohibited_items` and
-- `prohibited_services`, because nothing in that union is lawful in any of the five, and because
-- a global row keeps working when a sixth country opens before anyone remembers this table.
-- Country rows carry the genuinely local rules (Kenya's carrier bags, South Africa's licensed
-- hours, Nigeria's pre-registered SIMs).
-- ---------------------------------------------------------------------------
CREATE TABLE public.prohibited_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code char(2) REFERENCES public.countries (code),
  key          text NOT NULL CHECK (key ~ '^[a-z0-9_]{2,60}$'),
  kind         text NOT NULL DEFAULT 'item' CHECK (kind IN ('item', 'service')),
  -- Lower-case words or phrases. Constrained to letters, digits, spaces and hyphens so a term is
  -- never a regular expression: an operator editing this table cannot, by typing a bracket, turn
  -- one rule into a rule that matches everything.
  match_terms  text[] NOT NULL
               CHECK (cardinality(match_terms) > 0
                      AND array_to_string(match_terms, ' ') ~ '^[a-z0-9 -]+$'
                      AND NOT ('' = ANY (match_terms))),
  action       public.moderation_action NOT NULL DEFAULT 'block',
  active       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);
-- One rule per key per scope; `coalesce` because a unique index over a nullable column would let
-- the global row be inserted twice.
CREATE UNIQUE INDEX prohibited_items_scope
  ON public.prohibited_items (coalesce(country_code, '**'), key);
CREATE INDEX prohibited_items_lookup ON public.prohibited_items (country_code) WHERE active;

ALTER TABLE public.prohibited_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prohibited_items FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.prohibited_items FROM anon, authenticated;
GRANT SELECT ON public.prohibited_items TO authenticated;
GRANT ALL ON public.prohibited_items TO service_role;
-- What we will not carry is not a secret: a person is entitled to know before they type it, and
-- the apps show the list on the request screen.
CREATE POLICY prohibited_items_read ON public.prohibited_items FOR SELECT TO authenticated
  USING (active);

CREATE TYPE public.moderation_case_status AS ENUM ('open', 'upheld', 'overturned');

CREATE TABLE public.moderation_cases (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_kind text NOT NULL CHECK (subject_kind IN ('request', 'message', 'rating', 'profile')),
  subject_id   text NOT NULL,
  author_id    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  action       public.moderation_action NOT NULL,
  labels       jsonb NOT NULL DEFAULT '[]'::jsonb,
  source       text NOT NULL DEFAULT 'rules' CHECK (source IN ('rules', 'model', 'report')),
  status       public.moderation_case_status NOT NULL DEFAULT 'open',
  reviewer_id  uuid REFERENCES auth.users (id),
  reviewed_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX moderation_cases_queue ON public.moderation_cases (created_at)
  WHERE status = 'open';
CREATE INDEX moderation_cases_subject ON public.moderation_cases (subject_kind, subject_id);

ALTER TABLE public.moderation_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_cases FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderation_cases FROM anon, authenticated;
GRANT SELECT ON public.moderation_cases TO authenticated;
GRANT ALL ON public.moderation_cases TO service_role;
-- The author sees that their own content was held and why. Being moderated in silence is how
-- people conclude the app is broken.
CREATE POLICY moderation_cases_read ON public.moderation_cases FOR SELECT TO authenticated
  USING (author_id = (SELECT auth.uid())
         OR (SELECT private.has_admin_role(
               ARRAY['super_admin', 'support_agent']::public.admin_role[])));

-- ---------------------------------------------------------------------------
-- The rules themselves. Everything here is deterministic and explainable: a term from the
-- country pack, an off-platform payment pattern, a phone number in free text.
--
-- `block` is reserved for terms that cannot mean anything else. "stolen" is a `hold`, because
-- "my phone was stolen, please report it at the station" is an errand we want; "cocaine" is a
-- `block`, because it is not. Where a word is genuinely ambiguous — "gun" in "glue gun" — it is
-- left out entirely, and the later model pass can raise it as a label.
-- ---------------------------------------------------------------------------
CREATE FUNCTION private.moderate_text(p_text text, p_country char(2))
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
DECLARE
  v_text   text := lower(coalesce(p_text, ''));
  v_labels jsonb := '[]'::jsonb;
  v_action public.moderation_action := 'allow'::public.moderation_action;
  v_row    record;
BEGIN
  IF btrim(v_text) = '' THEN
    RETURN jsonb_build_object('action', 'allow', 'labels', v_labels);
  END IF;

  -- Restricted items and services: the global baseline plus this country's own rules.
  FOR v_row IN
    SELECT p.key, p.action, p.match_terms FROM public.prohibited_items p
    WHERE p.active AND (p.country_code IS NULL OR p.country_code = p_country)
    ORDER BY p.key
  LOOP
    IF EXISTS (
      SELECT 1 FROM unnest(v_row.match_terms) AS term
      -- Word boundary on both sides: "arms" must not fire on "warmers". `term` is safe to
      -- interpolate because the column's CHECK admits no regular-expression metacharacter.
      WHERE v_text ~ ('(^|[^a-z0-9])' || term || '([^a-z0-9]|$)')
    ) THEN
      v_labels := v_labels || jsonb_build_object(
        'category', 'restricted_item', 'rule_key', v_row.key,
        'severity', CASE WHEN v_row.action = 'block' THEN 3 ELSE 2 END);
      IF v_row.action = 'block' THEN
        v_action := 'block';
      ELSIF v_action <> 'block' THEN
        v_action := 'hold';
      END IF;
    END IF;
  END LOOP;

  -- Taking the job off the platform: the pattern the spec calls out (ai-design §8). Held, not
  -- blocked — "pay me in cash" is sometimes an innocent sentence, and a person should decide.
  IF v_text ~ '(pay|send|transfer)[^.]{0,30}(outside|off)[ -]?(the )?(app|platform)'
     OR v_text ~ '(cancel|close)[^.]{0,30}(the )?(job|request)[^.]{0,30}(pay|cash|transfer)'
     OR v_text ~ '(bank|account)[ -]?(number|details)[^.]{0,20}(send|give|share)' THEN
    v_labels := v_labels || jsonb_build_object(
      'category', 'off_platform_payment', 'rule_key', 'off_platform_payment', 'severity', 2);
    IF v_action <> 'block' THEN v_action := 'hold'; END IF;
  END IF;

  -- A phone number or an email address typed into free text, which is how two people leave the
  -- platform and lose every protection it gives them. Nine consecutive digits rather than a
  -- looser pattern, so a price or a date does not trip it.
  IF v_text ~ '[0-9]{9,}'
     OR v_text ~ '\+[0-9]{1,3}[0-9 -]{7,}'
     OR v_text ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' THEN
    v_labels := v_labels || jsonb_build_object(
      'category', 'pii_exposure', 'rule_key', 'contact_in_text', 'severity', 1);
    IF v_action = 'allow' THEN v_action := 'hold'; END IF;
  END IF;

  RETURN jsonb_build_object('action', v_action, 'labels', v_labels);
END $$;

CREATE FUNCTION private.open_moderation_case(
  p_subject_kind text, p_subject_id text, p_author uuid, p_verdict jsonb,
  p_source text DEFAULT 'rules')
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.moderation_cases (subject_kind, subject_id, author_id, action, labels, source)
  VALUES (p_subject_kind, p_subject_id, p_author,
          (p_verdict ->> 'action')::public.moderation_action,
          coalesce(p_verdict -> 'labels', '[]'::jsonb), p_source)
  RETURNING id INTO v_id;

  PERFORM private.emit_event('moderation', v_id::text, 'moderation.case_opened',
    jsonb_build_object('case_id', v_id, 'subject_kind', p_subject_kind,
                       'subject_id', p_subject_id, 'author_id', p_author,
                       'action', p_verdict ->> 'action', 'labels', p_verdict -> 'labels'));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Where the rules bite. Triggers, so every path into these tables is covered — including the
-- ones written after this migration.
-- ---------------------------------------------------------------------------
ALTER TABLE public.requests
  ADD COLUMN moderation_status public.moderation_status NOT NULL DEFAULT 'pending',
  ADD COLUMN moderation_flags text[] NOT NULL DEFAULT '{}'::text[];

CREATE FUNCTION private.requests_moderate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_verdict jsonb;
  v_action  public.moderation_action;
BEGIN
  v_verdict := private.moderate_text(
    coalesce(NEW.description, '') || ' ' || coalesce(NEW.custom_category_label, ''),
    NEW.country_code);
  v_action := (v_verdict ->> 'action')::public.moderation_action;

  IF v_action = 'block' THEN
    -- The one deterministic refusal: we do not carry this, and the person is told which rule, so
    -- the screen can name it rather than saying "something went wrong".
    RAISE EXCEPTION 'ERR_CONTENT_NOT_ALLOWED' USING ERRCODE = 'P0001',
      DETAIL = coalesce(v_verdict -> 'labels' -> 0 ->> 'rule_key', 'restricted');
  END IF;

  IF v_action = 'hold' THEN
    -- OD-21 fail-open: it publishes, and a person looks at it afterwards.
    NEW.moderation_flags := ARRAY(SELECT l ->> 'rule_key'
                            FROM jsonb_array_elements(v_verdict -> 'labels') AS l);
    PERFORM private.open_moderation_case('request', NEW.id::text, NEW.customer_id, v_verdict);
  ELSE
    NEW.moderation_status := 'approved';
  END IF;
  RETURN NEW;
END $$;

-- Named to sort before the other BEFORE triggers on this table, so a refused request is refused
-- before anything else has had a chance to act on it.
CREATE TRIGGER requests_moderate BEFORE UPDATE OF status ON public.requests
  FOR EACH ROW
  WHEN (NEW.status = 'published' AND OLD.status = 'draft')
  EXECUTE FUNCTION private.requests_moderate();

CREATE FUNCTION private.messages_moderate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
  v_verdict jsonb;
BEGIN
  IF NEW.body IS NULL OR btrim(NEW.body) = '' THEN
    RETURN NEW;
  END IF;
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = NEW.sender_id;

  v_verdict := private.moderate_text(NEW.body, v_country);
  IF (v_verdict ->> 'action') = 'allow' THEN
    RETURN NEW;
  END IF;

  -- Chat always delivers (OD-21). Even a blocked term becomes a held message rather than a
  -- swallowed one: two people mid-job need to keep talking, and a message that vanishes without
  -- explanation is worse than one a reviewer removes afterwards.
  NEW.moderation_flags := ARRAY(SELECT l ->> 'rule_key'
                            FROM jsonb_array_elements(v_verdict -> 'labels') AS l);
  PERFORM private.open_moderation_case('message', NEW.id::text, NEW.sender_id, v_verdict);
  RETURN NEW;
END $$;

CREATE TRIGGER messages_moderate BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION private.messages_moderate();

CREATE FUNCTION private.ratings_moderate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country char(2);
  v_verdict jsonb;
BEGIN
  IF NEW.comment IS NULL OR btrim(NEW.comment) = '' THEN
    RETURN NEW;
  END IF;
  SELECT p.country_code INTO v_country FROM public.profiles p WHERE p.user_id = NEW.rater_id;

  v_verdict := private.moderate_text(NEW.comment, v_country);
  IF (v_verdict ->> 'action') <> 'allow' THEN
    NEW.moderation_flags := ARRAY(SELECT l ->> 'rule_key'
                            FROM jsonb_array_elements(v_verdict -> 'labels') AS l);
    PERFORM private.open_moderation_case('rating', NEW.id::text, NEW.rater_id, v_verdict);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER ratings_moderate BEFORE INSERT ON public.ratings
  FOR EACH ROW EXECUTE FUNCTION private.ratings_moderate();

-- ---------------------------------------------------------------------------
-- The queue, and the decision. A reviewer upholds a hold (the content comes down) or overturns
-- it (the content stands) — and neither action touches the account.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.moderation_queue(p_limit integer DEFAULT 50)
RETURNS SETOF public.moderation_cases
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM public.moderation_cases c WHERE c.status = 'open'
  ORDER BY c.created_at
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
END $$;

CREATE FUNCTION public.decide_moderation_case(
  p_idempotency_key text, p_case_id uuid, p_uphold boolean)
RETURNS public.moderation_case_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := private.require_user();
  v_claim  jsonb;
  v_case   public.moderation_cases%ROWTYPE;
  v_status public.moderation_case_status;
  v_new    public.moderation_status;
BEGIN
  IF NOT private.has_admin_role(ARRAY['super_admin', 'support_agent']::public.admin_role[]) THEN
    RAISE EXCEPTION 'ERR_PERMISSION_DENIED' USING ERRCODE = '42501';
  END IF;

  v_claim := private.idempotency_claim(v_uid, p_idempotency_key, 'decide_moderation_case',
    jsonb_build_object('case_id', p_case_id, 'uphold', p_uphold));
  IF v_claim IS NOT NULL THEN
    RETURN (v_claim ->> 'status')::public.moderation_case_status;
  END IF;

  SELECT * INTO v_case FROM public.moderation_cases c WHERE c.id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ERR_MODERATION_CASE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_case.status <> 'open' THEN
    RAISE EXCEPTION 'ERR_ILLEGAL_TRANSITION' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE WHEN p_uphold THEN 'upheld' ELSE 'overturned' END::public.moderation_case_status;
  v_new := CASE WHEN p_uphold THEN 'rejected' ELSE 'approved' END::public.moderation_status;

  UPDATE public.moderation_cases c
  SET status = v_status, reviewer_id = v_uid, reviewed_at = now()
  WHERE c.id = p_case_id;

  IF v_case.subject_kind = 'message' THEN
    UPDATE public.messages m SET moderation_status = v_new
    WHERE m.id = v_case.subject_id::bigint;
  ELSIF v_case.subject_kind = 'rating' THEN
    UPDATE public.ratings r SET moderation_status = v_new WHERE r.id = v_case.subject_id::uuid;
  ELSIF v_case.subject_kind = 'request' THEN
    UPDATE public.requests r SET moderation_status = v_new WHERE r.id = v_case.subject_id::uuid;
    -- A rejected request has to leave the market, not merely carry a flag: the feed and the
    -- matcher read `status`, and a reviewer who takes content down expects it gone. Only while
    -- nobody has agreed to it — once there is a job and money behind it, taking it down is a
    -- dispute (Phase 5), not a moderation decision.
    IF p_uphold THEN
      UPDATE public.requests r
      SET status = 'cancelled', cancelled_at = now(),
          cancellation_reason_code = 'moderation_upheld', version = r.version + 1
      WHERE r.id = v_case.subject_id::uuid
        AND r.status IN ('draft', 'published', 'offers_received', 'negotiating');
    END IF;
  END IF;

  -- The author is told either way. A hold that is overturned is worth knowing about too: it is
  -- the difference between "the app is broken" and "somebody looked at it".
  IF v_case.author_id IS NOT NULL THEN
    PERFORM private.notify(v_case.author_id, 'system',
      'notification.moderation.title',
      CASE WHEN p_uphold THEN 'notification.moderation.upheld'
           ELSE 'notification.moderation.overturned' END,
      jsonb_build_object('case_id', p_case_id, 'subject_kind', v_case.subject_kind,
                         'rule_keys', ARRAY(SELECT l ->> 'rule_key'
                                            FROM jsonb_array_elements(v_case.labels) AS l)));
  END IF;

  PERFORM private.audit_write('moderation.decide', 'public.moderation_cases', p_case_id::text,
    jsonb_build_object('status', v_case.status), jsonb_build_object('status', v_status), NULL);
  PERFORM private.emit_event('moderation', p_case_id::text, 'moderation.decided',
    jsonb_build_object('case_id', p_case_id, 'status', v_status, 'by', v_uid));
  PERFORM private.idempotency_complete(v_uid, p_idempotency_key,
    jsonb_build_object('status', v_status));
  RETURN v_status;
END $$;

REVOKE ALL ON FUNCTION
  public.moderation_queue(integer),
  public.decide_moderation_case(text, uuid, boolean),
  private.moderate_text(text, char),
  private.open_moderation_case(text, text, uuid, jsonb, text),
  private.requests_moderate(),
  private.messages_moderate(),
  private.ratings_moderate()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.moderation_queue(integer),
  public.decide_moderation_case(text, uuid, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- The baseline rules. Reference data, not seed data: an empty rule table moderates nothing, and
-- a production database that moderates nothing is the failure this migration exists to prevent.
-- All `[A]` until counsel signs the country packs' `restricted` sections off; all editable by an
-- operator without a release.
-- ---------------------------------------------------------------------------
INSERT INTO public.prohibited_items (country_code, key, kind, match_terms, action) VALUES
  (NULL, 'firearms_ammunition', 'item',
   ARRAY['firearm', 'firearms', 'handgun', 'pistol', 'rifle', 'shotgun', 'ammunition',
         'ammo', 'ak47', 'ak-47', 'live rounds'], 'block'),
  (NULL, 'explosives', 'item',
   ARRAY['explosive', 'explosives', 'dynamite', 'grenade', 'detonator', 'blasting cap'], 'block'),
  (NULL, 'illegal_drugs', 'item',
   ARRAY['cocaine', 'heroin', 'methamphetamine', 'marijuana', 'cannabis', 'mkpuru mmiri'],
   'block'),
  (NULL, 'prescription_drugs_without_prescription', 'item',
   ARRAY['without prescription', 'no prescription', 'tramadol', 'codeine syrup'], 'hold'),
  (NULL, 'age_restricted_to_minors', 'item',
   ARRAY['underage', 'for a minor', 'to a minor', 'minors'], 'hold'),
  (NULL, 'counterfeit_goods', 'item',
   ARRAY['counterfeit', 'fake designer', 'replica watch', 'first copy'], 'hold'),
  -- "stolen" is a hold, not a block: reporting a stolen phone at the station is an errand.
  (NULL, 'stolen_goods', 'item', ARRAY['stolen'], 'hold'),
  (NULL, 'cash_courier', 'item',
   ARRAY['cash courier', 'carry cash', 'deliver cash', 'bag of cash', 'foreign currency',
         'bureau de change'], 'hold'),
  (NULL, 'hazardous_chemicals', 'item',
   ARRAY['cyanide', 'mercury', 'sulphuric acid', 'hydrochloric acid', 'corrosive'], 'hold'),
  (NULL, 'human_remains', 'item',
   ARRAY['human remains', 'corpse', 'dead body', 'cadaver'], 'block'),
  (NULL, 'wildlife_products', 'item',
   ARRAY['ivory', 'pangolin', 'rhino horn', 'elephant tusk'], 'block'),
  (NULL, 'live_wild_animals', 'item',
   ARRAY['wild animal', 'wild animals', 'bush meat', 'bushmeat'], 'hold'),
  (NULL, 'identity_document_trade', 'item',
   ARRAY['buy nin', 'sell nin', 'buy bvn', 'sell bvn', 'buy national id', 'sell national id',
         'sell voters card', 'buy ghana card', 'sell ghana card'], 'block'),
  (NULL, 'debt_collection_by_force', 'service',
   ARRAY['debt collection', 'collect a debt', 'force him to pay', 'force her to pay'], 'hold'),
  (NULL, 'sex_work', 'service',
   ARRAY['sex work', 'prostitute', 'prostitution', 'sexual services', 'commercial sex'], 'block'),
  (NULL, 'betting_agents', 'service',
   ARRAY['place a bet', 'betting agent', 'gambling agent', 'stake a bet'], 'hold'),
  (NULL, 'exam_impersonation', 'service',
   ARRAY['write my exam', 'sit my exam', 'write the exam for me', 'exam impersonation',
         'take my test for me'], 'block'),
  (NULL, 'document_forgery', 'service',
   ARRAY['forged', 'forgery', 'fake certificate', 'fake passport', 'fake receipt', 'fake id'],
   'block'),
  (NULL, 'unlicensed_medical_procedures', 'service',
   ARRAY['unlicensed clinic', 'backstreet clinic', 'unlicensed doctor', 'unlicensed nurse'],
   'hold'),
  (NULL, 'armed_security_services', 'service',
   ARRAY['armed escort', 'armed guard', 'armed security', 'come with a weapon'], 'block');

-- Country rules are *not* here. A country row does not exist until its pack is approved — the
-- `countries` table is empty at migration time — so a country's own restrictions (Kenya's
-- carrier bags, South Africa's licensed hours, Nigeria's pre-registered SIMs) arrive with that
-- approval, alongside its currency and cities. The dev seed carries the five we have researched.
-- The global baseline above applies to every country from the moment it opens.
