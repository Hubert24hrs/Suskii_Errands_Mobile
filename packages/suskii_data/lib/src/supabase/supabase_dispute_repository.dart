import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// DisputeRepository over Supabase: `open_dispute` freezes the payout and
/// starts the SLA server-side; reads are RLS-scoped selects on `disputes`
/// with the `requests(currency)` embed (the dispute row carries no currency)
/// and evidence paths from `dispute_evidence`.
class SupabaseDisputeRepository implements DisputeRepository {
  SupabaseDisputeRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _columns =
      'id, request_id, opened_by, reason_code, description, status, '
      'sla_due_at, resolution_key, refund_minor, created_at, '
      'requests(currency)';

  @override
  Future<List<Dispute>> getMyDisputes() async {
    final rows = await _gateway.selectList(
      'disputes',
      _columns,
      orderBy: 'created_at',
      ascending: false,
    );
    return Future.wait(
      rows.map((row) async {
        final id = SupabaseGateway.asId(row['id']);
        return disputeFromRow(row, evidencePaths: await _evidencePaths(id));
      }),
    );
  }

  @override
  Stream<Dispute?> watchDispute(String jobId) => _gateway
      .streamRows(
        'disputes',
        primaryKey: <String>['id'],
        filterColumn: 'request_id',
        filterValue: jobId,
      )
      .asyncMap((rows) async {
        if (rows.isEmpty) return null;
        rows.sort(
          (a, b) =>
              (a['created_at'] as String).compareTo(b['created_at'] as String),
        );
        final latest = rows.last;
        final id = SupabaseGateway.asId(latest['id']);
        return disputeFromRow(latest, evidencePaths: await _evidencePaths(id));
      });

  @override
  Future<Dispute> openDispute({
    required String jobId,
    required String reasonKey,
    required String idempotencyKey,
    String? details,
    List<String> evidencePaths = const <String>[],
  }) async {
    final id = await _gateway.rpc('open_dispute', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_reason_code': reasonKey,
      'p_description': details,
    });
    final disputeId = SupabaseGateway.asId(id);
    // Evidence uploads are separate rows (submit_dispute_evidence) — attach
    // any paths the caller already has.
    for (final path in evidencePaths) {
      await _gateway.rpc('submit_dispute_evidence', <String, Object?>{
        'p_idempotency_key': '$idempotencyKey:evidence:$path',
        'p_dispute_id': disputeId,
        'p_kind': 'photo',
        'p_storage_path': path,
      });
    }
    final row = await _gateway.selectSingle(
      'disputes',
      _columns,
      column: 'id',
      value: disputeId,
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return disputeFromRow(row, evidencePaths: await _evidencePaths(disputeId));
  }

  Future<List<String>> _evidencePaths(String disputeId) async {
    final rows = await _gateway.selectList(
      'dispute_evidence',
      'storage_path',
      column: 'dispute_id',
      value: disputeId,
      orderBy: 'created_at',
    );
    return rows
        .map((row) => row['storage_path'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }
}
