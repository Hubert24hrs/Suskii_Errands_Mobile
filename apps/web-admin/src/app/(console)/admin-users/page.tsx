import type { Metadata } from 'next';
import { dict } from '@/lib/i18n';
import { AdminUsersClient } from './AdminUsersClient';

export const metadata: Metadata = { title: dict.adminUsers.title };

export default function AdminUsersPage() {
  return <AdminUsersClient />;
}
