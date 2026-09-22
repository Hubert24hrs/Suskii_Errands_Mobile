import type { Dictionary } from './en';

export const locales = ['en', 'pcm'] as const;
export type Locale = (typeof locales)[number];

export const localeNames: Record<Locale, string> = {
  en: 'English',
  pcm: 'Naija (Pidgin)',
};

const dictionaries: Record<Locale, () => Promise<{ default: Dictionary }>> = {
  en: () => import('./en'),
  pcm: () => import('./pcm'),
};

export function isLocale(value: string): value is Locale {
  return (locales as readonly string[]).includes(value);
}

export async function getDictionary(locale: Locale): Promise<Dictionary> {
  return (await dictionaries[locale]()).default;
}
