# RB-11 — Changing an LLM model, and undoing it

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | Not an incident by default. SEV2 if a model is producing harmful output, SEV3 if it is producing expensive output |
| Last rehearsed | **Cannot be rehearsed yet.** See the blocker below |
| Related | ADR-0006 (model IDs in remote config, routing chosen by evaluation); ai-design §3.1, §6.5, §8; OD-17; RB-13, RB-01 |

## Blocker, stated plainly

**The AI service does not exist.** ADR-0006 is accepted and defines the mechanism — model IDs live
in `remote_config`, never in code, and routing is chosen by evaluation results — but the FastAPI
service that reads that config, the Gemini gateway, the redaction and output filter, and the eval
suites all need Vertex AI and GCP billing (**client action 1, unstarted**).

So the procedure below is written from ADR-0006 and ai-design §3.1, and **the eval gate in step 2
cannot be executed today**. Do not treat this runbook as rehearsed until it has been run end to end
against a real route. What *is* live today is the kill switch in step 5, because `feature_flags` and
`remote_config` have existed since Phase 2 (RB-13).

## Why a model swap needs a runbook at all

Because the deprecation notice can be two weeks. Phase 0 found the Gemini lineup moving fast enough
that a model you depend on can be withdrawn with less notice than a sprint, and the promotional
pricing on the 3.7/3.8 Flash tiers runs out on 31 Dec 2026 [V]. A swap is therefore a routine
operation, not an exceptional one, and it should be boring.

## The routes

From ai-design §3.1. Each workload key maps to a primary and a fallback; both are remote config
values, not constants.

| Workload key | What it does | Sensitivity if it degrades |
|---|---|---|
| `concierge.text` | The request-drafting conversation | High — it is the product's front door |
| `concierge.escalate` | Harder conversations, on a measurable trigger only | Medium |
| `offers.explain` | Why one offer ranks above another | Low; `rank_offers` is deterministic and unaffected |
| `moderation.text` / `moderation.image` | Advisory layer over deterministic rules | **A model cannot overrule the rules.** See below |
| `receipt.extract` | Item-float receipts | Medium — it touches money, via a human approval |
| `support.triage` | Ticket routing | Low |
| `admin.assistant` | Internal only | Low |
| `voice.live` / `voice.cascade` | Voice concierge | Blocked separately on LiveKit (action 11) |
| `embedding` | `classify_request` | **A change means re-embedding everything.** Not a swap; a migration |

**Moderation is the one to be calm about.** The deterministic rules are the control; the model is
advisory and fails open per OD-21. A moderation model going wrong degrades a suggestion, it does
not open a hole — a `block`-severity term still refuses a request whatever any model thinks.

## Symptoms that start a swap

- A deprecation notice from the vendor.
- Cost per conversation rising beyond the cost model's envelope.
- Eval scores dropping on a route (the intended trigger).
- Harmful or off-policy output reported by a user or an officer.

## Procedure

### 1. Decide which route, and only that route

Change one workload key at a time. A simultaneous swap across routes makes the eval delta
unreadable, which defeats the point of having one.

### 2. Run the eval suite for that route — **blocked today**

ADR-0006's rule is that routing is chosen by **evaluation results**, not by tier, price or vendor
marketing. A candidate that has not been evaluated on this product's own prompts is a guess.

`[BLOCKED: needs the eval harness, which needs GCP billing — client action 1]`

For Pidgin specifically, OD-17 gates voice on the S-08 eval, and OD-20 (the client recruiting and
paying native speakers, with consent) is unanswered. A Pidgin model swap without that data is not
evaluable at all, not merely unevaluated.

### 3. Change the config, with two signatures

Model routing is remote config, so it goes through `propose_config_change` / `review_config_change`
like any other. Record the eval result in the proposal's reason — that is the audit trail for why
this model, and it is what makes the rollback decision easy later.

### 4. Watch the first hour

| Watch | Healthy |
|---|---|
| Schema-validation failures | At or below the previous model's rate. Two consecutive failures is the documented escalation trigger |
| Tool-call loops | None. Same tool, same arguments, twice is a loop |
| `cost_micros` per conversation | Within the cost model's envelope |
| Latency against the route's timeout | Inside it. The timeouts in §3.1 are per route and are not advisory |
| Moderation agreement with the deterministic rules | No new disagreements on terms the rules already decide |

### 5. Roll back

Set the config key back. It takes effect at the next bootstrap for clients and immediately for
server-side reads, and there is no deploy involved — that is the whole reason ADR-0006 put model
IDs in config rather than in code.

If the model is actively harmful and you want it gone **now** rather than at the next config read,
use the kill switch instead: `concierge.text` and `concierge.voice` are feature flags (RB-13). The
app falls back to the plain request form, which is a complete and working path — the concierge has
always been an accelerator, never the only way to create a request.

## Backout

Covered in step 5: the rollback *is* the backout. The one change that cannot be rolled back this way
is `embedding` — a different embedding model means every stored vector is in a different space, so
changing it requires re-embedding the corpus and is a migration with a plan, not a config flip. That
is also why ADR-0006 has no fallback candidate for it.

## Communication

- **Internal:** which route, which model, the eval delta, and who approved. One line in the channel.
- **Users:** nothing for a routine swap. If the concierge is switched off, the app should say it is
  temporarily unavailable rather than silently hiding the entry point.
- **Trust and Safety:** any swap made because of harmful output, and the examples.

## After

- Record the eval numbers in `docs/research/` next to the previous ones. The series is what makes
  the next decision quick.
- If the swap was forced by a deprecation, check whether the fallback candidate is also deprecated;
  they tend to go together.
- Update ai-design §3.1's table, since it is the list this runbook reads from.
