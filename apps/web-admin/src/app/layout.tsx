import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import './globals.css';

export const metadata: Metadata = {
  title: 'Suskii Admin',
  description: 'Suskii operations console — internal staff tool.',
};

// Internal staff console: English-only by decision (logged in HANDOFF M8) —
// strings still live in a typed dictionary (src/lib/i18n.ts), never inline.
export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="bg-surface font-sans text-body-large text-ink-primary antialiased dark:bg-surface-dark dark:text-ink-dark-primary">
        {children}
      </body>
    </html>
  );
}
