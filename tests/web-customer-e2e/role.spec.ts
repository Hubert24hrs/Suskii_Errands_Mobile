// The first-run role question on the website, end to end against a real local Supabase
// (20261103120000): a new account is asked once, the answer is stored, Service Provider leads to
// provider onboarding without entering provider mode, and the question does not come back.

import { expect, test } from '@playwright/test';

import { SERVICE_KEY } from './env';
import { client, createUser, must } from './seed';
import { signedInPage } from './session';

const service = client(SERVICE_KEY);

test('a new account is asked how it will use Suskii Errands, once', async ({ browser }) => {
  const email = `e2e-web-role-${Date.now().toString(36)}@suskii.test`;
  const id = await createUser(email, 'Role Test');
  // createUser answers for the accounts other tests play; this one has not answered yet.
  await must('unanswer', service.from('profiles').update({ role_selected_at: null, signup_role: null }).eq('user_id', id));

  const page = await signedInPage(browser, email);
  await page.goto('/en');
  const gate = page.getByTestId('role-selection');
  await expect(gate).toBeVisible();
  await expect(gate.getByText('How would you like to use Suskii Errands?')).toBeVisible();
  await page.getByTestId('role-provider').click();
  await page.getByTestId('role-continue').click();
  await expect(page).toHaveURL(/\/en\/provider\/onboarding$/);
  await expect(gate).toHaveCount(0);

  const row = (await must('profile', service.from('profiles')
    .select('role_selected_at, signup_role, active_mode').eq('user_id', id).single())) as {
    role_selected_at: string | null;
    signup_role: string | null;
    active_mode: string;
  };
  expect(row.role_selected_at).not.toBeNull();
  expect(row.signup_role).toBe('provider');
  // Approval comes first: choosing Service Provider is not provider mode.
  expect(row.active_mode).toBe('customer');

  await page.goto('/en');
  await expect(page.getByTestId('role-selection')).toHaveCount(0);
  expect(page.errors).toEqual([]);
  await page.context().close();
});
