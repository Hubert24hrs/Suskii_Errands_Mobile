# ADR-0006 — Model IDs live in remote config; routing is chosen by evaluation results

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code |
| Unblocked by | — |

## Context

The spec fixes the provider (Gemini via Vertex AI) and suggests a Pro-tier model for the concierge and Flash tiers for high-volume work, while asking us to verify current model names.

Phase 0 found a fast-moving lineup: `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, Flash-Lite variants, `gemini-3.8-live` as the default Live model, and `gemini-3.1-pro-preview` as the Pro flagship (Gemini 3.5 Pro never shipped) [V][S]. Deprecations carry as little as two weeks of notice, and the 3.7/3.8 Flash prices are promotional until 31 Dec 2026 [V]. Cost analysis also showed that 3.5 Flash is priced close to 3.1 Pro, so **context caching matters more than tier choice**.

## Decision

We will keep every model ID in remote config behind the LLM gateway interface, never hardcoded in prompts, functions or clients. Routing per workload is decided by the eval suite (spike S-07), not by tier name, and each swap must pass the golden set in English and Pidgin plus the red-team set before rollout. Context caching of system prompts and tool schemas is mandatory for any repeated call path, and cost is tracked per feature with alerts.

## Consequences

**Good:** model churn becomes a config change with an eval gate; promo pricing can be exploited without a code release; cost regressions are caught by CI.

**Bad / costs:** we must maintain the eval suite and the golden sets, including Pidgin, which needs native speakers.

**Follow-on work:** LLM gateway in the FastAPI service; eval suite in CI (Phase 7); per-feature token budgets and cost dashboards; a documented model-swap runbook.

## Alternatives considered

| Option | Why not |
|---|---|
| Pin one model per workload in code | Two-week deprecation notices would force emergency releases |
| Always use the Pro tier | Higher cost for no measured benefit on most turns |
| Always use the cheapest tier | Tool-use quality on multi-turn slot filling is unproven at that tier |

## Revisit when

Vertex changes its data-handling or regional terms, an eval shows a tier consistently failing, or the LLM provider itself changes.
