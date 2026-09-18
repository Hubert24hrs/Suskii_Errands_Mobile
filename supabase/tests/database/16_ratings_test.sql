-- Ratings, the blind period and the reputation job (PRD SH-30, SH-31; ERD §3 and §5).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(32);

INSERT INTO auth.users (id, phone) VALUES
  ('e1111111-1111-4111-8111-111111111111', '2348000000091'),   -- customer
  ('e2222222-2222-4222-8222-222222222222', '2348000000092'),   -- provider
  ('e3333333-3333-4333-8333-333333333333', '2348000000093');   -- a bystander
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'e1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'e2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'e3333333-3333-4333-8333-333333333333';
INSERT INTO public.provider_profiles (user_id) VALUES ('e2222222-2222-4222-8222-222222222222');

CREATE TEMP TABLE rt (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE rtp (name text PRIMARY KEY, pin text);
GRANT ALL ON rt, rtp TO authenticated, service_role;

-- A job taken all the way to confirmed, which is where rating becomes possible.
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rt VALUES ('r', public.create_request(
  'key-rt-create-req-0000000001', 'personal_assistance', 'Queue at the bank for me',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM rt WHERE name = 'r'), 'key-rt-publish-0000000001');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rt VALUES ('o', public.create_offer(
  'key-rt-offer-p-000000000001', (SELECT id FROM rt WHERE name = 'r'), 500000, NULL));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-rt-accept-c-00000001', (SELECT id FROM rt WHERE name = 'o'));
-- Rating before the work is done is refused.
SELECT throws_ok(
  format($$SELECT public.rate_job('key-rt-rate-early-000001', %L, 5::smallint)$$,
    (SELECT id FROM rt WHERE name = 'r')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'nobody rates a job that has not happened');
RESET ROLE;

SELECT private.mark_paid_held((SELECT id FROM rt WHERE name = 'r'));
INSERT INTO rtp VALUES ('pickup', private.issue_pin((SELECT id FROM rt WHERE name = 'r'), 'pickup'));

SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-rt-enroute-p-0000001', (SELECT id FROM rt WHERE name = 'r'),
  'en_route');
SELECT public.set_job_status('key-rt-arrive-p-00000001', (SELECT id FROM rt WHERE name = 'r'),
  'arrived', NULL, 6.4460, 3.4751);
SELECT public.verify_pin('key-rt-pin-p-00000000001', (SELECT id FROM rt WHERE name = 'r'),
  (SELECT pin FROM rtp WHERE name = 'pickup'));
SELECT public.set_job_status('key-rt-complete-p-000001', (SELECT id FROM rt WHERE name = 'r'),
  'completed_by_provider');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.confirm_completion('key-rt-confirm-c-0000001', (SELECT id FROM rt WHERE name = 'r'));

-- ---------------------------------------------------------------------------
-- The customer rates first.
-- ---------------------------------------------------------------------------
INSERT INTO rt VALUES ('rate_c', public.rate_job('key-rt-rate-c-00000000001',
  (SELECT id FROM rt WHERE name = 'r'), 5::smallint, ARRAY['on_time', 'polite'],
  'Waited two hours and kept me posted.'));
SELECT ok((SELECT id FROM rt WHERE name = 'rate_c') IS NOT NULL, 'the customer rates the provider');
SELECT is((SELECT direction FROM public.ratings WHERE id = (SELECT id FROM rt WHERE name = 'rate_c')),
  'customer_to_provider'::public.rating_direction, 'the direction follows from who called');
SELECT is((SELECT ratee_id FROM public.ratings WHERE id = (SELECT id FROM rt WHERE name = 'rate_c')),
  'e2222222-2222-4222-8222-222222222222'::uuid, 'and so does who it is about');
SELECT ok((SELECT visible_at IS NULL FROM public.ratings
           WHERE id = (SELECT id FROM rt WHERE name = 'rate_c')),
  'it is not visible yet: the other side has not rated');
SELECT is(
  public.rate_job('key-rt-rate-c-00000000001', (SELECT id FROM rt WHERE name = 'r'), 5::smallint,
    ARRAY['on_time', 'polite'], 'Waited two hours and kept me posted.'),
  (SELECT id FROM rt WHERE name = 'rate_c'), 'a repeated key replays the first rating');
SELECT throws_ok(
  format($$SELECT public.rate_job('key-rt-rate-c-00000000002', %L, 4::smallint)$$,
    (SELECT id FROM rt WHERE name = 'r')),
  '23505', NULL, 'and a second rating on the same job is refused outright');
SELECT throws_ok(
  format($$SELECT public.rate_job('key-rt-rate-c-00000000003', %L, 9::smallint)$$,
    (SELECT id FROM rt WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'nine stars is not a rating');
RESET ROLE;

-- The provider cannot see it while the blind period holds.
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.ratings), 0,
  'the rated provider sees nothing until they have rated too — otherwise the second rating is a reply');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.ratings), 0, 'and a bystander sees nothing either');
RESET ROLE;

