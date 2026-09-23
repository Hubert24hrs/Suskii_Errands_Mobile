import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// ProviderKycRepository over Supabase.
///
/// Profile reads combine `get_my_kyc_profile` (step state — the source of
/// truth) with `provider_profiles` (kind, vehicle type), `provider_services`
/// and `provider_service_areas`; the uuid foreign keys are translated back
/// to the category keys / city codes the domain model carries. The overall
/// rollup is display-only ([kycOverallRollup]) until the server exposes one
/// (CR-20260923-10).
///
/// Writes: onboarding goes to `update_provider_services` /
/// `update_provider_service_areas` / a `provider_profiles` vehicle-type
/// update (no idempotency keys on those RPCs — client-side dedupe only;
/// `kind` is server-defaulted and `businessName` has no column). Upload-ref
/// steps (`idDocumentCapture`, `vehicleDocuments`, `credentials`) go through
/// `submit_kyc_step`.
///
/// Blocked (feature-unavailable, never weakened): anything needing
/// client-produced ciphertext (government id, police clearance, payout
/// account — CR-20260923-08), the provider-facial liveness result
/// (CR-20260923-09), structured address/guarantor/credentials payloads and
/// submit-for-review / payout name enquiry (CR-20260923-10).
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
    final stepRows = await _gateway
        .rpc('get_my_kyc_profile')
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
      overallStatus: kycOverallRollup(steps),
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
    if (input.vehicleType != null) {
      await _gateway.updateRows(
        'provider_profiles',
        <String, Object?>{
          'vehicle_type': vehicleTypeToWire(input.vehicleType!),
        },
        column: 'user_id',
        value: userId,
        columns: 'user_id',
      );
    }
    // input.kind is server-defaulted (not client-updatable); input.businessName
    // has no column (CR-20260923-10).
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
        // input.description has nowhere to go (CR-20260923-10).
        await _submitUploadRefs(kind, input.uploadRefs, idempotencyKey);
      case KycStepKind.governmentId:
      case KycStepKind.policeClearance:
      case KycStepKind.payoutAccount:
        // Client-produced ciphertext required — no key story (CR-20260923-08).
        throw const AppError(ErrorCodes.featureUnavailable);
      case KycStepKind.providerFacial:
        // No RPC accepts the liveness result (CR-20260923-09).
        throw const AppError(ErrorCodes.featureUnavailable);
      case KycStepKind.address:
      case KycStepKind.guarantor:
        // No structured payload parameter exists (CR-20260923-10).
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
  }) async =>
      // No submit-for-review RPC; the client must not self-declare the
      // profile in-review (CR-20260923-10).
      throw const AppError(ErrorCodes.featureUnavailable);

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
