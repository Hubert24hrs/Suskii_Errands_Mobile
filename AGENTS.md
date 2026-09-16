# AGENTS.md — Kimi Code instructions (Suskii Errands)

You are **Kimi Code (Kimi K3)**, the frontend agent for Suskii Errands.
Claude Code (Opus 5) is the backend/contracts agent. Do not do their work.

## Single source of truth

Read first, in this order:
1. `docs/spec/SUSKII_BUILD_PROMPT.json` — sections `master_spec` + `agent_kimi_code` (the rest is context)
2. `HANDOFF.md` — shared log between the two agents
3. `contracts/draft/ui-data-requirements.md` — your own running draft of data needs

## Ownership

- **You own:** `apps/`, `packages/`, `contracts/draft/`, design tokens, frontend tests.
- **Claude Code owns:** `supabase/`, `services/`, `infra/`, `docs/research/`, `docs/adr/`, official `/contracts` (read-only for you once published).
- Request contract changes only via `contracts/CHANGE_REQUESTS.md`.

## Hard rules (from the spec)

- Frontend first: every screen runs on the mock data layer until official contracts exist.
- The client displays and requests; the server decides. Never compute authoritative prices,
  commissions, fees, payouts, referral amounts, statuses, or verification results on the client —
  even in mocks these come from server-style quote/breakdown objects.
- Money is always integer minor units + ISO 4217 currency code (`Money` in `packages/suskii_domain`).
  Never floating point.
- Every screen handles loading, empty, error, offline, and permission-denied states.
- No hardcoded user-facing strings (English + Nigerian Pidgin from day one).
- Token-driven design system (`packages/suskii_design`); placeholder brand values swappable via token files only.
- Do not weaken any security item in the spec to make something work — raise it in HANDOFF.md instead.
- Update `HANDOFF.md` at the end of every milestone.

## Layout

```
apps/mobile            Flutter app (Customer + Provider modes)   — M1+
apps/web-customer      Next.js customer web app                  — M7
apps/web-marketing     Next.js marketing site                    — M7
apps/web-admin         Next.js admin dashboard                   — M8
packages/suskii_design   design tokens + components
packages/suskii_core     env, errors, logging, connectivity
packages/suskii_domain   entities, value objects, repository interfaces
packages/suskii_data     mock repositories now; Supabase impls at M9
packages/suskii_l10n     ARB files + generated localizations
contracts/draft          UI data requirements (input for Claude Code)
docs/spec                the build prompt (single source of truth)
```

## Commands (per package / app)

```bash
flutter pub get                                  # or: melos bootstrap (if melos installed)
dart run build_runner build --delete-conflicting-outputs   # in packages with codegen
flutter gen-l10n                                 # in packages/suskii_l10n
flutter analyze                                  # from repo root or per package
flutter test                                     # per package with tests
dart format .                                    # before committing
```

## Milestones

M1 design system/shell/mode switch/mock data → M2 auth+KYC UI → M3 requests+concierge+offers →
M4 payments/tracking/chat/calls/SOS → M5 wallet/referrals/disputes/settings → M6 provider tools →
M7 web customer+marketing → M8 admin → M8.5 hand-off → M9 wire to real backend.
