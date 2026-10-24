// Provider onboarding and KYC over Supabase, the calls the mobile app makes
// (packages/suskii_data/lib/src/supabase/supabase_provider_kyc_repository.dart).
// The profile is `get_my_kyc_profile` (step state and the server's overall
// status) plus `provider_profiles`, `provider_services` and
// `provider_service_areas`, with the uuids translated back to category keys
// and city codes. The ID number and the police certificate number go in as
// plaintext over TLS and are sealed server-side; the answer steps send a
// payload the server validates and seals; `submit_kyc_for_review` refuses an
// incomplete profile and decides nothing.
//
// Still blocked, never weakened: the provider-facial liveness result needs
// the identity vendor, and the payout account needs the gateway's name check.

import { AppError, ErrorCodes } from '@/mocks/errors';
import type {
  KycStep,
  KycStepInput,
  KycStepKind,
  KycStepStatus,
  PayoutAccountResult,
  ProviderKind,
  ProviderKycProfile,
  ProviderOnboardingInput,
  VehicleType,
} from '@/mocks/types';

import { SupabaseGateway, type Row } from './gateway';
import { kycStepKindFromWire, kycStepStatusFromWire } from './mappers';

export function kycStepFromProfileRow(row: Row): KycStep {
  return {
    kind: kycStepKindFromWire(row['kind']),
    status: kycStepStatusFromWire(row['status']),
    attemptCount: Number(row['attempt_count'] ?? 0),
    submittedAt: row['submitted_at'] == null ? undefined : SupabaseGateway.asTimestamp(row['submitted_at']),
    reviewedAt: row['reviewed_at'] == null ? undefined : SupabaseGateway.asTimestamp(row['reviewed_at']),
    rejectionReasonKey: (row['rejection_reason_key'] as string | null) ?? undefined,
  };
}

/**
 * The overall status as the server states it, in the step vocabulary. `pending`
 * means steps are in and review was not asked for yet; once it was, it reads
 * as in review.
 */
export function kycOverallFromProfileRows(rows: Row[], steps: KycStep[]): KycStepStatus {
  const first = rows[0];
  const overall = first?.['overall_status'];
  switch (overall) {
    case 'verified':
      return 'verified';
    case 'rejected':
      return 'rejected';
    case 'expired':
      return 'expired';
    case 'in_review':
      return 'in_review';
    case 'pending':
      return first?.['submitted_for_review_at'] != null ? 'in_review' : 'in_progress';
    default:
      return steps.every((s) => s.status === 'not_started') ? 'not_started' : 'in_progress';
  }
}

function dateToWire(value: string): string {
  return value.slice(0, 10);
}

export class SupabaseProviderKycRepository {
  constructor(private readonly gateway: SupabaseGateway) {}

  private readonly categoryKeys = new Map<string, string>();
  private readonly cityCodes = new Map<string, string>();

  async getKycProfile(): Promise<ProviderKycProfile> {
    const userId = await this.gateway.currentAuthUserId();
    if (!userId) throw new AppError(ErrorCodes.unauthenticated);
    // By name: an applicant is in customer mode until verified, and the active mode's list would
    // be the customer one (audit AA.2).
    const stepRows = (await this.gateway.rpc('get_my_kyc_profile', { p_mode: 'provider' })) as Row[];
    const profile = await this.gateway.selectSingle('provider_profiles', 'kind, vehicle_type', 'user_id', userId);
    const services = await this.gateway.selectList('provider_services', 'category_id');
    const areas = await this.gateway.selectList('provider_service_areas', 'city_id');
    await this.ensureKeyMappings(services.length > 0, areas.length > 0);
    const steps = stepRows.map(kycStepFromProfileRow).filter((step) => step.kind !== 'customer_facial');
    const submitted = stepRows[0]?.['submitted_for_review_at'];
    const kind = profile?.['kind'];
    return {
      userId,
      kind: (kind === 'business' ? 'business' : 'individual') as ProviderKind,
      serviceCategoryIds: services
        .map((row) => this.categoryKeys.get(SupabaseGateway.asId(row['category_id'])))
        .filter((key): key is string => key !== undefined),
      serviceAreaIds: areas
        .map((row) => this.cityCodes.get(SupabaseGateway.asId(row['city_id'])))
        .filter((code): code is string => code !== undefined),
      steps,
      overallStatus: kycOverallFromProfileRows(stepRows, steps),
      submittedForReviewAt: submitted == null ? undefined : SupabaseGateway.asTimestamp(submitted),
      vehicleType: (profile?.['vehicle_type'] as VehicleType | null) ?? undefined,
    };
  }

