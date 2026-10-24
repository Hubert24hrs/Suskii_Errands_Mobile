import { notFound } from 'next/navigation';
import { getDictionary, isLocale, type Locale } from '@/lib/i18n';
import { ProviderPage } from '../_shared';
import { WalletClient } from '../../wallet/WalletClient';

/** The provider's earnings are their wallet: the same balances, history and withdrawal. */
export default async function ProviderEarningsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const dict = await getDictionary(locale as Locale);
  return (
    <ProviderPage locale={locale as Locale} dict={dict}>
      <WalletClient dict={dict} title={dict.provider.earnings.title} embedded lifetimeLabel={dict.provider.earnings.lifetime} />
    </ProviderPage>
  );
}
