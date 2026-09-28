import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

/**
 * Smoke tests for the three Next.js apps, against their production builds
 * (`npm run build -w apps/<app>` first). Every listed route must answer,
 * render without a console error under the CSP, carry the security headers,
 * and paint the token background in both colour schemes.
 *
 *   npx playwright test -c tests/web-smoke
 */
export const apps = {
  customer: { dir: 'apps/web-customer', port: 3101 },
  marketing: { dir: 'apps/web-marketing', port: 3102 },
  admin: { dir: 'apps/web-admin', port: 3103 },
} as const;

const root = path.resolve(__dirname, '../..');

export default defineConfig({
  testDir: '.',
  timeout: 30_000,
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['github'], ['list']] : 'list',
  use: { trace: 'retain-on-failure' },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'phone', use: { ...devices['Pixel 7'] } },
  ],
  webServer: Object.values(apps).map(({ dir, port }) => ({
    command: `npx --no-install next start -p ${port}`,
    cwd: path.join(root, dir),
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  })),
});
