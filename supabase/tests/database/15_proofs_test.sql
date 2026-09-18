-- Proofs and the marketplace buckets: who may submit, who may read, and the category rule that
-- decides when a job has shown enough (job lifecycle transition 15; RLS matrix §5 and §11).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(25);

INSERT INTO auth.users (id, phone) VALUES
  ('d1111111-1111-4111-8111-111111111111', '2348000000081'),   -- customer
  ('d2222222-2222-4222-8222-222222222222', '2348000000082'),   -- provider
  ('d3333333-3333-4333-8333-333333333333', '2348000000083');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'd1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'd2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'd3333333-3333-4333-8333-333333333333';
INSERT INTO public.provider_profiles (user_id) VALUES ('d2222222-2222-4222-8222-222222222222');

CREATE TEMP TABLE pf (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE pfp (name text PRIMARY KEY, pin text);
GRANT ALL ON pf, pfp TO authenticated, service_role;

-- The buckets the marketplace writes to exist, and neither is public.
SELECT is((SELECT count(*)::int FROM storage.buckets
           WHERE id IN ('request-media', 'job-proofs') AND NOT public), 2,
  'the request-media and job-proofs buckets exist, both private');

-- Shopping: a photo and a receipt, so the proof rule has something to say.
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pf VALUES ('r', public.create_request(
  'key-pf-create-req-0000000001', 'shopping', 'Buy provisions at Shoprite', 'Shoprite Lekki',
  'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM pf WHERE name = 'r'), 'key-pf-publish-0000000001');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pf VALUES ('o', public.create_offer(
  'key-pf-offer-p-000000000001', (SELECT id FROM pf WHERE name = 'r'), 900000, NULL));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-pf-accept-c-00000001', (SELECT id FROM pf WHERE name = 'o'));
RESET ROLE;
SELECT is(private.mark_paid_held((SELECT id FROM pf WHERE name = 'r')),
  'assigned'::public.job_status, 'the job is paid and assigned');
INSERT INTO pfp VALUES ('pickup', private.issue_pin((SELECT id FROM pf WHERE name = 'r'), 'pickup'));

-- ---------------------------------------------------------------------------
-- Proofs can only be submitted while the work is happening.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.submit_proof('key-pf-proof-early-000001', %L, 'photo', %L)$$,
    (SELECT id FROM pf WHERE name = 'r'),
    (SELECT id FROM pf WHERE name = 'r') || '/early.jpg'),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'nothing is proven before the work has started');

SELECT public.set_job_status('key-pf-enroute-p-0000001', (SELECT id FROM pf WHERE name = 'r'),
  'en_route');
SELECT public.set_job_status('key-pf-arrive-p-00000001', (SELECT id FROM pf WHERE name = 'r'),
  'arrived', NULL, 6.4460, 3.4751);
SELECT is((public.verify_pin('key-pf-pin-p-00000000001', (SELECT id FROM pf WHERE name = 'r'),
             (SELECT pin FROM pfp WHERE name = 'pickup')) ->> 'status'),
  'in_progress', 'the pickup PIN starts the work');

-- The folder is the request id, and a proof filed against another job is refused.
SELECT throws_ok(
  format($$SELECT public.submit_proof('key-pf-proof-wrong-000001', %L, 'photo', 'somewhere/else.jpg')$$,
    (SELECT id FROM pf WHERE name = 'r')),
  '22023', 'ERR_INVALID_ARGUMENT', 'a proof path outside the job''s own folder is refused');

SELECT throws_ok(
  format($$SELECT public.set_job_status('key-pf-complete-p-000001', %L, 'completed_by_provider')$$,
    (SELECT id FROM pf WHERE name = 'r')),
  'P0001', 'ERR_PROOF_REQUIRED', 'shopping is not done until there is a photo and a receipt');

INSERT INTO pf VALUES ('proof1', public.submit_proof(
  'key-pf-proof-photo-000001', (SELECT id FROM pf WHERE name = 'r'), 'photo',
  (SELECT id FROM pf WHERE name = 'r') || '/basket.jpg', now() - interval '2 minutes',
  6.4459, 3.4750));
SELECT ok((SELECT id FROM pf WHERE name = 'proof1') IS NOT NULL, 'the provider submits a photo');
SELECT is(
  public.submit_proof('key-pf-proof-photo-000001', (SELECT id FROM pf WHERE name = 'r'), 'photo',
    (SELECT id FROM pf WHERE name = 'r') || '/basket.jpg', now() - interval '2 minutes',
    6.4459, 3.4750),
  (SELECT id FROM pf WHERE name = 'proof1'), 'and a repeated key replays rather than duplicating');

