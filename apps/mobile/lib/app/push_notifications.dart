import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'providers.dart';
import 'router.dart';

/// Push notifications (Android, FCM). The server decides who is told what
/// (`private.notify`) and sends a push that names nothing: the brand, a
/// generic line, and an id the app uses to open the right screen. This file
/// gets the device a token, tells the server, and routes a tap.

/// The slice of Firebase Messaging the app uses, so tests can stand in for it.
abstract interface class PushMessaging {
  Future<bool> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefreshes;
  Future<void> deleteToken();

  /// The push that launched the app from a cold start, if any.
  Future<Map<String, String>?> launchTap();

  /// Pushes tapped while the app was in memory.
  Stream<Map<String, String>> get taps;
}

// firebase_messaging 16, not 17: 17 brings Firebase's iOS SDK 13, which needs
// gtm-session-fetcher 4 while google_sign_in_ios still needs 3, so the iOS
// build cannot resolve. 17 also moves from registration tokens to Firebase
// Installation IDs; when google_sign_in moves, upgrade and switch the server
// (supabase/functions/_shared/notifications/fcm.ts) in the same change.
class FirebasePushMessaging implements PushMessaging {
  FirebaseMessaging get _m => FirebaseMessaging.instance;

  @override
  Future<bool> requestPermission() async {
    final settings = await _m.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> token() => _m.getToken();

  @override
  Stream<String> get tokenRefreshes => _m.onTokenRefresh;

  @override
  Future<void> deleteToken() => _m.deleteToken();

  @override
  Future<Map<String, String>?> launchTap() async {
    final message = await _m.getInitialMessage();
    return message == null ? null : _strings(message.data);
  }

  @override
  Stream<Map<String, String>> get taps =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => _strings(m.data));

  static Map<String, String> _strings(Map<String, dynamic> data) =>
      data.map((k, v) => MapEntry(k, '$v'));
}

/// Starts Firebase when this build carries its four public identifiers.
/// Returns the messaging handle, or null when push is not configured or
/// Firebase would not start (the app works without it).
Future<PushMessaging?> initializePush(AppConfig config) async {
  if (!config.hasPush) return null;
  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: config.firebaseApiKey,
        appId: config.firebaseAppId,
        messagingSenderId: config.firebaseMessagingSenderId,
        projectId: config.firebaseProjectId,
      ),
    );
    return FirebasePushMessaging();
  } on Object {
    return null;
  }
}

/// Null in tests, mock builds and builds without Firebase.
final pushMessagingProvider = Provider<PushMessaging?>((ref) => null);

/// The app route for a server deep link (`private.notify`'s `p_deep_link`).
/// Server links name the thing (`/jobs/<request id>`), not a screen, so the
/// same push opens the customer or the provider view by the current mode.
/// Anything unrecognised opens the home screen rather than a dead end.
String routeForPushLink(String? link, UserMode mode) {
  final provider = mode == UserMode.provider;
  final home = provider ? AppRoutes.providerFeed : AppRoutes.customerHome;
  if (link == null || !link.startsWith('/')) return home;
  final parts = Uri.parse(link).pathSegments;
  if (parts.isEmpty) return home;
  final id = parts.length > 1 ? parts[1] : null;
  final validId = id != null && RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(id);
  switch (parts.first) {
    case 'jobs':
      if (!validId) return home;
      return provider ? '/provider/jobs/$id' : '/customer/requests/$id';
    case 'requests':
      return validId && !provider ? '/customer/requests/$id' : home;
    case 'chat':
      if (!validId) return home;
      return provider
          ? '/provider/jobs/$id/chat'
          : '/customer/requests/$id/chat';
    case 'provider':
      if (parts.length > 2 && parts[1] == 'jobs') {
        final jobId = parts[2];
        return RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(jobId)
            ? '/provider/jobs/$jobId'
            : AppRoutes.providerJobs;
      }
      if (parts.length > 1 && parts[1] == 'documents') {
        return AppRoutes.providerKyc;
      }
      return AppRoutes.providerFeed;
    case 'meet':
      return validId ? '/meet/$id' : AppRoutes.meet;
    case 'support':
      return validId ? '/customer/support/$id' : AppRoutes.customerSupport;
    case 'disputes':
      return AppRoutes.customerDisputes;
    case 'earnings':
      return AppRoutes.providerEarnings;
    case 'offers':
      return AppRoutes.providerOffers;
    case 'referrals':
      return AppRoutes.customerReferrals;
    case 'business':
      return AppRoutes.providerOrg;
    case 'verify':
      return AppRoutes.verifyCustomer;
    case 'account':
      return AppRoutes.customerProfile;
    case 'settings':
      return AppRoutes.customerSettings;
  }
  return home;
}

