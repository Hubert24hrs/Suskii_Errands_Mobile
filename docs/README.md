# docs

Project documentation. `docs/spec/` is shared; everything else here is owned by Claude Code (see `CLAUDE.md`).

| Path | What | Read it when |
|---|---|---|
| [spec/SUSKII_BUILD_PROMPT.json](spec/SUSKII_BUILD_PROMPT.json) | The build prompt: product, money rules, verification, architecture, security, agent instructions | Before anything else. It wins every conflict |
| [OPEN-DECISIONS.md](OPEN-DECISIONS.md) | OD-01…OD-18 awaiting the client or counsel, with the default we build meanwhile | Starting a phase, or writing a checkpoint |
| [plan/](plan/README.md) | Phase 1 planning: state machines, draft review, and the architecture documents that become contracts v1 | Designing or building a backend feature |
| [adr/](adr/README.md) | Architecture decision records with an index and template | Making or questioning a technical decision |
| [research/](research/README.md) | Phase 0 evidence: report with sources, vendor matrix, country packs, compliance and DPIA, risk register, cost model, spike plan, checkpoint | Choosing a vendor, sizing cost, checking a country rule |
| [runbooks/](runbooks/README.md) | Operational procedures, one per failure mode | On call, or shipping a feature that can fail in production |
| [audit/](audit/README.md) | Dated audit findings and severity rules | After a Kimi integration milestone, before release |

Related files outside `docs/`: `CLAUDE.md` (Claude Code instructions and maintenance policy), `AGENTS.md` (Kimi Code instructions), `HANDOFF.md` (shared log), `contracts/README.md` (the API agreement).

## Conventions

- **Evidence tags** on factual claims: `[V]` verified against an official source, `[S]` secondary source, `[A]` assumption. Nothing tagged `[A]` may be implemented as fact.
- **Decisions are append-only.** Supersede an ADR; never rewrite one that is accepted. Never delete a row from the open-decisions or risk registers.
- **Every document states its date** and who owns it.
