# Phase 1 — Detailed Planning & Architecture

| | |
|---|---|
| Owner | Claude Code |
| Started | 2026-09-16 |
| Status | In progress |
| Rule | Documents only. No application code, no migrations |
| Inputs | [Phase 0 research](../research/README.md), [ADRs](../adr/README.md), [spike results](../research/spikes/README.md), `contracts/draft/ui-data-requirements.md` |

## The sequencing problem, stated plainly

The spec has Phase 1 begin after Kimi Code hands off at **M8.5**, when the UI inventory and the draft data requirements are complete. Kimi is at **M2**. The draft covers app shell, mode switch and verification/KYC; it does not yet cover requests, offers, negotiation, payments, tracking, chat, calls, disputes, wallet, referrals, provider tools, the web apps or admin.

So Phase 1 splits in two:

| | What | Depends on M8.5? |
|---|---|---|
| **Stage A — now** | The backend truth that the UI must conform to: state machines, ERD, RLS matrix, money flows, threat model, data-flow classification, AI design, infrastructure, test strategy, PRD, timeline | **No.** These derive from `master_spec` and Phase 0, not from Kimi's screens |
| **Stage B — at M8.5** | Contracts v1: RPC catalog, Edge Function OpenAPI, realtime events, error codes, storage conventions, fixtures, db-types — reconciled against the finished draft, plus the UI change list | **Yes** |

Stage A is not speculative work: it is where the rules live. Kimi builds against mocks shaped by the domain package, and contracts v1 mostly formalises what these documents decide. Publishing a partial contracts v1 now would be worse than useless — clients may call only what the contracts list, so a v1 that covers a third of the app would force a breaking v2 at M8.5.

**Exception worth making:** error codes and the `Money`/quote object shape are already being used by Kimi in M1 and M2. Those two get pinned early, as `contracts/v1-preview/`, clearly marked non-binding, so both sides stop guessing. Everything else waits.

## Deliverables and order

The spec lists fifteen. Ordered by what unblocks the most, with the Phase 0 evidence each one rests on.

| # | Deliverable | Stage | Rests on | Status |
|---|---|---|---|---|
| 1 | **Job lifecycle + negotiation state machines** (transition tables, guards, timeouts, side effects) | A | S-10, spec `job_lifecycle` | ✅ [state-machines/](state-machines/) |
| 2 | **Review of Kimi's draft** — gaps, missing states, client-side logic to move server-side | A, rolling | draft M1–M2 | ✅ first pass: [ui-draft-review.md](ui-draft-review.md) |
| 3 | **ERD** with indexes, constraints, partitioning | A | S-06, S-14, ADR-0009 | ✅ [erd.md](erd.md) |
| 4 | **RLS policy matrix** (role × table × operation × writable columns) | A | S-13 | ✅ [rls-policy-matrix.md](rls-policy-matrix.md) |
| 5 | **Money flow diagrams** per gateway: payment, refund, dispute, item float, tip, referral, clawback | A | S-14, ADR-0002, ADR-0003 | ✅ [money-flows.md](money-flows.md) + ADR-0011 |
| 6 | **C4 architecture diagrams** (context, container, component) | A | Phase 0 §10 | ✅ [architecture-c4.md](architecture-c4.md) + ADR-0012 |
| 7 | **Threat model (STRIDE)** per component | A | spec `security`, S-13 | ✅ [threat-model.md](threat-model.md) (+ R-31, R-32) |
| 8 | **Data flow diagram** marking personal, biometric, criminal-record and financial data | A | DPIA outline | ✅ [data-flow.md](data-flow.md) |
| 9 | **AI design**: prompts, tools, guardrails, eval sets, cost budget | A | ADR-0006, ADR-0012, S-07 (blocked), cost model §3 | **next** |
| 10 | **Infrastructure and CI/CD plan** | A | ADR-0008, spec `ci_cd` | then |
| 11 | **Test strategy** and device/network matrix | A | S-03/04/05 plan, spec `testing` | then |
| 12 | **PRD** with user stories and acceptance criteria | A | spec `baseline_features`, all of the above | then |
| 13 | **Revised timeline**, critical path, dependencies | A | everything | last of Stage A |
| 14 | **Contracts v1** + fixtures | **B** | complete draft at M8.5 | blocked |
| 15 | **UI change list** for Kimi in `HANDOFF.md` | **B**, rolling | draft review | rolling |

ADRs are written as decisions arise, not as a separate deliverable; ADR-0001…0010 already exist.

## Constraints that shape every document here

From Phase 0 and the spikes, these are settled and non-negotiable in Stage A:

1. **Money**: integer minor units + ISO 4217, exponent from a `currencies` table (UGX = 0). `round_half_even` is a database function, not the built-in `round()` (S-14).
2. **Ledger**: double-entry, zero-sum per transaction, single currency per transaction, balances derived. Validate before writing — a deferred constraint cannot be caught (S-14).
3. **Access control**: RLS default-deny plus `FORCE ROW LEVEL SECURITY`, **column-level grants** for anything a client may write, and `SECURITY DEFINER` functions with `SET search_path = ''` for state and money (S-13).
4. **Concurrency**: state transitions lock the aggregate row, are idempotent by key, and emit exactly one event (S-10).
5. **Location**: Broadcast for live pings; movement-gated heartbeat to the hot table; sampled trail persisted (ADR-0009, S-06).
6. **Payments**: collect to the gateway merchant balance, hold in our ledger, release by transfer. Never "escrow" in UI copy (ADR-0002).
7. **Hosting**: EU region, provisional London, pending S-01 (ADR-0008). Every user action should cost one round trip.

## Open decisions that gate Stage A

Work continues around them, with the spec default assumed and the alternative kept cheap to switch to.

| ID | Blocks | Assumed default while open |
|---|---|---|
| OD-11 | Money flow diagrams (which gateway per country) | Flutterwave primary, Paystack secondary |
| OD-12 | Money flows, country packs | Merchant balance + collection-agent terms |
| OD-13 | ERD (verification tables), AI/vendor cost | On-device daily, vendor weekly |
| OD-09 | ERD (police clearance fields), provider suspension rules | Accept ≤6 months old, re-verify yearly |
| OD-01/02/03 | Referral tables and ledger accounts | Platform-funded, lifetime with cap, 2.5% each |
| OD-04 | Item float in the money flow and ledger | Separate non-commissionable line |

Each is listed in [docs/OPEN-DECISIONS.md](../OPEN-DECISIONS.md) with its owner. None of them stops Stage A; all of them change configuration or a table column, not the architecture.

## Definition of done for Phase 1

- Every deliverable in Stage A exists and is internally consistent (a term means one thing across ERD, state machines and money flows).
- Every major decision has an ADR.
- Open decisions are still listed, with their defaults implemented as configuration.
- Kimi can read the state machines and money flows and see exactly which values come from the server.
- Phase 2 can start on the ERD and RLS matrix without re-litigating any of it.
