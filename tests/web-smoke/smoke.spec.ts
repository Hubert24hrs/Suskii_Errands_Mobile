import { expect, test, type Page } from '@playwright/test';

import { apps } from './playwright.config';

const routes: Record<keyof typeof apps, string[]> = {
  customer: [
    '/',
    '/en',
    '/pcm',
    '/en/auth',
    '/en/requests',
    '/en/requests/new',
    '/en/messages',
    '/en/concierge',
    '/en/wallet',
    '/en/referrals',
    '/en/promos',
    '/en/disputes',
    '/en/support',
    '/en/settings',
    '/en/verify',
  ],
  marketing: [
    '/',
    '/en',
    '/pcm',
    '/en/services',
    '/en/how-it-works',
    '/en/become-a-provider',
    '/en/businesses',
    '/en/safety',
    '/en/referrals',
    '/en/faq',
    '/en/contact',
    '/en/cities/lagos',
    '/en/legal/terms',
    '/en/legal/privacy',
  ],
  admin: [
    '/sign-in',
    '/',
    '/jobs',
    '/disputes',
    '/support',
    '/verification',
    '/payments',
    '/risk',
    '/sos',
    '/promos',
    '/referrals',
    '/config',
    '/directory',
    '/analytics',
    '/audit',
    '/admin-users',
  ],
};

/** Collects console errors and uncaught exceptions for one page. */
function watchErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('pageerror', (e) => errors.push(e.message));
  return errors;
}

for (const [app, { port }] of Object.entries(apps)) {
  test.describe(app, () => {
    for (const route of routes[app as keyof typeof apps]) {
      test(`${route} renders cleanly`, async ({ page }) => {
        const errors = watchErrors(page);
        const response = await page.goto(`http://127.0.0.1:${port}${route}`, {
          waitUntil: 'networkidle',
        });
        expect(response, 'navigation response').not.toBeNull();
        expect(response!.status(), 'HTTP status').toBeLessThan(400);
        await expect(page.locator('body')).toBeVisible();
        await expect(page.locator('html')).toHaveAttribute('lang', /.+/);
        // A CSP violation or a hydration error shows up here first.
        expect(errors, 'console errors').toEqual([]);
      });
    }

    test('sends the security headers', async ({ request }) => {
      const response = await request.get(
        `http://127.0.0.1:${port}${routes[app as keyof typeof apps][0]}`,
      );
      const headers = response.headers();
      expect(headers['content-security-policy']).toContain("frame-ancestors 'none'");
      expect(headers['content-security-policy']).toContain("object-src 'none'");
      expect(headers['x-content-type-options']).toBe('nosniff');
      expect(headers['x-frame-options']).toBe('DENY');
      expect(headers['referrer-policy']).toBe('strict-origin-when-cross-origin');
      expect(headers['permissions-policy']).toBeTruthy();
      expect(headers['x-powered-by']).toBeUndefined();
    });

    for (const scheme of ['dark', 'light'] as const) {
      test(`paints the ${scheme} token background`, async ({ browser }) => {
        const context = await browser.newContext({ colorScheme: scheme });
        const page = await context.newPage();
        await page.goto(`http://127.0.0.1:${port}${routes[app as keyof typeof apps][1]}`);
        // The page background is the body's, or the root's when the body is
        // transparent.
        const background = await page.evaluate(() => {
          const body = getComputedStyle(document.body).backgroundColor;
          return body === 'rgba(0, 0, 0, 0)'
            ? getComputedStyle(document.documentElement).backgroundColor
            : body;
        });
        const [r, g, b] = background.match(/\d+/g)!.map(Number);
        const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
        if (scheme === 'dark') expect(luminance).toBeLessThan(0.2);
        else expect(luminance).toBeGreaterThan(0.8);
        await context.close();
      });
    }
  });
}
