import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';
import 'package:suskii_mobile/app/device_location.dart';
import 'package:suskii_mobile/app/router.dart';

import '../support/harness.dart';

/// The end-to-end journeys the store build has to get right, driven through
/// the real screens on the mock backend: a person's taps and typing, not
/// repository calls. `flows_test.dart` runs them headless in CI and
/// `integration_test/app_flows_test.dart` runs the same bodies on a device.
///
/// Each flow starts from a fresh app and a fresh mock database, so they are
/// independent and can run in any order.
typedef Flow = Future<void> Function(WidgetTester tester);

final AppLocalizations l10n = lookupAppLocalizations(const Locale('en'));

/// Every flow, by name.
final Map<String, Flow> appFlows = <String, Flow>{
  'phone OTP sign-in lands on home': _signIn,
  'first run: welcome, onboarding, sign-in': _firstRun,
  'identity verification: consent, liveness, ID lookup': _verifyIdentity,
  'provider KYC: photograph a document and upload it': _providerKycUpload,
  'mode switch to provider and back': _modeSwitch,
  'create and publish a request': _createRequest,
  'offers arrive ranked and one is accepted': _acceptOffer,
  'pay into held funds': _payHeld,
  'track the provider on the way': _tracking,
  'chat and a masked call': _chatAndCall,
  'provider journey: start, manual arrival, pickup PIN': _providerArrival,
  'rate a finished job': _rating,
  'open a dispute': _dispute,
  'wallet withdrawal': _withdraw,
  'referral code is shown and copied': _referrals,
  'SOS from an active job': _sos,
  'account deletion, then keep the account': _accountDeletion,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<TestApp> _signedInApp(
  WidgetTester tester, {
  List<Override> overrides = const <Override>[],
}) async {
  final app = await TestApp.pump(
    tester,
    prefs: const <String, Object>{'welcome_seen': true},
    overrides: overrides,
  );
  await signInThroughUi(tester);
  expect(find.byKey(const ValueKey<String>('home.newRequest')), findsOneWidget);
  return app;
}

Future<void> _go(WidgetTester tester, TestApp app, String route) async {
  app.container.read(routerProvider).go(route);
  await settle(tester);
}

/// The topmost route's vertical list (a sheet's when one is open).
Finder get _mainList => find
    .byWidgetPredicate(
      (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .last;

/// Scrolls the page's main list until [finder] is built and on screen.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: _mainList);
  }
  await tester.ensureVisible(finder.first);
  await settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder.first);
  await settle(tester);
}

Future<void> _tapText(WidgetTester tester, String text) =>
    _tap(tester, find.text(text));

/// Types into the field labelled [label]. The design system's fields carry
/// their label as a Text above the input, so the input is found through it.
Future<void> _enter(WidgetTester tester, String label, String value) async {
  await _reveal(tester, find.text(label));
  final labelled = find.descendant(
    of: find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (Widget w) => w is STextField || w is SMoneyField,
      ),
    ),
    matching: find.byType(TextField),
  );
  final field = labelled.evaluate().isNotEmpty
      ? labelled
      : find.widgetWithText(TextField, label);
  await tester.enterText(field.first, value);
  await settle(tester);
}

/// A toast or snackbar with [text] is showing.
void _expectToast(String text) =>
    expect(find.text(text), findsWidgets, reason: 'toast "$text"');

Future<void> _switchToProvider(WidgetTester tester, TestApp app) async {
  await _go(tester, app, AppRoutes.customerProfile);
  await _tapText(tester, l10n.modeSwitchToProvider);
  await settle(tester, timeout: const Duration(seconds: 5));
}

// ---------------------------------------------------------------------------
// Flows
// ---------------------------------------------------------------------------

Future<void> _signIn(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await app.dispose(tester);
}

Future<void> _firstRun(WidgetTester tester) async {
  final app = await TestApp.pump(tester);
  await tester.tap(find.byKey(const ValueKey<String>('welcome.continue')));
  await settle(tester);
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.byKey(const ValueKey<String>('onboarding.next')));
    await settle(tester);
  }
  expect(find.byKey(const ValueKey<String>('auth.identity')), findsOneWidget);
  await signInThroughUi(tester);
  expect(find.byKey(const ValueKey<String>('home.newRequest')), findsOneWidget);
  await app.dispose(tester);
}

Future<void> _verifyIdentity(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.verifyCustomer);
  if (find.text(l10n.verifySuccessTitle).evaluate().isEmpty) {
    await _tapText(tester, l10n.verifyConsentCheckbox);
    await _tapText(tester, l10n.verifyConsentAction);
    await _tap(tester, find.widgetWithText(InkWell, l10n.verifyLivenessTitle));
    await settle(tester, timeout: const Duration(seconds: 5));
    await _enter(tester, l10n.verifyIdNumberLabel, '12345678901');
    await _tapText(tester, l10n.verifySubmit);
    await settle(tester, timeout: const Duration(seconds: 5));
  }
  expect(
    find.text(l10n.verifySuccessTitle).evaluate().isNotEmpty ||
        find.text(l10n.verifyInReviewTitle).evaluate().isNotEmpty,
    isTrue,
    reason: 'verification reaches review or success',
  );
  await app.dispose(tester);
}

