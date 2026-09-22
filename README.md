# Suskii Errands

> Tell us what you need. Set your price. Negotiate. Get it done.

An AI-powered, pan-African marketplace for getting anything done — one Flutter app with a
Customer/Provider mode switch, plus Next.js web surfaces and a Supabase backend.

## Repository layout

| Path | What | Owner |
|---|---|---|
| `docs/spec/SUSKII_BUILD_PROMPT.json` | Single source of truth (product, money, security, architecture) | both agents |
| `apps/mobile` | Flutter app — Customer + Provider modes | Kimi Code |
| `apps/web-customer` / `web-marketing` / `web-admin` | Next.js apps (M7/M8) | Kimi Code |
| `packages/suskii_*` | Shared Dart packages (design, core, domain, data, l10n) | Kimi Code |
| `packages/design-tokens` | `tokens.json`, required by all three web apps' `tailwind.config.ts` | Kimi Code |
| `package.json` (root) | npm workspace over the three web apps; holds the `next`/`postcss` override | Kimi Code |
| `contracts/` | Official API/data contracts (Claude Code) + `draft/` UI data requirements | Claude Code / Kimi Code |
| `supabase/`, `services/`, `infra/` | Backend (arrives with Claude Code phases) | Claude Code |
| `HANDOFF.md` | Shared log between the two build agents | both |

## Getting started (frontend)

Prereqs: Flutter 3.47.1 (see `.fvmrc`), Dart 3.13.

```bash
cd packages/suskii_domain && flutter pub get && cd ../..
cd packages/suskii_core && flutter pub get && cd ../..
cd packages/suskii_design && flutter pub get && cd ../..
cd packages/suskii_l10n && flutter pub get && flutter gen-l10n && cd ../..
cd packages/suskii_data && flutter pub get && cd ../..
cd apps/mobile && flutter pub get && flutter run --flavor dev -t lib/main_dev.dart
```

### The web apps

Prereqs: Node 22. The repository root is an npm workspace over all three, so install once
there rather than per app.

```bash
npm ci
npm run build -w apps/web-customer     # or web-marketing, web-admin
npm run dev   -w apps/web-customer
```

Addressed by workspace **path**, not package name. The names are scoped (`@suskii/web-customer`
and so on) because `web-admin` unscoped collides with a package flagged malicious on the public
registry (MAL-2025-38963), and the root `package.json` carries an override pinning `postcss`
above Next's own 8.4.31, which had two CVSS 7.5 advisories. `npm audit` reports 0
vulnerabilities; `frontend-ci` builds all three on every push.

### A testable Android build

```bash
cd apps/mobile && flutter build apk --release
# apps/mobile/build/app/outputs/flutter-apk/app-release.apk
```

The release config signs with the **debug** key, so this installs on a handset for testing and
is not a shippable artefact. Real signing needs the Play Console account (client action 9).

Melos (`melos bootstrap`) is optional convenience — see `melos.yaml`.

## Agent workflow

Two coding agents build this repo: **Kimi Code** (all frontends, goes first on mock data) and
**Claude Code** (research, contracts, Supabase backend, AI services, audits). See `AGENTS.md`
(Kimi) and `docs/spec/SUSKII_BUILD_PROMPT.json` → `agent_routing` for the full protocol.
