import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// ProviderKycRepository over Supabase.
///
/// Profile reads combine `get_my_kyc_profile` (step state, dates and the
/// server's overall status, contracts 2.0.0) with `provider_profiles` (kind,
/// vehicle type, business name), `provider_services` and
/// `provider_service_areas`; the uuid foreign keys are translated back to the
/// category keys / city codes the domain model carries.
///
/// Writes: onboarding goes to `update_provider_services` /
/// `update_provider_service_areas` and a `provider_profiles` update of
/// vehicle type and business name (`kind` is server-set: a provider becomes a
/// business by registering an organisation). Upload steps go through
/// `submit_kyc_step`; the answer steps (address, guarantor, credentials) send
/// their answer as `p_payload`, which the server validates and seals. The ID
/// number and the police certificate number go in as plaintext over TLS and
/// are sealed server-side (CR-20260923-08). `submitForReview` is the server's
/// `submit_kyc_for_review`, which refuses an incomplete profile and decides
/// nothing.
///
/// Still blocked, never weakened: the provider-facial liveness result needs the
/// identity vendor (CR-20260923-09), and the payout account needs the gateway's
/// name check and its KMS-sealed account number (CR-20260923-10 c).
class SupabaseProviderKycRepository implements ProviderKycRepository {
  SupabaseProviderKycRepository(this._gateway);

  final SupabaseGateway _gateway;

  /// category uuid → key, city uuid → code; built lazily.
  final Map<String, String> _categoryKeys = <String, String>{};
  final Map<String, String> _cityCodes = <String, String>{};

  @override
  Future<ProviderKycProfile> getKycProfile() async {
    final userId = _gateway.currentAuthUserId;
    if (userId == null) throw const AppError(ErrorCodes.unauthenticated);
    // By name: an applicant is in customer mode until verified, and the
    // active mode's list would be the customer one (audit AA.2).
    final stepRows = await _gateway
        .rpc('get_my_kyc_profile', <String, Object?>{'p_mode': 'provider'})
        .then((rows) => List<Map<String, dynamic>>.from(rows as List<dynamic>));
    final profile = await _gateway.selectSingle(
      'provider_profiles',
      'kind, vehicle_type',
      column: 'user_id',
      value: userId,
    );
    final services = await _gateway.selectList(
      'provider_services',
      'category_id',
    );
    final areas = await _gateway.selectList(
      'provider_service_areas',
      'city_id',
    );
    await _ensureKeyMappings(services, areas);

    final steps = stepRows
        .map(kycStepFromProfileRow)
        .where((step) => step.kind != KycStepKind.customerFacial)
        .toList();
    return ProviderKycProfile(
      userId: userId,
      kind: providerKindFromWire(profile?['kind']),
      serviceCategoryIds: services
          .map((row) => _categoryKeys[SupabaseGateway.asId(row['category_id'])])
          .whereType<String>()
          .toList(),
      serviceAreaIds: areas
          .map((row) => _cityCodes[SupabaseGateway.asId(row['city_id'])])
          .whereType<String>()
          .toList(),
      steps: steps,
      overallStatus: kycOverallFromProfileRows(stepRows, steps),
      submittedForReviewAt: kycSubmittedForReviewAt(stepRows),
      vehicleType: profile?['vehicle_type'] == null
          ? null
          : vehicleTypeFromWire(profile!['vehicle_type']),
    );
  }

  @override
  Stream<ProviderKycProfile> watchKycProfile() => _poll(getKycProfile);

  @override
  Future<ProviderKycProfile> saveOnboarding(
    ProviderOnboardingInput input, {
    required String idempotencyKey,
  }) async {
    final userId = _gateway.currentAuthUserId;
    if (userId == null) throw const AppError(ErrorCodes.unauthenticated);
    await _gateway.rpc('update_provider_services', <String, Object?>{
      'p_category_keys': input.serviceCategoryIds,
    });
    await _gateway.rpc('update_provider_service_areas', <String, Object?>{
      'p_city_codes': input.serviceAreaIds,
    });
    final businessName = input.businessName?.trim();
    final changes = <String, Object?>{
      if (input.vehicleType != null)
        'vehicle_type': vehicleTypeToWire(input.vehicleType!),
      if (businessName != null && businessName.isNotEmpty)
        'business_name': businessName,
    };
    if (changes.isNotEmpty) {
      await _gateway.updateRows(
        'provider_profiles',
        changes,
        column: 'user_id',
        value: userId,
        columns: 'user_id',
      );
    }
    // input.kind is server-set: `business` comes from registering an
    // organisation, where the check lives.
    return getKycProfile();
  }

