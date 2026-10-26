import 'dart:async';
import 'dart:convert';
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

  /// Calls an Edge Function with the signed-in user's session and a JSON body,
  /// returning the decoded JSON object. A non-2xx answer leaves as [AppError]
  /// carrying the function's `{error: {code}}`.
  Future<Map<String, dynamic>> invokeFunction(
    String name,
    Map<String, Object?> body,
  ) async {
    try {
      final response = await _client.functions.invoke(name, body: body);
      final data = response.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      if (data is String && data.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(data) as Map);
      }
      return <String, dynamic>{};
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

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

  /// Rows of a table as a stream (RLS scopes them server-side), emitted
  /// again only when they differ. Re-read on every [refreshes] tick: the
  /// project publishes no table changes, by design (ADR-0009, contracts rule
  /// 9), so a broadcast on one of [topics] says "look again" and the timer
  /// covers whatever no broadcast announces. Name the [columns] for a table
  /// with column-level grants: `*` is refused there.
  Stream<List<Map<String, dynamic>>> streamRows(
    String table, {
    String columns = '*',
    String? filterColumn,
    Object? filterValue,
    List<String> topics = const <String>[],
    Duration every = const Duration(seconds: 15),
    Stream<void>? nudges,
  }) {
    String? last;
    Future<List<Map<String, dynamic>>?> read() async {
      var query = _client.from(table).select(columns);
      if (filterColumn != null) query = query.eq(filterColumn, filterValue!);
      final rows = List<Map<String, dynamic>>.from(
        (await query).map((r) => Map<String, dynamic>.from(r)),
      );
      final encoded = jsonEncode(rows);
      if (encoded == last) return null;
      last = encoded;
      return rows;
    }

    return _coalesced(
      refreshes(topics: topics, every: every, nudges: nudges),
      read,
    ).where((rows) => rows != null).cast<List<Map<String, dynamic>>>();
  }

  /// A tick at once, then on any broadcast on [topics], on each (re)join of
  /// one (what was missed while away), and every [every] regardless — a
  /// broadcast is a courtesy, never a guarantee. A topic the caller may not
  /// join is refused by `private.may_join_topic` and the timer still runs.
  /// [nudges] is the caller's own "look again", for a write it knows it made.
  Stream<void> refreshes({
    List<String> topics = const <String>[],
    Duration every = const Duration(seconds: 15),
    Stream<void>? nudges,
  }) {
    final leaves = <void Function()>[];
    Timer? timer;
    StreamSubscription<void>? nudged;
    late final StreamController<void> controller;
    void tick() {
      if (!controller.isClosed) controller.add(null);
    }

    controller = StreamController<void>(
      onListen: () {
        tick();
        timer = Timer.periodic(every, (_) => tick());
        nudged = nudges?.listen((_) => tick());
        for (final topic in topics) {
          leaves.add(
            _listen(topic, onMessage: (_, _) => tick(), onJoined: tick),
          );
        }
      },
      onCancel: () {
        timer?.cancel();
        unawaited(nudged?.cancel());
        for (final leave in leaves) {
          leave();
        }
      },
    );
    return controller.stream;
  }

  /// Runs [read] per tick, one at a time; ticks that arrive mid-read fold into
  /// one more read. A failed read is an error event only before anything has
  /// been emitted — afterwards the last good value stands until the next tick.
  Stream<T> _coalesced<T>(Stream<void> ticks, Future<T> Function() read) {
    StreamSubscription<void>? sub;
    var reading = false;
    var again = false;
    var emitted = false;
    late final StreamController<T> controller;
    Future<void> run() async {
      if (reading) {
        again = true;
        return;
      }
      reading = true;
      try {
        do {
          again = false;
          try {
            final value = await read();
            if (controller.isClosed) return;
            controller.add(value);
            emitted = true;
          } on Object catch (error) {
            if (!emitted && !controller.isClosed) {
              controller.addError(mapSupabaseError(error));
            }
          }
        } while (again && !controller.isClosed);
      } finally {
        reading = false;
      }
    }

    controller = StreamController<T>(
      onListen: () => sub = ticks.listen((_) => unawaited(run())),
      onCancel: () async => sub?.cancel(),
    );
    return controller.stream;
  }

  /// One channel per topic, shared by everything on this client that uses
  /// it: Realtime closes the first of two joins of one topic on a socket, so
  /// a job screen's refresh and its location broadcasts must share a join.
  final Map<String, _Topic> _topics = <String, _Topic>{};

  /// Topics joined by [broadcast], held until [leaveTopic].
  final Map<String, void Function()> _sending = <String, void Function()>{};

  /// Joins [topic] (private, ADR-0009) or shares the existing join, and calls
  /// [onMessage] with each broadcast's event and payload and [onJoined] on
  /// each (re)join. Returns the call that leaves; the last one out closes it.
  void Function() _listen(
    String topic, {
    void Function(String? event, Map<String, dynamic> payload)? onMessage,
    void Function()? onJoined,
  }) {
    final entry = _topics.putIfAbsent(topic, () {
      final created = _Topic();
      created.channel = _client
          .channel(topic, opts: const RealtimeChannelConfig(private: true))
          .onBroadcast(
            event: '*',
            callback: (message) {
              // The callback receives the whole broadcast frame; what the
              // sender put in `payload` is one level down.
              final inner = message['payload'];
              final payload = inner is Map
                  ? Map<String, dynamic>.from(inner)
                  : Map<String, dynamic>.from(message);
              final event = message['event'] as String?;
              for (final listener in List.of(created.listeners)) {
                listener(event, payload);
              }
            },
          )
          .subscribe((status, _) {
            if (status != RealtimeSubscribeStatus.subscribed) return;
            for (final joined in List.of(created.joined)) {
              joined();
            }
          });
      return created;
    });
    entry.refs++;
    if (onMessage != null) entry.listeners.add(onMessage);
    if (onJoined != null) entry.joined.add(onJoined);
    var left = false;
    return () {
      if (left) return;
      left = true;
      if (onMessage != null) entry.listeners.remove(onMessage);
      if (onJoined != null) entry.joined.remove(onJoined);
      if (--entry.refs == 0 && identical(_topics[topic], entry)) {
        _topics.remove(topic);
        unawaited(_client.removeChannel(entry.channel));
      }
    };
  }

  /// The payloads of [event] on the private Realtime [topic] (ADR-0009):
  /// authorised by the `realtime.messages` policies, carried without a
  /// database row. Leaving the stream leaves the topic.
  Stream<Map<String, dynamic>> broadcasts(String topic, String event) {
    void Function()? leave;
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () => leave = _listen(
        topic,
        onMessage: (received, payload) {
          if (received == event && !controller.isClosed) {
            controller.add(payload);
          }
        },
      ),
      onCancel: () => leave?.call(),
    );
    return controller.stream;
  }

  /// Sends [payload] as [event] on the private Realtime [topic]. A broadcast
  /// is a courtesy, not a record (the tables are the truth), so the topic is
  /// joined once and kept for the next send.
  Future<void> broadcast(
    String topic,
    String event,
    Map<String, dynamic> payload,
  ) async {
    _sending.putIfAbsent(topic, () => _listen(topic));
    try {
      await _topics[topic]!.channel.sendBroadcastMessage(
        event: event,
        payload: payload,
      );
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Leaves a topic joined by [broadcast].
  Future<void> leaveTopic(String topic) async => _sending.remove(topic)?.call();

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

/// A joined topic and who is using it (see [SupabaseGateway._listen]).
class _Topic {
  late final RealtimeChannel channel;
  final Set<void Function(String? event, Map<String, dynamic> payload)>
  listeners = <void Function(String? event, Map<String, dynamic> payload)>{};
  final Set<void Function()> joined = <void Function()>{};
  int refs = 0;
}
