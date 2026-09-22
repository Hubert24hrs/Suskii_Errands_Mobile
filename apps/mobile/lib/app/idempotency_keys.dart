import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';

/// Idempotency keys held per intent for the whole app (audit finding M3.14).
///
/// In its own file rather than in `providers.dart` so that signing out can
/// reach it: keys belong to a session, and a second person on the same handset
/// must not inherit a key that would replay the first person's action.
///
/// Use it where a screen cannot hold the key itself — a `ConsumerWidget`, or an
/// action fired from a dialog. A screen with State should keep a `String?`
/// field instead, which is what `WithdrawSheet` does.
///
/// ```dart
/// final keys = ref.read(idempotencyKeysProvider);
/// await repo.submitForReview(idempotencyKey: keys.forIntent('kyc.submit'));
/// keys.done('kyc.submit'); // only on success
/// ```
final Provider<IdempotencyKeys> idempotencyKeysProvider =
    Provider<IdempotencyKeys>((Ref ref) => IdempotencyKeys());
