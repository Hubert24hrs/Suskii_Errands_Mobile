import type { Config } from 'tailwindcss';
import preset from '../../packages/design-tokens/tailwind-preset';

// Every visual value comes from packages/design-tokens (tokens.json via the
// shared preset); nothing here defines a colour, size or duration.
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  presets: [preset as Config],
  // Dark follows the device unless <html> pins a theme (`light` or `dark`),
  // set by the theme choice in Settings.
  darkMode: [
    'variant',
    ['@media (prefers-color-scheme: dark) { &:not(.light *) }', '&:is(.dark *)'],
  ],
};

export default config;
