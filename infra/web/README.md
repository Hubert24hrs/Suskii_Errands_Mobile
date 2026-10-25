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

## Deployed (2026-10-25, web-deploy run 40215313910)

All three Workers are live on `suskiierrand.com`:

- **Marketing:** `/en`, `/en/legal/privacy`, `/en/delete-account` and `/.well-known/assetlinks.json` answer 200. The Worker is 1,044 KiB compressed.
- **Customer:** `app.` answers 307 to `/en` (1,389 KiB).
- **Admin:** `admin.` answers 302 to the Access sign-in at `summer-glitter-0acb.cloudflareaccess.com` (1,243 KiB).

The customer and admin smoke tests failed on that first run only because the custom-domain DNS records are created by the deploy itself and had not resolved yet. They retry now. The Access application is "Suskii admin console" (policy "Suskii admins", the owner's email only), on Zero Trust Free.

## Mail

`suskiierrand.com` receives mail through **Cloudflare Email Routing**. It has no mailboxes of its
own; each address forwards to the owner's verified mailbox, and the catch-all is off, so mail to
any other address is dropped:

| Address | Since | Used for |
|---|---|---|
| `privacy@` | 2026-10-25 | The privacy policy's contact (data requests) |
| `support@` | 2026-10-25 | The public contact on the Play listing |

Sending mail as the domain is not set up. Supabase Auth still sends from the owner's Gmail SMTP
(testing only, RB-15). Choosing a sending provider belongs to the launch auth settings.

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
