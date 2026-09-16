# Spike results — status board

Live status of the 12 spikes in [spike-plan.md](../spike-plan.md). Update the row when a spike runs, and add `S-xx-results.md` next to this file.

Last updated 2026-09-16.

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
