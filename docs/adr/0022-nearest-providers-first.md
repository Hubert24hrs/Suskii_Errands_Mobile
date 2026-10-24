# ADR-0022 — The nearest providers first, a Google Map to say where, and Nigeria's 37 states

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-24 |
| Deciders | Owner (Google Maps; nearest first while keeping offers; approximate positions only before booking; one state per provider); Claude Code |
| Related | migration `20261024130000_nearest_first.sql`, `60_nearest_first_test.sql`, contracts 2.4.0, [ADR-0009](0009-live-location.md) (live tracking stays behind payment) |

## Context

The owner asked for two things: providers able to choose any state in Nigeria, not just Lagos and Abuja, and a map so that "customers receive services from the provider closest to them".

Three findings shaped the decision.
- **The app's request form had no map point at all.** It took a typed address only. `match_providers` needs `pickup_point`, and without one it returns nobody, so a request made from the app reached no provider on a real backend.
- **Matching already measured distance,** but the score ordered every candidate together. A well-rated provider 4 km away was told before an ordinary one round the corner.
- **The onboarding screen sent a city's display name** where `update_provider_service_areas` expects its code. Saving a service area therefore failed on a real backend with `ERR_CITY_NOT_FOUND`.

## Decision

1. **Service areas are Nigeria's 36 states and the FCT,** as `cities` rows centred on each capital [A: approximate coordinates]. Lagos and Abuja keep their codes. The country pack now carries `serviceAreas` (code and name) alongside the names. A provider picks one state from a searchable dropdown, and the code goes over the wire.
2. **Google Maps** (`google_maps_flutter` 2.18.2 on mobile; the Maps JavaScript API on the web):
   - The request form puts the pickup on the map, with the pin fixed and the map moving under it. The point is required to publish.
   - The key is a restricted client key. It is injected from the `GOOGLE_MAPS_API_KEY` CI secret, never committed: a key in the repository would also trip the secret scanner.
   - Without a key the app draws no map, because the native SDK refuses to start without one. A "use my location" card sets the point instead, so matching still works.
   - The website's CSP admits Google's Maps origins only when a key is configured.
3. **Nearest first, offers kept.**
   - `match_providers` orders candidates in 500 m distance bands, then by score within a band.
   - `fan_out_request` widens the search 5 → 15 → 30 km (`matching_radius_ladder_m`) when nobody is close.
   - `rank_offers` returns `distance_km`, from the provider's last fix in the past 30 minutes to the customer's own pickup, in half-kilometre steps and never below 0.5.
   - The offers board sorts closest first by default; "Best match" switches back to the score.
4. **Approximate only before booking.** `nearby_providers` returns a count and ~1 km grid cells, and only cells with at least 3 providers (`nearby_providers_min_per_cell`). It never returns a provider's position, and it hides providers across blocks. The map draws those cells as soft circles. A provider's exact position remains what it was: live tracking after payment (ADR-0009).

## Consequences

- **Fixes riding along:** customers' requests from the app can be matched for the first time, and providers can save a service area on a real backend.
- **Privacy:** an offer's distance tells a customer how far, not where. Trilaterating a provider would need several requests at chosen points, each with an offer from that provider.
- **Client actions:**
  - a Google Cloud project with the Maps SDK for Android, the Maps SDK for iOS and the Maps JavaScript API enabled, with billing;
  - keys restricted to the app ids, signing SHA-1s and the website's domains;
  - the key stored as the `GOOGLE_MAPS_API_KEY` secret, and as `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` for the website (RB-15).
- **Not built:**
  - address search (Places autocomplete);
  - showing the destination on the map;
  - staged fan-out over time (nearest first, then wider after N minutes). The radius ladder is by distance only.
