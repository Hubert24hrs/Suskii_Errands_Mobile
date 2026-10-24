// The website's customer side, end to end, against a real local Supabase: publish a request
// from the form, watch an offer arrive without reloading, accept and pay, chat, read the
// handover PIN off the screen, confirm and rate. The provider's half goes through the same
// functions the apps call; the gateway's confirmation is the only service-role step.

import { expect, test } from '@playwright/test';
import type { SupabaseClient } from '@supabase/supabase-js';

import { PICKUP, SERVICE_KEY } from './env';
import { client, createProvider, createUser, must, signedIn } from './seed';
import { signedInPage, type TrackedPage } from './session';

const service = client(SERVICE_KEY);
const run = `c${Date.now().toString(36)}`;
const key = () => crypto.randomUUID();

let page: TrackedPage;
let provider: SupabaseClient;
let customerId: string;
let requestId: string;

async function status(): Promise<string> {
  const row = await must('status', service.from('requests').select('status').eq('id', requestId).single());
  return (row as { status: string }).status;
}

test.describe.configure({ mode: 'serial' });

test.beforeAll(async ({ browser }) => {
  const providerEmail = `e2e-web-cp-${run}@suskii.test`;
  await createProvider(providerEmail, `Tunde Web ${run}`);
  provider = await signedIn(providerEmail);
  await must('services', provider.rpc('update_provider_services', { p_category_keys: ['plumbing'] }));
  await must('areas', provider.rpc('update_provider_service_areas', { p_city_codes: ['lagos'] }));
  await must('online', provider.rpc('set_online', { p_online: true }));
  // Fifty metres from the pickup, and fresh: matching ignores a position older than two minutes.
  await must('heartbeat', provider.rpc('heartbeat', { p_lat: PICKUP.latitude + 0.0005, p_lng: PICKUP.longitude }));

  const customerEmail = `e2e-web-cc-${run}@suskii.test`;
  customerId = await createUser(customerEmail, `Ngozi Web ${run}`);
  page = await signedInPage(browser, customerEmail);
});

test.afterAll(async () => {
  await page?.context().close();
});

test('a request goes out from the form with the device as the pickup point', async () => {
  await page.goto('/en/requests/new');
  await page.getByLabel('Category').selectOption('plumbing');
  await page.locator('#description').fill(`The bathroom sink is blocked ${run}`);
  await page.locator('#pickup').fill('Herbert Macaulay Way, Yaba');
  await page.getByTestId('map-use-my-location').click();
  await expect(page.getByText('Pickup point set')).toBeVisible();
  // The provider online fifty metres away is counted, never placed (at least them: a stack
  // reused across runs keeps earlier providers online).
  await expect(page.getByTestId('create-nearby')).toHaveText(/^\d+ providers? near you right now$/);
  await page.getByRole('button', { name: 'Publish request' }).click();
  await expect(page).toHaveURL(/\/en\/requests\/[0-9a-f-]{36}$/);
  requestId = page.url().split('/').at(-1)!;
  expect(['published', 'offers_received']).toContain(await status());
  const row = (await must('request', service.from('requests').select('customer_id, pickup_label')
    .eq('id', requestId).single())) as { customer_id: string; pickup_label: string };
  expect(row).toEqual({ customer_id: customerId, pickup_label: 'Herbert Macaulay Way, Yaba' });
});

test('an offer appears on the open page without a reload, and is accepted', async () => {
  await must('offer', provider.rpc('create_offer', {
    p_idempotency_key: key(), p_request_id: requestId, p_amount_minor: 900000, p_message: 'On my way in 15.',
  }));
  // A broadcast on request:{id}:customer, or the refresh timer: no navigation either way.
  await expect(page.getByText('₦9,000.00')).toBeVisible({ timeout: 20_000 });
  await expect(page.locator('[data-testid^="offer-distance-"]')).toContainText('0.5 km');
  await page.getByRole('button', { name: 'Accept' }).click();
  await expect.poll(status).toBe('agreed');
});

