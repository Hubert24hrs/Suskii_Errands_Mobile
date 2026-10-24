'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Dictionary } from '@/lib/i18n/en';
import type { Locale } from '@/lib/i18n';
import { bootstrapRepository, catalogRepository, providerKycRepository } from '@/lib/repositories';
import { newIdempotencyKey } from '@/lib/idempotency';
import type { ProviderKind, VehicleType } from '@/mocks/types';
import { StateBlock } from '@/components/StateBlock';
import {
  Notice,
  ProviderPage,
  btnPrimary,
  card,
  categoryLabel,
  errorText,
  inputClass,
  labelClass,
  mutedText,
  pageTitle,
} from '../_shared';

const VEHICLES: VehicleType[] = ['walking', 'bicycle', 'motorcycle', 'tricycle', 'car', 'van', 'truck'];

export function OnboardingClient({ locale, dict }: { locale: Locale; dict: Dictionary }) {
  const t = dict.provider.onboarding;
  const router = useRouter();
  const queryClient = useQueryClient();
  const profile = useQuery({ queryKey: ['provider', 'kyc'], queryFn: () => providerKycRepository.getKycProfile() });
  const categories = useQuery({ queryKey: ['catalog', 'categories'], queryFn: () => catalogRepository.getCategories() });
  const bootstrap = useQuery({ queryKey: ['bootstrap'], queryFn: () => bootstrapRepository.getBootstrap() });
  const areas = bootstrap.data?.countryPack.serviceAreas ?? [];

  const [kind, setKind] = useState<ProviderKind>('individual');
  const [businessName, setBusinessName] = useState('');
  const [services, setServices] = useState<string[]>([]);
  const [state, setState] = useState('');
  const [vehicle, setVehicle] = useState<VehicleType | ''>('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ text: string; tone: 'success' | 'error' }>();
  const key = useRef<{ forInput: string; key: string }>(undefined);

  useEffect(() => {
    const p = profile.data;
    if (!p) return;
    setKind(p.kind);
    setServices(p.serviceCategoryIds);
    setState(p.serviceAreaIds[0] ?? '');
    setVehicle(p.vehicleType ?? '');
  }, [profile.data]);

  async function save() {
    const input = {
      kind,
      serviceCategoryIds: services,
      // One state, from the dropdown: the code goes over the wire.
      serviceAreaIds: state ? [state] : [],
      vehicleType: vehicle || undefined,
      businessName: kind === 'business' ? businessName.trim() || undefined : undefined,
    };
    const forInput = JSON.stringify(input);
    if (key.current?.forInput !== forInput) key.current = { forInput, key: newIdempotencyKey() };
    setBusy(true);
    setNotice(undefined);
    try {
      await providerKycRepository.saveOnboarding(input, key.current.key);
      key.current = undefined;
      setNotice({ text: t.saved, tone: 'success' });
      await queryClient.invalidateQueries({ queryKey: ['provider', 'kyc'] });
      router.push(`/${locale}/provider/verification`);
    } catch (error) {
      setNotice({ text: errorText(dict, error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  if (profile.isPending || categories.isPending) {
    return (
      <ProviderPage locale={locale} dict={dict}>
        <StateBlock variant="loading" />
      </ProviderPage>
    );
  }

  return (
    <ProviderPage locale={locale} dict={dict}>
      <h1 className={pageTitle}>{t.title}</h1>
      <section className={`${card} flex flex-col gap-lg`}>
        <fieldset className="flex flex-col gap-xs">
          <legend className={labelClass}>{t.kind}</legend>
          <div className="flex flex-wrap gap-lg">
            {(['individual', 'business'] as const).map((k) => (
              <label key={k} className="flex items-center gap-xs text-body-medium">
                <input type="radio" name="provider-kind" checked={kind === k} onChange={() => setKind(k)} />
                {t[k]}
              </label>
            ))}
          </div>
        </fieldset>
        {kind === 'business' ? (
          <label className="flex flex-col gap-xs">
            <span className={labelClass}>{t.businessName}</span>
            <input value={businessName} onChange={(e) => setBusinessName(e.target.value)} className={inputClass} />
          </label>
        ) : null}

        <fieldset className="flex flex-col gap-xs" data-testid="onboarding-services">
          <legend className={labelClass}>{t.services}</legend>
          <div className="grid gap-xs sm:grid-cols-2">
            {(categories.data ?? []).map((c) => (
              <label key={c.id} className="flex items-center gap-xs text-body-medium">
                <input
                  type="checkbox"
                  data-testid={`onboarding-service-${c.id}`}
                  checked={services.includes(c.id)}
                  onChange={(e) =>
                    setServices((current) => (e.target.checked ? [...current, c.id] : current.filter((id) => id !== c.id)))
                  }
                />
                {categoryLabel(dict, categories.data ?? [], c.id)}
              </label>
            ))}
          </div>
        </fieldset>

        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.state}</span>
          <select data-testid="onboarding-state" value={state} onChange={(e) => setState(e.target.value)} className={inputClass}>
            <option value="">{t.stateHint}</option>
            {areas.map((area) => (
              <option key={area.code} value={area.code}>
                {area.name}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-xs">
          <span className={labelClass}>{t.vehicle}</span>
          <select value={vehicle} onChange={(e) => setVehicle(e.target.value as VehicleType | '')} className={inputClass}>
            <option value="">{t.vehicleNone}</option>
            {VEHICLES.map((v) => (
              <option key={v} value={v}>
                {t.vehicleTypes[v]}
              </option>
            ))}
          </select>
        </label>

        <div>
          <button
            type="button"
            data-testid="onboarding-save"
            disabled={busy || services.length === 0 || !state}
            onClick={() => void save()}
            className={btnPrimary}
          >
            {t.save}
          </button>
        </div>
        <Notice text={notice?.text} tone={notice?.tone} />
        <p className={mutedText}>{dict.provider.lockedBody}</p>
      </section>
    </ProviderPage>
  );
}
