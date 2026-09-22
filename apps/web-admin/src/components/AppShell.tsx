'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { ReactNode } from 'react';

export type NavItem = { href: string; label: string; group: string };

export function AppShell({
  appName,
  navItems,
  adminName,
  adminRoleLabel,
  signOutLabel,
  onSignOut,
  children,
}: {
  appName: string;
  navItems: NavItem[];
  adminName: string;
  adminRoleLabel: string;
  signOutLabel: string;
  onSignOut: () => void;
  children: ReactNode;
}) {
  const pathname = usePathname();

  const groups: { group: string; items: NavItem[] }[] = [];
  for (const item of navItems) {
    const existing = groups.find((g) => g.group === item.group);
    if (existing) {
      existing.items.push(item);
    } else {
      groups.push({ group: item.group, items: [item] });
    }
  }

  const isActive = (href: string) =>
    href === '/' ? pathname === '/' : pathname.startsWith(href);

  return (
    <div className="flex min-h-screen">
      <aside className="flex w-60 shrink-0 flex-col border-r border-outline bg-surface-raised dark:border-outline-dark dark:bg-surface-dark-raised">
        <div className="flex h-16 items-center gap-sm border-b border-outline px-lg dark:border-outline-dark">
          <span className="flex h-8 w-8 items-center justify-center rounded-sm bg-brand-primary font-bold text-brand-on-primary">
            S
          </span>
          <span className="text-title-large text-ink-primary dark:text-ink-dark-primary">
            {appName}
          </span>
        </div>
        <nav className="flex-1 overflow-y-auto px-md py-lg">
          {groups.map(({ group, items }) => (
            <div key={group} className="mb-lg">
              <p className="px-sm pb-xs text-label-small uppercase text-ink-secondary dark:text-ink-dark-secondary">
                {group}
              </p>
              <ul className="flex flex-col gap-xs">
                {items.map((item) => {
                  const active = isActive(item.href);
                  return (
                    <li key={item.href}>
                      <Link
                        href={item.href}
                        aria-current={active ? 'page' : undefined}
                        className={`block rounded-md px-sm py-sm text-body-medium transition-colors duration-normal ease-standard ${
                          active
                            ? 'bg-brand-primary font-semibold text-brand-on-primary'
                            : 'text-ink-primary hover:bg-surface-muted dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted'
                        }`}
                      >
                        {item.label}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </nav>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-16 items-center justify-between border-b border-outline bg-surface-raised px-lg dark:border-outline-dark dark:bg-surface-dark-raised">
          <div className="flex items-baseline gap-sm">
            <span className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
              {adminName}
            </span>
            <span className="text-body-small text-ink-secondary dark:text-ink-dark-secondary">
              {adminRoleLabel}
            </span>
          </div>
          <button
            type="button"
            onClick={onSignOut}
            className="rounded-md border border-outline px-lg py-sm text-label-large text-ink-primary transition-colors duration-normal ease-standard hover:bg-surface-muted dark:border-outline-dark dark:text-ink-dark-primary dark:hover:bg-surface-dark-muted"
          >
            {signOutLabel}
          </button>
        </header>
        <main className="min-w-0 flex-1 px-lg py-xxl">{children}</main>
      </div>
    </div>
  );
}
