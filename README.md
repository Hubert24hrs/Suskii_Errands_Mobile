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

Melos (`melos bootstrap`) is optional convenience — see `melos.yaml`.

## Agent workflow

Two coding agents build this repo: **Kimi Code** (all frontends, goes first on mock data) and
**Claude Code** (research, contracts, Supabase backend, AI services, audits). See `AGENTS.md`
(Kimi) and `docs/spec/SUSKII_BUILD_PROMPT.json` → `agent_routing` for the full protocol.
