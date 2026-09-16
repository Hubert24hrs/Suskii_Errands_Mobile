# S-07 — Gemini eval harness: attempts 1 and 2

| | |
|---|---|
| Dates | 2026-09-16 (two runs) |
| Run by | Claude Code |
| Status | **Blocked on billing.** Vertex AI API is now enabled; the project has no open billing account |
| Decision it blocks | The model routing table under ADR-0006 (the ADR itself is `Accepted`; the routing values need evals) |

## What was attempted

The cheapest, read-only part of S-07: confirm which Gemini models Vertex actually serves in `europe-west2` and `africa-south1`. Phase 0 could not verify this (`REPORT.md` §9 marks africa-south1 availability `[A]`), and it decides whether inference can stay in-region for data residency (OD-15).

Only metadata calls were made. Nothing was generated, so nothing was billed.

## Run 1 — misdiagnosed

Every model in every region returned HTTP 403, including `us-central1` where the models certainly exist. I read that as "the Vertex API is not enabled on this project". **That was wrong**, and the error body said so once read properly:

> Your application is authenticating by using local Application Default Credentials. The aiplatform.googleapis.com API requires a quota project, which is not set by default.

The requests were being attributed to gcloud's shared client project (`32555940559`), not to the user's project. A missing quota project produces a `SERVICE_DISABLED` reason that reads like a disabled API but is not one.

**Lesson for whoever runs this next:** with user credentials from `gcloud auth print-access-token`, always send `-H "x-goog-user-project: <project>"` (or run `gcloud auth application-default set-quota-project <project>`). Without it, every 403 is uninformative.

## Run 2 — real blocker found

The client authorised enabling the API, so it was enabled:

```
gcloud services enable aiplatform.googleapis.com --project my-project-58690ezike-oba
Operation "operations/acat.p2-909160401423-..." finished successfully.
```

Re-probed with the quota-project header. All 18 combinations (6 models × 3 regions) now return a single, clear error:

> HTTP 403 — This API method requires billing to be enabled. Please enable billing on project #my-project-58690ezike-oba

Confirmed at the source:

| Check | Result |
|---|---|
| `gcloud billing projects describe` | `billingEnabled: false` |
| `gcloud billing accounts list` | `01DD67-11792D-4FF148` (Hubert.dev) — **OPEN: False**; `01F5D0-2C095B-5DD0D3` (My Billing Account) — **OPEN: False** |

Both billing accounts on the account are **closed**, so there is nothing to link. This is a payment matter, not a technical one, and it is the client's to resolve.

## To unblock

1. Reopen one of the closed billing accounts, or create a new one with a valid payment method (Google Cloud console → Billing).
2. Link it to the project:
   ```bash
   gcloud billing projects link my-project-58690ezike-oba --billing-account=<ACCOUNT_ID>
   ```
3. Confirm the account holds `roles/aiplatform.user`.
4. Re-run the probe — the harness and the exact commands are in this file and the run log; it takes minutes.

**Budget note:** the availability probe stays free. The full eval (150 golden conversations plus 50 red-team prompts across five candidate models) is a real, if small, spend — on the order of a few dollars at the prices in `cost-model.md` §3. Set a billing budget alert before running it.

**Start now, in parallel:** the Pidgin golden set needs native speakers and is the long pole of S-07 and S-08. Recruiting it does not depend on billing.

## Note for whoever runs it

Model IDs move fast (`REPORT.md` §9, ADR-0006). Re-probe availability at the moment of the eval rather than trusting this file. `gemini-3.8-flash` and `gemini-3.7-flash` also carry promotional pricing that expires 31 Dec 2026.
