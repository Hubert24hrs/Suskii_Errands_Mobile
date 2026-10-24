import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// The ID token a provider's native SDK issued, ready for
/// [AuthRepository.signInWithIdToken].
typedef SocialCredential = ({
  SocialProvider provider,
  String idToken,
  String? rawNonce,
});

/// Thrown when the person closes the provider's sheet: not an error to show.
class SocialSignInCancelled implements Exception {
  const SocialSignInCancelled();
}

/// Obtains an ID token from Google or Apple on the device. Nothing here talks
/// to Supabase: the token goes to [AuthRepository.signInWithIdToken], which
/// is where the session is made and the country applied.
abstract interface class SocialSignIn {
  /// Apple is offered on iOS and macOS only; Google everywhere.
  bool get appleAvailable;
  Future<SocialCredential> obtain(SocialProvider provider);
}

/// The mock backend accepts any token, so the demo signs in without a
/// provider account and the flow can be driven in tests.
class MockSocialSignIn implements SocialSignIn {
  const MockSocialSignIn();

  @override
  bool get appleAvailable =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<SocialCredential> obtain(SocialProvider provider) async =>
      (provider: provider, idToken: 'mock-id-token', rawNonce: null);
}

class NativeSocialSignIn implements SocialSignIn {
  NativeSocialSignIn(this._config);

  final AppConfig _config;
  bool _googleReady = false;

  @override
  bool get appleAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<SocialCredential> obtain(SocialProvider provider) =>
      switch (provider) {
        SocialProvider.google => _google(),
        SocialProvider.apple => _apple(),
      };

  Future<SocialCredential> _google() async {
    if (_config.googleWebClientId.isEmpty) {
      throw const AppError(ErrorCodes.featureUnavailable);
    }
    final google = GoogleSignIn.instance;
    if (!_googleReady) {
      await google.initialize(
        clientId: _config.googleIosClientId.isEmpty
            ? null
            : _config.googleIosClientId,
        serverClientId: _config.googleWebClientId,
      );
      _googleReady = true;
    }
    try {
      final account = await google.authenticate(
        scopeHint: const <String>['email', 'profile'],
      );
      final idToken = account.authentication.idToken;
      if (idToken == null) throw const AppError(ErrorCodes.unauthenticated);
      return (
        provider: SocialProvider.google,
        idToken: idToken,
        rawNonce: null,
      );
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const SocialSignInCancelled();
      }
      throw const AppError(ErrorCodes.unauthenticated);
    }
  }

  /// Apple embeds the SHA-256 of the nonce in the token; Supabase is given
  /// the raw value and checks the hash, so a captured token cannot be
  /// replayed with another nonce.
  Future<SocialCredential> _apple() async {
    if (!appleAvailable) throw const AppError(ErrorCodes.featureUnavailable);
    final rawNonce = _nonce();
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const <AppleIDAuthorizationScopes>[
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
      final idToken = credential.identityToken;
      if (idToken == null) throw const AppError(ErrorCodes.unauthenticated);
      return (
        provider: SocialProvider.apple,
        idToken: idToken,
        rawNonce: rawNonce,
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const SocialSignInCancelled();
      }
      throw const AppError(ErrorCodes.unauthenticated);
    }
  }

  static String _nonce() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}
