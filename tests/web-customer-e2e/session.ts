// The site signs in by OTP and the local stack sends no SMS or email, so a page starts with a
// session made by password instead: the same session supabase-js would have stored.

import type { Browser, Page } from '@playwright/test';

import { SUPABASE_URL } from './env';
import { signedIn } from './seed';

// supabase-js keeps the session under `sb-<first label of the host>-auth-token`.
const STORAGE_KEY = `sb-${new URL(SUPABASE_URL).hostname.split('.')[0]}-auth-token`;

export type TrackedPage = Page & { errors: string[] };

/** A new browser context signed in as `email`, collecting uncaught page errors. */
export async function signedInPage(browser: Browser, email: string): Promise<TrackedPage> {
  const signed = await signedIn(email);
  const { data } = await signed.auth.getSession();
  const context = await browser.newContext();
  // Only when absent, so a session the site has since refreshed is not put back.
  await context.addInitScript(
    ([key, value]) => {
      if (!window.localStorage.getItem(key)) window.localStorage.setItem(key, value);
    },
    [STORAGE_KEY, JSON.stringify(data.session)] as const,
  );
  const page = (await context.newPage()) as TrackedPage;
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(e.message));
  return page;
}
