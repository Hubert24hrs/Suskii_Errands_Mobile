import type { ReactNode } from 'react';

// Pass-through root layout: `app/[locale]/layout.tsx` renders <html lang> per locale.
export default function RootLayout({ children }: { children: ReactNode }) {
  return children;
}
