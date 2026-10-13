import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// VerificationRepository (customer facial verification) over Supabase.
///
/// Supported: biometric consent via `record_consent`, session start via
/// `start_verification_session`, state via `get_my_kyc_profile` (the
/// `customer_facial` row), and the ID number via `submit_identity_document`,
/// which seals it server-side (CR-20260923-08). The verdict is not the
/// client's to give: no RPC accepts a liveness result until the identity
/// vendor is contracted (CR-20260923-09), so after the number goes in the
/// session reads back as the vendor check leaves it.
///
/// The profile row carries no session id (the step kind wire value stands in);
/// `updatedAt` is the step's review time, else its submission time. Watching
/// polls: KYC step state is RPC-only with no realtime topic.
class SupabaseVerificationRepository implements VerificationRepository {
  SupabaseVerificationRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _kind = 'customer_facial';

  @override
  Future<VerificationSession?> getCustomerVerification() async {
    final rows = await _profileRows();
    for (final row in rows) {
      if (row['kind'] == _kind) return _sessionFromRow(row);
    }
    return null;
  }

  @override
  Stream<VerificationSession?> watchCustomerVerification() =>
      _poll(getCustomerVerification);

  @override
  Future<VerificationSession> giveBiometricConsent({
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('record_consent', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_kind': 'biometric',
      'p_granted': true,
    });
    return await getCustomerVerification() ??
        _fallback(KycStepStatus.notStarted);
  }

  @override
  Future<VerificationSession> startFacialVerification({
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('start_verification_session', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_kind': _kind,
    });
    return await getCustomerVerification() ??
        _fallback(KycStepStatus.inProgress);
  }

  @override
  Future<VerificationSession> submitIdLookup(
    String sessionId,
    String idType,
    String idNumber, {
    required String idempotencyKey,
  }) async {
    await _gateway.rpc('submit_identity_document', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_id_type': idType,
      'p_id_number': idNumber,
    });
    return await getCustomerVerification() ??
        _fallback(KycStepStatus.inProgress);
  }

  Future<List<Map<String, dynamic>>> _profileRows() => _gateway
      .rpc('get_my_kyc_profile')
      .then((rows) => List<Map<String, dynamic>>.from(rows as List<dynamic>));

  VerificationSession _sessionFromRow(Map<String, dynamic> row) {
    final step = kycStepFromProfileRow(row);
    final expiresAt = row['expires_at'] == null
        ? null
        : SupabaseGateway.asTimestamp(row['expires_at']);
    return VerificationSession(
      id: _kind,
      kind: step.kind,
      status: step.status,
      updatedAt:
          step.reviewedAt ??
          step.submittedAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      rejectionReasonKey: step.rejectionReasonKey,
      expiresAt: expiresAt,
    );
  }

  VerificationSession _fallback(KycStepStatus status) => VerificationSession(
    id: _kind,
    kind: KycStepKind.customerFacial,
    status: status,
    updatedAt: DateTime.now().toUtc(),
  );

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
