-- The alarm RB-06 assumed and nothing provided.
--
-- Rehearsing RB-06 on staging (2026-10-26): an SOS escalated after 201 s and reached nobody.
-- `sos.raised` and `sos.escalated` go to the `ops:sos` broadcast and the outbox, and no worker reads
-- the `sos` aggregate, so "raises the alarm louder" was louder only for somebody already watching
-- the console.
--
-- This is the database half: one question a monitor can ask every minute, whether any SOS has been
-- escalated and is still unacknowledged, answered with a count and an age. Never a place, a person
-- or an incident id: the answer leaves the database for an uptime check, and the desk has the console
-- for the rest. The `health` function asks it under `?scope=safety`, a separate uptime check pages on
-- it (Terraform), and it clears itself when somebody acknowledges.
--
-- Separate from `get_health()` on purpose. An SOS is not an outage, and a deploy that smoke-tests
-- `/health` must not be blocked by one, least of all a deploy that might be the fix.

CREATE FUNCTION public.get_safety_alarm()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'status', CASE WHEN count(*) > 0 THEN 'fail' ELSE 'ok' END,
    'checked_at', now(),
    'unacknowledged', count(*),
    'oldest_escalated_seconds', extract(epoch FROM now() - min(s.escalated_at))::integer)
  FROM public.sos_incidents s
  WHERE s.status = 'open' AND s.escalated_at IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_safety_alarm() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_safety_alarm() TO service_role;
