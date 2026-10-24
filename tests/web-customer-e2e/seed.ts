// A verified provider who has not yet onboarded, and a customer whose plumbing request is
// already published beside the provider in Lagos. Only what no client may do is done as
// the service role: creating accounts and the verification verdict.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { ANON_KEY, PASSWORD, PICKUP, SERVICE_KEY, SUPABASE_URL } from './env';

export const SEED_FILE = path.join(tmpdir(), 'suskii-web-customer-e2e-seed.json');

export interface Seed {
  run: string;
  provider: { id: string; email: string };
  customer: { id: string; email: string };
  requestId: string;
}

export function client(apiKey: string): SupabaseClient {
  return createClient(SUPABASE_URL, apiKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function must<T>(label: string, p: PromiseLike<{ data: T; error: unknown }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Error(`${label}: ${JSON.stringify(error)}`);
  return data;
}

export async function signedIn(email: string): Promise<SupabaseClient> {
  const c = client(ANON_KEY);
  await must('signIn', c.auth.signInWithPassword({ email, password: PASSWORD }));
  return c;
}

/** A Nigerian account with a password, as only the service role may make one. */
export async function createUser(email: string, name: string): Promise<string> {
  const service = client(SERVICE_KEY);
  const created = await service.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
    user_metadata: { country_code: 'NG', language: 'en' },
  });
  if (created.error || !created.data.user) throw new Error(`createUser ${email}: ${created.error?.message}`);
  const id = created.data.user.id;
  await must('profile', service.from('profiles').update({ display_name: name }).eq('user_id', id));
  return id;
}

/** A provider the KYC vendor has already verified, not yet onboarded. */
export async function createProvider(email: string, name: string): Promise<string> {
  const service = client(SERVICE_KEY);
  const id = await createUser(email, name);
  await must('verify', service.from('profiles').update({ provider_verification: 'verified' }).eq('user_id', id));
  await must('provider', service.from('provider_profiles').insert({ user_id: id }));
  return id;
}

export default async function seed(): Promise<void> {
  const run = Date.now().toString(36);
  const providerEmail = `e2e-web-provider-${run}@suskii.test`;
  const providerId = await createProvider(providerEmail, `Bayo Web ${run}`);

  const customerEmail = `e2e-web-customer-${run}@suskii.test`;
  const customerId = await createUser(customerEmail, `Ada Web ${run}`);
  const customer = await signedIn(customerEmail);
  const requestId = String(await must('create_request', customer.rpc('create_request', {
    p_idempotency_key: crypto.randomUUID(),
    p_category_key: 'plumbing',
    p_description: `A leaking kitchen tap ${run}`,
    p_pickup_label: 'Herbert Macaulay Way, Yaba',
    p_pickup_lat: PICKUP.latitude,
    p_pickup_lng: PICKUP.longitude,
  })));
  await must('publish', customer.rpc('publish_request', {
    p_request_id: requestId, p_idempotency_key: crypto.randomUUID(),
  }));

  const seedData: Seed = {
    run,
    provider: { id: providerId, email: providerEmail },
    customer: { id: customerId, email: customerEmail },
    requestId,
  };
  writeFileSync(SEED_FILE, JSON.stringify(seedData));
}