  /** `kind` is server-set: a provider becomes a business by registering an organisation. */
  async saveOnboarding(input: ProviderOnboardingInput, _idempotencyKey: string): Promise<ProviderKycProfile> {
    const userId = await this.gateway.currentAuthUserId();
    if (!userId) throw new AppError(ErrorCodes.unauthenticated);
    await this.gateway.rpc('update_provider_services', { p_category_keys: input.serviceCategoryIds });
    await this.gateway.rpc('update_provider_service_areas', { p_city_codes: input.serviceAreaIds });
    const businessName = input.businessName?.trim();
    const changes: Row = {
      ...(input.vehicleType ? { vehicle_type: input.vehicleType } : {}),
      ...(businessName ? { business_name: businessName } : {}),
    };
    if (Object.keys(changes).length > 0) {
      await this.gateway.updateRows('provider_profiles', changes, 'user_id', userId, 'user_id');
    }
    return this.getKycProfile();
  }

  async submitStep(input: KycStepInput, idempotencyKey: string): Promise<ProviderKycProfile> {
    switch (input.kind) {
      case 'id_document_capture':
        await this.submitUploadRefs(input.kind, [input.uploadRef], idempotencyKey);
        break;
      case 'vehicle_documents':
        await this.submitUploadRefs(
          input.kind,
          [input.licenceUploadRef, input.registrationUploadRef, input.insuranceUploadRef].filter(
            (ref): ref is string => !!ref,
          ),
          idempotencyKey,
        );
        break;
      case 'credentials':
        await this.submitPayload(input.kind, { description: input.description }, idempotencyKey, input.uploadRefs);
        break;
      case 'address':
        await this.submitPayload(
          input.kind,
          {
            line1: input.line1,
            line2: input.line2,
            city: input.city,
            state: input.state,
            landmark: input.landmarkNote,
          },
          idempotencyKey,
        );
        break;
      case 'guarantor':
        await this.submitPayload(
          input.kind,
          { name: input.fullName, phone_e164: input.phoneE164, relationship: input.relationship },
          idempotencyKey,
        );
        break;
      case 'government_id':
        // Recorded and sealed server-side; the verdict is the identity vendor's lookup.
        await this.gateway.rpc('submit_identity_document', {
          p_idempotency_key: idempotencyKey,
          p_id_type: input.idType,
          p_id_number: input.idNumber,
        });
        break;
      case 'police_clearance':
        await this.gateway.rpc('submit_police_clearance', {
          p_idempotency_key: idempotencyKey,
          p_certificate_number: input.certificateNumber,
          p_issued_on: dateToWire(input.issueDate),
          p_expires_on: dateToWire(input.expiryDate),
          p_upload_ref: input.uploadRef,
        });
        break;
      case 'payout_account':
      case 'provider_facial':
        throw new AppError(ErrorCodes.featureUnavailable);
    }
    return this.getKycProfile();
  }

  /** No name-enquiry RPC exists until the gateway does; nameMatch must stay server-computed. */
  async resolvePayoutAccount(_input: { bankCode: string; accountNumber: string }): Promise<PayoutAccountResult> {
    throw new AppError(ErrorCodes.featureUnavailable);
  }

  async submitForReview(idempotencyKey: string): Promise<ProviderKycProfile> {
    await this.gateway.rpc('submit_kyc_for_review', { p_idempotency_key: idempotencyKey });
    return this.getKycProfile();
  }

  private async submitPayload(
    kind: KycStepKind,
    payload: Record<string, string | undefined>,
    idempotencyKey: string,
    uploadRefs?: string[],
  ): Promise<void> {
    const trimmed = Object.fromEntries(
      Object.entries(payload)
        .filter((entry): entry is [string, string] => typeof entry[1] === 'string' && entry[1].trim() !== '')
        .map(([key, value]) => [key, value.trim()]),
    );
    await this.gateway.rpc('submit_kyc_step', {
      p_idempotency_key: idempotencyKey,
      p_kind: kind,
      p_upload_refs: uploadRefs && uploadRefs.length > 0 ? uploadRefs : undefined,
      p_payload: trimmed,
    });
  }

  private async submitUploadRefs(kind: KycStepKind, refs: string[], idempotencyKey: string): Promise<void> {
    if (refs.length === 0) throw new AppError(ErrorCodes.kycStepInvalid);
    await this.gateway.rpc('submit_kyc_step', {
      p_idempotency_key: idempotencyKey,
      p_kind: kind,
      p_upload_refs: refs,
    });
  }

  private async ensureKeyMappings(needCategories: boolean, needCities: boolean): Promise<void> {
    if (needCategories && this.categoryKeys.size === 0) {
      for (const row of await this.gateway.selectList('service_categories', 'id, key')) {
        this.categoryKeys.set(SupabaseGateway.asId(row['id']), row['key'] as string);
      }
    }
    if (needCities && this.cityCodes.size === 0) {
      for (const row of await this.gateway.selectList('cities', 'id, code')) {
        this.cityCodes.set(SupabaseGateway.asId(row['id']), row['code'] as string);
      }
    }
  }
}
