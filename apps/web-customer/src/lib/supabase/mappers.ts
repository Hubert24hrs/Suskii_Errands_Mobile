// Row/jsonb → domain mappings for the web Supabase repositories, mirroring
// packages/suskii_data/lib/src/supabase/supabase_mappers.dart. Wire values
// come from contracts/v1; anything unrecognized maps to the safest default
// rather than throwing, because a new enum value on the server must not
// break an old build.

import type {
  AppUser,
  TrustLevel,
  UserMode,
  VerificationStatus,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';

/// Column list for the caller's own `profiles` row (explicit lists — a `*`
/// naming an ungranted column fails the whole query).
export const profileRowColumns =
  'user_id, display_name, country_code, language, avatar_path, ' +
  'active_mode, customer_verification, provider_verification, ' +
  'trust_level, created_at';

const VERIFICATION_STATUSES: readonly VerificationStatus[] = [
  'unverified',
  'pending',
  'in_review',
  'verified',
  'rejected',
  'suspended',
  'expired',
];

export function userModeFromWire(value: unknown): UserMode {
  return value === 'provider' ? 'provider' : 'customer';
}

export function verificationFromWire(value: unknown): VerificationStatus {
  return VERIFICATION_STATUSES.includes(value as VerificationStatus)
    ? (value as VerificationStatus)
    : 'unverified';
}

export function trustLevelFromWire(value: unknown): TrustLevel {
  switch (value) {
    case 'verified':
    case 'trusted':
    case 'elite':
      return value;
    default:
      return 'new';
  }
}

/** A `profiles` row (own row, RLS-scoped) merged with the GoTrue identity
 * for phone/email, which the table deliberately does not carry. */
export function appUserFromProfileRow(
  row: Row,
  identity: { phoneE164?: string; email?: string } = {},
): AppUser {
  // profiles rows key the id as user_id; get_bootstrap's user object as id.
  const createdAt = row['created_at'];
  return {
    id: SupabaseGateway.asId(row['user_id'] ?? row['id']),
    displayName: (row['display_name'] as string | null) ?? '',
    // Nullable on a fresh signup before onboarding completes.
    countryCode: (row['country_code'] as string | null) ?? '',
    preferredLanguage: (row['language'] as string | null) ?? 'en',
    activeMode: userModeFromWire(row['active_mode']),
    customerVerification: verificationFromWire(row['customer_verification']),
    providerVerification: verificationFromWire(row['provider_verification']),
    trustLevel: trustLevelFromWire(row['trust_level']),
    createdAt:
      createdAt == null ? new Date(0) : SupabaseGateway.asTimestamp(createdAt),
    phoneE164: identity.phoneE164,
    email: identity.email,
    // avatar_path is a storage path, not a URL — signed URLs are a later
    // slice (storage gateway), so photoUrl stays undefined for now.
  };
}
