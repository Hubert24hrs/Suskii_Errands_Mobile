// The website's provider side, end to end, against a real local Supabase: onboarding, going
// online, an offer, the job from the road to completion, the tools and a business — then the
// customer's SOS and name on the same job. Each step checks the database afterwards.

import { expect, test, type Browser, type BrowserContext } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';

import { SERVICE_KEY } from './env';
import { SEED_FILE, client, must, signedIn, type Seed } from './seed';
import { signedInPage, type TrackedPage } from './session';

const seed = (): Seed => JSON.parse(readFileSync(SEED_FILE, 'utf8')) as Seed;
const service = client(SERVICE_KEY);

// A 1×1 PNG: job-proofs takes images and PDFs.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64',
);

type Who = 'provider' | 'customer';
const pages = new Map<Who, TrackedPage>();
const contexts = new Map<Who, BrowserContext>();

/** One signed-in page per person for the whole file. */
async function as(browser: Browser, who: Who): Promise<TrackedPage> {
  const existing = pages.get(who);
  if (existing) return existing;
  const page = await signedInPage(browser, seed()[who].email);
  pages.set(who, page);
  contexts.set(who, page.context());
  return page;
}

/** The request's status as the database has it. */
async function status(): Promise<string> {
  const row = await must('status', service.from('requests').select('status').eq('id', seed().requestId).single());
  return (row as { status: string }).status;
}

test.describe.configure({ mode: 'serial' });

test.afterEach(async ({}, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  for (const [who, context] of contexts) {
    for (const page of context.pages()) {
      await page.screenshot({ path: testInfo.outputPath(`${who}.png`) }).catch(() => {});
      const aria = await page.locator('body').ariaSnapshot().catch(() => 'no snapshot');
      writeFileSync(testInfo.outputPath(`${who}.aria.yml`), `${page.url()}\n${aria}`);
      writeFileSync(testInfo.outputPath(`${who}.errors.txt`), (pages.get(who)?.errors ?? []).join('\n'));
    }
  }
});

test.afterAll(async () => {
  for (const context of contexts.values()) await context.close();
});

test('a provider picks a service and a state, by code', async ({ browser }) => {
  const page = await as(browser, 'provider');
  await page.goto('/en/provider/onboarding');
  await page.getByTestId('onboarding-service-plumbing').check();
  await page.getByTestId('onboarding-state').selectOption('lagos');
  await page.getByTestId('onboarding-save').click();
  await expect(page).toHaveURL(/\/en\/provider\/verification$/);
  await expect(page.getByTestId('kyc-steps')).toBeVisible();

  const { provider } = seed();
  const services = await must('services', service.from('provider_services').select('category_id').eq('provider_id', provider.id));
  expect(services).toHaveLength(1);
  const areas = (await must('areas', service.from('provider_service_areas')
    .select('cities(code)').eq('provider_id', provider.id))) as unknown as Array<{ cities: { code: string } }>;
  expect(areas.map((a) => a.cities.code)).toEqual(['lagos']);
});

test('going online starts the heartbeat, so matching can find them', async ({ browser }) => {
  const page = await as(browser, 'provider');
  await page.goto('/en/provider');
  await page.getByTestId('provider-online-toggle').click();
  await expect(page.getByTestId('provider-online-state')).toHaveText("You're online");

  // The position, with no job: only `heartbeat` writes it, and matching ignores one older
  // than two minutes.
  await expect.poll(async () => {
    const { data } = await service.from('provider_live_location')
      .select('updated_at').eq('provider_id', seed().provider.id).maybeSingle();
    return data ? Date.now() - Date.parse((data as { updated_at: string }).updated_at) : null;
  }).toBeLessThan(60_000);
});

test('the request is in the feed and an offer goes in at its exact minor units', async ({ browser }) => {
  const page = await as(browser, 'provider');
  const { requestId, provider } = seed();
  await page.goto('/en/provider');
  await page.getByTestId(`feed-${requestId}`).click();
  const modal = page.getByTestId('feed-request-modal');
  await modal.getByLabel('Your price').fill('8000');
  await modal.getByTestId('offer-message').fill('Can be there in 20 minutes.');
  await modal.getByTestId('offer-send').click();
  await expect(modal.getByTestId('feed-my-offer')).toBeVisible();

  const offers = (await must('offers', service.from('offers').select('amount_minor, author_side')
    .eq('request_id', requestId).eq('provider_id', provider.id))) as Array<{ amount_minor: number; author_side: string }>;
  expect(offers).toEqual([{ amount_minor: 800000, author_side: 'provider' }]);

  await page.goto('/en/provider/offers');
  await expect(page.getByTestId('my-offers')).toContainText('8,000');
});

