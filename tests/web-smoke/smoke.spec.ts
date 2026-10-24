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
    '/en/meet',
    '/en/meet/meet-1',
    '/en/provider',
    '/en/provider/offers',
    '/en/provider/jobs',
    '/en/provider/jobs/job-p1',
    '/en/provider/jobs/job-p1/chat',
    '/en/provider/earnings',
    '/en/provider/tools',
    '/en/provider/business',
    '/en/provider/onboarding',
    '/en/provider/verification',
    '/pcm/provider',
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
    '/en/delete-account',
    '/pcm/delete-account',
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

test.describe('marketing app-link files', () => {
  const base = `http://127.0.0.1:${apps.marketing.port}`;

  // Unconfigured (no fingerprints, no Team ID) they must still be well-formed: Android reads
  // an empty list as "no association", and iOS treats a 404 the same way.
  test('assetlinks.json is JSON at the well-known path', async ({ request }) => {
    const response = await request.get(`${base}/.well-known/assetlinks.json`);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('application/json');
    expect(Array.isArray(await response.json())).toBe(true);
  });

  test('apple-app-site-association answers without a redirect', async ({ request }) => {
    const response = await request.get(`${base}/.well-known/apple-app-site-association`, {
      maxRedirects: 0,
    });
    expect([200, 404]).toContain(response.status());
  });
});

// 2026-10-24: Google/Apple sign-in, the renamed concierge card and Suskii Meet, on the mock
// backend (the build the smoke run serves has no Supabase env).
test.describe('customer: sign-in, home and Suskii Meet', () => {
  const base = `http://127.0.0.1:${apps.customer.port}`;

  test('Google signs the demo user in; home names the new services', async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(`${base}/en/auth`);
    await expect(page.getByTestId('auth-apple')).toBeVisible();
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
    await expect(page.getByText('Ask Suskii for any service')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Suskii Meet' })).toBeVisible();
    expect(errors).toEqual([]);
  });

  test('join a meet-up, then host one', async ({ page, context }) => {
    await context.grantPermissions(['geolocation']);
    await context.setGeolocation({ latitude: 6.455, longitude: 3.394 });
    const errors = watchErrors(page);
    await page.goto(`${base}/en/meet`);
    await page.getByTestId('meet-card-meet-1').click();
    await page.getByTestId('meet-join').click();
    await expect(page.getByTestId('meet-leave')).toBeVisible();
    await expect(page.getByText("Who's going")).toBeVisible();

    await page.goto(`${base}/en/meet`);
    await page.getByTestId('meet-create').click();
    await page.getByTestId('meet-title').fill('Sunday picnic');
    await page.getByTestId('meet-venue').fill('Muri Okunola Park');
    await page.getByTestId('meet-locate').click();
    await expect(page.getByText('Venue location set')).toBeVisible();
    await page.getByTestId('meet-publish').click();
    await expect(page.getByRole('heading', { name: 'Sunday picnic' })).toBeVisible();
    await expect(page.getByTestId('meet-cancel')).toBeVisible();
    expect(errors).toEqual([]);
  });
});

// 2026-10-24: the map pickup, providers near you and closest-first offers (ADR-0022). The smoke
// build has no Maps key, so the location fallback stands in for the map.
test.describe('customer: nearest providers', () => {
  const base = `http://127.0.0.1:${apps.customer.port}`;

  test('the pickup point comes from the device and the nearby count follows', async ({ page, context }) => {
    await context.grantPermissions(['geolocation']);
    await context.setGeolocation({ latitude: 6.455, longitude: 3.394 });
    const errors = watchErrors(page);
    await page.goto(`${base}/en/auth`);
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
    await page.goto(`${base}/en/requests/new`);
    await expect(page.getByTestId('map-fallback')).toBeVisible();
    await page.getByTestId('map-use-my-location').click();
    await expect(page.getByText('Pickup point set')).toBeVisible();
    await expect(page.getByTestId('create-nearby')).toContainText('providers near you');
    expect(errors).toEqual([]);
  });

  test('offers are closest first, each saying how far', async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(`${base}/en/auth`);
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
    await page.goto(`${base}/en/requests/req-1`);
    await expect(page.getByTestId('offers-sort-closest')).toHaveAttribute('aria-selected', 'true');
    const distances = await page.locator('[data-testid^="offer-distance-"]').allTextContents();
    expect(distances.length).toBeGreaterThan(0);
    const km = distances.map((t) => Number.parseFloat(t.replace(/[^0-9.]/g, '')));
    expect([...km].sort((a, b) => a - b)).toEqual(km);
    await page.getByTestId('offers-sort-best').click();
    await expect(page.getByText('Ranked by price and reputation together')).toBeVisible();
    expect(errors).toEqual([]);
  });
});