test('payment: the page follows the gateway to held funds by itself', async () => {
  await page.getByRole('link', { name: 'Pay now' }).click();
  await expect(page).toHaveURL(new RegExp(`/requests/${requestId}/pay$`));
  await page.getByRole('button', { name: 'Pay now' }).click();
  await expect(page.getByText('Waiting for payment confirmation…')).toBeVisible();

  const payment = (await must('payment', service.from('payments').select('id, amount_minor')
    .eq('request_id', requestId).single())) as { id: string; amount_minor: number };
  const reference = `e2e-web-pay-${run}`;
  await must('checkout', service.rpc('gateway_record_checkout', {
    p_payment_id: payment.id, p_gateway: 'flutterwave', p_gateway_reference: reference,
    p_checkout_url: `https://checkout.example/${reference}`,
  }));
  await must('confirm', service.rpc('gateway_confirm_payment', {
    p_gateway: 'flutterwave', p_gateway_reference: reference, p_amount_minor: payment.amount_minor, p_fee_minor: 290,
  }));
  await expect(page.getByText('Payment received')).toBeVisible({ timeout: 20_000 });
  expect(await status()).toBe('assigned');
});

test('chat: the provider writes, the customer reads and answers', async () => {
  await must('send', provider.rpc('send_message', {
    p_idempotency_key: key(), p_request_id: requestId, p_body: 'Leaving now.',
  }));
  await page.goto(`/en/requests/${requestId}/chat`);
  await expect(page.getByText('Leaving now.')).toBeVisible();
  await page.getByLabel('Type a message').fill('See you soon.');
  await page.getByRole('button', { name: 'Send' }).click();
  await expect(page.getByText('See you soon.')).toBeVisible();
  // And the provider's next message arrives while the chat is open.
  await must('send', provider.rpc('send_message', {
    p_idempotency_key: key(), p_request_id: requestId, p_body: 'Two minutes away.',
  }));
  await expect(page.getByText('Two minutes away.')).toBeVisible({ timeout: 20_000 });
});

test('the PIN on the customer screen is the one that starts the work', async () => {
  await must('en_route', provider.rpc('set_job_status', {
    p_idempotency_key: key(), p_request_id: requestId, p_target: 'en_route',
  }));
  await must('arrived', provider.rpc('set_job_status', {
    p_idempotency_key: key(), p_request_id: requestId, p_target: 'arrived',
    p_lat: PICKUP.latitude, p_lng: PICKUP.longitude,
  }));
  await page.goto(`/en/requests/${requestId}`);
  await page.getByRole('button', { name: 'Reveal PIN' }).click();
  const pin = (await page.locator('span.tracking-widest').first().textContent())!.trim();
  expect(pin).toMatch(/^\d{6}$/);
  const verified = (await must('verify', provider.rpc('verify_pin', {
    p_idempotency_key: key(), p_request_id: requestId, p_pin: pin, p_kind: 'pickup',
  }))) as { verified: boolean };
  expect(verified.verified).toBe(true);
  expect(await status()).toBe('in_progress');
});

test('the customer confirms completion and rates the provider', async () => {
  await must('complete', provider.rpc('set_job_status', {
    p_idempotency_key: key(), p_request_id: requestId, p_target: 'completed_by_provider',
  }));
  await page.getByRole('button', { name: 'Confirm completion' }).click({ timeout: 20_000 });
  await page.getByRole('button', { name: 'Yes, the job is done' }).click();
  await expect.poll(status).toBe('confirmed');

  await page.getByRole('radiogroup', { name: 'Your rating' }).getByRole('radio').nth(4).click();
  await page.getByRole('button', { name: 'Punctual' }).click();
  await page.getByRole('button', { name: 'Submit rating' }).click();
  await expect.poll(async () => {
    const { data } = await service.from('ratings').select('stars').eq('request_id', requestId).eq('rater_id', customerId);
    return (data as Array<{ stars: number }> | null)?.map((r) => r.stars);
  }).toEqual([5]);
  expect(page.errors).toEqual([]);
});
