'use client';

// The customer/provider switch. The server records the active mode
// (`set_active_mode`) and refuses provider mode until verification is done,
// which sends the person to set it up instead.

import { usePathname, useRouter } from 'next/navigation';
import { useState, type ReactNode } from 'react';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { ErrorCodes, isAppError, userRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';

export function useModeSwitch(locale: Locale) {
  const router = useRouter();
  const pathname = usePathname();
  const inProvider = pathname.startsWith(`/${locale}/provider`);
  const [switching, setSwitching] = useState(false);

  async function switchTo(mode: 'customer' | 'provider') {
    setSwitching(true);
    try {
      await userRepository.setActiveMode(mode, newIdempotencyKey());
      router.push(mode === 'provider' ? `/${locale}/provider` : `/${locale}`);
    } catch (error) {
      if (mode === 'provider' && isAppError(error, ErrorCodes.providerNotVerified)) {
        router.push(`/${locale}/provider/onboarding`);
      } else if (mode === 'customer') {
        router.push(`/${locale}`);
      }
    } finally {
      setSwitching(false);
    }
  }

  return { inProvider, switching, switchTo };
}

/** A button that flips to the other mode from wherever it is shown. */
export function ModeSwitchButton({
  locale,
  dict,
  className,
  testId = 'mode-switch',
  children,
}: {
  locale: Locale;
  dict: Dictionary;
  className: string;
  testId?: string;
  children?: ReactNode;
}) {
  const { inProvider, switching, switchTo } = useModeSwitch(locale);
  return (
    <button
      type="button"
      data-testid={testId}
      disabled={switching}
      onClick={() => void switchTo(inProvider ? 'customer' : 'provider')}
      className={className}
    >
      {children ?? (inProvider ? dict.provider.switchToCustomer : dict.provider.switchToProvider)}
    </button>
  );
}
