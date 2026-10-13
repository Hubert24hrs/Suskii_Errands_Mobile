// The admin console, end to end, against a real local Supabase. Every staff member signs in
// with a password and enrols a TOTP factor on first use; nothing here touches a mock.

import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync } from 'node:fs';

import { PASSWORD, SERVICE_KEY, SUPABASE_URL } from './env';
import { SEED_FILE, type Seed } from './seed';
import { freshCode } from './totp';

const seed = (): Seed => JSON.parse(readFileSync(SEED_FILE, 'utf8')) as Seed;
const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Who = keyof Seed['staff'];
const secrets = new Map<Who, string>();
const contexts = new Map<Who, BrowserContext>();

/** A signed-in page for a staff member: password, then TOTP (enrolled on first use). */
async function as(browser: Browser, who: Who): Promise<Page> {
  const existing = contexts.get(who);
  if (existing) return existing.pages()[0] ?? existing.newPage();
  const context = await browser.newContext();
  contexts.set(who, context);
  const page = await context.newPage();
  const errors: string[] = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('pageerror', (e) => errors.push(e.message));
  (page as Page & { errors?: string[] }).errors = errors;

  await page.goto('/sign-in');
  await page.getByLabel('Work email').fill(seed().staff[who].email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();

  const secretBox = page.getByTestId('totp-secret');
  await expect(page.getByLabel('6-digit code')).toBeVisible();
  if (await secretBox.isVisible()) {
    // First sign-in: GoTrue enrolled a factor and the console shows its secret once.
    await expect(page.getByAltText('QR code for your authenticator app')).toBeVisible();
    secrets.set(who, (await secretBox.textContent())!.trim());
  }
  const secret = secrets.get(who);
  if (!secret) throw new Error(`${who} has no TOTP secret`);
  await page.getByLabel('6-digit code').fill(await freshCode(secret));
  await page.getByRole('button', { name: 'Verify and continue' }).click();
  await expect(page).toHaveURL(/\/$/);
  return page;
}

/** Answers the step-up prompt when a sensitive action asks for a fresh code. */
async function stepUpIfAsked(page: Page, who: Who): Promise<void> {
  const prompt = page.getByRole('dialog', { name: 'Confirm it is you' });
  if (await prompt.isVisible().catch(() => false)) {
    await prompt.getByLabel('6-digit code').fill(await freshCode(secrets.get(who)!));
    await prompt.getByRole('button', { name: 'Confirm and continue' }).click();
    await expect(prompt).toBeHidden();
  }
}

test.describe.configure({ mode: 'serial' });

// On a failure, every staff member's tab: the test's own `page` is not the one that failed.
// Written beside the trace, so a CI artifact carries them.
test.afterEach(async ({}, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  for (const [who, context] of contexts) {
    for (const page of context.pages()) {
      await page.screenshot({ path: testInfo.outputPath(`${who}.png`) }).catch(() => {});
      const aria = await page.locator('body').ariaSnapshot().catch(() => 'no snapshot');
      writeFileSync(testInfo.outputPath(`${who}.aria.yml`), `${page.url()}\n${aria}`);
      const errors = (page as Page & { errors?: string[] }).errors ?? [];
      writeFileSync(testInfo.outputPath(`${who}.console.txt`), errors.join('\n'));
    }
  }
});

test.afterAll(async () => {
  for (const context of contexts.values()) await context.close();
});

test('a super admin enrols a second factor on first sign-in and sees the dashboard', async ({ browser }) => {
  const page = await as(browser, 'superA');
  await expect(page.getByRole('heading', { name: 'Nigeria' })).toBeVisible();
  // The dispute and the SOS the seed opened, counted by the server.
  const nigeria = page.locator('section', { has: page.getByRole('heading', { name: 'Nigeria' }) });
  await expect(nigeria.getByText('Funds held')).toBeVisible();
  await expect(nigeria.getByText('—')).toHaveCount(0);
});

test('a second sign-in asks for the code without enrolling again', async ({ browser }) => {
  const page = await as(browser, 'superA');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page).toHaveURL(/\/sign-in$/);
  await page.getByLabel('Work email').fill(seed().staff.superA.email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByLabel('6-digit code')).toBeVisible();
  await expect(page.getByTestId('totp-secret')).toHaveCount(0);
  await page.getByLabel('6-digit code').fill(await freshCode(secrets.get('superA')!));
  await page.getByRole('button', { name: 'Verify and continue' }).click();
  await expect(page).toHaveURL(/\/$/);
});

