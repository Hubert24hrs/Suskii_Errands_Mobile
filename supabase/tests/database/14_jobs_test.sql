-- The job lifecycle: the transitions that exist before money does, the PINs, and the
-- append-only history (job lifecycle state machine; RLS matrix §5).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(46);

INSERT INTO auth.users (id, phone) VALUES
  ('c1111111-1111-4111-8111-111111111111', '2348000000071'),   -- customer
  ('c2222222-2222-4222-8222-222222222222', '2348000000072'),   -- provider
  ('c3333333-3333-4333-8333-333333333333', '2348000000073');   -- a stranger
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id = 'c1111111-1111-4111-8111-111111111111';
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'c2222222-2222-4222-8222-222222222222';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id = 'c3333333-3333-4333-8333-333333333333';
INSERT INTO public.provider_profiles (user_id) VALUES ('c2222222-2222-4222-8222-222222222222');

CREATE TEMP TABLE jids (name text PRIMARY KEY, id uuid);
CREATE TEMP TABLE pins (name text PRIMARY KEY, pin text);
GRANT ALL ON jids, pins TO authenticated, service_role;

-- A request with a destination: that is what makes it a delivery, and a delivery ends with a PIN.
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('r', public.create_request(
  'key-j-create-req-00000000001', 'errands_delivery', 'Take a parcel to Ikoyi',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750, 'Awolowo Road', NULL,
  6.4531, 3.4356));
SELECT public.publish_request((SELECT id FROM jids WHERE name = 'r'), 'key-j-publish-000000000001');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('o', public.create_offer(
  'key-j-offer-p-00000000000001', (SELECT id FROM jids WHERE name = 'r'), 800000, NULL));
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Acceptance creates the job.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_offer('key-j-accept-c-0000000001', (SELECT id FROM jids WHERE name = 'o')),
  'agreed'::public.job_status, 'accepting the offer agrees the job');
SELECT is((SELECT agreed_amount_minor FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')), 800000::bigint,
  'the job carries the amount that was agreed');
SELECT ok((SELECT delivery_pin_required FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')),
  'a job with a destination needs a delivery PIN');
SELECT ok((SELECT commission_minor IS NULL AND net_minor IS NULL FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')),
  'and no money snapshot yet: that waits for the commission rate (OD-06)');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r') AND to_status = 'agreed'), 1,
  'the history records the agreement');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c3333333-3333-4333-8333-333333333333", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.jobs), 0, 'a stranger sees no jobs');
SELECT is((SELECT count(*)::int FROM public.job_events), 0, 'and none of the history');
RESET ROLE;

-- A client cannot reach the payment seam, whatever it knows.
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT private.mark_paid_held(%L)$$, (SELECT id FROM jids WHERE name = 'r')),
  '42501', NULL, 'no client may move a job into paid_held: that is the webhook''s job alone');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The payment seam, then the provider's own transitions.
-- ---------------------------------------------------------------------------
SELECT is(private.mark_paid_held((SELECT id FROM jids WHERE name = 'r')),
  'assigned'::public.job_status, 'a confirmed payment holds the funds and assigns the provider');
