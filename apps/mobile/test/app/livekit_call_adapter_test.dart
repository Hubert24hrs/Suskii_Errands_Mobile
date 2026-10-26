import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_mobile/app/livekit_call_adapter.dart';

class _FakeRoom implements CallRoom {
  _FakeRoom({this.alreadyThere = 0, this.failConnect = false});

  int alreadyThere;
  final bool failConnect;
  String? url;
  String? token;
  bool? microphone;
  bool disconnectedCalled = false;
  final StreamController<bool> remoteController =
      StreamController<bool>.broadcast();
  final StreamController<void> disconnectedController =
      StreamController<void>.broadcast();

  @override
  Future<void> connect(String url, String token) async {
    if (failConnect) throw StateError('no network');
    this.url = url;
    this.token = token;
  }

  @override
  Future<void> setMicrophoneEnabled({required bool enabled}) async =>
      microphone = enabled;

  @override
  Future<void> disconnect() async => disconnectedCalled = true;

  @override
  int get remoteCount => alreadyThere;

  @override
  Stream<bool> get remote => remoteController.stream;

  @override
  Stream<void> get disconnected => disconnectedController.stream;
}

void main() {
  const job = '0f0f0f0f-0000-4000-8000-000000000001';
  late List<String> calls;
  late List<Map<String, Object?>> rpcArgs;
  late _FakeRoom room;

  LiveKitCallAdapter adapter({Duration ring = const Duration(seconds: 60)}) =>
      LiveKitCallAdapter(
        invoke: (name, body) async {
          calls.add(name);
          expect(body['request_id'], job);
          return <String, dynamic>{
            'url': 'wss://suskii.livekit.cloud',
            'token': 'tok',
            'expires_at': '2026-10-26T06:10:00Z',
            'call_id': 'call-1',
          };
        },
        rpc: (name, args) async {
          calls.add(name);
          rpcArgs.add(args);
          return 'ended';
        },
        room: () => room,
        ringTimeout: ring,
      );

  setUp(() {
    calls = <String>[];
    rpcArgs = <Map<String, Object?>>[];
    room = _FakeRoom();
  });

  test(
    'the caller joins the room the server chose, microphone on, ringing',
    () async {
      final a = adapter();
      final session = await a.startCall(
        job,
        idempotencyKey: 'key-call-0000001',
      );
      expect(session.sessionId, 'call-1');
      expect(room.url, 'wss://suskii.livekit.cloud');
      expect(room.token, 'tok');
      expect(room.microphone, isTrue);
      final states = <CallState>[];
      final sub = a
          .events(session.sessionId)
          .listen((e) => states.add(e.state));
      await pumpEventQueue();
      expect(states, <CallState>[CallState.ringing]);
      room.remoteController.add(true);
      await pumpEventQueue();
      expect(states.last, CallState.active);
      await sub.cancel();
    },
  );

  test(
    'the person being rung is active at once, the caller already there',
    () async {
      room = _FakeRoom(alreadyThere: 1);
      final a = adapter();
      final session = await a.startCall(
        job,
        idempotencyKey: 'key-call-0000002',
      );
      expect((await a.events(session.sessionId).first).state, CallState.active);
    },
  );

  test('ending hangs up on the server with a key of its own, once', () async {
    final a = adapter();
    final session = await a.startCall(job, idempotencyKey: 'key-call-0000003');
    await a.endCall(session.sessionId);
    await a.endCall(session.sessionId);
    expect(calls.where((c) => c == 'end_call').length, 1);
    expect(rpcArgs.single['p_idempotency_key'], 'key-call-0000003:end');
    expect(room.disconnectedCalled, isTrue);
  });

  test('the other person leaving ends the call here too', () async {
    final a = adapter();
    final session = await a.startCall(job, idempotencyKey: 'key-call-0000004');
    final states = <CallState>[];
    a.events(session.sessionId).listen((e) => states.add(e.state));
    room.remoteController.add(true);
    room.alreadyThere = 0;
    room.remoteController.add(false);
    await pumpEventQueue();
    expect(states.last, CallState.ended);
    expect(calls, contains('end_call'));
  });

  test('nobody answering stops the ringing when the server gives up', () async {
    final a = adapter(ring: const Duration(milliseconds: 10));
    final session = await a.startCall(job, idempotencyKey: 'key-call-0000005');
    final states = <CallState>[];
    a.events(session.sessionId).listen((e) => states.add(e.state));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(states.last, CallState.ended);
  });

  test('a failed connection is reported failed and cleaned up', () async {
    room = _FakeRoom(failConnect: true);
    final a = adapter();
    await expectLater(
      a.startCall(job, idempotencyKey: 'key-call-0000006'),
      throwsStateError,
    );
    expect(rpcArgs.single['p_failed'], isTrue);
  });

  test('mute turns the microphone off and back on', () async {
    final a = adapter();
    final session = await a.startCall(job, idempotencyKey: 'key-call-0000007');
    await a.setMuted(session.sessionId, muted: true);
    expect(room.microphone, isFalse);
    await a.setMuted(session.sessionId, muted: false);
    expect(room.microphone, isTrue);
  });
}
