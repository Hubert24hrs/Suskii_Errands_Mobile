-- Requests: drafts belong to their owner, only a verified customer publishes, state changes go
-- through functions, and a provider cannot enumerate the market (RLS matrix §5).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(26);

INSERT INTO auth.users (id, phone) VALUES
  ('f1111111-1111-4111-8111-111111111111', '2348000000041'),
  ('f2222222-2222-4222-8222-222222222222', '2348000000042');
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'f1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'unverified'
WHERE user_id = 'f2222222-2222-4222-8222-222222222222';

SELECT ok((SELECT count(*) FROM public.service_categories WHERE active) >= 5,
  'the seeded taxonomy is there');

-- The catalogue is readable before sign-in: the request screen renders it.
SET LOCAL ROLE anon;
SELECT ok((SELECT count(*) FROM public.service_categories) > 0, 'anon reads the category list');
SELECT throws_ok($$SELECT count(*) FROM public.requests$$,
  '42501', NULL, 'anon has no access to requests at all, not even an empty read');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE r (id uuid);
GRANT ALL ON r TO authenticated, service_role;
INSERT INTO r SELECT public.create_request(
  'key-create-0000000000000001', 'errands_delivery', 'Collect a parcel from Yaba market',
  'Yaba market stall 14', 'standard', false, NULL, 'Blue gate',
  6.5095, 3.3711, 'Admiralty Way, Lekki', NULL, 6.4459, 3.4750,
  NULL, 500000, NULL, NULL, NULL, 'app', ARRAY['f1111111-1111-4111-8111-111111111111/parcel.jpg']);

SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM r)), 'draft'::public.job_status,
  'a new request starts as a draft, never published');
SELECT is((SELECT currency FROM public.requests WHERE id = (SELECT id FROM r)), 'NGN'::char(3),
  'the currency comes from the country, not the client');
SELECT is((SELECT country_code FROM public.requests WHERE id = (SELECT id FROM r)), 'NG'::char(2),
  'the country comes from the profile');
SELECT ok((SELECT pickup_point IS NOT NULL FROM public.requests WHERE id = (SELECT id FROM r)),
  'the pickup point is stored as geography');
SELECT is((SELECT count(*)::int FROM public.request_media WHERE request_id = (SELECT id FROM r)), 1,
  'media paths are attached to the request');

-- Idempotency: the same key returns the same request instead of creating a second one.
SELECT is(
  public.create_request('key-create-0000000000000001', 'errands_delivery',
    'Collect a parcel from Yaba market', 'Yaba market stall 14', 'standard', false, NULL,
    'Blue gate', 6.5095, 3.3711, 'Admiralty Way, Lekki', NULL, 6.4459, 3.4750,
    NULL, 500000, NULL, NULL, NULL, 'app', ARRAY['f1111111-1111-4111-8111-111111111111/parcel.jpg']),
  (SELECT id FROM r), 'a repeated key replays the first request');
SELECT is((SELECT count(*)::int FROM public.requests), 1, 'and creates nothing new');

SELECT throws_ok(
  $$SELECT public.create_request('key-create-0000000000000002', 'no_such_category', 'x', 'y')$$,
  'P0001', 'ERR_CATEGORY_NOT_FOUND', 'an unknown category is refused');

-- Draft edits: the allowed columns only, and only while it is a draft.
UPDATE public.requests SET description = 'Collect two parcels from Yaba market'
WHERE id = (SELECT id FROM r);
SELECT is((SELECT description FROM public.requests WHERE id = (SELECT id FROM r)),
  'Collect two parcels from Yaba market', 'a customer edits their own draft');
SELECT throws_ok(
  format($$UPDATE public.requests SET status = 'published' WHERE id = %L$$, (SELECT id FROM r)),
  '42501', NULL, 'a customer cannot write status directly');
SELECT throws_ok(
  format($$UPDATE public.requests SET customer_id = 'f2222222-2222-4222-8222-222222222222' WHERE id = %L$$,
    (SELECT id FROM r)),
  '42501', NULL, 'a customer cannot hand their request to someone else');

SELECT is(public.publish_request((SELECT id FROM r), 'key-publish-000000000000001'),
  'published'::public.job_status, 'a verified customer publishes their draft');
SELECT ok((SELECT expires_at IS NOT NULL FROM public.requests WHERE id = (SELECT id FROM r)),
  'publishing starts the request TTL');
SELECT is(public.publish_request((SELECT id FROM r), 'key-publish-000000000000001'),
  'published'::public.job_status, 'publishing twice with one key replays');
SELECT throws_ok(
  format($$SELECT public.publish_request(%L, 'key-publish-000000000000002')$$, (SELECT id FROM r)),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a published request cannot be published again');
-- Once published the row falls outside the update policy, so the statement matches nothing:
-- Postgres filters it silently rather than raising, and the description stands.
UPDATE public.requests SET description = 'after publishing' WHERE id = (SELECT id FROM r);
SELECT is((SELECT description FROM public.requests WHERE id = (SELECT id FROM r)),
  'Collect two parcels from Yaba market', 'edits stop when the draft is published');
RESET ROLE;

-- Another signed-in user sees nothing of it, and cannot act on it.
SELECT set_config('request.jwt.claims',
  '{"sub": "f2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.requests), 0,
  'another user cannot read, or enumerate, anyone else''s requests');
SELECT throws_ok(
  format($$SELECT public.cancel_request(%L, 'key-cancel-0000000000000001')$$, (SELECT id FROM r)),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'another user cannot cancel it');

-- An unverified customer may draft, but not publish.
CREATE TEMP TABLE r2 (id uuid);
GRANT ALL ON r2 TO authenticated, service_role;
INSERT INTO r2 SELECT public.create_request(
  'key-create-0000000000000003', 'document_delivery', 'Take documents to Ikoyi', 'Home');
SELECT throws_ok(
  format($$SELECT public.publish_request(%L, 'key-publish-000000000000003')$$, (SELECT id FROM r2)),
  'P0001', 'ERR_VERIFICATION_REQUIRED', 'an unverified customer cannot publish');
RESET ROLE;

-- Cancellation and expiry.
SELECT set_config('request.jwt.claims',
  '{"sub": "f1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.cancel_request((SELECT id FROM r), 'key-cancel-0000000000000002', 'changed_mind'),
  'cancelled'::public.job_status, 'a customer cancels a published request');
SELECT throws_ok(
  format($$SELECT public.cancel_request(%L, 'key-cancel-0000000000000003')$$, (SELECT id FROM r)),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a cancelled request cannot be cancelled again');
RESET ROLE;

UPDATE public.requests SET status = 'published', expires_at = now() - interval '1 minute'
WHERE id = (SELECT id FROM r);
SELECT is(private.expire_requests(), 1, 'the expiry job closes a request nobody took');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM r)), 'expired'::public.job_status,
  'and marks it expired');

SELECT * FROM finish();
ROLLBACK;