SELECT ok((SELECT assigned_at IS NOT NULL FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')), 'the job is timestamped');
SELECT is((SELECT count(*)::int FROM private.job_pins
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')), 2,
  'both PINs exist from assignment');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')
             AND to_status IN ('paid_held', 'assigned')), 2,
  'and both transitions are in the history');

SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.set_job_status('key-j-skip-p-000000000001', %L, 'arrived')$$,
    (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_ILLEGAL_TRANSITION', 'a provider cannot arrive before setting off');
SELECT is(public.set_job_status('key-j-enroute-p-00000001', (SELECT id FROM jids WHERE name = 'r'),
            'en_route'),
  'en_route'::public.job_status, 'the provider sets off');
SELECT is(public.set_job_status('key-j-enroute-p-00000001', (SELECT id FROM jids WHERE name = 'r'),
            'en_route'),
  'en_route'::public.job_status, 'and a replayed call returns the same answer');

SELECT throws_ok(
  format($$SELECT public.set_job_status('key-j-arrive-p-000000001', %L, 'arrived', NULL, 6.6000, 3.9000)$$,
    (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_NOT_AT_PICKUP',
  'arriving from the wrong side of Lagos needs a reason, not a tap');
SELECT is(public.set_job_status('key-j-arrive-p-000000002', (SELECT id FROM jids WHERE name = 'r'),
            'arrived', NULL, 6.4460, 3.4751),
  'arrived'::public.job_status, 'inside the geofence it is just an arrival');
RESET ROLE;
SELECT is((SELECT (payload ->> 'inside_geofence')::boolean FROM public.job_events
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r') AND to_status = 'arrived'),
  true, 'and the history records that it was inside');

-- ---------------------------------------------------------------------------
-- PINs.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
-- Seven digits: wrong by construction, not wrong one run in a million.
SELECT throws_ok(
  format($$SELECT public.reveal_job_pin(%L)$$, (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'the provider cannot ask for the PIN they are meant to be told');
SELECT is(
  (public.verify_pin('key-j-pin-wrong-0000000001', (SELECT id FROM jids WHERE name = 'r'),
     '0000000') ->> 'verified')::boolean,
  false, 'a wrong PIN is an answer, not an exception');
SELECT is(
  (public.verify_pin('key-j-pin-wrong-0000000002', (SELECT id FROM jids WHERE name = 'r'),
     '1111111') ->> 'attempts_remaining')::int,
  3, 'and the attempts left come down with each one');
RESET ROLE;
SELECT is((SELECT attempts FROM private.job_pins
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r') AND kind = 'pickup'),
  2::smallint, 'the counter survives the failures, which is the point of not raising');

-- The customer reads out the PIN. Every reveal rotates it.
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pins VALUES ('pickup', public.reveal_job_pin((SELECT id FROM jids WHERE name = 'r')));
SELECT matches((SELECT pin FROM pins WHERE name = 'pickup'), '^[0-9]{6}$',
  'the PIN is six digits the customer can read aloud');
RESET ROLE;
SELECT is((SELECT attempts FROM private.job_pins
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r') AND kind = 'pickup'),
  0::smallint, 'a fresh PIN starts the attempt count again');

SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (public.verify_pin('key-j-pin-right-0000000001', (SELECT id FROM jids WHERE name = 'r'),
     (SELECT pin FROM pins WHERE name = 'pickup')) ->> 'status'),
  'in_progress', 'the right PIN starts the work');
SELECT throws_ok(
  format($$SELECT public.set_job_status('key-j-complete-p-0000001', %L, 'completed_by_provider')$$,
    (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_PROOF_REQUIRED', 'a delivery is not complete without its delivery PIN');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO pins VALUES ('delivery',
  public.reveal_job_pin((SELECT id FROM jids WHERE name = 'r'), 'delivery'));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(
  (public.verify_pin('key-j-pin-right-0000000002', (SELECT id FROM jids WHERE name = 'r'),
     (SELECT pin FROM pins WHERE name = 'delivery'), 'delivery') ->> 'verified')::boolean,
  true, 'the delivery PIN is verified at the door');
SELECT public.submit_proof('key-j-proof-p-000000000001', (SELECT id FROM jids WHERE name = 'r'),
  'photo', (SELECT id FROM jids WHERE name = 'r') || '/handover.jpg');
SELECT is(public.set_job_status('key-j-complete-p-0000002',
            (SELECT id FROM jids WHERE name = 'r'), 'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'and now the work can be handed over');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Confirmation.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  format($$SELECT public.confirm_completion('key-j-confirm-p-0000001', %L)$$,
    (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_REQUEST_NOT_FOUND', 'a provider cannot confirm their own work');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.confirm_completion('key-j-confirm-c-0000001',
            (SELECT id FROM jids WHERE name = 'r')),
  'confirmed'::public.job_status, 'the customer confirms');
SELECT is(public.confirm_completion('key-j-confirm-c-0000001',
            (SELECT id FROM jids WHERE name = 'r')),
  'confirmed'::public.job_status, 'and a replay returns the same result');
SELECT throws_ok(
  format($$SELECT public.cancel_request(%L, 'key-j-cancel-c-00000001')$$,
    (SELECT id FROM jids WHERE name = 'r')),
  'P0001', 'ERR_JOB_NOT_CANCELLABLE', 'a confirmed job is long past free cancellation');
RESET ROLE;

SELECT ok((SELECT confirmed_at IS NOT NULL AND NOT auto_confirmed FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')),
  'the confirmation was the customer''s, not the clock''s');

-- The history is append-only, for everyone.
SELECT throws_ok(
  format($$UPDATE public.job_events SET reason_code = 'rewritten' WHERE request_id = %L$$,
    (SELECT id FROM jids WHERE name = 'r')),
  '42501', 'ERR_AUDIT_APPEND_ONLY', 'nobody rewrites the job history');
SELECT throws_ok(
  format($$DELETE FROM public.job_events WHERE request_id = %L$$,
    (SELECT id FROM jids WHERE name = 'r')),
  '42501', 'ERR_AUDIT_APPEND_ONLY', 'nor deletes from it');
SELECT ok((SELECT count(*) FROM public.job_events
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r')) >= 7,
  'every transition left a row behind');

-- ---------------------------------------------------------------------------
-- Auto-confirmation, and free cancellation while nobody has paid.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('r2', public.create_request(
  'key-j-create-req-00000000002', 'errands_delivery', 'Collect a parcel in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM jids WHERE name = 'r2'), 'key-j-publish-000000000002');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('o2', public.create_offer(
  'key-j-offer-p-00000000000002', (SELECT id FROM jids WHERE name = 'r2'), 500000, NULL));
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.accept_offer('key-j-accept-c-0000000002', (SELECT id FROM jids WHERE name = 'o2')),
  'agreed'::public.job_status, 'a second job is agreed');
-- Nobody has paid yet, so walking away is free (transition 23).
SELECT is(public.cancel_request((SELECT id FROM jids WHERE name = 'r2'), 'key-j-cancel-c-00000002',
            'changed_mind'),
  'cancelled'::public.job_status, 'and can be cancelled for nothing before payment');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r2') AND to_status = 'cancelled'),
  1, 'the cancellation is in the history like any other transition');

-- A third job, taken to completion without a delivery PIN, then left to the clock.
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('r3', public.create_request(
  'key-j-create-req-00000000003', 'cleaning_laundry', 'Clean a flat in Lekki',
  'Admiralty Way', 'standard', false, NULL, NULL, 6.4459, 3.4750));
SELECT public.publish_request((SELECT id FROM jids WHERE name = 'r3'), 'key-j-publish-000000000003');
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO jids VALUES ('o3', public.create_offer(
  'key-j-offer-p-00000000000003', (SELECT id FROM jids WHERE name = 'r3'), 600000, NULL));
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub": "c1111111-1111-4111-8111-111111111111", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.accept_offer('key-j-accept-c-0000000003', (SELECT id FROM jids WHERE name = 'o3'));
RESET ROLE;
SELECT ok(NOT (SELECT delivery_pin_required FROM public.jobs
               WHERE request_id = (SELECT id FROM jids WHERE name = 'r3')),
  'a job with nowhere to deliver to needs no delivery PIN');
SELECT is(private.mark_paid_held((SELECT id FROM jids WHERE name = 'r3')),
  'assigned'::public.job_status, 'it is paid and assigned');

INSERT INTO pins VALUES ('pickup3', private.issue_pin((SELECT id FROM jids WHERE name = 'r3'), 'pickup'));
SELECT set_config('request.jwt.claims',
  '{"sub": "c2222222-2222-4222-8222-222222222222", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.set_job_status('key-j-enroute-p-00000003', (SELECT id FROM jids WHERE name = 'r3'),
  'en_route');
SELECT public.set_job_status('key-j-arrive-p-000000003', (SELECT id FROM jids WHERE name = 'r3'),
  'arrived', NULL, 6.4460, 3.4751);
SELECT public.verify_pin('key-j-pin-right-0000000003', (SELECT id FROM jids WHERE name = 'r3'),
  (SELECT pin FROM pins WHERE name = 'pickup3'));
SELECT public.submit_proof('key-j-proof-p-000000000002', (SELECT id FROM jids WHERE name = 'r3'),
  'photo', (SELECT id FROM jids WHERE name = 'r3') || '/done.jpg');
SELECT is(public.set_job_status('key-j-complete-p-0000003',
            (SELECT id FROM jids WHERE name = 'r3'), 'completed_by_provider'),
  'completed_by_provider'::public.job_status, 'the provider finishes');
RESET ROLE;

SELECT is(private.auto_confirm_jobs(), 0,
  'a job completed a minute ago is not auto-confirmed');
UPDATE public.jobs SET completed_at = now() - interval '25 hours'
WHERE request_id = (SELECT id FROM jids WHERE name = 'r3');
SELECT is(private.auto_confirm_jobs(), 1, 'a day later, the clock confirms it');
SELECT ok((SELECT auto_confirmed FROM public.jobs
           WHERE request_id = (SELECT id FROM jids WHERE name = 'r3')),
  'and says it was the clock, not the customer');
SELECT is((SELECT status FROM public.requests WHERE id = (SELECT id FROM jids WHERE name = 'r3')),
  'confirmed'::public.job_status, 'the job is confirmed');

SELECT * FROM finish();
ROLLBACK;
