import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

import { PICKUP, WEB_PORT } from './env';

/**
 * The website's provider side against a real local Supabase: the same screens the web
 * smoke drives on mocks, here reading and writing through the backend's own functions.
 * Build the site with the Supabase env first:
 *
 *   NEXT_PUBLIC_SUPABASE_URL=… NEXT_PUBLIC_SUPABASE_ANON_KEY=… npm run build -w apps/web-customer
 *   npx playwright test -c tests/web-customer-e2e
 *
 * Sign-in is by OTP on the site, and the local stack sends no SMS or email, so each person
 * signs in with a password here and the browser starts with that session.
 */
const root = path.resolve(__dirname, '../..');

export default defineConfig({
  testDir: '.',
  outputDir: path.join(__dirname, 'test-results'),
  timeout: Number(process.env.E2E_TIMEOUT ?? 120_000),
  expect: { timeout: 15_000 },
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['github'], ['list']] : 'list',
  globalSetup: './seed.ts',
  use: {
    ...devices['Desktop Chrome'],
    baseURL: `http://127.0.0.1:${WEB_PORT}`,
    trace: 'retain-on-failure',
    permissions: ['geolocation'],
    geolocation: PICKUP,
  },
  webServer: {
    command: `npx --no-install next start -p ${WEB_PORT}`,
    cwd: path.join(root, 'apps/web-customer'),
    url: `http://127.0.0.1:${WEB_PORT}/en`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
