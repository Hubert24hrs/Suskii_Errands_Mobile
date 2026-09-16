# S-07 — Gemini eval harness: first attempt

| | |
|---|---|
| Date | 2026-09-16 |
| Run by | Claude Code |
| Status | **Blocked.** Vertex AI API is not enabled on the available GCP project |
| Decision it blocks | ADR-0006 model routing table (the ADR itself is `Accepted`; the routing values need evals) |

## What was attempted

The cheapest, read-only part of S-07: confirm which Gemini models Vertex actually serves in `europe-west2` and `africa-south1`. Phase 0 could not verify this (`REPORT.md` §9 marks africa-south1 availability `[A]`), and it matters because it decides whether inference can stay in-region for data residency (OD-15).

Only metadata calls were attempted. Nothing was generated, so nothing was billed.

## Result

`gcloud` is authenticated as the project owner with project `my-project-58690ezike-oba`.

| Call | Result |
|---|---|
| `GET /v1/publishers/google/models` (list) | HTTP 404 — not a valid list path at v1 |
| `GET /v1/projects/{p}/locations/{r}/publishers/google/models` | HTTP 404 |
| `GET /v1/publishers/google/models/{model}` for 6 models × 3 regions | **HTTP 403 for every combination, including `us-central1`** |

Uniform 403 in a region where these models certainly exist means the **`aiplatform.googleapis.com` API is not enabled on this project** (or the account lacks the Vertex role), rather than the models being absent in a region.

I did not enable the API: that changes the state of the project and can have billing consequences, so it is the client's call.

## To unblock

Either:

- enable `aiplatform.googleapis.com` on a project with billing attached and confirm the account holds `roles/aiplatform.user`; or
- provide a project where Vertex is already in use.

Then this probe answers region availability in minutes, and the rest of S-07 (tool-calling accuracy, English and Pidgin golden sets, latency, caching cost, prompt-injection resistance) can run. The Pidgin golden set needs native speakers and is the long pole — start recruiting before the API question is settled.

## Note for whoever runs it

Model IDs move fast (`REPORT.md` §9, ADR-0006). Re-probe availability at the moment of the eval rather than trusting this file: `gemini-3.8-flash` and `gemini-3.7-flash` also carry promotional pricing that expires 31 Dec 2026.
