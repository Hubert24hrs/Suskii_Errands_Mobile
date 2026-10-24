# ADR-0023 — Host the three websites on Cloudflare

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-24 |
| Deciders | Owner (client); Claude Code |
| Unblocked by | Infra open question I-2 (`docs/plan/infra-cicd.md`) |

## Context

`apps/web-marketing`, `apps/web-customer` and `apps/web-admin` are Next.js apps that build in CI
but have never been deployed: where they run was open question I-2. The two candidates in the
plan were Vercel and Cloudflare via the OpenNext adapter [S].

Two constraints matter more than the build target:

- The **admin console must not be open to the internet**. It has to sit behind an identity-aware
  gate, and the plan already names Cloudflare Access for that, along with Cloudflare's firewall.
- The owner wants to start without a monthly hosting bill. Vercel's free tier is for
  non-commercial use, so a commercial app means its paid plan [S, `VERIFY-IN-RESEARCH` the current
  terms and price].

## Decision

We will host all three websites on **Cloudflare**, building each Next.js app with the **OpenNext
Cloudflare adapter** and deploying it as a Worker. The admin console is reachable only through
**Cloudflare Access**. Each site gets its own production `NEXT_PUBLIC_SUPABASE_*` values, and the
customer site gets `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY`, all set in Cloudflare, never in the
repository.

Nothing is deployed yet. It needs, in order:

1. **A domain** (client action 18), with its DNS on Cloudflare.
2. **A Cloudflare account**, made by the owner, with an API token for CI stored as a GitHub
   environment secret.
3. **The production backend** (go-live Phase 2, blocked on GCP billing), so the sites have real
   values to point at.

## Consequences

**Good:**

- One vendor for DNS, firewall, Access and hosting.
- The admin gate and the host are the same product, so the console never has a public window.
- A free tier to start [S].

**Bad / costs:**

- OpenNext is an adapter, not Next.js's own runtime, so some Next.js features may behave
  differently on Workers. `VERIFY-IN-RESEARCH`: check each app against OpenNext's supported-feature
  list before the first deploy, and keep the existing smoke and E2E suites green against the
  deployed build.
- Workers have their own size and CPU limits. `VERIFY-IN-RESEARCH` the current limits for the plan
  in use.

**Follow-on work:**

- A deploy workflow, added by pull request, one job per site.
- Cloudflare Terraform, which `infra/terraform/README.md` deferred until this decision and the
  domain: DNS, Access application and policy for the admin host, firewall rules, Turnstile if the
  sign-in pages use it.
- Replacing the placeholder domain `suskii-errands.example` across the apps once action 18 is done.
- `assetlinks.json` and `apple-app-site-association` served from the marketing site (RB-15).

## Alternatives considered

| Option | Why not |
|---|---|
| Vercel | Simplest for Next.js, but a commercial app needs its paid plan, and the admin console would still need Cloudflare Access (or an equivalent) in front, so two vendors instead of one |
| Self-hosting on Cloud Run | Possible inside the existing GCP plan, but it adds container builds and puts the websites behind the same billing blocker as the backend |
