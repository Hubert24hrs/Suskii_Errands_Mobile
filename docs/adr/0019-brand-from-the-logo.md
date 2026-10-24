# ADR-0019 — The brand comes from the Suskii Errands logo

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-24 |
| Deciders | Owner (supplied the logo and asked for its colours throughout); Claude Code |
| Supersedes | The *palette* of [ADR-0016](0016-aurora-design-system.md). The token architecture, the dark-first rule and the contrast tests stand |
| Related | `packages/suskii_design/lib/src/tokens/colors.dart`, `packages/design-tokens/tokens.json` |

## Context

ADR-0016 built the design system around a placeholder palette ("Aurora": mint, sky, violet), because no brand existed. The owner has now supplied the logo: a red-to-orange rounded tile, a white "S" of two arrows, an orange-to-amber cart badge, the wordmark in royal blue and the tagline "Rendering all available services" in gold, on a deep navy ground. The owner asked for the logo to be the app icon and the in-app logo, and for its colours to carry through the apps.

## Decision

- **Icon and logo.** The supplied artwork is the app icon on Android (legacy icons, plus an adaptive icon: the logo inside the 66 dp safe zone on the tile's red) and on iOS (opaque, full-bleed red, as the App Store requires). It is also the in-app logo (`SBrandMark`, an asset of `suskii_design`), and the logo and icon of all three web apps. The icon is generated from one source image by a script, so changing the artwork means regenerating, not editing by hand.
- **Palette.** Sampled from the artwork: red `#EF1E00`/`#D30303`, orange `#FE8802`/`#F54F01`, amber `#F7AF0B`, royal blue `#093095`, navy `#000D1E`.
  - **Dark (default):** navy ground `#050B18`, primary coral-orange `#FF7A45`, gradient `#FF4D2E → #FF7F1F → #FFB524`, secondary light blue `#8FA8FF`.
  - **Light:** warm off-white ground `#FBF7F5`, primary deep red `#C41A0A`, gradient `#B81506 → #D02A06 → #C24400`, secondary royal blue `#093095`, navy text `#0B1636`.
  - The logo's own red and orange are too light to carry white text at WCAG AA, which `design_tokens_test.dart` enforces. So the light theme uses deeper shades of the same hues: red at 6.0:1 and the darkest orange stop at 5.1:1.
- **Error colour.** Error moves to crimson (`#B0123E` light, `#FF7C96` dark), so that it stays distinguishable from a brand that is itself red.

## Consequences

- Every golden was re-recorded. The test harness now decodes the logo before the first frame, because a golden captured before the image decoded silently dropped it, and that would have made CI flaky.
- The web apps follow automatically through `tokens.css`. Their placeholder "S" mark is replaced by the logo.
- The tagline is legible only at icon sizes of about 60 pt or larger. At launcher sizes the logo reads as the tile and the cart. That is the artwork's choice, not ours.
- Store listing screenshots (RB-15) must be retaken.
