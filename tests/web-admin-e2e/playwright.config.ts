import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

import { ADMIN_PORT, ANON_KEY, FUNCTIONS_PORT, SERVICE_KEY, SUPABASE_URL } from './env';

/**
 * The admin console against a real local Supabase: staff sign in with a password and a
 * TOTP code they enrol on first use, and every screen reads and writes through the
 * backend's own functions. Build the console with the Supabase env first:
 *
 *   NEXT_PUBLIC_SUPABASE_URL=… NEXT_PUBLIC_SUPABASE_ANON_KEY=… \
 *   NEXT_PUBLIC_SUPABASE_FUNCTIONS_URL=http://127.0.0.1:54390 npm run build -w apps/web-admin
 *   npx playwright test -c tests/web-admin-e2e
 *
 * `kyc-document-url` is served by Deno here rather than by the edge-runtime container, so
 * the run needs no image beyond what the database tests already use. Same entrypoint.
 */
const root = path.resolve(__dirname, '../..');

export default defineConfig({
  testDir: '.',
  timeout: Number(process.env.E2E_TIMEOUT ?? 180_000),
  expect: { timeout: 15_000 },
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['github'], ['list']] : 'list',
  globalSetup: './seed.ts',
  use: {
    ...devices['Desktop Chrome'],
    baseURL: `http://127.0.0.1:${ADMIN_PORT}`,
    trace: 'retain-on-failure',
  },
  webServer: [
    {
      command: `npx --yes deno@2.9.6 serve --allow-env --allow-net --allow-read --port ${FUNCTIONS_PORT} index.ts`,
      cwd: path.join(root, 'supabase/functions/kyc-document-url'),
      url: `http://127.0.0.1:${FUNCTIONS_PORT}`,
      env: {
        SUPABASE_URL,
        SUPABASE_JWKS_URL: `${SUPABASE_URL.replace('127.0.0.1', 'localhost')}/auth/v1/.well-known/jwks.json`,
        SUPABASE_PUBLISHABLE_KEY: ANON_KEY,
        SUPABASE_SECRET_KEY: SERVICE_KEY,
      },
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
    },
    {
      command: `npx --no-install next start -p ${ADMIN_PORT}`,
      cwd: path.join(root, 'apps/web-admin'),
      url: `http://127.0.0.1:${ADMIN_PORT}/sign-in`,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
    },
  ],
});
