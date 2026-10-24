import type { ReactNode } from 'react';
import { ProviderHeartbeat } from './ProviderHeartbeat';

export default function ProviderLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ProviderHeartbeat />
      {children}
    </>
  );
}
