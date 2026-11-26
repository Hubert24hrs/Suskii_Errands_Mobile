# fixtures/meet

Authored payloads for Suskii Meet v5 ([ADR-0026](../../../../docs/adr/0026-meet-v5-social-layer.md),
[design](../../../../docs/plan/meet-v5-design.md)), published in M0 **before any of it is built**, so
the M1 and M2 backend, both apps' mocks and the tests start from one shape. Each file names the PR
that implements it; where the SQL and a fixture disagree, that PR changes one of them and says
which. Files marked M2 describe the Cowrie economy (ADR-0027, ADR-0028), which ships later and dark.

| File | The case it covers | Why it is here |
|---|---|---|
| [`daily-set.json`](daily-set.json) | Today's faces, and the end of the set | The set is finite, distance is a band, activity is "today" or "this week", and photos are object paths read through the authenticated endpoint, never URLs |
| [`locked-teaser.json`](locked-teaser.json) | M2. A badge-locked profile below the caller's card | Photo 0 only, no prompts; the ways in carry no prices, which come from the catalogue and go back as `p_expected_cost` |
| [`blocked-message.json`](blocked-message.json) | The contact filter refusing a message, the third strike, a platform mention, a profile field | Chat refusals are returned statuses (they write a strike); profile refusals raise (they write nothing) |
| [`expiring-match.json`](expiring-match.json) | A pending match counting down, an engaged one, and after expiry | `expires_at` is meaningless once engaged, and expired matches simply disappear |
| [`held-photo.json`](held-photo.json) | Photos in every review state, and the moderator's queue row | Every photo is approved by a person first (OD-41); only the owner sees the others |
| [`negative-balance.json`](negative-balance.json) | M2. A refund clawed back below zero | Spends are refused but buying is allowed, and bonus Cowries cannot be spent meanwhile |
| [`pending-purchase.json`](pending-purchase.json) | M2. A slow payment Play reports as PENDING | Nothing is credited until PURCHASED; prices come only from Play's own strings |
| [`contact_filter_cases.json`](contact_filter_cases.json) | 340 test vectors and 7 multi-message sequences for `private.meet_screen_text` | pgTAP 75, the Dart mock and the TypeScript mock all load this file by path, which is why its name is the design's and not kebab-case |

## Rules these obey

The parent [`README.md`](../README.md)'s rules, plus:

- **The only person id is a Meet profile id** (`meet_profiles.id`), never an auth user id, and it is
  also the storage folder (ADR-0026 D15).
- **Cowries are plain integers**, never `{ amount_minor, currency }`: they are not money and never
  touch `Money` (ADR-0027). Naira appears only as Play's own price string from the mock store.
- **No presence, no exact distance, no birth date** appears in any payload a client receives.
- Names are first names only and recognisably fictional. Area labels name a district and a city,
  never an address.
- The vectors' `[A]` marks a restricted term or a number word that counsel or native speakers have
  not reviewed (OD-24, OD-50).
