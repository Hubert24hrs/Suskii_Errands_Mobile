import type { ReactNode } from 'react';

// Pass-through root layout: `app/[locale]/layout.tsx` renders <html lang> per locale,
// and `app/not-found.tsx` renders its own <html>/<body> fallback.
export default function RootLayout({ children }: { children: ReactNode }) {
  return children;
}
