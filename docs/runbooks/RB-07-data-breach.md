# RB-07 — Personal data may have been exposed: breach response and regulator notification

| | |
|---|---|
| Owner | Claude Code (technical) · client DPO / Information Officer per country (legal decisions) |
| Severity | SEV1 until the assessment shows otherwise (RB-01) |
| Last rehearsed | Not yet — tabletop with the client and counsel before the first country goes `live` (RB-08) |
| Related | [data-flow.md](../plan/data-flow.md) (data classes, processors); [compliance-checklist-and-dpia.md](../research/compliance-checklist-and-dpia.md) D10; country packs `breach_notice_hours`; RB-01, RB-10 |

> **This is not legal advice.** The notification rules below come from Phase 0 research with their evidence tags. Anything marked `[A]` or *counsel required* must be confirmed by counsel in that country **before** the country goes live. The client and counsel make every notification decision; engineering supplies facts, containment and evidence.

## Clocks that may apply

The clock typically starts when Suskii **becomes aware** of a breach, not when the investigation ends. Write down the awareness time the moment you start this runbook.

| Country | Regulator | Deadline | Channel | Evidence |
|---|---|---|---|---|
| Nigeria | Nigeria Data Protection Commission (NDPC) | **72 hours**; affected people notified immediately where the risk is high | NDPC process under the NDPA 2023 and GAID 2025 — counsel confirms the form | [S] REPORT §11 [P42]; country pack `NG.breach_notice_hours: 72` |
| Kenya | Office of the Data Protection Commissioner (ODPC) | 72 hours | Counsel confirms | **[A]** REPORT §11; `KE.breach_notice_hours: 72` |
| South Africa | Information Regulator | As soon as reasonably possible | **Information Regulator eServices portal** (mandatory since 1 Apr 2025) | [S] REPORT §11 [P46]; `ZA.breach_notice_hours: as_soon_as_reasonably_possible` |
| Ghana | Data Protection Commission | **Counsel required** | Counsel | `GH.breach_notice_hours: counsel_required` |
| Uganda | Personal Data Protection Office (PDPO) | **Counsel required** | Counsel | `UG.breach_notice_hours: counsel_required` |

Users in more than one country can mean more than one clock. Work to the **shortest** applicable deadline.

## Symptoms

- A secret found in a commit, log, ticket or chat (gitleaks alert, a person reporting it).
- Unexpected reads: advisor finding, RLS change, a pgTAP deny test failing in CI, anomalous query volume.
- A processor tells us they had an incident (Smile ID, gateways, SMS, LiveKit, Sentry, PostHog, Google, Supabase).
- A lost or stolen staff device with dashboard access.
- A user reports seeing someone else's data.
- Data from Suskii appears somewhere public.

## Impact assessment — decide fast, refine later

| Question | Why it matters |
|---|---|
| Which **data classes** (data-flow: P personal, G government ID, B biometric, C criminal record, F financial, L location, M content)? | B, C, G, F and L are high or special: assume notification is needed until counsel says otherwise |
| Which **countries** do affected people live in? | Decides the clocks above |
| **How many** people, and can we list them? | Regulator forms ask; user notification needs it |
| Was it **accessed or only exposed**? Is there evidence (logs, audit rows, Sentry, vendor logs)? | Changes risk, not the obligation to assess |
| Is it **still happening**? | Containment first |
| Encrypted? Blind-indexed only? Keys also exposed? (ADR-0007) | Ciphertext without keys is lower risk; ciphertext with keys is not |

## Immediate actions (first hour)

1. **Record the awareness time** (UTC and Lagos) in the incident log. Open an incident under RB-01 at SEV1.
2. **Tell the client's DPO / Information Officer and counsel** now, with what is known. Do not wait for certainty.
3. **Contain** — in this order, stopping when the exposure is closed:
   - Revoke or rotate the exposed credential (RB-10).
   - Switch off the leaking feature (RB-13).
   - Remove public access (bucket policy, link, published file).
   - Suspend compromised staff or user accounts.
   - Ask the processor to contain on their side (for a vendor breach).
4. **Preserve evidence**: export the relevant `audit.log` and `audit.kyc_access` rows (and verify the chain with `private.run_audit_chain_check()`), Supabase and function logs for the window, Sentry events, vendor correspondence. Store them in a restricted location, never in chat.
5. **Start the assessment table** above and update it every hour.

**Stop conditions:**
- Never delete logs, audit rows or evidence, even to "clean up" exposed data. Removing public access is containment; deleting records is destruction of evidence.
- Never contact affected users or regulators before the client and counsel approve the wording.
- Never copy the exposed personal data into tickets, chat, email or Sentry while investigating. Refer to records by id.
- Never pay or negotiate with anyone claiming to hold the data. That is a client and law-enforcement decision.

## Diagnosis

| Check | Where | What to look for |
|---|---|---|
| Who read KYC documents | `audit.kyc_access` (hash-chained) | Views outside a review, unusual officers or hours |
| Admin reads and changes | `audit.log` by `actor_id`, `target_table` | Bulk reads, role grants, flag or country-pack changes |
| Access control changes | Git history of `supabase/migrations`; CI runs of `backend-db` | A policy, grant or function privilege that changed; failing structure tests |
| Secrets in code | `security.yaml` gitleaks results; `gitleaks git .` locally | The commit, author, and whether it reached the remote |
| Storage exposure | Supabase Storage bucket settings; signed URL expiry | Public buckets, long-lived URLs, the `kyc-docs` read policy (must not exist) |
| Function behaviour | Function logs by `x-request-id`; Sentry | Responses containing other users' data |
| Processors | Vendor incident notices, DPAs (compliance checklist D6) | Scope, data classes, their timeline |

## Resolution

1. Close the exposure (containment steps) and confirm with a test: the failing pgTAP deny test now passes, the bucket returns 403, the rotated key is rejected.
2. Fix the root cause through the normal pipeline (PR, CI, dev → staging → production). No hotfix skips the RLS and structure tests.
3. With counsel: decide per country whether to notify the regulator and affected people, what to say, and who submits.
4. Submit notifications within the deadlines; record submission time and reference numbers.
5. Offer affected people practical help where relevant (for example: change of payout account, re-verification, watching for SIM-swap fraud, R-32).

## Communication

| Audience | When | Who approves |
|---|---|---|
| Client DPO / Information Officer, counsel | Immediately | — |
| Regulator(s) | Within the applicable deadline | Client + counsel |
| Affected users | As counsel advises; immediately where risk is high (Nigeria) | Client + counsel |
| Processors involved | Immediately, under the DPA | Client |
| Kimi Code | If app behaviour or contracts change (`HANDOFF.md`) | Claude Code |

User notices say plainly what happened, which data, what we did, what they should do, and how to contact us. No jargon, no blame on the user, no speculation.

## After the incident

- Breach register entry: facts, effects, remedial action, decisions and reasons (kept even when notification was judged unnecessary).
- Write-up within 48 h; DPIA updated if a risk was missed (compliance checklist D-rows).
- Follow-up engineering tasks: missing deny test, missing alert, scrubbing rule, key rotation automation.
- This runbook corrected, and the country table re-checked with counsel.
