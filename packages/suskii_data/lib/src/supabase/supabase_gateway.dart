import 'dart:async';
import 'dart:typed_data';

import 'package:supabase/supabase.dart';
import 'package:suskii_core/suskii_core.dart';

import 'supabase_error_mapping.dart';

/// Thin wrapper over [SupabaseClient] that encodes the contracts-v1 calling
/// conventions in one place:
///
/// * RPC arguments are passed **by name**; null values are **omitted**, never
///   sent (for several functions `null` is a meaningful value).
/// * Every failure leaves as [AppError] via [mapSupabaseError].
/// * `numeric` arrives as a JSON **string** — use [asMinorUnits] / [asDecimal]
///   rather than casting.
/// * 64-bit ids (`messages.id`) arrive as JSON numbers that can exceed 2^53 —
///   hold them as opaque strings via [asId], never `int`.
class SupabaseGateway {
  SupabaseGateway(this._client);

  final SupabaseClient _client;

  /// The authenticated GoTrue client (session, OTP, sign-out).
  GoTrueClient get auth => _client.auth;

  /// The signed-in user's auth id, or null when signed out.
  String? get currentAuthUserId => _client.auth.currentUser?.id;

  /// Calls an RPC with named arguments, omitting null-valued ones.
  Future<dynamic> rpc(
    String function, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    try {
      return await _client.rpc(function, params: rpcParams(args));
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Named RPC arguments with nulls omitted (contracts v1: an optional
  /// argument is omitted, never passed as `null`).
  static Map<String, dynamic> rpcParams(Map<String, Object?> args) =>
      <String, dynamic>{
        for (final entry in args.entries)
          if (entry.value != null) entry.key: entry.value,
      };

  /// Reads a single row, or null when no row matches. Column lists are always
  /// explicit — contracts v1 narrows column grants on several tables, and a
  /// `*` that names a column the role was not granted fails the whole query.
  Future<Map<String, dynamic>?> selectSingle(
    String table,
    String columns, {
    required String column,
    required Object value,
  }) async {
    try {
      return await _client
          .from(table)
          .select(columns)
          .eq(column, value)
          .maybeSingle();
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Reads rows with optional filters and an optional ordering. Supported
  /// filters: one equality, one IN list, one `<` comparison (cursor
  /// pagination), plus a row limit.
  Future<List<Map<String, dynamic>>> selectList(
    String table,
    String columns, {
    String? column,
    Object? value,
    String? inColumn,
    List<Object>? inValues,
    String? ltColumn,
    Object? ltValue,
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    try {
      var query = _client.from(table).select(columns);
      if (column != null) query = query.eq(column, value!);
      if (inColumn != null) query = query.inFilter(inColumn, inValues!);
      if (ltColumn != null) query = query.lt(ltColumn, ltValue!);
      var ordered = orderBy == null
          ? query
          : query.order(orderBy, ascending: ascending);
      if (limit != null) ordered = ordered.limit(limit);
      final rows = await ordered;
      return List<Map<String, dynamic>>.from(rows as List<dynamic>);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Row count with one equality filter and/or one null filter.
  Future<int> countRows(
    String table, {
    String? column,
    Object? value,
    String? isNullColumn,
  }) async {
    try {
      var query = _client.from(table).count();
      if (column != null) query = query.eq(column, value!);
      if (isNullColumn != null) query = query.isFilter(isNullColumn, null);
      return await query;
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Upserts rows, returning the upserted rows. `onConflict` names the
  /// unique key columns (PostgREST `on_conflict`).
  Future<List<Map<String, dynamic>>> upsertRows(
    String table,
    List<Map<String, Object?>> rows, {
    required String onConflict,
    String columns = '*',
  }) async {
    try {
      final result = await _client
          .from(table)
          .upsert(rows, onConflict: onConflict)
          .select(columns);
      return List<Map<String, dynamic>>.from(result as List<dynamic>);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Updates rows matching one equality filter, returning the updated rows.
  Future<List<Map<String, dynamic>>> updateRows(
    String table,
    Map<String, Object?> values, {
    required String column,
    required Object value,
    String columns = '*',
  }) async {
    try {
      final result = await _client
          .from(table)
          .update(values)
          .eq(column, value)
          .select(columns);
      return List<Map<String, dynamic>>.from(result as List<dynamic>);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Uploads bytes to a private bucket. `upsert` is off: an object path is
  /// written once, so a retried upload cannot overwrite evidence.
  Future<void> uploadBinary(
    String bucket,
    String path,
    List<int> bytes, {
    required String contentType,
  }) async {
    try {
      await _client.storage
          .from(bucket)
          .uploadBinary(
            path,
            Uint8List.fromList(bytes),
            fileOptions: FileOptions(contentType: contentType),
          );
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Live rows of a table as a stream (RLS scopes them server-side). An
  /// optional equality filter narrows the subscription server-side.
  Stream<List<Map<String, dynamic>>> streamRows(
    String table, {
    required List<String> primaryKey,
    String? filterColumn,
    Object? filterValue,
  }) {
    var query = _client.from(table).stream(primaryKey: primaryKey);
    if (filterColumn != null) query = query.eq(filterColumn, filterValue!);
    return query.map(
      (rows) => List<Map<String, dynamic>>.from(
        rows.map((r) => Map<String, dynamic>.from(r)),
      ),
    );
  }

  /// Channels this client has joined to send on, by topic.
  final Map<String, RealtimeChannel> _sendChannels =
      <String, RealtimeChannel>{};

  /// The payloads of [event] on the private Realtime [topic] (ADR-0009):
  /// authorised by the `realtime.messages` policies, carried without a
  /// database row. Leaving the stream leaves the channel.
  Stream<Map<String, dynamic>> broadcasts(String topic, String event) {
    RealtimeChannel? channel;
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        channel = _client
            .channel(topic, opts: const RealtimeChannelConfig(private: true))
            .onBroadcast(
              event: event,
              callback: (message) {
                // The callback receives the whole broadcast frame; what the
                // sender put in `payload` is one level down.
                final inner = message['payload'];
                controller.add(
                  inner is Map
                      ? Map<String, dynamic>.from(inner)
                      : Map<String, dynamic>.from(message),
                );
              },
            )
            .subscribe();
      },
      onCancel: () async {
        final joined = channel;
        if (joined != null) await _client.removeChannel(joined);
      },
    );
    return controller.stream;
  }

  /// Sends [payload] as [event] on the private Realtime [topic]. A broadcast
  /// is a courtesy, not a record (the tables are the truth), so the channel
  /// is joined once and kept for the next send.
  Future<void> broadcast(
    String topic,
    String event,
    Map<String, dynamic> payload,
  ) async {
    final channel = _sendChannels.putIfAbsent(
      topic,
      () => _client
          .channel(topic, opts: const RealtimeChannelConfig(private: true))
          .subscribe(),
    );
    try {
      await channel.sendBroadcastMessage(event: event, payload: payload);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Leaves a topic joined by [broadcast].
  Future<void> leaveTopic(String topic) async {
    final channel = _sendChannels.remove(topic);
    if (channel != null) await _client.removeChannel(channel);
  }

  /// Opaque id string — safe for 64-bit ids that exceed 2^53.
  static String asId(Object? value) => value.toString();

  /// Parses a minor-units integer that may arrive as int, double or a
  /// `numeric` string (money columns are bigint/numeric minor units).
  static int asMinorUnits(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return BigInt.parse(value).toInt();
    throw const AppError(ErrorCodes.unknown);
  }

  /// Parses a decimal that may arrive as num or a `numeric` string
  /// (`rank_offers.score`, rating averages).
  static double asDecimal(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.parse(value);
    throw const AppError(ErrorCodes.unknown);
  }

  /// Parses an RFC 3339 / Postgres timestamp with time zone.
  static DateTime asTimestamp(Object? value) =>
      DateTime.parse(value! as String).toUtc();
}
