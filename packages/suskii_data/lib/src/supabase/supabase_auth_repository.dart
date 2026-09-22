import 'package:supabase/supabase.dart' hide AuthState;
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_error_mapping.dart';
import 'supabase_gateway.dart';

/// AuthRepository over Supabase Auth (GoTrue) + the `profiles` row (own row
/// only — RLS). Phone/email OTP are GoTrue's; social providers stay
/// unavailable until vendor accounts exist (see the interface contract).
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._gateway);

  final SupabaseGateway _gateway;

  @override
  Stream<AuthState> authStateChanges() =>
      _gateway.auth.onAuthStateChange.asyncMap((authEvent) async {
        final session = authEvent.session;
        if (session == null || authEvent.event == AuthChangeEvent.signedOut) {
          return const AuthState(status: AuthStatus.signedOut);
        }
        try {
          return AuthState(
            status: AuthStatus.signedIn,
            user: await _fetchProfile(),
          );
        } on Object {
          // Profile unreadable (e.g. mid-signup before the row exists): the
          // session is real, the profile is not yet.
          return const AuthState(status: AuthStatus.signedIn);
        }
      });

  @override
  Future<void> requestPhoneOtp(String phoneE164) async {
    try {
      await _gateway.auth.signInWithOtp(phone: phoneE164);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<AppUser> verifyPhoneOtp(String phoneE164, String code) async {
    try {
      await _gateway.auth.verifyOTP(
        type: OtpType.sms,
        phone: phoneE164,
        token: code,
      );
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
    return _fetchProfile();
  }

  @override
  Future<void> requestEmailOtp(String email) async {
    try {
      await _gateway.auth.signInWithOtp(email: email);
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<AppUser> verifyEmailOtp(String email, String code) async {
    try {
      await _gateway.auth.verifyOTP(
        type: OtpType.email,
        email: email,
        token: code,
      );
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
    return _fetchProfile();
  }

  @override
  Future<AppUser> signInWithGoogle() =>
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<AppUser> signInWithApple() =>
      throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Future<void> signOut() async {
    try {
      await _gateway.auth.signOut();
    } on Object catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// The caller's own `profiles` row (RLS-scoped) merged with the GoTrue
  /// identity for phone/email, which `profiles` deliberately does not carry.
  Future<AppUser> _fetchProfile() async {
    final authUser = _gateway.auth.currentUser;
    if (authUser == null) throw const AppError(ErrorCodes.unauthenticated);
    final row = await _gateway.selectSingle(
      'profiles',
      'user_id, display_name, country_code, language, avatar_path, '
          'active_mode, customer_verification, provider_verification, '
          'trust_level, created_at',
      column: 'user_id',
      value: authUser.id,
    );
    if (row == null) throw const AppError(ErrorCodes.unauthenticated);
    return AppUser(
      id: SupabaseGateway.asId(row['user_id']),
      displayName: row['display_name'] as String? ?? '',
      // Nullable on a fresh signup before onboarding completes.
      countryCode: row['country_code'] as String? ?? '',
      preferredLanguage: row['language'] as String? ?? 'en',
      activeMode: _userMode(row['active_mode']),
      customerVerification: _verification(row['customer_verification']),
      providerVerification: _verification(row['provider_verification']),
      trustLevel: _trustLevel(row['trust_level']),
      createdAt: SupabaseGateway.asTimestamp(row['created_at']),
      phoneE164: authUser.phone,
      email: authUser.email,
      // avatar_path is a storage path, not a URL — signed URLs are a
      // later M9 slice (storage gateway), so photoUrl stays null for now.
    );
  }

  static UserMode _userMode(Object? value) => switch (value) {
    'provider' => UserMode.provider,
    _ => UserMode.customer,
  };

  static VerificationStatus _verification(Object? value) => switch (value) {
    'pending' => VerificationStatus.pending,
    'in_review' => VerificationStatus.inReview,
    'verified' => VerificationStatus.verified,
    'rejected' => VerificationStatus.rejected,
    _ => VerificationStatus.unverified,
  };

  static TrustLevel _trustLevel(Object? value) => switch (value) {
    'verified' => TrustLevel.verified,
    'trusted' => TrustLevel.trusted,
    'elite' => TrustLevel.elite,
    _ => TrustLevel.new_,
  };
}
