import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// The room a call connects to, behind an interface so the call logic can be
/// tested without WebRTC. [LiveKitCallRoom] is the real one.
abstract interface class CallRoom {
  Future<void> connect(String url, String token);
  Future<void> setMicrophoneEnabled({required bool enabled});
  Future<void> disconnect();
  int get remoteCount;

  /// The other person joined (`true`) or left (`false`).
  Stream<bool> get remote;

  /// The connection to the room was lost or closed.
  Stream<void> get disconnected;
}

class LiveKitCallRoom implements CallRoom {
  final lk.Room _room = lk.Room();
  late final lk.EventsListener<lk.RoomEvent> _listener = _room.createListener();
  final StreamController<bool> _remote = StreamController<bool>.broadcast();
  final StreamController<void> _disconnected =
      StreamController<void>.broadcast();

  @override
  Future<void> connect(String url, String token) async {
    _listener
      ..on<lk.ParticipantConnectedEvent>((_) => _remote.add(true))
      ..on<lk.ParticipantDisconnectedEvent>((_) => _remote.add(false))
      ..on<lk.RoomDisconnectedEvent>((_) => _disconnected.add(null));
    await _room.connect(url, token);
  }

  @override
  Future<void> setMicrophoneEnabled({required bool enabled}) async {
    await _room.localParticipant?.setMicrophoneEnabled(enabled);
  }

  @override
  Future<void> disconnect() async {
    await _room.disconnect();
    await _listener.dispose();
    await _remote.close();
    await _disconnected.close();
  }

  @override
  int get remoteCount => _room.remoteParticipants.length;

  @override
  Stream<bool> get remote => _remote.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;
}

/// Masked in-app calls over LiveKit Cloud. The `call-token` Edge Function runs
/// `start_call` as the caller (and `answer_call` when the other person is
/// already ringing them), so who is called, when calls are allowed and one call
/// per job are all decided by the database. This joins the room it returns
/// with the microphone on and nothing else. No recording exists anywhere.
class LiveKitCallAdapter implements CallAdapter {
  LiveKitCallAdapter({
    required Future<Map<String, dynamic>> Function(String, Map<String, Object?>)
    invoke,
    required Future<dynamic> Function(String, Map<String, Object?>) rpc,
    CallRoom Function()? room,
    this.ringTimeout = const Duration(seconds: 60),
  }) : _invoke = invoke,
       _rpc = rpc,
       _newRoom = room ?? LiveKitCallRoom.new;

  /// The real backend: the `call-token` function and `end_call`, as the user.
  factory LiveKitCallAdapter.overGateway(SupabaseGateway gateway) =>
      LiveKitCallAdapter(invoke: gateway.invokeFunction, rpc: gateway.rpc);

  final Future<Map<String, dynamic>> Function(String, Map<String, Object?>)
  _invoke;
  final Future<dynamic> Function(String, Map<String, Object?>) _rpc;
  final CallRoom Function() _newRoom;

  /// The server marks an unanswered call missed after a minute; the caller's
  /// screen stops ringing at the same point instead of waiting alone.
  final Duration ringTimeout;

  final Map<String, _LiveCall> _calls = <String, _LiveCall>{};

  @override
  Future<CallSession> startCall(
    String jobId, {
    required String idempotencyKey,
  }) async {
    final answer = await _invoke('call-token', <String, Object?>{
      'request_id': jobId,
      'idempotency_key': idempotencyKey,
    });
    final callId = answer['call_id'] as String;
    final room = _newRoom();
    final call = _LiveCall(callId, idempotencyKey, room);
    _calls[callId] = call;

    call.subscriptions
      ..add(
        room.remote.listen((joined) {
          if (joined) {
            call.ring?.cancel();
            call.emit(CallState.active);
          } else if (room.remoteCount == 0) {
            // The other person hung up or dropped: the call is over for both.
            unawaited(endCall(callId));
          }
        }),
      )
      ..add(room.disconnected.listen((_) => unawaited(endCall(callId))));

    try {
      await room.connect(answer['url'] as String, answer['token'] as String);
      await room.setMicrophoneEnabled(enabled: true);
    } on Object {
      await _finish(call, failed: true);
      rethrow;
    }
    if (room.remoteCount > 0) {
      call.emit(CallState.active);
    } else {
      call.emit(CallState.ringing);
      call.ring = Timer(ringTimeout, () => unawaited(endCall(callId)));
    }
    return CallSession(
      sessionId: callId,
      jobId: jobId,
      expiresAt: DateTime.parse(answer['expires_at'] as String),
    );
  }

  @override
  Stream<CallEvent> events(String sessionId) =>
      _calls[sessionId]?.events.stream ??
      Stream<CallEvent>.value(const CallEvent(state: CallState.ended));

  @override
  Future<void> setMuted(String sessionId, {required bool muted}) async {
    await _calls[sessionId]?.room.setMicrophoneEnabled(enabled: !muted);
  }

  @override
  Future<void> endCall(String sessionId) async {
    final call = _calls[sessionId];
    if (call == null) return;
    await _finish(call);
  }

  Future<void> _finish(_LiveCall call, {bool failed = false}) async {
    if (call.finished) return;
    call.finished = true;
    _calls.remove(call.id);
    call.ring?.cancel();
    for (final s in call.subscriptions) {
      await s.cancel();
    }
    try {
      await _rpc('end_call', <String, Object?>{
        'p_idempotency_key': '${call.key}:end',
        'p_call_id': call.id,
        if (failed) 'p_failed': true,
      });
    } on Object {
      // Already ended by the other side or by the ring timeout: nothing to undo.
    }
    try {
      await call.room.disconnect();
    } on Object {
      // The room is gone either way.
    }
    call.emit(failed ? CallState.failed : CallState.ended);
    // Not awaited: a single-subscription stream nobody listens to never finishes closing.
    unawaited(call.events.close());
  }
}

class _LiveCall {
  _LiveCall(this.id, this.key, this.room);

  final String id;
  final String key;
  final CallRoom room;

  /// Single-subscription, so the first state is held until the screen listens.
  final StreamController<CallEvent> events = StreamController<CallEvent>();
  final List<StreamSubscription<Object?>> subscriptions =
      <StreamSubscription<Object?>>[];
  Timer? ring;
  bool finished = false;

  void emit(CallState state) {
    if (!events.isClosed) events.add(CallEvent(state: state));
  }
}