test('the customer accepts and pays; the provider runs the job to completion', async ({ browser }) => {
  const { requestId, provider, customer: who } = seed();
  // The customer's side and the gateway's confirmation happen off this page.
  const customer = await signedIn(who.email);
  const offer = (await must('offer', service.from('offers').select('id')
    .eq('request_id', requestId).eq('provider_id', provider.id).single())) as { id: string };
  await must('accept', customer.rpc('accept_offer', { p_idempotency_key: crypto.randomUUID(), p_offer_id: offer.id }));
  const payment = (await must('start_payment', customer.rpc('start_payment', {
    p_idempotency_key: crypto.randomUUID(), p_request_id: requestId,
  }))) as Array<{ payment_id: string; amount_minor: number }>;
  const reference = `e2e-web-${seed().run}`;
  await must('checkout', service.rpc('gateway_record_checkout', {
    p_payment_id: payment[0]!.payment_id, p_gateway: 'flutterwave', p_gateway_reference: reference,
    p_checkout_url: `https://checkout.example/${reference}`,
  }));
  await must('confirm', service.rpc('gateway_confirm_payment', {
    p_gateway: 'flutterwave', p_gateway_reference: reference,
    p_amount_minor: payment[0]!.amount_minor, p_fee_minor: 290,
  }));
  expect(await status()).toBe('assigned');

  const page = await as(browser, 'provider');
  await page.goto('/en/provider/jobs');
  await page.getByTestId(`provider-job-${requestId}`).click();
  await page.getByTestId('job-start').click();
  await expect.poll(status).toBe('en_route');

  // The browser stands at the pickup, so arrival goes in with a position the server accepts.
  await page.getByTestId('job-arrived').click();
  await expect.poll(status).toBe('arrived');

  const pin = String(await must('pin', customer.rpc('reveal_job_pin', { p_request_id: requestId, p_kind: 'pickup' })));
  await page.getByTestId('pin-input-pickup').fill(pin);
  await page.getByTestId('pin-verify-pickup').click();
  await expect.poll(status).toBe('in_progress');

  await page.locator('[data-testid^="proof-input-"]').first().setInputFiles({
    name: 'after.png', mimeType: 'image/png', buffer: PNG,
  });
  await expect.poll(async () => {
    const { count } = await service.from('proofs').select('id', { count: 'exact', head: true }).eq('request_id', requestId);
    return count;
  }).toBe(1);
  await page.getByTestId('job-complete').click();
  await expect.poll(status).toBe('completed_by_provider');
});

test('tools: the week and the goal are saved on the server', async ({ browser }) => {
  const page = await as(browser, 'provider');
  const { provider } = seed();
  await page.goto('/en/provider/tools');
  const hours = page.getByTestId('tools-availability');
  await hours.getByRole('button', { name: 'Add hours' }).click();
  await hours.getByRole('button', { name: 'Save hours' }).click();
  await expect(hours.getByText('Hours saved.')).toBeVisible();
  const slots = (await must('slots', service.from('availability_schedules')
    .select('weekday, start_time, end_time').eq('provider_id', provider.id))) as Array<Record<string, unknown>>;
  expect(slots).toEqual([{ weekday: 1, start_time: '09:00:00', end_time: '17:00:00' }]);

  const goal = page.getByTestId('tools-goal');
  await goal.getByLabel('Goal amount').fill('50000');
  await goal.getByRole('button', { name: 'Save goal' }).click();
  await expect(goal.getByText('Goal saved.')).toBeVisible();
  const saved = (await must('goal', service.from('provider_earnings_goals')
    .select('target_minor, currency').eq('provider_id', provider.id).single())) as Record<string, unknown>;
  expect(saved).toEqual({ target_minor: 5000000, currency: 'NGN' });
});

test('a business registers and its number is kept sealed, shown masked', async ({ browser }) => {
  const page = await as(browser, 'provider');
  const number = `RC${seed().run.toUpperCase().slice(-6)}`;
  await page.goto('/en/provider/business');
  await page.getByTestId('business-name').fill(`Swift Plumbing ${seed().run}`);
  await page.getByTestId('business-number').fill(number);
  await page.getByTestId('business-register-submit').click();
  await expect(page.getByTestId('business-summary')).toContainText(`Swift Plumbing ${seed().run}`);

  const org = (await must('org', service.from('organizations').select('verification_status, registration_masked')
    .eq('created_by', seed().provider.id).single())) as { verification_status: string; registration_masked: string };
  expect(org.verification_status).toBe('unverified');
  expect(org.registration_masked).not.toContain(number);
});

test('earnings, offers and verification read the real backend without an error', async ({ browser }) => {
  const page = await as(browser, 'provider');
  for (const path of ['/en/provider/earnings', '/en/provider/offers', '/en/provider/verification']) {
    await page.goto(path);
    await expect(page.locator('main')).toBeVisible();
    // Inside main: Next.js keeps an empty role="alert" route announcer at the end of body.
    await expect(page.locator('main').getByRole('alert')).toHaveCount(0);
  }
  expect(page.errors).toEqual([]);
});

test('the customer raises an SOS on the job and changes their name', async ({ browser }) => {
  const page = await as(browser, 'customer');
  const { requestId, customer } = seed();
  await page.goto(`/en/requests/${requestId}`);
  await page.getByTestId('sos-button').click();
  await page.getByTestId('sos-send').click();
  await expect.poll(async () => {
    const { count } = await service.from('sos_incidents').select('id', { count: 'exact', head: true })
      .eq('request_id', requestId).eq('raised_by', customer.id);
    return count;
  }).toBe(1);

  await page.goto('/en/settings');
  await page.getByTestId('settings-name').fill('Ada Okafor');
  await page.getByTestId('settings-name-save').click();
  await expect.poll(async () => {
    const { data } = await service.from('profiles').select('display_name').eq('user_id', customer.id).single();
    return (data as { display_name: string }).display_name;
  }).toBe('Ada Okafor');
  // The position the page offered went with the SOS.
  const sos = (await must('sos', service.from('sos_incidents').select('point')
    .eq('request_id', requestId).single())) as { point: unknown };
  expect(sos.point).not.toBeNull();
});
