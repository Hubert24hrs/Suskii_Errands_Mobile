import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';
import 'supabase_request_repository.dart';

/// JobProgressRepository over Supabase: the provider's status transitions,
/// completion confirmation, handover PINs and proofs all go through the
/// contract RPCs (the server owns the state machine, PIN attempt limits and
/// proof gating). Entity-returning mutations re-select the request row,
/// which the requests/jobs embeds make a single read.
class SupabaseJobProgressRepository implements JobProgressRepository {
  SupabaseJobProgressRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _proofColumns =
      'id, request_id, uploaded_by, kind, storage_path, device_point, '
      'device_captured_at, server_received_at';

  @override
  Future<JobRequest> requestStatusChange(
    String jobId,
    JobStatus target, {
    required String idempotencyKey,
  }) => _reloadAfter('set_job_status', <String, Object?>{
    'p_idempotency_key': idempotencyKey,
    'p_request_id': jobId,
    'p_target': jobStatusToWire(target),
  }, jobId);

  @override
  Future<JobRequest> confirmCompletion(
    String jobId, {
    required String idempotencyKey,
  }) => _reloadAfter('confirm_completion', <String, Object?>{
    'p_idempotency_key': idempotencyKey,
    'p_request_id': jobId,
  }, jobId);

  Future<JobRequest> _reloadAfter(
    String function,
    Map<String, Object?> args,
    String jobId,
  ) async {
    await _gateway.rpc(function, args);
    final updated = await loadJobRequestRow(_gateway, jobId);
    if (updated == null) throw const AppError(ErrorCodes.unknown);
    return updated;
  }

  @override
  Future<PinVerificationResult> verifyHandoverPin(
    String jobId,
    String pin, {
    required HandoverPinKind kind,
    required String idempotencyKey,
  }) async {
    final result = await _gateway.rpc('verify_pin', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_pin': pin,
      'p_kind': kind.name,
    });
    return pinVerificationFromWire(result);
  }

  @override
  Future<String> revealHandoverPin(
    String jobId, {
    required HandoverPinKind kind,
  }) async {
    final pin = await _gateway.rpc('reveal_job_pin', <String, Object?>{
      'p_request_id': jobId,
      'p_kind': kind.name,
    });
    return pin as String;
  }

  @override
  Future<Proof> submitProof({
    required String jobId,
    required ProofKind kind,
    required String storagePath,
    required String idempotencyKey,
    DateTime? capturedAt,
    double? lat,
    double? lng,
  }) async {
    final id = await _gateway.rpc('submit_proof', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_kind': kind.name,
      'p_storage_path': storagePath,
      'p_device_captured_at': capturedAt?.toIso8601String(),
      'p_lat': lat,
      'p_lng': lng,
    });
    final row = await _gateway.selectSingle(
      'proofs',
      _proofColumns,
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return proofFromRow(row);
  }

  @override
  Future<List<Proof>> getProofs(String jobId) async {
    final rows = await _gateway.selectList(
      'proofs',
      _proofColumns,
      column: 'request_id',
      value: jobId,
      orderBy: 'server_received_at',
    );
    return rows.map(proofFromRow).toList(growable: false);
  }
}
