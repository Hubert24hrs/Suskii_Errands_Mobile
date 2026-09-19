import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'dispute.freezed.dart';
part 'dispute.g.dart';

/// A dispute on a job (spec: added_features — dispute center with evidence,
/// SLA timers, partial/full refunds; payout is frozen while one is open).
/// Opening and resolving are server decisions; the client supplies the
/// reason key, details and evidence refs and renders the outcome.
@freezed
abstract class Dispute with _$Dispute {
  const factory Dispute({
    required String id,
    required String jobId,
    required String openedBy,

    /// Localization key (e.g. `disputeReasonItemNotDelivered`), never free
    /// text for the category itself.
    required String reasonKey,
    required DisputeStatus status,
    required DateTime createdAt,
    String? details,
    List<String>? evidencePaths,

    /// Response SLA (server timestamp — render against the clock offset).
    DateTime? slaDeadline,

    /// Localizable resolution summary key, set when resolved.
    String? resolutionNoteKey,

    /// Refund decided by the server (partial or full). Null = no refund.
    Money? refundAmount,
  }) = _Dispute;

  factory Dispute.fromJson(Map<String, dynamic> json) =>
      _$DisputeFromJson(json);
}
