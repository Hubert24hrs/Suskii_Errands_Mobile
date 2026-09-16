import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import 'providers.dart';
import 'router.dart';

class SuskiiApp extends ConsumerWidget {
  const SuskiiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeControllerProvider);
    final locale = ref.watch(localeControllerProvider);

    // Seed the active mode once the first bootstrap arrives.
    ref.listen(bootstrapProvider, (previous, next) {
      final user = next.value?.user;
      if (user != null) {
        ref.read(modeControllerProvider.notifier).seed(user.activeMode);
      }
    });

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      theme: SAppTheme.light(),
      darkTheme: SAppTheme.dark(),
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
