// Builds what the console has to work on, through the backend's own functions wherever
// one exists: a KYC step in review with a real document in `kyc-docs`, a paid job the
// customer disputes, a support ticket, an SOS, a fraud flag, and a withdrawal that needs
// two signatures. Only what no client may do is done as the service role — creating
// accounts, the KYC vendor's verdict, the gateway's confirmation, and (because a provider
// cannot earn and settle in a test's lifetime) the withdrawal row itself.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { ANON_KEY, PASSWORD, SERVICE_KEY, SUPABASE_URL } from './env';

export const SEED_FILE = path.join(tmpdir(), 'suskii-admin-e2e-seed.json');

export interface Seed {
  run: string;
  staff: Record<'superA' | 'superB' | 'verifier' | 'finance' | 'disputer' | 'support', {
    id: string;
    email: string;
  }>;
  invitee: { id: string; email: string };
  customer: { id: string; name: string };
  kycCustomer: { id: string; name: string; uploadRef: string };
  provider: { id: string; name: string };
  requestId: string;
  disputeId: string;
  ticketId: string;
  sosId: string;
  withdrawalId: string;
  fraudFlagId: string;
}

// A 1×1 PNG: kyc-docs takes images and PDFs.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64',
);

const key = () => crypto.randomUUID();

function client(apiKey: string): SupabaseClient {
  return createClient(SUPABASE_URL, apiKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function must<T>(label: string, p: PromiseLike<{ data: T; error: unknown }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Error(`${label}: ${JSON.stringify(error)}`);
  return data;
}

export default async function seed(): Promise<void> {
  const run = Date.now().toString(36);
  const service = client(SERVICE_KEY);

  const createUser = async (email: string, name: string) => {
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
  };
  const signedIn = async (email: string) => {
    const c = client(ANON_KEY);
    await must('signIn', c.auth.signInWithPassword({ email, password: PASSWORD }));
    return c;
  };

  // Staff, with the roles the backend checks. Each enrols a second factor on first sign-in.
  const roles = {
    superA: ['super_admin'],
    superB: ['super_admin'],
    verifier: ['verification_officer'],
    finance: ['finance_officer'],
    disputer: ['dispute_officer'],
    support: ['support_agent'],
  } as const;
  const staff = {} as Seed['staff'];
  for (const [label, roleList] of Object.entries(roles)) {
    const email = `e2e-${label.toLowerCase()}-${run}@suskii.test`;
    const id = await createUser(email, `${label} ${run}`);
    await must('admin_users', service.from('admin_users').insert({ user_id: id, roles: roleList }));
    staff[label as keyof Seed['staff']] = { id, email };
  }
  const inviteeEmail = `e2e-invitee-${run}@suskii.test`;
  const invitee = { id: await createUser(inviteeEmail, `Invitee ${run}`), email: inviteeEmail };

  // A customer and a provider the KYC vendor has already verified.
  const customerName = `Ada Customer ${run}`;
  const customerEmail = `e2e-customer-${run}@suskii.test`;
  const customerId = await createUser(customerEmail, customerName);
  const providerName = `Bayo Provider ${run}`;
  const providerEmail = `e2e-provider-${run}@suskii.test`;
  const providerId = await createUser(providerEmail, providerName);
  await must('verify', service.from('profiles').update({ customer_verification: 'verified' }).eq('user_id', customerId));
  await must('verify', service.from('profiles')
    .update({ customer_verification: 'verified', provider_verification: 'verified' }).eq('user_id', providerId));
  await must('provider', service.from('provider_profiles').insert({ user_id: providerId }));

  // A KYC step in review, with its document really in the bucket.
  const kycName = `Chioma Kyc ${run}`;
  const kycEmail = `e2e-kyc-${run}@suskii.test`;
  const kycId = await createUser(kycEmail, kycName);
  const kycClient = await signedIn(kycEmail);
  const uploadRef = `${kycId}/id-front-${run}.png`;
  await must('upload', kycClient.storage.from('kyc-docs').upload(uploadRef, PNG, { contentType: 'image/png' }));
  await must('submit_kyc_step', kycClient.rpc('submit_kyc_step', {
    p_idempotency_key: key(), p_kind: 'government_id', p_upload_refs: [uploadRef],
  }));

  // A paid job, then a dispute about it: 100.00 held.
  const customer = await signedIn(customerEmail);
  const provider = await signedIn(providerEmail);
  const requestId = String(await must('create_request', customer.rpc('create_request', {
    p_idempotency_key: key(), p_category_key: 'personal_assistance',
    p_description: `E2E parcel ${run}`, p_pickup_label: 'Yaba market',
    p_pickup_lat: 6.5095, p_pickup_lng: 3.3711,
  })));
  await must('publish', customer.rpc('publish_request', { p_request_id: requestId, p_idempotency_key: key() }));
  const offerId = String(await must('offer', provider.rpc('create_offer', {
    p_idempotency_key: key(), p_request_id: requestId, p_amount_minor: 10000,
  })));
  await must('accept', customer.rpc('accept_offer', { p_idempotency_key: key(), p_offer_id: offerId }));
  const payment = (await must('start_payment', customer.rpc('start_payment', {
    p_idempotency_key: key(), p_request_id: requestId,
  }))) as Array<{ payment_id: string; amount_minor: number }>;
  const paymentId = payment[0]!.payment_id;
  const reference = `e2e-admin-${run}`;
  await must('checkout', service.rpc('gateway_record_checkout', {
    p_payment_id: paymentId, p_gateway: 'flutterwave', p_gateway_reference: reference,
    p_checkout_url: `https://checkout.example/${reference}`,
  }));
  await must('confirm', service.rpc('gateway_confirm_payment', {
    p_gateway: 'flutterwave', p_gateway_reference: reference, p_amount_minor: 10000, p_fee_minor: 290,
  }));
  const disputeId = String(await must('open_dispute', customer.rpc('open_dispute', {
    p_idempotency_key: key(), p_request_id: requestId, p_reason_code: 'not_delivered',
    p_description: 'Nothing arrived.',
  })));

  const ticketId = String(await must('open_ticket', customer.rpc('open_ticket', {
    p_idempotency_key: key(), p_category: 'payment', p_body: `My refund ${run}?`,
  })));
  const sosId = String(await must('raise_sos', customer.rpc('raise_sos', {
    p_idempotency_key: key(), p_lat: 6.5095, p_lng: 3.3711,
  })));

  // The risk engine's signal and a withdrawal above the two-signature threshold.
  const flag = await must('fraud_flag', service.from('fraud_flags').insert({
    subject_kind: 'user', subject_id: providerId, rule_key: 'offer_velocity', score: 60,
    details: { offers_last_hour: 40 },
  }).select('id').single()) as { id: string };
  const account = await must('payout_account', service.from('payout_accounts').insert({
    user_id: providerId, country_code: 'NG', rail: 'bank',
    account_ciphertext: '\\x00', account_blind_index: `\\x${Buffer.from(run).toString('hex')}`,
    institution_code: '058', holder_name: providerName, is_default: true,
  }).select('id').single()) as { id: string };
  const withdrawal = await must('withdrawal', service.from('withdrawals').insert({
    user_id: providerId, source_account: 'provider_earnings', payout_account_id: account.id,
    amount_minor: 2_500_000, currency: 'NGN', status: 'awaiting_approval', approvals_required: 2,
  }).select('id').single()) as { id: string };
  await must('approvals', service.from('approvals').insert([1, 2].map((level) => ({
    subject_kind: 'withdrawal', subject_id: withdrawal.id, action: 'withdrawal.approve',
    payload: { amount_minor: 2_500_000, currency: 'NGN' }, requested_by: providerId, level,
  }))));

  const out: Seed = {
    run,
    staff,
    invitee,
    customer: { id: customerId, name: customerName },
    kycCustomer: { id: kycId, name: kycName, uploadRef },
    provider: { id: providerId, name: providerName },
    requestId,
    disputeId,
    ticketId,
    sosId,
    withdrawalId: withdrawal.id,
    fraudFlagId: flag.id,
  };
  writeFileSync(SEED_FILE, JSON.stringify(out, null, 2));
}
