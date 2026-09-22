import 'package:suskii_core/suskii_core.dart';
import 'package:test/test.dart';

void main() {
  group('Result', () {
    test('Ok carries value', () {
      const r = Ok<int>(42);
      expect(r.when(ok: (v) => v, err: (_) => -1), 42);
    });

    test('Err carries error view', () {
      const r = Err<int>(AppErrorView(ErrorCodes.network));
      expect(r.when(ok: (v) => v, err: (e) => e.code), ErrorCodes.network);
    });
  });

  group('AppConfig.fromEnvironment', () {
    test('defaults to dev flavor with empty placeholders', () {
      final config = AppConfig.fromEnvironment();
      expect(config.flavor, AppFlavor.dev);
      expect(config.isProd, isFalse);
      expect(config.supabaseUrl, isEmpty);
    });
  });

  group('ErrorCodes', () {
    test('codes are stable strings', () {
      expect(ErrorCodes.offerExpired, 'ERR_OFFER_EXPIRED');
      expect(ErrorCodes.providerNotVerified, 'ERR_PROVIDER_NOT_VERIFIED');
      expect(ErrorCodes.verificationRequired, 'ERR_VERIFICATION_REQUIRED');
      expect(ErrorCodes.unsupportedLanguage, 'ERR_UNSUPPORTED_LANGUAGE');
    });
  });

  group('ServerClock', () {
    test('falls back to device clock before sync', () {
      final clock = ServerClock();
      expect(clock.isSynced, isFalse);
      expect(
        clock.now().difference(DateTime.now()).inSeconds.abs(),
        lessThan(2),
      );
    });

    test('applies the measured offset after sync', () {
      final clock = ServerClock();
      clock.sync(DateTime.now().add(const Duration(seconds: 90)));
      expect(clock.isSynced, isTrue);
      expect(clock.offset!.inSeconds, closeTo(90, 2));
      expect(clock.now().difference(DateTime.now()).inSeconds, closeTo(90, 2));
    });

    test('remaining() counts down against server time', () {
      final clock = ServerClock();
      clock.sync(DateTime.now().add(const Duration(seconds: 60)));
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      expect(clock.remaining(deadline).inSeconds, closeTo(60, 2));
    });

    test('extrapolation is monotonic (Stopwatch, not device clock)', () async {
      final clock = ServerClock();
      clock.sync(DateTime.now().toUtc().add(const Duration(seconds: 90)));
      final first = clock.now();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = clock.now();
      // now() never moves backwards, even if the device clock jumps.
      expect(second.isBefore(first), isFalse);
      expect(second.difference(first).inMilliseconds, greaterThanOrEqualTo(10));
      // And it still tracks the synced server time, not raw device time.
      expect(second.difference(DateTime.now()).inSeconds, closeTo(90, 2));
    });
  });

  group('newIdempotencyKey', () {
    test('is a well-formed UUIDv7 and unique per call', () {
      final key = newIdempotencyKey();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}'
          r'-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(key),
        isTrue,
      );
      final keys = <String>{for (var i = 0; i < 500; i++) newIdempotencyKey()};
      expect(keys.length, 500);
    });
  });

  group('IdempotencyKeys', () {
    test('the same intent keeps its key until it is done', () {
      final keys = IdempotencyKeys();
      final first = keys.forIntent('kyc.submit');
      expect(
        keys.forIntent('kyc.submit'),
        first,
        reason: 'a retry of the same intent must replay, not act again',
      );
      keys.done('kyc.submit');
      expect(
        keys.forIntent('kyc.submit'),
        isNot(first),
        reason: 'a new intent after success is a new operation',
      );
    });

    test('different intents never share a key', () {
      final keys = IdempotencyKeys();
      expect(
        keys.forIntent('org.invite:+2348000000001'),
        isNot(keys.forIntent('org.invite:+2348000000002')),
      );
    });

    test('done on an intent that was never started is harmless', () {
      final keys = IdempotencyKeys();
      expect(() => keys.done('never.started'), returnsNormally);
    });

    test('clear forgets everything, because keys belong to a session', () {
      final keys = IdempotencyKeys();
      final first = keys.forIntent('settings.exportData');
      expect(keys.pending, contains('settings.exportData'));
      keys.clear();
      expect(keys.pending, isEmpty);
      expect(
        keys.forIntent('settings.exportData'),
        isNot(first),
        reason: 'a second person on the same handset must not inherit a key',
      );
    });
  });
}