/// Hands back a small JPEG instead of opening the camera or the library.
class _FakeImagePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile.fromData(
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0xFF, 0xD9]),
    name: 'document.jpg',
    mimeType: 'image/jpeg',
  );
}

Future<void> _providerKycUpload(WidgetTester tester) async {
  final previous = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = _FakeImagePicker();
  addTearDown(() => ImagePickerPlatform.instance = previous);

  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.providerKyc);
  await _tapText(tester, l10n.kycStepCredentials);
  await _tapText(tester, l10n.credentialsAddFile);
  // The platform asks camera or library first.
  await tester.tap(find.text(l10n.captureFromLibrary));
  await settle(tester);
  expect(find.text(l10n.kycCaptured), findsOneWidget);
  expect(app.database.uploadedObjects, hasLength(1));
  expect(app.database.uploadedObjects.keys.single, contains('.jpg'));
  await app.dispose(tester);
}

Future<void> _modeSwitch(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _switchToProvider(tester, app);
  expect(
    app.container.read(routerProvider).state.uri.path,
    startsWith('/provider'),
  );
  await _go(tester, app, AppRoutes.providerProfile);
  await _tapText(tester, l10n.modeSwitchToCustomer);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(
    app.container.read(routerProvider).state.uri.path,
    startsWith('/customer'),
  );
  await app.dispose(tester);
}

Future<void> _createRequest(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await tester.tap(find.byKey(const ValueKey<String>('home.newRequest')));
  await settle(tester);
  expect(find.text(l10n.createTitle), findsOneWidget);
  await tester.tap(find.byType(ChoiceChip).first);
  await settle(tester);
  await _enter(
    tester,
    l10n.createDescriptionLabel,
    'Collect a parcel from the front desk and bring it home.',
  );
  await _enter(tester, l10n.createPickupLabel, 'Lekki Phase 1 gate');
  final before = app.database.requests.length;
  await _tapText(tester, l10n.createPublish);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(app.database.requests.length, before + 1);
  final created = app.database.requests.values.last;
  expect(created.status, JobStatus.published);
  expect(
    app.container.read(routerProvider).state.uri.path,
    AppRoutes.customerRequestDetailPath(created.id),
  );
  await app.dispose(tester);
}

Future<void> _acceptOffer(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestDetailPath('req-1'));
  await _reveal(tester, find.text(l10n.offersRankedHint));
  final accept = find.widgetWithText(InkWell, l10n.offersAccept);
  expect(accept, findsWidgets);
  await _tap(tester, accept);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(
    app.database.requests['req-1']!.status,
    isIn(<JobStatus>[JobStatus.agreed, JobStatus.paymentPending]),
  );
  await app.dispose(tester);
}

Future<void> _payHeld(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestPayPath('req-6'));
  expect(find.text(l10n.payTitle), findsOneWidget);
  await _tap(tester, find.byType(RadioListTile<PaymentMethod>));
  final pay = find.byWidgetPredicate(
    (Widget w) => w is SButton && w.label.startsWith(l10n.payNow('')),
  );
  await _reveal(tester, pay);
  await tester.tap(pay.first);
  // Past the mock's confirmation delay, short of the two-second exit.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.text(l10n.paySuccess), findsOneWidget);
  expect(app.database.requests['req-6']!.status, JobStatus.paidHeld);
  // The success state shows for a moment, then the screen returns to the
  // request — once, even though the payment stream keeps emitting HELD.
  await tester.pump(const Duration(seconds: 3));
  await settle(tester);
  expect(
    app.container.read(routerProvider).state.uri.path,
    AppRoutes.customerRequestDetailPath('req-6'),
  );
  await app.dispose(tester);
}

Future<void> _tracking(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestTrackPath('req-2'));
  expect(find.text(l10n.trackingTitle), findsOneWidget);
  expect(find.text(l10n.trackingEnRoute), findsWidgets);
  await app.dispose(tester);
}

Future<void> _chatAndCall(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestChatPath('req-2'));
  const message = 'I am at the blue gate.';
  await tester.enterText(find.byType(TextField).last, message);
  await settle(tester);
  await tester.tap(find.byTooltip(l10n.chatSend));
  await settle(tester);
  expect(find.text(message), findsOneWidget);

  await _go(tester, app, AppRoutes.customerRequestCallPath('req-2'));
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(find.text(l10n.callMaskedNote), findsOneWidget);
  await _tap(tester, find.byTooltip(l10n.callEnd));
  await settle(tester, timeout: const Duration(seconds: 5));
  // Opened directly (as a notification would), the call has nothing to pop
  // back to and returns to the request instead.
  expect(
    app.container.read(routerProvider).state.uri.path,
    AppRoutes.customerRequestDetailPath('req-2'),
  );
  await app.dispose(tester);
}

