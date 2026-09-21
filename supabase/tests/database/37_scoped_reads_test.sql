-- Audit finding S.1, second half: `job_events` and the storage read scopes (RLS matrix §9 and
-- §Storage; `docs/audit/AUDIT-2026-09-21.md`).
--
-- The shape of every assertion here is the same, and it is the shape the finding asked for:
-- nothing before a ticket or a case, that job and only that job after one. A support agent who
-- can read every job's history because they are a support agent is the control the DPIA relies
-- on, absent.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(26);

INSERT INTO auth.users (id, phone) VALUES
  ('b1111111-1111-4111-8111-444444444444', '2348000000501'),   -- customer
  ('b2222222-2222-4222-8222-444444444444', '2348000000502'),   -- provider
  ('b3333333-3333-4333-8333-444444444444', '2348000000503'),   -- support agent
  ('b4444444-4444-4444-8444-444444444444', '2348000000504'),   -- dispute officer
  ('b5555555-5555-4555-8555-444444444444', '2348000000505'),   -- super admin
  ('b6666666-6666-4666-8666-444444444444', '2348000000506');   -- second customer
UPDATE public.profiles SET country_code = 'NG', customer_verification = 'verified'
WHERE user_id IN ('b1111111-1111-4111-8111-444444444444',
                  'b6666666-6666-4666-8666-444444444444');
UPDATE public.profiles SET country_code = 'NG', provider_verification = 'verified'
WHERE user_id = 'b2222222-2222-4222-8222-444444444444';
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('b3333333-3333-4333-8333-444444444444',
                  'b4444444-4444-4444-8444-444444444444',
                  'b5555555-5555-4555-8555-444444444444');
INSERT INTO public.provider_profiles (user_id) VALUES ('b2222222-2222-4222-8222-444444444444');
INSERT INTO public.admin_users (user_id, roles) VALUES
  ('b3333333-3333-4333-8333-444444444444', ARRAY['support_agent']::public.admin_role[]),
  ('b4444444-4444-4444-8444-444444444444', ARRAY['dispute_officer']::public.admin_role[]),
  ('b5555555-5555-4555-8555-444444444444', ARRAY['super_admin']::public.admin_role[]);

CREATE TEMP TABLE sc (name text PRIMARY KEY, id uuid);
GRANT ALL ON sc TO authenticated, service_role;

CREATE FUNCTION pg_temp.act(p_user text, p_aal text DEFAULT 'aal2') RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  SELECT NULL::void;
$fn$;

-- Two jobs, so "that job and only that job" has something to be only.
CREATE FUNCTION pg_temp.job(p_tag text, p_customer text) RETURNS uuid
LANGUAGE plpgsql AS $fn$
DECLARE
  v_request uuid;
  v_offer   uuid;
  v_payment uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_customer, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_request := public.create_request('key-sc-req-' || p_tag, 'personal_assistance',
    'Deliver a parcel', 'Yaba', 'standard', false, NULL, NULL, 6.5095, 3.3711);
  PERFORM public.publish_request(v_request, 'key-sc-pub-' || p_tag);
  PERFORM set_config('request.jwt.claims',
    '{"sub": "b2222222-2222-4222-8222-444444444444", "role": "authenticated", "aal": "aal1"}',
    true);
  v_offer := public.create_offer('key-sc-off-' || p_tag, v_request, 10000, NULL);
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_customer, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  PERFORM public.accept_offer('key-sc-acc-' || p_tag, v_offer);
  -- Paid, because a dispute can only be opened while there is still money to argue about.
  SELECT payment_id INTO v_payment FROM public.start_payment('key-sc-pay-' || p_tag, v_request);
  PERFORM private.record_gateway_checkout(v_payment, 'flutterwave', 'FLWS-' || p_tag, NULL);
  PERFORM private.confirm_payment('flutterwave', 'FLWS-' || p_tag, 10000, 290);
  RETURN v_request;
END $fn$;

INSERT INTO sc VALUES ('ticketed', pg_temp.job('t-00000001',
  'b1111111-1111-4111-8111-444444444444'));
INSERT INTO sc VALUES ('other', pg_temp.job('o-00000001',
  'b6666666-6666-4666-8666-444444444444'));
RESET ROLE;

-- Media on both jobs, so the storage policies have rows to be tested against.
INSERT INTO public.request_media (request_id, storage_path, kind) VALUES
  ((SELECT id FROM sc WHERE name = 'ticketed'),
   'b1111111-1111-4111-8111-444444444444/parcel.jpg', 'photo'),
  ((SELECT id FROM sc WHERE name = 'other'),
   'b6666666-6666-4666-8666-444444444444/parcel.jpg', 'photo');
