# design-tokens

`tokens.json` is the web mirror of the Flutter design tokens in `packages/suskii_design/lib/src/tokens/` (colors, spacing, radius, typography, motion). The two are a single source of truth split across platforms: **any change must be made in both places together**. All brand values are placeholders — a rebrand means editing this file and the corresponding `suskii_design` token files, nothing else. The Next.js apps (`apps/web-marketing`, `apps/web-customer`) consume this JSON directly from their Tailwind configs; do not add a build step or publish it as a package.
