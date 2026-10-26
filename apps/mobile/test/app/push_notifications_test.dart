import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_mobile/app/push_notifications.dart';
import 'package:suskii_mobile/app/router.dart';

class FakeMessaging implements PushMessaging {
  int permissionRequests = 0;
  int deletes = 0;
  String? currentToken = 'tok-1';
  Map<String, String>? launch;
  final refreshes = StreamController<String>.broadcast();
  final tapped = StreamController<Map<String, String>>.broadcast();

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<String?> token() async => currentToken;

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;

  @override
  Future<void> deleteToken() async {
    deletes++;
    currentToken = null;
  }

  @override
  Future<Map<String, String>?> launchTap() async => launch;

  @override
  Stream<Map<String, String>> get taps => tapped.stream;
}

const id = '6f1c2a9e-1b2c-4d3e-8f90-123456789abc';

void main() {
  group('routeForPushLink', () {
    test(
      'a job opens the request for a customer and the job for a provider',
      () {
        expect(
          routeForPushLink('/jobs/$id', UserMode.customer),
          '/customer/requests/$id',
        );
        expect(
          routeForPushLink('/jobs/$id', UserMode.provider),
          '/provider/jobs/$id',
        );
      },
    );

    test('offers on a request open the request', () {
      expect(
        routeForPushLink('/requests/$id/offers', UserMode.customer),
        '/customer/requests/$id',
      );
    });

    test('chat follows the mode', () {
      expect(
        routeForPushLink('/chat/$id', UserMode.customer),
        '/customer/requests/$id/chat',
      );
      expect(
        routeForPushLink('/chat/$id', UserMode.provider),
        '/provider/jobs/$id/chat',
      );
    });

    test('named screens map to their routes', () {
      expect(
        routeForPushLink('/earnings', UserMode.provider),
        AppRoutes.providerEarnings,
      );
      expect(
        routeForPushLink('/referrals', UserMode.customer),
        AppRoutes.customerReferrals,
      );
      expect(
        routeForPushLink('/support/$id', UserMode.customer),
        '/customer/support/$id',
      );
      expect(
        routeForPushLink('/provider/jobs/$id', UserMode.provider),
        '/provider/jobs/$id',
      );
      expect(
        routeForPushLink('/provider/documents', UserMode.provider),
        AppRoutes.providerKyc,
      );
      expect(routeForPushLink('/meet/$id', UserMode.customer), '/meet/$id');
    });

    test('anything unknown or malformed opens home, never a dead end', () {
      expect(routeForPushLink(null, UserMode.customer), AppRoutes.customerHome);
      expect(
        routeForPushLink('https://evil.example/x', UserMode.customer),
        AppRoutes.customerHome,
      );
      expect(
        routeForPushLink('/jobs/../../admin', UserMode.customer),
        AppRoutes.customerHome,
      );
      expect(
        routeForPushLink('/nope', UserMode.provider),
        AppRoutes.providerFeed,
      );
    });
  });

  group('PushRegistration', () {
    late FakeMessaging messaging;
    late SharedPreferences prefs;
    late List<(String, String)> registered;
    late List<Map<String, String>> navigated;

    PushRegistration make() => PushRegistration(
      messaging: messaging,
      prefs: prefs,
      register: (fingerprint, token) async =>
          registered.add((fingerprint, token)),
      navigate: navigated.add,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      prefs = await SharedPreferences.getInstance();
      messaging = FakeMessaging();
      registered = <(String, String)>[];
      navigated = <Map<String, String>>[];
    });

    test(
      'sign-in asks once and registers the token under one install id',
      () async {
        final r = make();
        await r.signedIn();
        await r.signedIn();
        expect(messaging.permissionRequests, 1);
        expect(registered.length, 2);
        expect(registered.first.$2, 'tok-1');
        expect(registered.first.$1, startsWith('install:'));
        expect(registered.first.$1, registered.last.$1);
        await r.dispose();
      },
    );

    test('a refreshed token is registered again', () async {
      final r = make();
      await r.signedIn();
      messaging.refreshes.add('tok-2');
      await Future<void>.delayed(Duration.zero);
      expect(registered.last.$2, 'tok-2');
      await r.dispose();
    });

    test('a push that launched the app is followed after sign-in', () async {
      messaging.launch = {'deep_link': '/jobs/$id'};
      final r = make();
      await r.signedIn();
      expect(navigated, [
        {'deep_link': '/jobs/$id'},
      ]);
      await r.dispose();
    });

    test('a tap while running is followed', () async {
      final r = make();
      await r.signedIn();
      messaging.tapped.add({'deep_link': '/earnings'});
      await Future<void>.delayed(Duration.zero);
      expect(navigated.single['deep_link'], '/earnings');
      await r.dispose();
    });

    test(
      'sign-out drops the token so the next person does not get these alerts',
      () async {
        final r = make();
        await r.signedIn();
        await r.signedOut();
        expect(messaging.deletes, 1);
        messaging.refreshes.add('tok-3');
        await Future<void>.delayed(Duration.zero);
        expect(registered.where((e) => e.$2 == 'tok-3'), isEmpty);
        await r.dispose();
      },
    );

    test('no token yet means nothing is registered', () async {
      messaging.currentToken = null;
      final r = make();
      await r.signedIn();
      expect(registered, isEmpty);
      await r.dispose();
    });
  });
}