/// Registers this install's token for the signed-in person, keeps it fresh,
/// and drops it on sign-out so the next person on the handset never gets the
/// last one's alerts.
class PushRegistration {
  PushRegistration({
    required this.messaging,
    required this.prefs,
    required this.register,
    required this.navigate,
  });

  final PushMessaging messaging;
  final SharedPreferences prefs;

  /// Calls `register_device` with this install's fingerprint and the token.
  final Future<void> Function(String fingerprint, String token) register;
  final void Function(Map<String, String> data) navigate;

  static const _installIdKey = 'push.install_id';
  static const _askedKey = 'push.permission_asked';

  StreamSubscription<String>? _refreshes;
  StreamSubscription<Map<String, String>>? _taps;

  /// Not a hardware identifier: a random id minted once per install, so the
  /// server can keep one row per handset without the app reading anything
  /// that identifies the phone.
  String get fingerprint {
    final existing = prefs.getString(_installIdKey);
    if (existing != null) return 'install:$existing';
    final id = newIdempotencyKey();
    unawaited(prefs.setString(_installIdKey, id));
    return 'install:$id';
  }

  Future<void> signedIn() async {
    _taps ??= messaging.taps.listen(navigate);
    // Asked once, just after the first sign-in, rather than on first launch
    // before the person knows what the app will tell them about.
    if (prefs.getBool(_askedKey) != true) {
      await prefs.setBool(_askedKey, true);
      await messaging.requestPermission();
    }
    final token = await messaging.token();
    if (token != null && token.isNotEmpty) await register(fingerprint, token);
    _refreshes ??= messaging.tokenRefreshes.listen((t) {
      if (t.isNotEmpty) unawaited(register(fingerprint, t));
    });
    final launch = await messaging.launchTap();
    if (launch != null) navigate(launch);
  }

  Future<void> signedOut() async {
    await _refreshes?.cancel();
    _refreshes = null;
    await messaging.deleteToken();
  }

  Future<void> dispose() async {
    await _refreshes?.cancel();
    await _taps?.cancel();
  }
}

final pushRegistrationProvider = Provider<PushRegistration?>((ref) {
  final messaging = ref.watch(pushMessagingProvider);
  final gateway = ref.watch(supabaseGatewayProvider);
  if (messaging == null || gateway == null) return null;
  final version = RegExp(r'^\d+\.\d+\.\d+')
      .stringMatch(ref.watch(appVersionProvider));
  final registration = PushRegistration(
    messaging: messaging,
    prefs: ref.watch(sharedPreferencesProvider),
    register: (fingerprint, token) =>
        gateway.rpc('register_device', <String, Object?>{
          'p_platform': 'android',
          'p_fingerprint': fingerprint,
          'p_app_version': version,
          'p_push_token': token,
        }),
    navigate: (data) => ref
        .read(routerProvider)
        .go(
          routeForPushLink(data['deep_link'], ref.read(modeControllerProvider)),
        ),
  );
  ref.onDispose(registration.dispose);
  return registration;
});

/// Follows the session: registers on sign-in, unregisters on sign-out.
class PushNotificationsScope extends ConsumerStatefulWidget {
  const PushNotificationsScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PushNotificationsScope> createState() =>
      _PushNotificationsScopeState();
}

class _PushNotificationsScopeState
    extends ConsumerState<PushNotificationsScope> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(sessionUserIdProvider, (previous, next) {
      final registration = ref.read(pushRegistrationProvider);
      if (registration == null) return;
      if (next != null && next.isNotEmpty && next != previous) {
        unawaited(registration.signedIn().catchError((Object _) {}));
      } else if (next == null && previous != null) {
        unawaited(registration.signedOut().catchError((Object _) {}));
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
