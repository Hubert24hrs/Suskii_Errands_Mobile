# S-01 — Region and media latency: first run

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code, from the development machine |
| Status | **Inconclusive for the region decision.** Method proven, vantage point invalid |
| Harness | `spikes/S-01-latency/` (branch `spike/phase-0-runs`) |
| Decision it blocks | ADR-0008 (Supabase region) stays `Proposed` |

## What was asked

Which Supabase region (London, Paris, Frankfurt, Ireland, Mumbai) gives the best p95 RTT from Lagos, Accra, Nairobi, Kampala and Johannesburg, and how does LiveKit Cloud behave from those cities.

## What was actually measured

RTT from **one machine, behind a VPN**, to a regional endpoint per candidate region. That is not the question above, and the numbers must not be used to pick a region.

## Two instrument findings (these are the useful part)

**1. TCP measurement is unusable in this environment.** The first harness measured TCP connect time and returned a ~131 ms floor for *every* target — London, Cape Town, Mumbai and Virginia alike. One location cannot be equidistant from all four, so TCP is being terminated locally by a proxy. Any future runner must sanity-check for a flat floor before trusting TCP timings.

**2. The machine is behind a VPN egressing in Europe.** ICMP differentiates correctly, and `tracert` shows hop 1 at a private gateway (`10.2.0.1`) already costing ~131 ms, then M247/Cloudflare infrastructure. So every number below is *tunnel latency + distance from the European egress*, and the 132 ms floor to the nearest anycast edge is the tunnel itself.

## Results (ICMP, 15 probes per target)

Read the min column; avg and max carry access-network jitter.

| Target | min ms | avg ms | max ms | vs. nearest-edge floor |
|---|---:|---:|---:|---:|
| Cloudflare 1.1.1.1 (nearest edge) | 132 | 177 | 301 | floor |
| Google 8.8.8.8 (nearest edge) | 132 | 239 | 1113 | floor |
| GCP europe-west2 (GFE) | 131 | 137 | 173 | −1 |
| GCP africa-south1 (GFE) | 132 | 137 | 148 | 0 |
| AWS eu-central-1 Frankfurt | 137 | 144 | 167 | +5 |
| AWS eu-west-2 London | 147 | 161 | 200 | +15 |
| AWS eu-west-3 Paris | 147 | 165 | 219 | +15 |
| AWS eu-west-1 Ireland | 160 | 166 | 191 | +28 |
| AWS eu-north-1 Stockholm | 169 | 176 | 221 | +37 |
| AWS us-east-1 N. Virginia | 234 | 245 | 287 | +102 |
| AWS ap-south-1 Mumbai | 250 | 265 | 390 | +118 |
| AWS af-south-1 Cape Town | 282 | 292 | 344 | +150 |

No packet loss on any target. Raw data: `results-icmp.json` in the harness folder.

## What can and cannot be concluded

**Cannot:** anything about London vs Paris vs Frankfurt for African users. The ordering here measures distance from a European VPN egress, not from Lagos or Nairobi.

**Can, and worth keeping:**

- **Cape Town is the most distant AWS region from Europe in this test (+150 ms), further than Virginia or Mumbai.** That is consistent with the well-known weakness of intra-African routing, where African traffic often transits Europe. It is a caution for the OD-15 self-hosting contingency: an African-hosted database is not automatically closer to African users on every path, and the fallback needs its own measurement rather than an assumption.
- GCP frontends answer at the floor in both `europe-west2` and `africa-south1`, which confirms only that Google terminates at a nearby edge. It says nothing about where Vertex inference actually runs.
- The harness works and is reusable. Point it at real vantage points and it produces the table we need.

## To finish this spike

1. **Vantage points in the target cities.** Cheapest credible route: RIPE Atlas probes in Lagos, Accra, Nairobi, Kampala and Johannesburg (measurements cost credits, not money). Alternative: testers running a small probe on real MTN, Airtel, Safaricom and Glo SIMs.
2. **Measure the real thing, not a proxy.** Once a Supabase project exists per candidate region, time an actual RPC round trip (`/rest/v1/rpc/ping`) and a Realtime broadcast echo, not just ICMP. Include a cold-start and a warm-pool case.
3. **LiveKit**: join time, RTT, jitter and packet loss from the same vantage points, on Wi-Fi and 4G.
4. Re-run with the VPN off if the operator machine is genuinely in a target city — it may then serve as one honest vantage point.

Until then ADR-0008 stays `Proposed` and London remains provisional.
