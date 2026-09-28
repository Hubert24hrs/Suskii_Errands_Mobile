import type { Config } from 'tailwindcss';
import preset from '../../packages/design-tokens/tailwind-preset';

// Every visual value comes from packages/design-tokens (tokens.json via the
// shared preset); nothing here defines a colour, size or duration.
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  presets: [preset as Config],
};

export default config;
