# infra/web — the three websites on Cloudflare

ADR-0023. `.github/workflows/web-deploy.yaml` builds each Next.js app with the OpenNext Cloudflare
adapter and deploys it as a Worker; `write-cloudflare-config.sh` writes the two files the adapter
needs at build time, so nothing under `apps/` changes and the adapter's version is pinned in the
workflow alone.

| App | Worker | Hosts |
|---|---|---|
| `apps/web-marketing` | `suskii-web-marketing` | `<zone>`, `www.<zone>`: home, legal pages, account deletion, `.well-known` files |
| `apps/web-customer` | `suskii-web-customer` | `app.<zone>` |
| `apps/web-admin` | `suskii-web-admin` | `admin.<zone>`, behind Cloudflare Access only |

`workers_dev` and `preview_urls` are off for all three: a `*.workers.dev` address would be a way
round Access for the console.

## Measured (2026-10-25, adapter 1.20.10, Next 15.5.28)

Compressed Worker size: `web-customer` 1,371 KiB, `web-admin` 1,248 KiB. Workers Free allows
3 MiB [S], so `WORKERS_PLAN=free`, and the workflow refuses a larger Worker before uploading it.
`next/image` is served unoptimised: without an `IMAGES` binding the adapter returns the original
file, which for a 28 px logo is what we want.

**Next.js 15 is out of the Next.js team's support window** (two years from its October 2024
release), and the adapter builds it only with `--dangerouslyUseUnsupportedNextVersion`. The owner
chose to deploy now and upgrade after (2026-10-25); the upgrade to Next 16 is filed in HANDOFF
part 15.

## One-time setup

1. **Cloudflare API token** (owner), as `CLOUDFLARE_API_TOKEN` in the GitHub environment
   `web-production`. Custom token:
   - Account: Workers Scripts Edit, Access: Apps and Policies Read;
   - Zone `<zone>`: Workers Routes Edit, DNS Edit, Zone Read.
2. **Cloudflare Access** (owner, Zero Trust): a self-hosted application for `admin.<zone>`, with a
   policy that allows the admin team's emails only. The workflow will not deploy the console
   until this exists.
3. **GitHub environment `web-production`**, with a required reviewer, holding the variables and
   secrets listed at the top of `web-deploy.yaml`.
