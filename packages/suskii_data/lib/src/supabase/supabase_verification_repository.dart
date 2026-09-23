import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// VerificationRepository (customer facial verification) over Supabase.
///
/// Supported: biometric consent via `record_consent`, session start via
/// `start_verification_session`, state via `get_my_kyc_profile` (the
/// `customer_facial` row). Blocked (CR-20260923-08/09): `submitIdLookup`
/// needs client-side ID-number encryption the contract has no key story for,
/// and there is no RPC to submit the liveness result — the client must never
/// decide the verification verdict, so both stay feature-unavailable rather
/// than sending plaintext or self-declaring an outcome.
///
/// Wire gaps mapped defensively: the profile row has no session id (the
/// step kind wire value stands in) and no `updated_at` (`expires_at` stands
/// in, epoch when absent). Watching polls — KYC step state is RPC-only with
/// no realtime topic.
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
  }) async =>
      // submit_identity_document expects id-number ciphertext + blind index;
      // the client has no encryption story (CR-20260923-08) and no RPC
      // accepts the liveness result (CR-20260923-09). Sending plaintext or
      // a client-decided outcome would weaken the security model.
      throw const AppError(ErrorCodes.featureUnavailable);

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
          expiresAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
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
