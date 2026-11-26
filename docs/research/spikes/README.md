# Spike results — status board

Live status of the 12 spikes in [spike-plan.md](../spike-plan.md). Update the row when a spike runs, and add `S-xx-results.md` next to this file.

Last updated 2026-09-16. S-15 … S-17 added 2026-11-26 for Meet v5 ([below](#meet-v5-spikes-s-15--s-17-added-2026-11-26)).

| ID | Spike | Status | Blocked on | Result |
|---|---|---|---|---|
| S-01 | Region and media latency | **Attempted — inconclusive** | Vantage points in Lagos/Nairobi/Johannesburg; Supabase projects per region | [S-01-results.md](S-01-results.md) |
| S-02 | Supabase capability check | Not started | A Supabase project + CLI + Docker | — |
| S-03 | VoIP call with the app killed | Not started | Physical iOS + Android devices, Kimi's app, APNs/FCM credentials | — |
| S-04 | Background location on low-end Android | Not started | Tecno / Infinix / itel devices, 8-hour test shifts | — |
| S-05 | Liveness SDK on 2 GB devices | Not started | Devices + Smile ID sandbox credentials | — |
| S-06 | PostGIS nearest provider at 100k | **Passed** | — (re-run on Supabase later) | [S-06-results.md](S-06-results.md) |
| S-07 | Gemini eval harness | **Attempted twice — blocked on billing** | Vertex API now enabled, but both GCP billing accounts are closed | [S-07-results.md](S-07-results.md) |
| S-08 | Voice concierge, English + Pidgin | Not started | S-07 unblocked, LiveKit project, native Pidgin speakers | — |
| S-09 | SMS/OTP delivery per MNO | Not started | Provider accounts; **Nigerian sender-ID and DND registration takes weeks — start it now** | — |
| S-10 | Concurrent offer acceptance | **Passed** | — (re-run on Supabase later) | [S-10-results.md](S-10-results.md) |
| S-11 | Realtime load for location broadcast | Not started | A Supabase project + k6 | — |
| S-12 | Payment hold to payout, end to end | Not started | Flutterwave and Paystack sandbox credentials | — |
| S-13 | RLS default-deny and SECURITY DEFINER patterns *(added)* | **Passed 17/17** | — | [S-13-results.md](S-13-results.md) |
| S-14 | Money rounding and ledger invariants *(added)* | **Passed 24/24** | — | [S-14-results.md](S-14-results.md) |
| S-15 | Play Billing end to end with license testers *(Meet v5)* | Not started | The Play payments profile alert fixed, the products created, license testers, the `play-billing@` service account with its two app-level permissions | — |
| S-16 | LiveKit server-side disconnect and webhook *(Meet v5)* | Not started | The LiveKit project's API key and secret in a scratch environment | — |
| S-17 | `image_picker` EXIF behaviour; Play Age Signals in Nigeria *(Meet v5)* | Not started | An Android device or emulator with a GPS-tagged photo; Play Console access for the Age Signals half | — |

## What this run established

1. **S-06 and S-10 are done and passed.** Docker would not install, so they ran on portable PostgreSQL 17.5 + PostGIS 3.6 (no installer, no admin) via `spikes/postgres/setup-local-windows.sh`. R-11 and R-12 are downgraded from High/Critical to Medium on measured evidence.
2. **S-01 needs real vantage points, not this machine.** The development machine sits behind a VPN egressing in Europe, so its latency ordering reflects distance from that egress, not from Lagos. Details and the reusable harness are in the result file.
3. **S-07 needs an open billing account.** The Vertex API is now enabled on the project, and the first diagnosis ("API not enabled") was wrong — those 403s came from a missing quota project. With that fixed, Vertex says billing is required, and both billing accounts on the Google account are closed. Reopening one is a payment matter for the client.
4. **Two spikes were added because they need no credentials.** S-13 proves the access-control rules (RLS default-deny, column privileges, SECURITY DEFINER) on plain Postgres; S-14 proves the money rules (half-even rounding, currency exponents, zero-sum ledger). Both found real fixes, listed in their results.
5. **Everything else needs hardware or vendor accounts** that do not exist yet. The device spikes (S-03, S-04, S-05) also need Kimi's app, which reached M2 on 2026-09-16.

## Order to run them in

| Priority | Spike | Why now |
|---|---|---|
| 1 | ~~S-06, S-10~~ | **Done 2026-09-16.** Assertions carry into Phase 3 pgTAP tests |
| 2 | S-09 sender-ID registration | Weeks of external lead time; start the paperwork before the test |
| 3 | S-07 | Reopen a billing account; unblocks S-08 and the model routing table |
| 4 | S-01, S-02, S-11 | Need a Supabase project; do all three against the same projects |
| 5 | S-12 | Needs gateway sandbox credentials from the client |
| 6 | S-03, S-04, S-05 | Need purchased devices and Kimi's app further along |

## Meet v5 spikes (S-15 … S-17, added 2026-11-26)

Raised by [the Meet v5 design](../../plan/meet-v5-design.md) (§1.6, §10.3). Each settles items the
design marks VERIFY-IN-RESEARCH, and each gates a flag: the flag stays off until the spike passes.
Spike code is throwaway, as for every other spike: `spike/*` branches, under `spikes/`, never in
`apps/`, `supabase/` or `services/`.

| ID | What it settles | Method | Passes when | Gates |
|---|---|---|---|---|
| S-15 | The androidpublisher v3 paths and responses for productsv2, subscriptionsv2, consume, acknowledge, the voided-purchases list, `orders.refund` with revoke, `subscriptionsv2.revoke` and the subscription cancel endpoint; whether `completePurchase` after a server-side consume is a no-op; whether the plugin redelivers a purchase after a server-side consume | License testers on the internal track buy each pack and each VIP base plan, including a slow test card (pending), a declined card, a refund from Play Console and a quantity-partial refund; the server half runs against a scratch project with the `play-billing@` service account; the RTDN "Send test message" reaches `play-rtdn` | Every path in ADR-0028 is confirmed or corrected in `S-15-results.md`; each purchase is granted exactly once; a refund is clawed back by RTDN and, with RTDN disabled, by the voided sweep; nothing is left unacknowledged after 24 hours | `meet.purchases` and `meet.vip` beyond testers (readiness item `license_tests_passed`); ADR-0028 accepted |
| S-16 | LiveKit RoomService `RemoveParticipant` and `DeleteRoom`: the Twirp paths and their authorisation; how LiveKit signs webhooks and how to verify them | Against the LiveKit docs and the owner's project, from a scratch script holding a server token: remove a participant mid-call, delete a room, receive and verify `room_finished` and `participant_left` | A call can be ended by the server within seconds and the client cannot keep it alive with an old token; the webhook signature verifies, and a tampered body fails | `meet.calls.voice`; ADR-0029 and RB-19 (M3-PR1) |
| S-17 | Whether `image_picker`'s resizing (`maxWidth`/`imageQuality`) keeps EXIF GPS in the output file; whether Play's Age Signals API is available in Nigeria, and on what terms | Pick a GPS-tagged photo on Android through the system picker with and without resizing and dump the output's metadata; read the Age Signals API documentation and availability in Play Console | Both answers written down with their sources. The server-side strip in `meet-media-worker` is authoritative either way, so S-17 decides only whether the client may also be relied on; the Age Signals half decides whether layer L5 can be built | Layer L5 of the 18+ gate (`meet_eligibility.age_signal`); ADR-0026's revisit list |

One question has no spike, because nothing can be tested before submission: whether Google treats
in-app virtual currency as a financial feature (no exemption page found). It is re-checked at M2
submission (ADR-0028).
