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
| S-06 | PostGIS nearest provider at 100k | **Harness ready, unrun** | Docker on the runner | `spikes/postgres/S-06/` |
| S-07 | Gemini eval harness | **Attempted — blocked** | Vertex AI API not enabled on the GCP project | [S-07-results.md](S-07-results.md) |
| S-08 | Voice concierge, English + Pidgin | Not started | S-07 unblocked, LiveKit project, native Pidgin speakers | — |
| S-09 | SMS/OTP delivery per MNO | Not started | Provider accounts; **Nigerian sender-ID and DND registration takes weeks — start it now** | — |
| S-10 | Concurrent offer acceptance | **Harness ready, unrun** | Docker on the runner | `spikes/postgres/S-10/` |
| S-11 | Realtime load for location broadcast | Not started | A Supabase project + k6 | — |
| S-12 | Payment hold to payout, end to end | Not started | Flutterwave and Paystack sandbox credentials | — |

## What this run established

1. **Two spikes need only Docker.** S-06 and S-10 have complete harnesses in `spikes/postgres/` (branch `spike/phase-0-runs`). Install Docker and they run in minutes. S-10 covers risk R-12, a critical one.
2. **S-01 needs real vantage points, not this machine.** The development machine sits behind a VPN egressing in Europe, so its latency ordering reflects distance from that egress, not from Lagos. Details and the reusable harness are in the result file.
3. **S-07 needs one GCP setting.** Every Vertex call returns 403, including in `us-central1`, so the API is not enabled on the project. That is a client decision, since enabling it touches billing.
4. **Everything else needs hardware or vendor accounts** that do not exist yet. The device spikes (S-03, S-04, S-05) also need Kimi's app, which reached M1 on 2026-09-16.

## Order to run them in

| Priority | Spike | Why now |
|---|---|---|
| 1 | S-06, S-10 | Only need Docker; S-10 clears a critical risk and its asserts become permanent pgTAP tests |
| 2 | S-09 sender-ID registration | Weeks of external lead time; start the paperwork before the test |
| 3 | S-07 | One API toggle; unblocks S-08 and the model routing table |
| 4 | S-01, S-02, S-11 | Need a Supabase project; do all three against the same projects |
| 5 | S-12 | Needs gateway sandbox credentials from the client |
| 6 | S-03, S-04, S-05 | Need purchased devices and Kimi's app further along |
