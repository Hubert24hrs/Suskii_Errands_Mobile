# docs/research — Phase 0 Deep Research

Output of Claude Code's Phase 0 (spec `agent_claude_code.phases[0]`), produced 2026-09-15 in parallel with Kimi Code's frontend build. These are documents only; there is no application code here.

**Start with [CHECKPOINT-PHASE-0.md](CHECKPOINT-PHASE-0.md)** (the decisions and next steps), then read [REPORT.md §0](REPORT.md#0-executive-summary--findings-that-change-the-plan) for the findings that change the plan.

| File | What it is |
|---|---|
| [CHECKPOINT-PHASE-0.md](CHECKPOINT-PHASE-0.md) | Phase 0 checkpoint: delivered, decisions, open decisions OD-01…OD-18, risks, next steps, staged HANDOFF entry |
| [REPORT.md](REPORT.md) | Full research report across all 13 Phase 0 tasks, with an evidence legend and sources |
| [vendor-decision-matrix.md](vendor-decision-matrix.md) | Weighted vendor scores, primary/fallback per category and country, package due diligence |
| [country-packs/](country-packs/) | Draft country packs: NG, KE, GH, ZA, UG (YAML with per-field verification status) |
| [compliance-checklist-and-dpia.md](compliance-checklist-and-dpia.md) | Compliance checklist, registrations per country, go-live checklist, DPIA outline, retention schedule |
| [risk-register.md](risk-register.md) | 30 scored risks with owners, mitigations and indicators |
| [cost-model.md](cost-model.md) | Monthly running cost at 1k / 10k / 100k / 1M MAU, two scenarios, sensitivities |
| [spike-plan.md](spike-plan.md) | 12 time-boxed spikes with methods and pass criteria |
| [spikes/](spikes/README.md) | Status board and results for spike runs |

Related, outside this folder: [docs/OPEN-DECISIONS.md](../OPEN-DECISIONS.md) (the live OD register), [docs/adr/](../adr/README.md) (decisions D-01…D-10 written up as ADR-0001…0010).

## Evidence tags

| Tag | Meaning |
|---|---|
| `[V]` | Verified against an official source this session |
| `[S]` | Secondary source |
| `[A]` | Assumption to confirm with a vendor, counsel or a spike |

Nothing tagged `[A]` should be implemented as fact.