test('a customer account cannot get into the console at all', async ({ page }) => {
  const s = seed();
  const { data } = await service.auth.admin.getUserById(s.customer.id);
  await page.goto('/sign-in');
  await page.getByLabel('Work email').fill(data.user!.email!);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('You do not have permission for this action.')).toBeVisible();
});

test('a verification officer opens the document through a 60-second link and approves the step', async ({ browser }) => {
  const s = seed();
  const page = await as(browser, 'verifier');
  await page.goto('/verification');
  const row = page.getByRole('row', { name: new RegExp(s.kycCustomer.name) });
  await expect(row).toBeVisible();
  await row.click();
  const drawer = page.getByRole('dialog', { name: s.kycCustomer.name });
  await drawer.getByRole('button', { name: 'View document' }).click();
  await stepUpIfAsked(page, 'verifier');
  const link = drawer.getByText(/\/storage\/v1\/object\/sign\/kyc-docs\//);
  await expect(link).toBeVisible();
  // The link is a real signed URL for the uploaded file, and it works.
  const url = (await link.textContent())!.trim();
  const response = await page.request.get(url);
  expect(response.status()).toBe(200);
  expect(response.headers()['content-type']).toContain('image/png');
  await drawer.getByRole('button', { name: 'Close' }).click();

  await row.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByRole('row', { name: new RegExp(`${s.kycCustomer.name}.*Approved`) })).toBeVisible();
  // The customer's own view of the step: verified, by a person, through decide_kyc_step.
  const { data: user } = await service.auth.admin.getUserById(s.kycCustomer.id);
  const customer = createClient(SUPABASE_URL, process.env.SUPABASE_ANON_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await customer.auth.signInWithPassword({ email: user.user!.email!, password: PASSWORD });
  const { data: kyc, error } = await customer.rpc('get_my_kyc_profile');
  expect(error).toBeNull();
  const steps = (kyc as Array<{ kind: string; status: string }>);
  expect(steps.find((k) => k.kind === 'government_id')?.status).toBe('verified');
});

test('a dispute officer takes the case and resolves a 40% refund at the quoted amounts', async ({ browser }) => {
  const s = seed();
  const page = await as(browser, 'disputer');
  await page.goto('/disputes');
  const row = page.getByRole('row', { name: new RegExp(s.customer.name) });
  await row.getByRole('button', { name: 'Assign to me' }).click();
  await expect(page.getByRole('row', { name: new RegExp(`${s.customer.name}.*In review`) })).toBeVisible();
  await row.click();
  await expect(page).toHaveURL(new RegExp(`/disputes/${s.disputeId}$`));
  await page.getByLabel('Actions').selectOption('refund_partial');
  await page.getByLabel('Partial refund amount').fill('40');
  // money-flows 6a: 40.00 back, 7.50 commission, 49.60 to the provider after the 2.90 fee.
  await expect(page.getByText(/40\.00/).first()).toBeVisible();
  await expect(page.getByText(/49\.60/).first()).toBeVisible();
  await expect(page.getByRole('button', { name: 'Resolve dispute' })).toBeDisabled();
  await page.getByLabel(/Reason for the decision/).fill('Parcel never arrived; partial refund agreed.');
  await page.getByRole('button', { name: 'Resolve dispute' }).click();
  await stepUpIfAsked(page, 'disputer');
  await expect(page.getByText(/This dispute is resolved/)).toBeVisible();
  const { data } = await service.from('disputes')
    .select('status, refund_minor, assigned_officer_id').eq('id', s.disputeId).single();
  expect(data).toEqual({ status: 'resolved', refund_minor: 4000, assigned_officer_id: s.staff.disputer.id });
});

test('support answers and closes a ticket, handles the SOS, and clears a risk flag', async ({ browser }) => {
  const s = seed();
  const page = await as(browser, 'support');

  await page.goto('/support');
  const ticket = page.getByRole('row', { name: new RegExp(s.customer.name) }).first();
  await ticket.getByRole('button', { name: 'Assign to me' }).click();
  await expect.poll(async () => (await service.from('support_tickets')
    .select('assignee_id').eq('id', s.ticketId).single()).data?.assignee_id).toBe(s.staff.support.id);
  await ticket.click();
  await expect(page).toHaveURL(new RegExp(`/support/${s.ticketId}$`));
  await page.getByLabel(/reply/i).fill('We are looking at your refund now.');
  await page.getByRole('button', { name: 'Send reply' }).click();
  await expect(page.getByText('We are looking at your refund now.')).toBeVisible();
  await page.getByRole('button', { name: 'Close ticket' }).click();
  await page.getByRole('dialog', { name: 'Close ticket' }).getByRole('button', { name: 'Confirm' }).click();
  await expect.poll(async () => (await service.from('support_tickets')
    .select('status').eq('id', s.ticketId).single()).data?.status).toBe('closed');

  await page.goto('/sos');
  await page.getByRole('row', { name: new RegExp(s.customer.name) }).first().click();
  const sos = page.getByRole('dialog');
  await sos.getByRole('button', { name: 'Acknowledge' }).click();
  await expect.poll(async () => (await service.from('sos_incidents')
    .select('status').eq('id', s.sosId).single()).data?.status).toBe('acknowledged');
  await sos.locator('#sos-resolve-note').fill('Called the customer; they are safe.');
  await sos.getByRole('button', { name: 'Resolve', exact: true }).click();
  await expect.poll(async () => (await service.from('sos_incidents')
    .select('status').eq('id', s.sosId).single()).data?.status).toBe('resolved');

  await page.goto('/risk');
  await page.getByRole('row', { name: new RegExp(s.provider.name) }).first().click();
  await page.getByRole('dialog').getByRole('button', { name: 'Mark reviewed' }).click();
  await expect.poll(async () => (await service.from('fraud_flags')
    .select('status').eq('id', s.fraudFlagId).single()).data?.status).toBe('cleared');
});

test('a large withdrawal takes two different people', async ({ browser }) => {
  const s = seed();
  const finance = await as(browser, 'finance');
  await finance.goto('/payments');
  await finance.getByRole('tab', { name: 'Withdrawals' }).click().catch(() =>
    finance.getByRole('button', { name: 'Withdrawals' }).click());
  await finance.getByRole('row', { name: new RegExp(s.provider.name) }).first().click();
  await finance.getByRole('dialog').getByRole('button', { name: 'Approve' }).click();
  await stepUpIfAsked(finance, 'finance');
  await expect(finance.getByText('Awaiting second approver')).toBeVisible();
  await expect(finance.getByText(/You cannot approve your own request/)).toBeVisible();

  const superA = await as(browser, 'superA');
  await superA.goto('/payments');
  await superA.getByRole('tab', { name: 'Withdrawals' }).click().catch(() =>
    superA.getByRole('button', { name: 'Withdrawals' }).click());
  await superA.getByRole('row', { name: new RegExp(s.provider.name) }).first().click();
  await superA.getByRole('dialog').getByRole('button', { name: 'Approve' }).click();
  await stepUpIfAsked(superA, 'superA');
  await expect.poll(async () => (await service.from('withdrawals')
    .select('status').eq('id', s.withdrawalId).single()).data?.status).toBe('approved');
});

test('a feature flag changes only when a second super admin signs', async ({ browser }) => {
  const flag = async () => (await service.from('feature_flags').select('enabled')
    .eq('key', 'calls.pstn_fallback').is('country_code', null).single()).data?.enabled as boolean;
  const before = await flag();
  const label = (on: boolean) => (on ? 'Enabled' : 'Disabled');
  const summary = new RegExp(`calls\\.pstn_fallback: ${label(before)} → ${label(!before)}`);

  const superA = await as(browser, 'superA');
  await superA.goto('/config');
  const row = superA.getByRole('row', { name: /calls\.pstn_fallback/ });
  await row.getByRole('button', { name: 'Toggle flag' }).click();
  await stepUpIfAsked(superA, 'superA');
  await expect(superA.getByText(summary).first()).toBeVisible();
  // Proposed is not applied: the proposer cannot sign their own change.
  expect(await flag()).toBe(before);

  const superB = await as(browser, 'superB');
  await superB.goto('/config');
  // A rerun against the same database may find an earlier identical proposal; either applies
  // the same value.
  const change = superB.getByRole('listitem').filter({ hasText: summary }).first();
  await change.getByRole('button', { name: 'Approve change' }).click();
  await stepUpIfAsked(superB, 'superB');
  await expect.poll(flag).toBe(!before);
});

test('inviting staff and creating a promo are proposals a second super admin applies', async ({ browser }) => {
  const s = seed();
  const superA = await as(browser, 'superA');
  await superA.goto('/admin-users');
  await superA.getByRole('button', { name: 'Invite admin' }).click();
  const invite = superA.getByRole('dialog', { name: 'Invite admin user' });
  await invite.getByLabel('Full name').fill('Invitee');
  await invite.getByLabel('Work email').fill(s.invitee.email);
  await invite.getByLabel('Role').selectOption('support_agent');
  await invite.getByRole('button', { name: 'Send invite' }).click();
  await stepUpIfAsked(superA, 'superA');
  await expect(superA.getByText(/Sent for approval/)).toBeVisible();

  await superA.goto('/promos');
  await superA.getByRole('button', { name: 'Create campaign' }).click();
  const promo = superA.getByRole('dialog');
  const code = `E2E${s.run.toUpperCase()}`.slice(0, 20);
  await promo.getByLabel('Promo code').fill(code);
  await promo.getByLabel('Percent off').fill('10');
  await promo.getByLabel('Max discount').fill('200000');
  await promo.getByLabel('Budget').fill('5000000');
  await promo.getByLabel('Max redemptions').fill('100');
  await promo.getByLabel('From').fill('2026-01-01');
  await promo.getByLabel('Expiry date').fill('2099-01-01');
  await promo.getByRole('button', { name: /Save|Submit|Create/ }).last().click();
  await expect(superA.getByText(/Sent for approval/)).toBeVisible();
  await expect(superA.getByRole('row', { name: new RegExp(`${code}.*Awaiting approval`) })).toBeVisible();

  const superB = await as(browser, 'superB');
  await superB.goto('/config');
  for (const label of [/Staff access/, /Promo code/]) {
    const change = superB.getByRole('listitem').filter({ hasText: label }).first();
    await change.getByRole('button', { name: 'Approve change' }).click();
    await stepUpIfAsked(superB, 'superB');
    await expect(change).toBeHidden();
  }
  const { data: staff } = await service.from('admin_users').select('roles').eq('user_id', s.invitee.id).single();
  expect(staff?.roles).toEqual(['support_agent']);
  await superA.goto('/promos');
  await expect(superA.getByRole('row', { name: new RegExp(`${code}.*Active`) })).toBeVisible();
});

test('a super admin finds a provider by name, suspends them for a week, and reinstates them', async ({ browser }) => {
  const s = seed();
  const page = await as(browser, 'superA');
  await page.goto('/directory');
  await page.getByRole('tab', { name: 'Providers' }).click();
  await page.getByLabel('Search').fill(s.provider.name.slice(0, 8));
  await page.getByRole('row', { name: new RegExp(s.provider.name) }).click();
  const drawer = page.getByRole('dialog', { name: s.provider.name });
  await drawer.getByRole('button', { name: 'Suspend' }).click();
  const modal = page.getByRole('dialog', { name: 'Suspend' });
  await modal.getByLabel('Suspension reason').selectOption('quality_complaints');
  await modal.getByLabel('Suspend for').selectOption('7');
  await modal.getByRole('button', { name: 'Confirm' }).click();
  await expect.poll(async () => (await service.from('provider_profiles')
    .select('suspension_reason_key').eq('user_id', s.provider.id).single()).data?.suspension_reason_key)
    .toBe('quality_complaints');
  await drawer.getByRole('button', { name: 'Unsuspend' }).click();
  await expect.poll(async () => (await service.from('provider_profiles')
    .select('suspended_until').eq('user_id', s.provider.id).single()).data?.suspended_until).toBeNull();
});

test('jobs, the audit log and analytics read real rows', async ({ browser }) => {
  const s = seed();
  const page = await as(browser, 'superA');
  await page.goto(`/jobs/${s.requestId}`);
  await expect(page.getByText(`E2E parcel ${s.run}`).first()).toBeVisible();
  await expect(page.getByText('Disputed').first()).toBeVisible();

  await page.goto('/audit');
  await expect(page.getByRole('row', { name: /config\.review/ }).first()).toBeVisible();
  // The document read was audited before the link existed.
  await expect(page.getByRole('row', { name: /kyc\.document_access/ }).first()).toBeVisible();
  await expect(page.getByRole('row', { name: /dispute\.resolve/ }).first()).toBeVisible();

  await page.goto('/analytics');
  await expect(page.getByText(/Something went wrong/)).toHaveCount(0);

  const errors = (page as Page & { errors?: string[] }).errors ?? [];
  expect(errors.filter((e) => !/Failed to load resource/.test(e))).toEqual([]);
});
