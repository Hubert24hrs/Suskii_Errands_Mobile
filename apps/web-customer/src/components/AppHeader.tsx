'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { authRepository } from '@/lib/repositories';
import type { AuthState } from '@/mocks/types';
import { LocaleSwitcher } from './LocaleSwitcher';
import Image from 'next/image';

export function AppHeader({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const router = useRouter();
  const [auth, setAuth] = useState<AuthState>({ status: 'unknown' });

  useEffect(() => authRepository.authStateChanges(setAuth), []);

  async function signOut() {
    await authRepository.signOut();
    router.push(`/${locale}`);
    router.refresh();
  }

  return (
    <header className="border-b border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised">
      <div className="mx-auto flex h-16 w-full max-w-5xl items-center justify-between gap-sm px-md sm:px-lg">
        <Link
          href={`/${locale}`}
          className="flex shrink-0 items-center gap-sm text-title-large text-ink-primary dark:text-ink-dark-primary"
          aria-label={dict.header.appName}
        >
          <Image src="/brand/suskii_logo.png" alt="" width={28} height={32} priority />
          {/* On a phone the logo stands alone, so the language links and sign-out fit on one line. */}
          <span className="hidden sm:inline">{dict.header.appName}</span>
        </Link>
        <nav className="hidden items-center gap-lg md:flex">
          {(
            [
              [dict.requests.listTitle, '/requests'],
              [dict.messages.title, '/messages'],
              [dict.meet.title, '/meet'],
              [dict.wallet.title, '/wallet'],
              [dict.settings.title, '/settings'],
            ] as const
          ).map(([label, href]) => (
            <Link
              key={href}
              href={`/${locale}${href}`}
              className="text-label-large text-ink-secondary transition-colors duration-normal ease-standard hover:text-brand-primary dark:text-ink-dark-secondary dark:hover:text-brand-secondary"
            >
              {label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-sm sm:gap-md">
          <LocaleSwitcher locale={locale} />
          {auth.status === 'signed_in' && auth.user ? (
            <>
              <span className="hidden text-body-small text-ink-secondary sm:inline dark:text-ink-dark-secondary">
                {auth.user.displayName || auth.user.phoneE164 || auth.user.email}
              </span>
              <button
                type="button"
                onClick={() => void signOut()}
                className="whitespace-nowrap rounded-md border border-outline px-md py-sm text-label-large sm:px-lg text-ink-secondary transition-colors duration-normal ease-standard hover:text-ink-primary dark:border-outline-dark dark:text-ink-dark-secondary dark:hover:text-ink-dark-primary"
              >
                {dict.auth.signOut}
              </button>
            </>
          ) : auth.status === 'unknown' ? null : (
            <Link
              href={`/${locale}/auth`}
              className="whitespace-nowrap rounded-md bg-brand-primary px-md py-sm text-label-large sm:px-lg text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
            >
              {dict.header.signIn}
            </Link>
          )}
        </div>
      </div>
    </header>
  );
}
