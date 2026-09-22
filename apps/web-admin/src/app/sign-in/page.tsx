import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { SignInClient } from './SignInClient';

export const metadata: Metadata = { title: dict.auth.title };

export default function SignInPage() {
  return <SignInClient />;
}
