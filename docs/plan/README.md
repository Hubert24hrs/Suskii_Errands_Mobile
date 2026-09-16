# docs/plan — Phase 1 planning and architecture

Phase 1 output (spec `agent_claude_code.phases[1]`). Documents only: no code, no migrations.

Start with [PHASE-1-PLAN.md](PHASE-1-PLAN.md), which explains the staging, the order of deliverables, and which ones wait for Kimi's M8.5 hand-off.

| File | What |
|---|---|
| [PHASE-1-PLAN.md](PHASE-1-PLAN.md) | Deliverable list, sequencing, constraints carried from Phase 0, definition of done |
| [state-machines/job-lifecycle.md](state-machines/job-lifecycle.md) | 20 states, 31 transitions with actors, guards, side effects and timeouts |
| [state-machines/offer-negotiation.md](state-machines/offer-negotiation.md) | Offer states, negotiation thread rules, pricing guardrails, realtime events |
| [ui-draft-review.md](ui-draft-review.md) | Rolling review of Kimi's draft against master_spec; source of the UI change list |
| [erd.md](erd.md) | Tables, keys, constraints, indexes, partitioning, schema placement, encryption |
| [rls-policy-matrix.md](rls-policy-matrix.md) | Role × table × operation × writable columns; storage and realtime authorisation; pgTAP obligations |
| [money-flows.md](money-flows.md) | Chart of accounts and verified ledger postings for every money path: payment, tip, item float, promo, cancellations, disputes, chargeback, payout reversal, referral withdrawal |
| [architecture-c4.md](architecture-c4.md) | Context, container and component views; container responsibilities; regions; scale-out path |
| [threat-model.md](threat-model.md) | STRIDE per component with controls and residual risk; owners for high and medium residuals |
| [data-flow.md](data-flow.md) | Data classes, trust boundaries, 26 flows with protection and retention, cross-border transfers |
| [ai-design.md](ai-design.md) | AI features, gateway and model routing, tool allowlist, prompt structure, guardrails, voice, eval sets, cost budget |
| [infra-cicd.md](infra-cicd.md) | Environments, IaC, secrets, CI workflows, promote-don't-rebuild delivery, expand/contract migrations, observability and SLOs, backups |
| [test-strategy.md](test-strategy.md) | Test layers and catalogue (pgTAP, concurrency, money properties, webhooks, integration, load, security), device and network matrix, quality gates |
| [prd/](prd/README.md) | PRD: personas, non-functional requirements, 147 user stories with acceptance criteria across shared, customer, provider, business, web, marketing and admin |

Conventions match the rest of `docs/`: decisions are append-only, evidence tags `[V]`/`[S]`/`[A]`, and every document names its owner and date.