SELECT throws_ok(
  format($$SELECT public.set_job_status('key-pf-complete-p-000002', %L, 'completed_by_provider')$$,
    (SELECT id FROM pf WHERE name = 'r')),
  'P0001', 'ERR_PROOF_REQUIRED', 'a photo alone is not the receipt shopping also needs');

SELECT public.submit_proof('key-pf-proof-receipt-00001', (SELECT id FROM pf WHERE name = 'r'),
  'receipt', (SELECT id FROM pf WHERE name = 'r') || '/receipt.pdf');
SELECT is(public.set_job_status('key-pf-complete-p-000003',
            (SELECT id FROM pf WHERE name = 'r'), 'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'with both, the work can be handed over');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.proofs
           WHERE request_id = (SELECT id FROM pf WHERE name = 'r')), 2,
  'both proofs are on the job');
SELECT ok((SELECT server_received_at IS NOT NULL AND device_captured_at < server_received_at
           FROM public.proofs WHERE id = (SELECT id FROM pf WHERE name = 'proof1')),
  'the server timestamp is its own, and the device time is kept beside it');
SELECT ok((SELECT device_point IS NOT NULL FROM public.proofs
           WHERE id = (SELECT id FROM pf WHERE name = 'proof1')),
  'the device position is recorded for the dispute file');
SELECT ok((SELECT display_path IS NULL FROM public.proofs
           WHERE id = (SELECT id FROM pf WHERE name = 'proof1')),
  'and there is no stripped rendition yet, because nothing makes one');

-- ---------------------------------------------------------------------------
-- Who can see them.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.proofs), 2, 'the customer sees the proofs on their job');
SELECT throws_ok(
  format($$SELECT public.submit_proof('key-pf-proof-cust-0000001', %L, 'photo', %L)$$,
    (SELECT id FROM pf WHERE name = 'r'),
    (SELECT id FROM pf WHERE name = 'r') || '/customer.jpg'),
  'P0001', 'ERR_JOB_NOT_FOUND', 'the customer does not submit the provider''s proof');
SELECT ok((SELECT private.is_job_participant((SELECT id FROM pf WHERE name = 'r'))),
  'the customer is a participant, which is what the storage policy asks');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "d3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.proofs), 0, 'a stranger sees none of them');
SELECT ok(NOT (SELECT private.is_job_participant((SELECT id FROM pf WHERE name = 'r'))),
  'and is not a participant, so the bucket will not serve them either');
SELECT ok(NOT (SELECT private.may_read_request_media(
            (SELECT id FROM pf WHERE name = 'r') || '/anything.jpg')),
  'nor may they read the request''s own media');
RESET ROLE;

SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM public.proofs$$,
  '42501', NULL, 'anon has no access to proofs at all');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A category with no proof requirement completes without one.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pf VALUES ('r2', public.create_request(
  'key-pf-create-req-0000000002', 'personal_assistance', 'Queue at the bank for me',
  'GTBank Admiralty', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM pf WHERE name = 'r2'), 'key-pf-publish-0000000002');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pf VALUES ('o2', public.create_offer(
  'key-pf-offer-p-000000000002', (SELECT id FROM pf WHERE name = 'r2'), 400000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "d1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-pf-accept-c-00000002', (SELECT id FROM pf WHERE name = 'o2'));
RESET ROLE;
SELECT is((SELECT proof_requirements FROM public.service_categories WHERE key = 'personal_assistance'),
  '{}'::jsonb, 'personal assistance asks for no proof');
SELECT is(private.mark_paid_held((SELECT id FROM pf WHERE name = 'r2')),
  'assigned'::public.job_status, 'the second job is assigned');
INSERT INTO pfp VALUES ('pickup2', private.issue_pin((SELECT id FROM pf WHERE name = 'r2'), 'pickup'));

SELECT set_config('request.jwt.claims',
  '{"sub": "d2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-pf-enroute-p-0000002', (SELECT id FROM pf WHERE name = 'r2'),
  'en_route');
SELECT public.set_job_status('key-pf-arrive-p-00000002', (SELECT id FROM pf WHERE name = 'r2'),
  'arrived', NULL, 6.4460, 3.4751);
SELECT public.verify_pin('key-pf-pin-p-00000000002', (SELECT id FROM pf WHERE name = 'r2'),
  (SELECT pin FROM pfp WHERE name = 'pickup2'));
SELECT is(public.set_job_status('key-pf-complete-p-000004',
            (SELECT id FROM pf WHERE name = 'r2'), 'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'and completes with none');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM pf WHERE name = 'r') AND reason_code = 'proof_submitted'),
  2, 'each proof is in the job history');

SELECT * FROM finish();
ROLLBACK;
