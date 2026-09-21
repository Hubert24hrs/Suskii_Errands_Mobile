-- Phase 6, part 0: two notification kinds, alone in their own migration.
--
-- `ALTER TYPE ... ADD VALUE` may run inside a transaction from PostgreSQL 12, but the new value
-- cannot be *used* until that transaction commits. Putting these two lines in the migration that
-- needs them would work only for as long as nothing in it touched the new values, which is a
-- constraint nobody reading that file would know about. A file of its own costs one filename.
--
-- The apps route on `kind`: an incoming call rings (CallKit / full-screen intent, SH-13) and a
-- missed one does not, so they cannot share `system`.

ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'call_incoming';
ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'call_missed';
