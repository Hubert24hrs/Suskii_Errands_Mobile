# docs/plan — Phase 1 planning and architecture

Phase 1 output (spec `agent_claude_code.phases[1]`). Documents only: no code, no migrations.

Start with [PHASE-1-PLAN.md](PHASE-1-PLAN.md), which explains the staging, the order of deliverables, and which ones wait for Kimi's M8.5 hand-off.

| File | What |
|---|---|
| [PHASE-1-PLAN.md](PHASE-1-PLAN.md) | Deliverable list, sequencing, constraints carried from Phase 0, definition of done |
| [state-machines/job-lifecycle.md](state-machines/job-lifecycle.md) | 20 states, 31 transitions with actors, guards, side effects and timeouts |
| [state-machines/offer-negotiation.md](state-machines/offer-negotiation.md) | Offer states, negotiation thread rules, pricing guardrails, realtime events |
| [ui-draft-review.md](ui-draft-review.md) | Rolling review of Kimi's draft against master_spec; source of the UI change list |

Conventions match the rest of `docs/`: decisions are append-only, evidence tags `[V]`/`[S]`/`[A]`, and every document names its owner and date.
