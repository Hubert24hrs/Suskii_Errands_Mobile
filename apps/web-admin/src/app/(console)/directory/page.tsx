import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { DirectoryClient } from './DirectoryClient';

export const metadata: Metadata = { title: dict.directory.title };

export default function DirectoryPage() {
  return <DirectoryClient />;
}
