import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// RequestRepository over Supabase: drafts/publish/cancel go through the
/// contract RPCs (the server owns the state machine and fees); reads are
/// RLS-scoped selects on `requests` with the category-key and to-one `jobs`
/// embeds.
class SupabaseRequestRepository implements RequestRepository {
  SupabaseRequestRepository(this._gateway);

  final SupabaseGateway _gateway;

  /// Explicit columns (contracts v1 narrows column grants on several tables).
  /// `service_categories(key)` embeds the category key via the category_id
  /// FK (rows store the uuid; the domain carries the key). `jobs(...)` embeds
  /// the to-one job row that exists once an offer has been accepted.
  static const String _columns =
      'id, customer_id, is_custom_category, custom_category_label, '
      'description, urgency, status, pickup_point, pickup_label, '
      'pickup_landmark_note, destination_point, destination_label, '
      'destination_landmark_note, scheduled_at, preferred_price_minor, '
      'item_float_minor, declared_value_minor, currency, expires_at, '
      'created_at, service_categories(key), '
      'jobs(provider_id, agreed_amount_minor, currency, commission_rate_bps, '
      'commission_minor, net_minor, estimated_gateway_fee_minor, '
      'actual_gateway_fee_minor, tip_minor)';

  static final List<String> _activeStatuses = <String>[
    for (final status in JobStatus.values)
      if (!status.isTerminal) jobStatusToWire(status),
  ];

  static final List<String> _terminalStatuses = <String>[
    for (final status in JobStatus.values)
      if (status.isTerminal) jobStatusToWire(status),
  ];

  @override
  Future<List<JobRequest>> getMyActiveJobs() async {
    final rows = await _gateway.selectList(
      'requests',
      _columns,
      inColumn: 'status',
      inValues: _activeStatuses,
      orderBy: 'created_at',
    );
    return rows.map(jobRequestFromRow).toList(growable: false);
  }

  @override
  Future<List<JobRequest>> getMyRequestHistory({
    String? cursor,
    int limit = 20,
  }) async {
    // Cursor is the last row's created_at (ISO-8601) — an opaque page token,
    // same as the mock's use of the last row's id.
    final rows = await _gateway.selectList(
      'requests',
      _columns,
      inColumn: 'status',
      inValues: _terminalStatuses,
      ltColumn: cursor == null ? null : 'created_at',
      ltValue: cursor,
      orderBy: 'created_at',
      limit: limit,
    );
    return rows.map(jobRequestFromRow).toList(growable: false);
  }

  @override
  Stream<JobRequest> watchJob(String jobId) {
    // The requests row carries the status; every jobs-row money change happens
    // in the same transaction as a requests status change, so re-reading the
    // joins on each requests event stays consistent. Media are immutable
    // after creation, but cheap to re-read here (one job only).
    return _gateway
        .streamRows(
          'requests',
          primaryKey: <String>['id'],
          filterColumn: 'id',
          filterValue: jobId,
        )
        .asyncMap((_) => _load(jobId))
        .where((request) => request != null)
        .cast<JobRequest>();
  }

  Future<JobRequest?> _load(String jobId) async {
    final row = await _gateway.selectSingle(
      'requests',
      _columns,
      column: 'id',
      value: jobId,
    );
    if (row == null) return null;
    final media = await _gateway.selectList(
      'request_media',
      'storage_path',
      column: 'request_id',
      value: jobId,
      orderBy: 'created_at',
    );
    return jobRequestFromRow(
      row,
      mediaPaths: media
          .map((m) => m['storage_path'] as String)
          .toList(growable: false),
    );
  }

  @override
  Future<JobRequest> createRequest(
    CreateRequestInput input, {
    required String idempotencyKey,
  }) async {
    final pickupPoint = input.pickup.point;
    final destinationPoint = input.destination?.point;
    final id = await _gateway.rpc('create_request', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_category_key': input.categoryId,
      'p_description': input.description,
      'p_pickup_label': input.pickup.label,
      'p_urgency': input.urgency.name,
      'p_is_custom_category': input.isCustomCategory ? true : null,
      'p_custom_category_label': input.customCategoryLabel,
      'p_pickup_landmark_note': input.pickup.landmarkNote,
      'p_pickup_lat': pickupPoint?.latitude,
      'p_pickup_lng': pickupPoint?.longitude,
      'p_destination_label': input.destination?.label,
      'p_destination_landmark_note': input.destination?.landmarkNote,
      'p_destination_lat': destinationPoint?.latitude,
      'p_destination_lng': destinationPoint?.longitude,
      'p_scheduled_at': input.scheduledAt?.toIso8601String(),
      'p_preferred_price_minor': input.preferredPrice?.minorUnits,
      'p_item_float_minor': input.itemFloat?.minorUnits,
      'p_declared_value_minor': input.declaredValue?.minorUnits,
      'p_media_paths': input.mediaPaths.isEmpty ? null : input.mediaPaths,
    });
    final created = await _load(SupabaseGateway.asId(id));
    if (created == null) throw const AppError(ErrorCodes.unknown);
    return created;
  }

  @override
  Future<JobRequest> publishRequest(
    String jobId, {
    required String idempotencyKey,
  }) => _mutate('publish_request', jobId, <String, Object?>{
    'p_idempotency_key': idempotencyKey,
  });

  @override
  Future<JobRequest> cancelRequest(
    String jobId,
    String reasonKey, {
    required String idempotencyKey,
  }) => _mutate('cancel_request', jobId, <String, Object?>{
    'p_idempotency_key': idempotencyKey,
    'p_reason_code': reasonKey,
  });

  /// The transition RPCs return the new status scalar; the entity needs the
  /// full row, so every mutation re-selects.
  Future<JobRequest> _mutate(
    String function,
    String jobId,
    Map<String, Object?> args,
  ) async {
    await _gateway.rpc(function, <String, Object?>{
      'p_request_id': jobId,
      ...args,
    });
    final updated = await _load(jobId);
    if (updated == null) throw const AppError(ErrorCodes.unknown);
    return updated;
  }
}