-- The reputation job ignores what is still blind.
SELECT is(private.recompute_reputation_all(), 1, 'the reputation job runs over the provider');
SELECT is((SELECT rating_count FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 0,
  'a rating inside its blind period does not count yet: the average would leak it');

-- ---------------------------------------------------------------------------
-- The provider rates back, which opens both.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rt VALUES ('rate_p', public.rate_job('key-rt-rate-p-00000000001',
  (SELECT id FROM rt WHERE name = 'r'), 4::smallint, ARRAY['clear_instructions'], NULL));
SELECT is((SELECT count(*)::int FROM public.ratings), 2,
  'once both have rated, both are visible');
SELECT is((SELECT stars FROM public.ratings WHERE id = (SELECT id FROM rt WHERE name = 'rate_c')),
  5::smallint, 'and the provider can read what was said about them');
RESET ROLE;

SELECT ok((SELECT visible_at IS NOT NULL FROM public.ratings
           WHERE id = (SELECT id FROM rt WHERE name = 'rate_c')),
  'the blind period ended for the first rating too, at the same moment');

SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.ratings), 2,
  'a published rating is public: that is what makes a reputation checkable');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Reputation: Bayesian smoothing, not an average.
-- ---------------------------------------------------------------------------
SELECT is(private.recompute_reputation_all(), 1, 'the job recomputes');
SELECT is((SELECT rating_count FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 1,
  'now the rating counts');
-- (10 × 4500 + 5 × 1000) / 11 = 4545: five stars once, not five stars overall.
SELECT is((SELECT rating_avg_milli FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 4545,
  'one five-star job moves a new provider from 4.500 to 4.545, not to 5.000');
SELECT is((SELECT completion_rate_bps FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 10000,
  'the job they finished counts as finished');
SELECT is((SELECT cancellation_rate_bps FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 0,
  'and nothing was cancelled');
SELECT ok((SELECT response_time_p50_s IS NOT NULL FROM public.provider_profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'),
  'their answering speed is measured from publication to their first offer');
SELECT is((SELECT trust_level FROM public.profiles
           WHERE user_id = 'e2222222-2222-4222-8222-222222222222'), 'new'::public.trust_level,
  'trust level is untouched: SH-31 ties it to address verification, which does not exist yet');

-- A rating nobody answered opens when the window closes.
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.ratings WHERE visible_at IS NULL), 0,
  'nothing is left blind on this job');
RESET ROLE;
UPDATE public.ratings SET visible_at = NULL WHERE request_id = (SELECT id FROM rt WHERE name = 'r');
SELECT is(private.close_rating_windows(), 0,
  'the window job leaves a fresh rating alone');
UPDATE public.jobs SET confirmed_at = now() - interval '8 days'
WHERE request_id = (SELECT id FROM rt WHERE name = 'r');
SELECT is(private.close_rating_windows(), 2,
  'and opens them once the window has passed');

-- Rating after the window is refused.
DELETE FROM public.ratings WHERE rater_id = 'e1111111-1111-4111-8111-111111111111';
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.rate_job('key-rt-rate-late-0000001', %L, 3::smallint)$$,
    (SELECT id FROM rt WHERE name = 'r')),
  'P0001', 'ERR_RATING_WINDOW_CLOSED', 'a rating eight days later is too late');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The feed card carries an area, not an address (PR-11).
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "e1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO rt VALUES ('r2', public.create_request(
  'key-rt-create-req-0000000002', 'errands_delivery', 'Collect a parcel', '14 Bode Thomas Street',
  'standard', false, NULL, NULL, 6.4459, 3.4750, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  'lagos', 'app', ARRAY['e1111111-1111-4111-8111-111111111111/parcel.jpg']));
SELECT public.publish_request((SELECT id FROM rt WHERE name = 'r2'), 'key-rt-publish-0000000002');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.update_provider_services(ARRAY['errands_delivery']);
SELECT public.set_online(true);
SELECT public.heartbeat(6.4470, 3.4760);
SELECT is((SELECT pickup_area FROM public.provider_feed() WHERE request_id = (SELECT id FROM rt WHERE name = 'r2')),
  'Lagos', 'the card names the city, not the street the customer typed');
SELECT ok((SELECT round(pickup_approx_lat::numeric, 2) FROM public.provider_feed()
           WHERE request_id = (SELECT id FROM rt WHERE name = 'r2')) = 6.45,
  'and the point is rounded to about a kilometre');
SELECT is((SELECT array_length(media_paths, 1) FROM public.provider_feed()
           WHERE request_id = (SELECT id FROM rt WHERE name = 'r2')), 1,
  'the photos are on the card, as PR-11 asks');
SELECT ok((SELECT private.may_read_request_media('e1111111-1111-4111-8111-111111111111/parcel.jpg')),
  'and a provider who could take the job may fetch them');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "e3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT ok(NOT (SELECT private.may_read_request_media('e1111111-1111-4111-8111-111111111111/parcel.jpg')),
  'somebody who is not a provider at all may not');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
