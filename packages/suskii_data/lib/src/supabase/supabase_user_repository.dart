import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_auth_repository.dart' show profileRowColumns;
import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// UserRepository over Supabase: the caller's own `profiles` row (RLS-scoped)
/// merged with the GoTrue identity for phone/email, and `set_active_mode`
/// for the customer/provider switch — the server enforces provider KYC
/// (`ERR_PROVIDER_NOT_VERIFIED`). The RPC takes no idempotency key (the mode
/// switch is naturally idempotent — same input, same state).
class SupabaseUserRepository implements UserRepository {
  SupabaseUserRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Future<AppUser> getProfile() async {
    final authUser = _gateway.auth.currentUser;
    if (authUser == null) throw const AppError(ErrorCodes.unauthenticated);
    final row = await _gateway.selectSingle(
      'profiles',
      profileRowColumns,
      column: 'user_id',
      value: authUser.id,
    );
    if (row == null) throw const AppError(ErrorCodes.unauthenticated);
    return appUserFromProfileRow(
      row,
      phoneE164: authUser.phone,
      email: authUser.email,
    );
  }

  @override
  Stream<AppUser> watchProfile() async* {
    final authUser = _gateway.auth.currentUser;
    if (authUser == null) throw const AppError(ErrorCodes.unauthenticated);
    await for (final rows in _gateway.streamRows(
      'profiles',
      primaryKey: <String>['user_id'],
      filterColumn: 'user_id',
      filterValue: authUser.id,
    )) {
      if (rows.isEmpty) continue;
      yield appUserFromProfileRow(
        rows.first,
        phoneE164: authUser.phone,
        email: authUser.email,
      );
    }
  }

  @override
  Future<UserMode> setActiveMode(
    UserMode mode, {
    required String idempotencyKey,
  }) async {
    final result = await _gateway.rpc('set_active_mode', <String, Object?>{
      'p_mode': mode == UserMode.provider ? 'provider' : 'customer',
    });
    return userModeFromWire(result);
  }
}
