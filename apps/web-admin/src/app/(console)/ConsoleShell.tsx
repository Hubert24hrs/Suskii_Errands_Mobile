'use client';

import { useEffect, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { useQueryClient } from '@tanstack/react-query';
import { dict } from '@/lib/i18n';
import { sessionRepository, type AdminAction } from '@/mocks/repositories';
import { AppShell, type NavItem } from '@/components/AppShell';
import { StateBlock } from '@/components/StateBlock';
import { can, errorText, isSessionError, roleLabel, useAdminSession } from './_shared';

/** Nav entries in group order; the required read permission gates each. */
const NAV: ReadonlyArray<{
  href: string;
  label: string;
  group: string;
  action: AdminAction;
}> = [
  { href: '/', label: dict.nav.dashboard, group: dict.nav.groups.operations, action: 'metrics.read' },
  { href: '/directory', label: dict.nav.directory, group: dict.nav.groups.operations, action: 'directory.read' },
  { href: '/verification', label: dict.nav.verification, group: dict.nav.groups.operations, action: 'verification.read' },
  { href: '/jobs', label: dict.nav.jobs, group: dict.nav.groups.operations, action: 'jobs.read' },
  { href: '/sos', label: dict.nav.sos, group: dict.nav.groups.operations, action: 'sos.read' },
  { href: '/payments', label: dict.nav.payments, group: dict.nav.groups.money, action: 'payments.read' },
  { href: '/referrals', label: dict.nav.referrals, group: dict.nav.groups.money, action: 'referrals.read' },
  { href: '/promos', label: dict.nav.promos, group: dict.nav.groups.money, action: 'promos.read' },
  { href: '/disputes', label: dict.nav.disputes, group: dict.nav.groups.trustSafety, action: 'disputes.read' },
  { href: '/support', label: dict.nav.support, group: dict.nav.groups.trustSafety, action: 'support.read' },
  { href: '/risk', label: dict.nav.risk, group: dict.nav.groups.trustSafety, action: 'risk.read' },
  { href: '/config', label: dict.nav.config, group: dict.nav.groups.system, action: 'config.read' },
  { href: '/analytics', label: dict.nav.analytics, group: dict.nav.groups.system, action: 'analytics.read' },
  { href: '/audit', label: dict.nav.auditLog, group: dict.nav.groups.system, action: 'audit.read' },
  { href: '/admin-users', label: dict.nav.adminUsers, group: dict.nav.groups.system, action: 'adminUsers.read' },
];

export function ConsoleShell({ children }: { children: ReactNode }) {
  const router = useRouter();
  const queryClient = useQueryClient();
  const sessionQuery = useAdminSession();
  const session = sessionQuery.data;

  useEffect(() => {
    // No session (or an expired one destroyed server-side) → sign in again.
    if (session === null) router.replace('/sign-in');
  }, [session, router]);

  useEffect(() => {
    if (sessionQuery.error && isSessionError(sessionQuery.error)) {
      router.replace('/sign-in');
    }
  }, [sessionQuery.error, router]);

  if (sessionQuery.isPending) {
    return (
      <div className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center px-lg">
        <StateBlock variant="loading" />
      </div>
    );
  }

  if (sessionQuery.isError) {
    return (
      <div className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center px-lg">
        <StateBlock
          variant="error"
          errorMessage={errorText(sessionQuery.error)}
          retryLabel={dict.common.retry}
          onRetry={() => void sessionQuery.refetch()}
        />
      </div>
    );
  }

  if (!session) {
    // Signed out — the effect above redirects to /sign-in.
    return (
      <div className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center px-lg">
        <StateBlock variant="loading" />
      </div>
    );
  }

  const navItems: NavItem[] = NAV.filter((item) =>
    can(session.admin.role, item.action),
  ).map(({ href, label, group }) => ({ href, label, group }));

  const signOut = async () => {
    try {
      await sessionRepository.signOut();
    } finally {
      queryClient.clear();
      router.replace('/sign-in');
    }
  };

  return (
    <AppShell
      appName={dict.meta.title}
      navItems={navItems}
      adminName={session.admin.name}
      adminRoleLabel={roleLabel(session.admin.role)}
      signOutLabel={dict.auth.signOut}
      onSignOut={() => void signOut()}
    >
      {children}
    </AppShell>
  );
}
