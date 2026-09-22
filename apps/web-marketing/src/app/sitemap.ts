import type { MetadataRoute } from 'next';
import { locales } from '@/lib/i18n';
import { cities } from '@/lib/cities';

const base = 'https://suskii.example';

const staticRoutes = [
  '',
  '/how-it-works',
  '/services',
  '/become-a-provider',
  '/businesses',
  '/safety',
  '/referrals',
  '/faq',
  '/contact',
  '/legal/privacy',
  '/legal/terms',
];

export default function sitemap(): MetadataRoute.Sitemap {
  return locales.flatMap((locale) => [
    ...staticRoutes.map((route) => ({
      url: `${base}/${locale}${route}`,
      lastModified: new Date(),
    })),
    ...cities.map((city) => ({
      url: `${base}/${locale}/cities/${city}`,
      lastModified: new Date(),
    })),
  ]);
}
