'use client';

import { useState, type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ConsoleShell } from './ConsoleShell';

export default function ConsoleLayout({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <QueryClientProvider client={queryClient}>
      <ConsoleShell>{children}</ConsoleShell>
    </QueryClientProvider>
  );
}
