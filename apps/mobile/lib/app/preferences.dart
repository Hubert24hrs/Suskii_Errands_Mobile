import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device preferences that survive a restart: the first-run flag, the
/// country and language chosen before sign-in, and the theme. None of it is
/// sensitive — the session lives in secure storage (`secure_session_storage`)
/// — so plain SharedPreferences is the right tool (audit 2026-09-27 Y.14).
///
/// Overridden in `main()` with the instance loaded before the first frame,
/// and in tests with `SharedPreferences.setMockInitialValues`.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);

abstract final class _Keys {
  static const String welcomeSeen = 'welcome_seen';
  static const String country = 'country_code';
  static const String locale = 'locale';
  static const String themeMode = 'theme_mode';
}

/// First-run flag: until it is set, signed-out users see welcome →
/// onboarding → auth.
class WelcomeSeenController extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_Keys.welcomeSeen) ?? false;

  void set(bool value) {
    state = value;
    unawaited(
      ref.read(sharedPreferencesProvider).setBool(_Keys.welcomeSeen, value),
    );
  }
}

final welcomeSeenProvider = NotifierProvider<WelcomeSeenController, bool>(
  WelcomeSeenController.new,
);

/// The country chosen on the welcome screen (ISO 3166-1 alpha-2), sent as
/// the bootstrap hint and as sign-up metadata. Null until chosen.
class SelectedCountryController extends Notifier<String?> {
  @override
  String? build() =>
      ref.watch(sharedPreferencesProvider).getString(_Keys.country);

  void set(String countryCode) {
    state = countryCode;
    unawaited(
      ref.read(sharedPreferencesProvider).setString(_Keys.country, countryCode),
    );
  }
}

final selectedCountryProvider =
    NotifierProvider<SelectedCountryController, String?>(
      SelectedCountryController.new,
    );

/// null = follow system / country default.
class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    final code = ref.watch(sharedPreferencesProvider).getString(_Keys.locale);
    return code == null ? null : Locale(code);
  }

  void setLocale(Locale? locale) {
    state = locale;
    final prefs = ref.read(sharedPreferencesProvider);
    if (locale == null) {
      unawaited(prefs.remove(_Keys.locale));
    } else {
      unawaited(prefs.setString(_Keys.locale, locale.languageCode));
    }
  }
}

final localeControllerProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

/// Dark-first: a fresh install follows the system, and the system default on
/// most handsets in the launch markets is dark.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final name = ref
        .watch(sharedPreferencesProvider)
        .getString(_Keys.themeMode);
    return ThemeMode.values.asNameMap()[name] ?? ThemeMode.system;
  }

  void setThemeMode(ThemeMode mode) {
    state = mode;
    unawaited(
      ref.read(sharedPreferencesProvider).setString(_Keys.themeMode, mode.name),
    );
  }
}

final themeModeControllerProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
