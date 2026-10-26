# ADR-0024 — Ask Suskii runs as a Supabase Edge Function calling Vertex AI

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-26 |
| Deciders | Owner (go-live goal: "Ask Suskii, the AI concierge … on Vertex AI"); Claude Code |
| Amends | `docs/plan/ai-design.md` §3 (where the service runs). ADR-0006 (model ids are configuration) and ADR-0012 (tools act as the user) are unchanged and binding |

## Context

ai-design §3 placed the AI service in a FastAPI app on Cloud Run. That was written before
anything ran. Six weeks later, the concierge's first version needs, end to end:

- a user-authenticated HTTPS endpoint;
- calls to Vertex Gemini;
- calls to the database as the user;
- redaction, a validator and an output filter.

None of that needs Python, a container or a separate deploy surface. Meanwhile:

- **The app already calls the backend with the user's session.** A Cloud Run service means a new
  URL in every build's configuration, CORS for the web app, and JWKS verification written by hand.
  An Edge Function under `withSupabase({ auth: "user" })` has all three already.
- **Staging deploys every Edge Function automatically from `main`** (`pipeline-main`), with a
  health gate and a rehearsed rollback (RB-14). A Cloud Run service needs an image pipeline, a
  digest promoted through Terraform and an infra apply the owner approves, for every change.
- **The pattern exists.** Push (FCM) is an Edge Function calling a Google API with a service
  account whose key lives in Secret Manager and reaches the function through the deploy pipeline.
  Vertex is the same shape.
- **Measured on 2026-10-26 in `suskii-staging`:**
  - `gemini-3.5-flash` serves in `europe-west2` and on `global`;
  - tools and a JSON response schema work in one request;
  - `thinkingBudget: 0` turns thinking off;
  - a turn is a few seconds of waiting on Vertex and a little CPU, well inside the Edge Function
    limits.

## Decision

The text concierge is the Edge Function `concierge`:

- **Calls to Vertex** go through `_shared/ai/llm.ts`. That is ai-design's LLM gateway: one interface, a Vertex
  implementation with ordered routes, one retry with jitter on 429 and 5xx, fallback to the next route,
  and a fake for tests. It uses the `concierge-vertex` service account, which holds
  `roles/aiplatform.user` and nothing else.
- **Model routes are a server-only `remote_config` row**, `ai.routes.concierge.text`, returned by
  `concierge_begin_turn` (ADR-0006). RB-11 changes models by changing that row.
- **Every database call is made as the customer**: `concierge_begin_turn`, `concierge_record_turn`,
  and the allowlisted read tools. RLS and grants apply exactly as they do to the app (ADR-0012).
- **v1 never creates or publishes a request.** A finished errand hands off to the request form,
  where the customer drops the pin and sets the price, so the model is never near coordinates or
  money (ai-design §§1, 5.3).

## Consequences

- One deploy surface for the backend; the concierge is rehearsed, rolled back and health-checked
  with everything else.
- **A service-account key exists**, where Cloud Run with Workload Identity would have had none. It
  lives only in Secret Manager and the function's environment, can call models and nothing else,
  and rotates under RB-10 like FCM's. That is the trade, and it is accepted for v1.
- **ai-design's Python-specific pieces are now TypeScript**: the Pydantic validators, a generated
  database client. The containment they stood for is kept: the allowlist file, its CI check, the
  validator that refuses money, the output filter.
- **Voice is not decided here.** A LiveKit Agents worker is a long-running process and cannot be
  an Edge Function. When voice is built it runs where a worker can run, and calls the same
  database functions.

## Revisit when

- A workload needs more than an Edge Function's limits: long multimodal jobs, batch evaluation in
  production, or voice.
- Google issues keyless federation that a Supabase function can use.
