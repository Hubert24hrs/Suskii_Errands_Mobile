import 'dart:math';

final Random _secureRandom = Random.secure();

String _hex(int value, int digits) =>
    value.toRadixString(16).padLeft(digits, '0');

/// [byteCount] random bytes as lowercase hex.
///
/// Drawn one byte at a time on purpose. `Random.secure().nextInt` is capped at
/// 2^32, and on the web an int is a JavaScript double whose bitwise operators
/// are 32-bit: `1 << 32` is `0` there (so `nextInt(1 << 32)` throws), and a
/// 62-bit intermediate would lose precision. Bytes avoid both.
String _randomHex(int byteCount) {
  final buffer = StringBuffer();
  for (var i = 0; i < byteCount; i++) {
    buffer.write(_hex(_secureRandom.nextInt(256), 2));
  }
  return buffer.toString();
}

/// A fresh idempotency key (UUIDv7) for one user intent.
///
/// Generate one key per intent (a tap, a send, a submit) and pass it to every
/// mutating repository call for that intent; reuse the SAME key only when
/// retrying that same intent (e.g. after a network failure), never for a new
/// one. The mock layer mirrors the backend's idempotency behavior (spike
/// S-10): a repeated key replays the first result without re-executing the
/// side effect.
String newIdempotencyKey() {
  // UUIDv7: 48-bit Unix epoch milliseconds, version 7, then 74 random bits.
  // Split with ~/ and % rather than shifts and masks: both are exact for values
  // below 2^53 on every platform, while bitwise operators are 32-bit on the web.
  final millis = DateTime.now().millisecondsSinceEpoch % 0x1000000000000;
  final timeHigh = millis ~/ 0x10000;
  final timeLow = millis % 0x10000;
  // Variant bits: the first hex digit of the fourth group is 8, 9, a or b.
  final variant = (8 + _secureRandom.nextInt(4)).toRadixString(16);
  return '${_hex(timeHigh, 8)}-${_hex(timeLow, 4)}'
      '-7${_randomHex(2).substring(1)}'
      '-$variant${_randomHex(2).substring(1)}'
      '-${_randomHex(6)}';
}

/// Keys held per intent, so a retry replays instead of acting twice.
///
/// [newIdempotencyKey] says to reuse the same key when retrying the same
/// intent, and that is the part screens get wrong: calling it inline at the
/// call site mints a *fresh* key on every attempt, so a retry after a failure
/// looks to the server like a new operation. Where there is no natural
/// uniqueness behind it — `start_verification_session` is the example — that
/// creates a second row rather than replaying the first (audit finding M3.14).
///
/// A screen that already has State can hold a `String?` field and do this
/// itself; `WithdrawSheet` does. This exists for the ones that cannot, because
/// the action lives on a `ConsumerWidget` or is fired from a dialog.
///
/// Intents are named by the caller and must be specific enough to be one
/// intent: `'org.invite'` is wrong if two invitations can be in flight, while
/// `'org.invite:$email'` is right.
class IdempotencyKeys {
  final Map<String, String> _keys = <String, String>{};

  /// The key for [intent], minting one the first time and returning the same
  /// one on every retry until [done] is called.
  String forIntent(String intent) =>
      _keys.putIfAbsent(intent, newIdempotencyKey);

  /// Call after the intent succeeds, so the next one starts a new key.
  ///
  /// Deliberately NOT called on failure: retaining the key is what makes the
  /// retry a replay.
  void done(String intent) => _keys.remove(intent);

  /// Forget everything. For sign-out: keys belong to a session, and a second
  /// person on the same handset must not inherit them.
  void clear() => _keys.clear();

  /// Intents with a key outstanding. For tests and diagnostics.
  Iterable<String> get pending => _keys.keys;
}
