# `services/ai` — the AI service, and what exists of it

**Ask Suskii, the text concierge, is built** (2026-10-26) as the `concierge` Edge Function on Vertex
AI, not as the FastAPI service the plan drew (ADR-0024). Its code is in `supabase/functions/concierge`
and `supabase/functions/_shared/ai`; its database half is `…20261026190000_concierge`; its evals are
`supabase/functions/concierge/evals` (golden 5/5, red-team 11/11 on 2026-10-26). This directory
keeps the allowlist, which binds every AI surface whatever runs it.

What is here is the part of `docs/plan/ai-design.md` that does not need a model, and the part that
has to exist *before* one does.

## The tool allowlist — `tools/allowlist.json`

ai-design §4.2 states the containment as a structural rule rather than a prompt:

> the AI service's database client is generated from an allowlist file, and a CI test fails if the
> generated client exposes any function not on it.

`tools/allowlist.json` is that file. It names every database function the concierge and the admin
assistant may call, and — separately — every function they must never reach. `tools/check_allowlist.py`
enforces three things, and runs in `backend-db.yaml`:

1. Every allowed function **exists** in `supabase/migrations`. An allowlist naming a function
   nobody wrote is a promise the service cannot keep.
2. No function appears on both lists.
3. Every **denied** function exists too — a denial that names nothing has stopped protecting
   anything, usually because the function was renamed.

The deny list is the interesting half. It is §4.2's own list: publishing, accepting, paying,
cancelling, transitioning, verifying, SOS, messaging, rating, every wallet and payout verb, and
every admin function. `raise_sos` is on it deliberately — an emergency must never depend on a
model understanding somebody. If the concierge detects distress it shows the SOS card and the
country's emergency numbers, and the person presses the button themselves.

## What the tools are

The database half is built (`supabase/migrations/…121100_ai_tools.sql` and `…121200_ai_admin_kpis.sql`)
and is useful with or without a model: `rank_offers` is what the offers board's compare runs on,
`get_price_band` is the price hint on the request form, and the eight `kpi_*` functions are the
admin dashboard's numbers.

## Still to come, and what each needs

| Piece | Needs |
|---|---|
| ~~FastAPI service, Gemini gateway, model routing, cost tracking~~ | Built for the concierge as an Edge Function (ADR-0024); token counts per turn in `ai_messages` |
| ~~Redaction (§6.1) and the output filter (§6.2)~~ | Built: `_shared/ai/redact.ts`, `concierge/filter.ts` |
| Golden and red-team eval suites (§8) | Built and run by hand (`concierge/evals/run.ts`); not yet a CI job, because each run calls Vertex and needs a key in CI |
| LiveKit Agents voice concierge | A LiveKit account (action 11) |
| Embeddings for `classify_request` | ADR-0006 must pick a model before a vector dimension can be fixed |
