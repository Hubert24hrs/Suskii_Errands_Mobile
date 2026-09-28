import type { Config } from 'tailwindcss';
import tokens from './tokens.json';

// The one Tailwind preset the three Next.js apps share, built from
// tokens.json. Brand colours are CSS variables from tokens.css, so they
// follow the colour scheme like the Flutter themes; surfaces keep the
// explicit light/`dark` pairs the apps already use.

const c = tokens.color;

type TypeScale = { size: number; weight: number; lineHeight: number };
const typo = tokens.typography as unknown as Record<string, TypeScale | string>;
const kebab = (k: string) => k.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`);

const fontSize = Object.fromEntries(
  Object.entries(typo)
    .filter((entry): entry is [string, TypeScale] => typeof entry[1] !== 'string')
    .map(([k, v]) => [
      kebab(k),
      [`${v.size}px`, { lineHeight: String(v.lineHeight), fontWeight: String(v.weight) }] as [
        string,
        { lineHeight: string; fontWeight: string },
      ],
    ]),
);

const px = (record: Record<string, number>) =>
  Object.fromEntries(Object.entries(record).map(([k, v]) => [k, `${v}px`]));

const cssVar = (name: string) => `rgb(var(--sk-${name}) / <alpha-value>)`;

const stack = (value: string) => value.split(',').map((f) => f.trim());

const preset: Partial<Config> = {
  theme: {
    extend: {
      colors: {
        brand: {
          primary: cssVar('brand-primary'),
          'primary-strong': cssVar('brand-primary-strong'),
          'on-primary': cssVar('brand-on-primary'),
          secondary: cssVar('brand-secondary'),
          'on-secondary': cssVar('brand-on-secondary'),
        },
        success: { DEFAULT: c.semantic.light.success, dark: c.semantic.dark.success },
        warning: { DEFAULT: c.semantic.light.warning, dark: c.semantic.dark.warning },
        error: { DEFAULT: c.semantic.light.error, dark: c.semantic.dark.error },
        info: { DEFAULT: c.semantic.light.info, dark: c.semantic.dark.info },
        surface: {
          DEFAULT: c.surface.light.surface,
          raised: c.surface.light.surfaceRaised,
          muted: c.surface.light.surfaceMuted,
          high: c.surface.light.surfaceHigh,
          background: c.surface.light.background,
          dark: {
            DEFAULT: c.surface.dark.surface,
            raised: c.surface.dark.surfaceRaised,
            muted: c.surface.dark.surfaceMuted,
            high: c.surface.dark.surfaceHigh,
            background: c.surface.dark.background,
          },
        },
        ink: {
          primary: c.surface.light.textPrimary,
          secondary: c.surface.light.textSecondary,
          'dark-primary': c.surface.dark.textPrimary,
          'dark-secondary': c.surface.dark.textSecondary,
        },
        // `outline` is the decorative hairline (cards, dividers) the apps
        // have always used; `outline-strong` is the 3:1 boundary for inputs
        // and other components a person must be able to find (WCAG 1.4.11).
        outline: {
          DEFAULT: c.surface.light.outlineVariant,
          dark: c.surface.dark.outlineVariant,
          strong: c.surface.light.outline,
          'strong-dark': c.surface.dark.outline,
        },
      },
      backgroundImage: {
        'brand-gradient': 'var(--sk-gradient)',
      },
      spacing: px(tokens.spacing),
      borderRadius: px(tokens.radius),
      fontFamily: {
        sans: ['var(--font-body)', ...stack(tokens.typography.fontFamily)],
        display: ['var(--font-display)', ...stack(tokens.typography.displayFontFamily)],
      },
      fontSize,
      transitionDuration: Object.fromEntries(
        Object.entries(tokens.motion.duration).map(([k, v]) => [k, `${v}ms`]),
      ),
      transitionTimingFunction: tokens.motion.easing,
      backdropBlur: { glass: `${tokens.blur.glass}px` },
    },
  },
};

export default preset;
