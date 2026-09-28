## Unreleased (2026-09-28)

- Supabase: account deletion/export, media uploads, display name, sign-up country metadata,
  arrival with position or reason, live position over the job's Realtime Broadcast plus the
  heartbeat; the tracking map no longer reads `location_samples` (audit Y.31). A signed-out
  bootstrap no longer counts notifications (Y.26).
- `SupabaseGateway.broadcasts` / `broadcast` / `leaveTopic` for private Realtime topics.
- Mocks mirror the server's arrival geofence and record published positions.
- `test/integration`: an end-to-end suite against a local Supabase stack (11 flows).

## 1.0.0

- Initial version.
