# ADR-0016 — "Aurora": a dark-first design system driven by one token set

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-28 (built 2026-09-27) |
| Supersedes | — |
| Related | `packages/suskii_design`, `packages/design-tokens`, audit [2026-09-27](../audit/AUDIT-2026-09-27.md) |

## Context

The user asked for a premium, dark-first redesign — glass surfaces, gradient accents, fluid motion,
bold type — without changing business logic, and for it to reach the three web apps. The mobile
design system had a light-first palette, hard-coded colours in several screens, platform fonts, and
no motion or haptic vocabulary; the web apps each carried their own Tailwind colours.

Constraints that shaped the answer: WCAG AA in both themes, 48 dp targets, 200% text scaling,
English and Nigerian Pidgin, cheap Android devices on slow networks, and brand values that are
placeholders until the client supplies a brand.

## Decision

- **Tokens are the only source of colour, type, spacing, radius, blur and motion.**
  `packages/suskii_design/lib/src/tokens/` for Flutter and `packages/design-tokens/tokens.json` for
  the web, kept in lock-step: `design_tokens_test.dart` checks parity and contrast, and CI checks
  `tokens.css` is regenerated from `tokens.json`.
- **Dark first**, light a tap away: ink-navy surfaces, a mint → sky → violet brand gradient, and a
  `SuskiiColors` `ThemeExtension` for glass, gradient, semantic and shimmer colours.
- **Type**: Sora for display, Manrope for body, bundled (SIL OFL, licences registered) so the app
  never fetches a font and the web serves the same files via `next/font/local`.
- **Motion and haptics** as components (`SPressable`, `SFadeSlideIn`, `SHaptics`), with durations
  that collapse to zero under the platform's reduced-motion setting.
- **Contrast is tested, not eyeballed**: every text/surface pair in both themes at AA, component
  boundaries at 3:1, text on every gradient stop.
- **Goldens for every route** in both themes, and a catalogue test that renders each at 2× text and
  fails on overflow — which is how the full-screen pay button (a bare `Center` under loose
  constraints) was caught.

## Consequences

**Good:** a rebrand is an edit to two token files; no screen hard-codes a colour; accessibility is
enforced by tests rather than review.

**Bad / costs:** the brand is a placeholder; when the client's brand arrives, the gradient stops
must be re-checked for contrast (the test will say which fail). Goldens must be re-recorded
deliberately after any visual change (`flutter test --tags golden --update-goldens`). The headless
test font has no ₦ glyph, so money renders as a box in goldens only; store screenshots are taken on
devices for that reason.

## Alternatives considered

| Option | Why not |
|---|---|
| A third-party UI kit | Another dependency to theme against, and it would not share tokens with the web |
| Google Fonts at runtime | A network fetch on first launch on slow networks, and a privacy disclosure |
| Light first | The brief asked for dark first; both themes pass AA either way |