class _NoFix implements DeviceLocation {
  const _NoFix();

  @override
  Future<LocationReading> current() async =>
      const LocationReading.missing('location_denied');
}

Future<void> _providerArrival(WidgetTester tester) async {
  final app = await _signedInApp(
    tester,
    overrides: <Override>[
      deviceLocationProvider.overrideWithValue(const _NoFix()),
    ],
  );
  // Payment assigns a solo provider on the server (transition 11), so the
  // journey starts from ASSIGNED; the fixture waits in PAID_HELD.
  app.database.requests['req-p1'] = app.database.requests['req-p1']!.copyWith(
    status: JobStatus.assigned,
  );
  await _switchToProvider(tester, app);
  await _go(tester, app, AppRoutes.providerJobExecutionPath('req-p1'));
  await _tapText(tester, l10n.jobActionStartJourney);
  expect(app.database.requests['req-p1']!.status, JobStatus.enRoute);

  await _tapText(tester, l10n.jobActionArrived);
  // No position: the provider is asked before a manual arrival is recorded.
  expect(find.text(l10n.jobArrivalManualTitle), findsOneWidget);
  await tester.tap(find.text(l10n.jobArrivalManualConfirm));
  await settle(tester);
  expect(app.database.requests['req-p1']!.status, JobStatus.arrived);
  await _reveal(tester, find.text(l10n.jobActionVerifyPickupPin));
  await app.dispose(tester);
}

Future<void> _rating(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _switchToProvider(tester, app);
  await _go(tester, app, AppRoutes.providerJobExecutionPath('req-p4'));
  await _tapText(tester, l10n.ratingTitle);
  await tester.tap(find.byIcon(Icons.star_outline_rounded).last);
  await settle(tester);
  await _tapText(tester, l10n.ratingSubmit);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(find.text(l10n.ratingDoneLabel(5)), findsOneWidget);
  await app.dispose(tester);
}

Future<void> _dispute(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestDetailPath('req-2'));
  await _tapText(tester, l10n.disputeOpenCta);
  await tester.tap(find.byType(RadioListTile<String>).first);
  await settle(tester);
  await _enter(
    tester,
    l10n.disputeDetailsHint,
    'The rider took the order to the wrong gate and left.',
  );
  await _tapText(tester, l10n.disputeSubmitCta);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(
    app.database.disputes.values.where((Dispute d) => d.jobId == 'req-2'),
    hasLength(1),
  );
  expect(find.text(l10n.disputeOpenCta), findsNothing);
  await app.dispose(tester);
}

Future<void> _withdraw(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerWallet);
  await _tapText(tester, l10n.walletWithdraw);
  await _enter(tester, '${l10n.walletWithdrawAmount} (NGN)', '1000');
  await _tapText(tester, l10n.walletWithdrawCta);
  await settle(tester, timeout: const Duration(seconds: 5));
  _expectToast(l10n.walletWithdrawDone);
  await app.dispose(tester);
}

Future<void> _referrals(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerReferrals);
  expect(find.text(l10n.referralYourCode), findsOneWidget);
  await _tap(tester, find.byTooltip(l10n.referralCopy));
  _expectToast(l10n.referralCopied);
  await app.dispose(tester);
}

Future<void> _sos(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerRequestDetailPath('req-2'));
  await tester.tap(find.byTooltip(l10n.sosButton));
  await settle(tester);
  expect(find.text(l10n.sosTitle), findsOneWidget);
  await _tapText(tester, l10n.sosSend);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(find.text(l10n.sosActiveTitle), findsOneWidget);
  await app.dispose(tester);
}

Future<void> _accountDeletion(WidgetTester tester) async {
  final app = await _signedInApp(tester);
  await _go(tester, app, AppRoutes.customerSettings);
  await _tapText(tester, l10n.settingsDeleteAccount);
  expect(find.text(l10n.settingsDeleteConfirmTitle), findsOneWidget);
  // The dialog's confirm button carries the same label as the tile.
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(l10n.settingsDeleteAccount),
    ),
  );
  await settle(tester, timeout: const Duration(seconds: 5));
  // The server revokes every session with the request, so the app signs
  // out; signing back in before the date offers to keep the account.
  expect(app.container.read(routerProvider).state.uri.path, AppRoutes.auth);
  await signInThroughUi(tester);
  expect(
    app.container.read(routerProvider).state.uri.path,
    AppRoutes.deletionPending,
  );
  await _tapText(tester, l10n.deletionPendingKeep);
  await settle(tester, timeout: const Duration(seconds: 5));
  expect(
    app.container.read(routerProvider).state.uri.path,
    startsWith('/customer'),
  );
  await app.dispose(tester);
}
