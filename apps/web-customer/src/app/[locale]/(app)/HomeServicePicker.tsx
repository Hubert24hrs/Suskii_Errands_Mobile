'use client';

// "All services available" on the home page, as the app has it (owner, 2026-11-04): one searchable
// dropdown of every service, and choosing one opens a new request with it already selected.

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { catalogRepository } from '@/lib/repositories';
import { categoryDescription, categoryLabel } from './requests/_shared';

const inputClasses =
  'w-full rounded-md border border-outline bg-surface px-md py-sm text-body-large text-ink-primary outline-none transition-colors duration-normal ease-standard focus:border-brand-primary dark:border-outline-dark dark:bg-surface-dark dark:text-ink-dark-primary';

export function HomeServicePicker({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const router = useRouter();
  const [query, setQuery] = useState('');
  const categories = useQuery({
    queryKey: ['catalog', 'categories'],
    queryFn: () => catalogRepository.getCategories(),
  });
  const all = categories.data ?? [];
  const words = query.trim().toLowerCase().split(/\s+/).filter((w) => w !== '');
  const shown = all.filter((c) => {
    if (words.length === 0) return true;
    const haystack = [
      categoryLabel(dict, all, c.id),
      categoryDescription(dict, c) ?? '',
      ...Object.values(c.displayNames ?? {}),
      c.id.replace(/_/g, ' '),
    ]
      .join(' ')
      .toLowerCase();
    return words.every((w) => haystack.includes(w));
  });

  return (
    <section className="mt-xxl flex flex-col gap-xs" data-testid="home-services">
      <label htmlFor="home-service" className="text-title-medium text-ink-primary dark:text-ink-dark-primary">
        {dict.servicePicker.heading}
      </label>
      <input
        type="search"
        aria-label={dict.servicePicker.search}
        placeholder={dict.servicePicker.search}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        className={inputClasses}
      />
      <select
        id="home-service"
        value=""
        disabled={categories.isPending}
        onChange={(e) => {
          if (e.target.value) router.push(`/${locale}/requests/new?service=${encodeURIComponent(e.target.value)}`);
        }}
        className={inputClasses}
      >
        <option value="" disabled>
          {shown.length === 0 && !categories.isPending ? dict.servicePicker.empty : dict.servicePicker.placeholder}
        </option>
        {shown.map((c) => (
          <option key={c.id} value={c.id}>
            {categoryLabel(dict, all, c.id)}
          </option>
        ))}
      </select>
    </section>
  );
}