// 2026-10-24 (part 4): provider mode on the website, the same screens as the app's provider side.
// The mock keeps its session in memory, so in-app navigation is client-side (router.push).
test.describe('provider mode', () => {
  const base = `http://127.0.0.1:${apps.customer.port}`;

  async function signIn(page: Page) {
    await page.goto(`${base}/en/auth`);
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
  }

  async function go(page: Page, path: string) {
    await page.evaluate((url) => (window as unknown as { next: { router: { push(u: string): void } } }).next.router.push(url), path);
    await page.waitForURL(`**${path}`);
  }

  test('switch to provider, go online and make an offer', async ({ page }) => {
    const errors = watchErrors(page);
    await signIn(page);
    await page.getByTestId('dashboard-provider').click();
    await page.waitForURL(`${base}/en/provider`);
    await page.getByTestId('provider-online-toggle').click();
    await expect(page.getByTestId('provider-online-state')).toHaveText("You're online");
    await page.getByTestId('feed-req-feed-1').click();
    await page.getByTestId('offer-send').click();
    await expect(page.getByText('Offer sent.')).toBeVisible();
    await expect(page.getByTestId('feed-my-offer')).toBeVisible();
    expect(errors).toEqual([]);
  });

  test('answer a counter-offer, then run a job to completion', async ({ page, context }) => {
    await context.grantPermissions(['geolocation']);
    await context.setGeolocation({ latitude: 6.4531, longitude: 3.3958 });
    const errors = watchErrors(page);
    await signIn(page);
    await go(page, '/en/provider/offers');
    await page.getByTestId('offer-accept-offer-p1').click();
    await expect(page.getByText('Accepted. The customer pays next.')).toBeVisible();

    await go(page, '/en/provider/jobs/job-p1');
    await page.getByTestId('job-start').click();
    await page.getByTestId('job-arrived').click();
    await page.getByTestId('pin-input-pickup').fill('111111');
    await page.getByTestId('pin-verify-pickup').click();
    await expect(page.getByText('Wrong PIN. 4 attempts left.')).toBeVisible();
    await page.getByTestId('pin-input-pickup').fill('428135');
    await page.getByTestId('pin-verify-pickup').click();
    await expect(page.getByTestId('job-proofs')).toBeVisible();

    await page.getByTestId('job-complete').click();
    await expect(page.getByText('Add the required proof before marking the job complete.')).toBeVisible();
    await page
      .locator('[data-testid^="proof-input-"]')
      .first()
      .setInputFiles({ name: 'proof.jpg', mimeType: 'image/jpeg', buffer: Buffer.from([0xff, 0xd8, 0xff, 0xd9]) });
    await expect(page.getByText('Proof added.')).toBeVisible();
    await page.getByTestId('pin-input-delivery').fill('428135');
    await page.getByTestId('pin-verify-delivery').click();
    await expect(page.getByTestId('pin-delivery').getByText('PIN verified.')).toBeVisible();
    await page.getByTestId('job-complete').click();
    await expect(page.getByText('Waiting for the customer to confirm the job is done.')).toBeVisible();
    expect(errors).toEqual([]);
  });

  test('tools, business invitation and a state from the dropdown', async ({ page }) => {
    const errors = watchErrors(page);
    await signIn(page);
    await go(page, '/en/provider/tools');
    await page.getByTestId('tools-goal').getByRole('button', { name: 'Save goal' }).click();
    await expect(page.getByText('Goal saved.')).toBeVisible();
    await go(page, '/en/provider/business');
    await page.getByTestId('invitation-accept-org-swift').click();
    await expect(page.getByTestId('business-summary')).toContainText('SwiftErrands Ltd');
    await go(page, '/en/provider/onboarding');
    await page.getByTestId('onboarding-state').selectOption('kano');
    await page.getByTestId('onboarding-save').click();
    await page.waitForURL('**/en/provider/verification');
    await expect(page.getByTestId('kyc-steps')).toBeVisible();
    expect(errors).toEqual([]);
  });

  // 2026-10-24 (part 6): the account header the owner asked for, after the sportsbook panels.
  test('the dashboard header hides the balance until asked, then pays out', async ({ page }) => {
    const errors = watchErrors(page);
    await signIn(page);
    await go(page, '/en/provider');
    await expect(page.getByTestId('dashboard-account-label')).toHaveText('80*******8');
    await expect(page.getByTestId('dashboard-tier')).toHaveText('Trust tier: III · Trusted');
    await expect(page.getByTestId('dashboard-balance')).toHaveText('NGN *****');
    await page.getByTestId('dashboard-toggle-balance').click();
    await expect(page.getByTestId('dashboard-balance')).toHaveText(/^₦[\d,]+\.\d{2}$/);
    await page.getByTestId('dashboard-withdraw').click();
    await expect(page.getByRole('dialog')).toContainText('Withdraw funds');
    await page.keyboard.press('Escape');
    await page.getByTestId('dashboard-instant-payout').click();
    await expect(page.getByRole('dialog').getByTestId('tools-instant-payout')).toBeVisible();
    expect(errors).toEqual([]);
  });
});

