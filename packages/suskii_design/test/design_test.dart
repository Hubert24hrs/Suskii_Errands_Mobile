import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_design/suskii_design.dart';

Widget _wrap(Widget child, {bool dark = false}) => MaterialApp(
  theme: SAppTheme.light(),
  darkTheme: SAppTheme.dark(),
  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('SButton renders label and respects loading', (tester) async {
    await tester.pumpWidget(_wrap(const SButton(label: 'Continue')));
    expect(find.text('Continue'), findsOneWidget);

    await tester.pumpWidget(_wrap(const SButton(label: 'Pay', loading: true)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Pay'), findsNothing);
  });

  testWidgets('SButton enforces 48dp touch target', (tester) async {
    await tester.pumpWidget(_wrap(const SButton(label: 'Go')));
    final size = tester.getSize(find.byType(SButton));
    expect(size.height, SSpacing.minTouchTarget);
  });

  testWidgets('empty/error/offline states render', (tester) async {
    await tester.pumpWidget(
      _wrap(const SEmptyState(icon: Icons.inbox, title: 'Nothing here')),
    );
    expect(find.text('Nothing here'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const SErrorState(title: 'Failed', retryLabel: 'Retry')),
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(_wrap(const SOfflineBanner(label: 'Offline')));
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('themes build in light and dark', (tester) async {
    await tester.pumpWidget(_wrap(const SButton(label: 'Light')));
    await tester.pumpWidget(_wrap(const SButton(label: 'Dark'), dark: true));
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('SRatingInput reports selection', (tester) async {
    var picked = 0;
    await tester.pumpWidget(
      _wrap(SRatingInput(value: 0, onChanged: (int v) => picked = v)),
    );
    await tester.tap(find.byType(IconButton).at(3));
    expect(picked, 4);
  });
}