  @override
  Future<ProviderKycProfile> submitStep(
    KycStepKind kind,
    Object input, {
    required String idempotencyKey,
  }) async {
    switch (kind) {
      case KycStepKind.idDocumentCapture:
        final refs = <String>[
          if (input is IdDocumentInput && input.uploadRef != null)
            input.uploadRef!,
        ];
        await _submitUploadRefs(kind, refs, idempotencyKey);
      case KycStepKind.vehicleDocuments:
        if (input is! VehicleDocumentsInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        await _submitUploadRefs(kind, <String>[
          input.licenceUploadRef,
          input.registrationUploadRef,
          if (input.insuranceUploadRef != null) input.insuranceUploadRef!,
        ], idempotencyKey);
      case KycStepKind.credentials:
        if (input is! CredentialsInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        await _submitPayload(
          kind,
          <String, Object?>{'description': input.description},
          idempotencyKey,
          uploadRefs: input.uploadRefs,
        );
      case KycStepKind.address:
        if (input is! AddressInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        await _submitPayload(kind, <String, Object?>{
          'line1': input.line1,
          'line2': input.line2,
          'city': input.city,
          'state': input.state,
          'landmark': input.landmarkNote,
        }, idempotencyKey);
      case KycStepKind.guarantor:
        if (input is! GuarantorInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        await _submitPayload(kind, <String, Object?>{
          'name': input.fullName,
          'phone_e164': input.phoneE164,
          'relationship': input.relationship,
        }, idempotencyKey);
      case KycStepKind.governmentId:
        if (input is! IdDocumentInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        // Recorded and sealed server-side; the verdict is the identity
        // vendor's lookup (CR-20260923-09), never the client's.
        await _gateway.rpc('submit_identity_document', <String, Object?>{
          'p_idempotency_key': idempotencyKey,
          'p_id_type': input.idType,
          'p_id_number': input.idNumber,
        });
      case KycStepKind.policeClearance:
        if (input is! PoliceClearanceInput) {
          throw const AppError(ErrorCodes.kycStepInvalid);
        }
        await _gateway.rpc('submit_police_clearance', <String, Object?>{
          'p_idempotency_key': idempotencyKey,
          'p_certificate_number': input.certificateNumber,
          'p_issued_on': dateToWire(input.issueDate),
          'p_expires_on': dateToWire(input.expiryDate),
          'p_upload_ref': input.uploadRef,
        });
      case KycStepKind.payoutAccount:
        // The account number is sealed under the payments worker's KMS key
        // and its holder name comes from the gateway's name check
        // (CR-20260923-10 c): both wait on the gateway.
        throw const AppError(ErrorCodes.featureUnavailable);
      case KycStepKind.providerFacial:
        // No RPC accepts the liveness result until the identity vendor is
        // contracted (CR-20260923-09).
        throw const AppError(ErrorCodes.featureUnavailable);
      case KycStepKind.customerFacial:
        // Customer-side step; not submittable through this repository.
        throw const AppError(ErrorCodes.kycStepInvalid);
    }
    return getKycProfile();
  }

  @override
  Future<PayoutAccountResult> resolvePayoutAccount(
    PayoutAccountInput input,
  ) async =>
      // No name-enquiry RPC; nameMatch must stay server-computed
      // (CR-20260923-10).
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<ProviderKycProfile> submitForReview({
    required String idempotencyKey,
  }) async {
    // Refused with ERR_KYC_INCOMPLETE while a required step is missing; the
    // officer still decides every step.
    await _gateway.rpc('submit_kyc_for_review', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
    });
    return getKycProfile();
  }

  Future<void> _submitPayload(
    KycStepKind kind,
    Map<String, Object?> payload,
    String idempotencyKey, {
    List<String>? uploadRefs,
  }) async {
    await _gateway.rpc('submit_kyc_step', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_kind': kycStepKindToWire(kind),
      'p_upload_refs': uploadRefs == null || uploadRefs.isEmpty
          ? null
          : uploadRefs,
      'p_payload': <String, Object?>{
        for (final entry in payload.entries)
          if (entry.value is String &&
              (entry.value! as String).trim().isNotEmpty)
            entry.key: (entry.value! as String).trim(),
      },
    });
  }

  Future<void> _submitUploadRefs(
    KycStepKind kind,
    List<String> refs,
    String idempotencyKey,
  ) async {
    if (refs.isEmpty) throw const AppError(ErrorCodes.kycStepInvalid);
    await _gateway.rpc('submit_kyc_step', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_kind': kycStepKindToWire(kind),
      'p_upload_refs': refs,
    });
  }

  Future<void> _ensureKeyMappings(
    List<Map<String, dynamic>> services,
    List<Map<String, dynamic>> areas,
  ) async {
    if (services.isNotEmpty && _categoryKeys.isEmpty) {
      final rows = await _gateway.selectList('service_categories', 'id, key');
      for (final row in rows) {
        _categoryKeys[SupabaseGateway.asId(row['id'])] = row['key'] as String;
      }
    }
    if (areas.isNotEmpty && _cityCodes.isEmpty) {
      final rows = await _gateway.selectList('cities', 'id, code');
      for (final row in rows) {
        _cityCodes[SupabaseGateway.asId(row['id'])] = row['code'] as String;
      }
    }
  }

  Stream<T> _poll<T>(
    Future<T> Function() load, {
    Duration interval = const Duration(seconds: 15),
  }) async* {
    yield await load();
    await for (final _ in Stream<void>.periodic(interval)) {
      yield await load();
    }
  }
}
