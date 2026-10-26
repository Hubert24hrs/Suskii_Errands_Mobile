-- The SOS alarm (RB-06): an escalated, unacknowledged SOS is something a monitor can page on.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, public;
SELECT plan(10);

INSERT INTO auth.users (id, phone) VALUES
  ('5a555555-5555-4555-8555-eeeeeeeeeeee', '2348000000151'),   -- raises the SOS
  ('5a666666-6666-4666-8666-eeeeeeeeeeee', '2348000000152');   -- the desk
UPDATE public.profiles SET country_code = 'NG'
WHERE user_id IN ('5a555555-5555-4555-8555-eeeeeeeeeeee', '5a666666-6666-4666-8666-eeeeeeeeeeee');
INSERT INTO public.admin_users (user_id, roles)
VALUES ('5a666666-6666-4666-8666-eeeeeeeeeeee', ARRAY['support_agent']::public.admin_role[]);
CREATE TEMP TABLE alarm (id uuid);
GRANT ALL ON alarm TO authenticated;

SELECT is(public.get_safety_alarm() ->> 'status', 'ok', 'no SOS, no alarm');

SELECT set_config('request.jwt.claims',
  '{"sub": "5a555555-5555-4555-8555-eeeeeeeeeeee", "role": "authenticated", "aal": "aal1"}', true);
SET LOCAL ROLE authenticated;
INSERT INTO alarm SELECT public.raise_sos('key-alarm-sos-000000000001', NULL, 6.4459, 3.4750);
RESET ROLE;

SELECT is(public.get_safety_alarm() ->> 'status', 'ok',
  'an SOS inside the desk''s three minutes is the desk''s, not the pager''s');

UPDATE public.sos_incidents SET created_at = now() - interval '4 minutes' WHERE id = (SELECT id FROM alarm);
SELECT is(private.escalate_unacked_sos(), 1, 'past three minutes the cron escalates it');
SELECT is(public.get_safety_alarm() ->> 'status', 'fail', 'and the alarm fails, which pages');
SELECT is((public.get_safety_alarm() ->> 'unacknowledged')::int, 1, 'with how many');
SELECT ok((public.get_safety_alarm() ->> 'oldest_escalated_seconds')::int >= 0, 'and for how long');
SELECT is((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(public.get_safety_alarm()) k),
  ARRAY['checked_at', 'oldest_escalated_seconds', 'status', 'unacknowledged'],
  'and nothing else: no place, no person, no incident id leaves for the monitor');

SELECT set_config('request.jwt.claims',
  '{"sub": "5a666666-6666-4666-8666-eeeeeeeeeeee", "role": "authenticated", "aal": "aal2"}', true);
SET LOCAL ROLE authenticated;
SELECT is(public.update_sos_incident('key-alarm-ack-000000000001', (SELECT id FROM alarm), 'acknowledged'),
  'acknowledged'::public.sos_status, 'the desk acknowledges');
SELECT throws_ok($$SELECT public.get_safety_alarm()$$, '42501', NULL, 'clients cannot ask');
RESET ROLE;

SELECT is(public.get_safety_alarm() ->> 'status', 'ok', 'and acknowledging clears the alarm');

SELECT * FROM finish();
ROLLBACK;
