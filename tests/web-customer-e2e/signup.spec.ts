// A new account takes the country the browser is in: nobody picks one any more (owner,
// 2026-10-24). A browser in Nairobi signs up by email from the sign-in page, and the profile
// the server creates is Kenyan. Before this, the site sent no sign-up country at all, so an
// email sign-up had a profile with no country and could never post a request.

import { expect, test } from '@playwright/test';

import { SERVICE_KEY } from './env';
import { client } from './seed';

const service = client(SERVICE_KEY);

async function profileCountry(email: string): Promise<string | null | undefined> {
  const { data, error } = await service.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (error) throw error;
  const user = data.users.find((u) => u.email === email);
  if (!user) return undefined;
  const row = await service.from('profiles').select('country_code').eq('user_id', user.id).single();
  return (row.data as { country_code: string | null } | null)?.country_code;
}

test('an email sign-up from Nairobi lands in Kenya, with no country to pick', async ({ browser }) => {
  const email = `e2e-web-signup-${Date.now().toString(36)}@suskii.test`;
  const context = await browser.newContext({ timezoneId: 'Africa/Nairobi', locale: 'en-KE' });
  const page = await context.newPage();
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));

  await page.goto('/en/auth');
  await expect(page.getByRole('combobox')).toHaveCount(0);
  await page.getByRole('button', { name: 'Email', exact: true }).click();
  await page.getByLabel('Email').fill(email);
  await page.getByRole('button', { name: 'Send code' }).click();
  await expect(page.getByText(email)).toBeVisible();

  await expect.poll(() => profileCountry(email)).toBe('KE');
  expect(errors).toEqual([]);
  await context.close();
});