INSERT INTO storage.objects (bucket_id, name, owner) VALUES
  ('request-media', 'b1111111-1111-4111-8111-444444444444/parcel.jpg',
   'b1111111-1111-4111-8111-444444444444'),
  ('request-media', 'b6666666-6666-4666-8666-444444444444/parcel.jpg',
   'b6666666-6666-4666-8666-444444444444'),
  ('chat-media', (SELECT id FROM sc WHERE name = 'ticketed')::text || '/note.jpg',
   'b1111111-1111-4111-8111-444444444444'),
  ('chat-media', (SELECT id FROM sc WHERE name = 'other')::text || '/note.jpg',
   'b6666666-6666-4666-8666-444444444444'),
  ('job-proofs', (SELECT id FROM sc WHERE name = 'ticketed')::text || '/done.jpg',
   'b2222222-2222-4222-8222-444444444444'),
  ('receipts', (SELECT id FROM sc WHERE name = 'ticketed')::text || '/till.jpg',
   'b2222222-2222-4222-8222-444444444444');

-- ---------------------------------------------------------------------------
-- Before anything is scoped.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b3333333-3333-4333-8333-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_events), 0,
  'a support agent reads no job history at all before a ticket names one');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'chat-media'), 0,
  'and no chat media');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'request-media'), 0,
  'and no request photos');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM public.job_events), 0,
  'nor a dispute officer before a case exists');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'job-proofs'), 0,
  'and proof photos carry a place and a time, so least of all those');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A ticket opens exactly one job.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b1111111-1111-4111-8111-444444444444', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.open_ticket('key-sc-ticket-0000001', 'payment',
  'The provider never arrived', (SELECT id FROM sc WHERE name = 'ticketed')) IS NOT NULL,
  'the customer opens a ticket about their job');
RESET ROLE;

SELECT pg_temp.act('b3333333-3333-4333-8333-444444444444');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'ticketed')) > 0,
  'now support can read that job''s history');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'other')), 0,
  'and still not the other job''s — the ticket is the scope, not the role');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'chat-media'), 1,
  'the same for chat media: one job''s, not every job''s');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'request-media'), 1,
  'and for the photos attached to the request');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'job-proofs'), 0,
  'but not the proofs: the matrix gives those to a dispute, not to support');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'receipts'), 0,
  'nor a receipt, which is a purchase record with a shop and a time on it');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A dispute opens the evidence.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b1111111-1111-4111-8111-444444444444', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok(public.open_dispute('key-sc-dispute-000001',
  (SELECT id FROM sc WHERE name = 'ticketed'), 'not_delivered',
  'The parcel never arrived and the provider stopped replying.') IS NOT NULL,
  'and opens a dispute about the same job');
RESET ROLE;

SELECT pg_temp.act('b4444444-4444-4444-8444-444444444444');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'ticketed')) > 0,
  'the officer reads the disputed job''s history');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'other')), 0,
  'and no other');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'job-proofs'), 1,
  'and the proof photos, which are the evidence the argument is about');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'receipts'), 1,
  'and the receipt');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Super admin keeps the unscoped read, because the matrix gives it one.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b5555555-5555-4555-8555-444444444444');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'other')) > 0,
  'a super admin reads any job''s history: the role that can do anything is not made safer '
  'by pretending otherwise');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'chat-media'), 2,
  'and any chat media');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Participants are untouched by all of this.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('b1111111-1111-4111-8111-444444444444', 'aal1');
SET LOCAL ROLE authenticated;
SELECT ok((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'ticketed')) > 0,
  'the customer still reads their own job''s history');
SELECT is((SELECT count(*)::int FROM public.job_events
           WHERE request_id = (SELECT id FROM sc WHERE name = 'other')), 0,
  'and not somebody else''s, which was never in question');
SELECT is((SELECT count(*)::int FROM storage.objects
           WHERE bucket_id = 'request-media'
             AND name LIKE 'b1111111%'), 1, 'and their own uploads');
RESET ROLE;

SELECT pg_temp.act('b2222222-2222-4222-8222-444444444444', 'aal1');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'job-proofs'), 1,
  'the provider reads the proofs of the job they did');
SELECT is((SELECT count(*)::int FROM storage.objects WHERE bucket_id = 'receipts'), 1,
  'and the receipt they uploaded');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- The receipts bucket, which the matrix named and nothing had built.
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM storage.buckets WHERE id = 'receipts'), 1,
  'the bucket exists');
SELECT is((SELECT public FROM storage.buckets WHERE id = 'receipts'), false,
  'and is private, like everything except avatars');

SELECT * FROM finish();
ROLLBACK;
