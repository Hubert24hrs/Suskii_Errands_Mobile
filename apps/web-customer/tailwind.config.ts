import type { Config } from 'tailwindcss';
import tokens from '../../packages/design-tokens/tokens.json';

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

const spacing = Object.fromEntries(
  Object.entries(tokens.spacing).map(([k, v]) => [k, `${v}px`]),
);

const radius = Object.fromEntries(
  Object.entries(tokens.radius).map(([k, v]) => [k, `${v}px`]),
);

const duration = Object.fromEntries(
  Object.entries(tokens.motion.duration).map(([k, v]) => [k, `${v}ms`]),
);

const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          primary: c.brand.primary,
          'primary-strong': c.brand.primaryStrong,
          'on-primary': c.brand.onPrimary,
          secondary: c.brand.secondary,
          'on-secondary': c.brand.onSecondary,
        },
        success: { DEFAULT: c.semantic.light.success, dark: c.semantic.dark.success },
        warning: { DEFAULT: c.semantic.light.warning, dark: c.semantic.dark.warning },
        error: { DEFAULT: c.semantic.light.error, dark: c.semantic.dark.error },
        info: { DEFAULT: c.semantic.light.info, dark: c.semantic.dark.info },
        surface: {
          DEFAULT: c.surface.light.surface,
          raised: c.surface.light.surfaceRaised,
          muted: c.surface.light.surfaceMuted,
          dark: {
            DEFAULT: c.surface.dark.surface,
            raised: c.surface.dark.surfaceRaised,
            muted: c.surface.dark.surfaceMuted,
          },
        },
        ink: {
          primary: c.surface.light.textPrimary,
          secondary: c.surface.light.textSecondary,
          'dark-primary': c.surface.dark.textPrimary,
          'dark-secondary': c.surface.dark.textSecondary,
        },
        outline: { DEFAULT: c.surface.light.outline, dark: c.surface.dark.outline },
      },
      spacing,
      borderRadius: radius,
      fontFamily: {
        sans: tokens.typography.fontFamily.split(',').map((f) => f.trim()),
      },
      fontSize,
      transitionDuration: duration,
      transitionTimingFunction: {
        standard: tokens.motion.easing.standard,
        emphasized: tokens.motion.easing.emphasized,
      },
    },
  },
  plugins: [],
};

export default config;
