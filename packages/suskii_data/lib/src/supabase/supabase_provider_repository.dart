import 'dart:async';

import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';
import 'supabase_request_repository.dart';
import 'supabase_wallet_repository.dart';

/// ProviderRepository over Supabase: the open-requests feed comes from
/// `provider_feed` (approximate locations — the customer's exact pickup is
/// not exposed until assignment), offers from `create_offer`, and the online
/// toggle from `set_online`. Assigned jobs read through the same request-row
/// loader as the customer side.
class SupabaseProviderRepository implements ProviderRepository {
  SupabaseProviderRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<ProviderHomeSummary> getHomeSummary() async {
    final myId = _gateway.currentAuthUserId;
    final profile = await _gateway.selectSingle(
      'provider_profiles',
      'online',
      column: 'user_id',
      value: myId!,
    );
    final user = await _gateway.selectSingle(
      'profiles',
      'provider_verification',
      column: 'user_id',
      value: myId,
    );
    final feed = await _feed();
    final currency = await myCurrencyCode(_gateway);
    // todayEarnings / completedToday / documentWarnings have no contract
    // source (CR-20260923-05) — they report zero/empty rather than
    // fabricating numbers.
    return ProviderHomeSummary(
      online: profile?['online'] as bool? ?? false,
      verificationStatus: verificationFromWire(user?['provider_verification']),
      todayEarnings: Money(0, currency),
      completedToday: 0,
      nearbyOpenRequests: feed.length,
      documentWarnings: const <DocumentExpiryWarning>[],
    );
  }

  @override
  Stream<List<JobRequest>> watchNearbyRequests() {
    // provider_feed is a one-shot RPC; the stream re-runs it whenever a
    // published request changes (and once at listen time — the initial
    // snapshot of the requests stream already covers the cold read).
    late StreamController<List<JobRequest>> controller;
    StreamSubscription<List<Map<String, dynamic>>>? sub;
    var refreshing = false;
    var dirty = false;
    controller = StreamController<List<JobRequest>>(
      onListen: () {
        Future<void> refresh() async {
          if (refreshing) {
            dirty = true;
            return;
          }
          refreshing = true;
          try {
            if (!controller.isClosed) controller.add(await _feed());
          } on Object catch (error) {
            if (!controller.isClosed) controller.addError(error);
          } finally {
            refreshing = false;
            if (dirty) {
              dirty = false;
              await refresh();
            }
          }
        }

        sub = _gateway
            .streamRows(
              'requests',
              primaryKey: <String>['id'],
              filterColumn: 'status',
              filterValue: 'published',
            )
            .listen((_) => unawaited(refresh()));
      },
      onCancel: () async {
        await sub?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<List<JobRequest>> _feed() async {
    final rows = await _gateway.rpc('provider_feed');
    return List<Map<String, dynamic>>.from(rows as List<dynamic>)
        .map(jobRequestFromFeedRow)
        .toList(growable: false);
  }

  @override
  Future<List<Offer>> getMyOffers() async {
    final rows = await _gateway.selectList(
      'offers',
      'id, thread_id, request_id, provider_id, author_side, amount_minor, '
          'currency, message, status, round, expires_at, created_at',
      column: 'provider_id',
      value: _gateway.currentAuthUserId!,
      orderBy: 'created_at',
      ascending: false,
    );
    // The provider's own offers — the display card is the caller's own, so
    // no get_provider_card lookup.
    return rows.map((row) => offerFromRow(row)).toList(growable: false);
  }

  @override
  Stream<List<JobRequest>> watchMyJobs() => _gateway
      .streamRows(
        'jobs',
        primaryKey: <String>['request_id'],
        filterColumn: 'provider_id',
        filterValue: _gateway.currentAuthUserId,
      )
      .asyncMap((rows) async {
        final jobs = <JobRequest>[];
        for (final row in rows) {
          final request = await loadJobRequestRow(
            _gateway,
            SupabaseGateway.asId(row['request_id']),
          );
          if (request != null && !request.status.isTerminal) jobs.add(request);
        }
        jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return List<JobRequest>.unmodifiable(jobs);
      });

  @override
  Future<List<JobRequest>> getMyJobsHistory({
    String? cursor,
    int limit = 20,
  }) async {
    final jobs = await _gateway.selectList(
      'jobs',
      'request_id',
      column: 'provider_id',
      value: _gateway.currentAuthUserId!,
    );
    if (jobs.isEmpty) return const <JobRequest>[];
    final ids = jobs
        .map((row) => SupabaseGateway.asId(row['request_id']))
        .toList(growable: false);
    // Cursor is the last row's created_at (ISO-8601), same convention as the
    // customer history. Status filtering is client-side: one IN filter per
    // query, and the id list needs it.
    final rows = await _gateway.selectList(
      'requests',
      requestRowColumns,
      inColumn: 'id',
      inValues: ids,
      ltColumn: cursor == null ? null : 'created_at',
      ltValue: cursor,
      orderBy: 'created_at',
      ascending: false,
    );
    return rows
        .map(jobRequestFromRow)
        .where((request) => request.status.isTerminal)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<Offer> submitOffer({
    required String requestId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  }) async {
    final id = await _gateway.rpc('create_offer', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': requestId,
      'p_amount_minor': amount.minorUnits,
      'p_message': message,
    });
    final row = await _gateway.selectSingle(
      'offers',
      'id, thread_id, request_id, provider_id, author_side, amount_minor, '
          'currency, message, status, round, expires_at, created_at',
      column: 'id',
      value: SupabaseGateway.asId(id),
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return offerFromRow(row);
  }

  @override
  Future<bool> setOnline(bool online, {required String idempotencyKey}) async {
    // set_online takes no idempotency key (a plain state toggle — replays are
    // naturally idempotent); the interface's key is unused here.
    final result = await _gateway.rpc('set_online', <String, Object?>{
      'p_online': online,
    });
    return result as bool;
  }
}
