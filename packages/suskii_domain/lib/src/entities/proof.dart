import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';

part 'proof.freezed.dart';
part 'proof.g.dart';

/// Proof-of-execution attached to a job (spec: job_lifecycle.proof).
/// Mirrors the backend's `submit_proof(idempotency_key, request_id, kind,
/// storage_path, device_captured_at, lat, lng)`: the provider uploads the
/// bytes to storage first (server signs uploads only into the job's own
/// `<jobId>/…` prefix) and then records this row. Server-side rules:
/// provider-only, only while the job is IN_PROGRESS or COMPLETED_BY_PROVIDER,
/// and [storagePath] must start with the job id.
@freezed
abstract class Proof with _$Proof {
  const factory Proof({
    required String id,
    required String jobId,
    required String providerId,
    required ProofKind kind,

    /// Storage object path, namespaced under the job (`<jobId>/…`).
    required String storagePath,

    /// Server receipt time.
    required DateTime createdAt,

    /// Device-reported capture time (as sent in `device_captured_at`).
    DateTime? capturedAt,

    /// Device-reported capture coordinates, when the device granted
    /// location permission.
    double? lat,
    double? lng,
  }) = _Proof;

  factory Proof.fromJson(Map<String, dynamic> json) => _$ProofFromJson(json);
}