// 2026-10-24 (part 4): what the app had and the website did not, on the customer side.
test.describe('customer: SOS, name and theme', () => {
  const base = `http://127.0.0.1:${apps.customer.port}`;

  test('SOS during a paid job; name and theme in settings', async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(`${base}/en/auth`);
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
    await page.evaluate(() => (window as unknown as { next: { router: { push(u: string): void } } }).next.router.push('/en/requests/req-8'));
    await page.getByTestId('sos-button').click();
    await page.getByTestId('sos-send').click();
    await expect(page.getByTestId('sos-sheet')).toContainText('Help has been notified.');
    await page.keyboard.press('Escape');
    await page.evaluate(() => (window as unknown as { next: { router: { push(u: string): void } } }).next.router.push('/en/settings'));
    await page.getByTestId('settings-name').fill('Adaeze O.');
    await page.getByTestId('settings-name-save').click();
    await expect(page.getByText('Name saved.')).toBeVisible();
    await page.getByTestId('theme-dark').check();
    await expect(page.locator('html')).toHaveClass(/dark/);
    await page.getByTestId('theme-system').check();
    await expect(page.locator('html')).not.toHaveClass(/dark/);
    expect(errors).toEqual([]);
  });

  test('delete the account, then keep it, as the app offers', async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto(`${base}/en/auth`);
    await page.getByTestId('auth-google').click();
    await page.waitForURL(`${base}/en`);
    await page.evaluate(() => (window as unknown as { next: { router: { push(u: string): void } } }).next.router.push('/en/settings'));
    await page.getByRole('button', { name: 'Delete account' }).click();
    await page.getByRole('button', { name: 'Delete my account' }).click();
    await expect(page.getByTestId('deletion-pending')).toContainText('Your account is scheduled for deletion');
    await page.getByTestId('deletion-keep').click();
    await expect(page.getByTestId('deletion-kept')).toHaveText('Your account is no longer scheduled for deletion.');
    await expect(page.getByTestId('deletion-pending')).toHaveCount(0);
    expect(errors).toEqual([]);
  });
});
