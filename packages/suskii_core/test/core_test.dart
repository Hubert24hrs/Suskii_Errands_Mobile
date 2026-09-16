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
    });
  });
}
