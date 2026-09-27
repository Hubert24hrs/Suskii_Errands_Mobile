/// Build flavors. Selected with `--dart-define-from-file=config/env/<f>.json`.
enum AppFlavor { dev, staging, prod }

/// Compile-time app configuration. Only public values (anon key, URLs) may
/// ever appear here — never a service role key or any other secret.
class AppConfig {
  const AppConfig({
    required this.flavor,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.aiServiceBaseUrl,
    required this.sentryDsn,
    required this.privacyPolicyUrl,
    required this.termsUrl,
    required this.supportEmail,
  });

  final AppFlavor flavor;

  /// Placeholder until Claude Code provisions Supabase projects.
  final String supabaseUrl;

  /// PUBLIC anon key only. Placeholder until backend exists.
  final String supabaseAnonKey;

  final String aiServiceBaseUrl;

  /// Crash reporting. Empty disables it (the default for local builds);
  /// a DSN is a public client key, not a secret.
  final String sentryDsn;

  /// Store listings and the in-app legal links point here. Hosted by the
  /// marketing site; the documents themselves are counsel's (OD-24).
  final String privacyPolicyUrl;
  final String termsUrl;
  final String supportEmail;

  bool get isProd => flavor == AppFlavor.prod;

  /// True when no backend is configured and every repository is the mock:
  /// the only case in which demo affordances ("any code signs you in",
  /// simulated offline) may appear (audit 2026-09-27 Y.8).
  bool get usesMockBackend => supabaseUrl.isEmpty || supabaseAnonKey.isEmpty;

  static AppConfig fromEnvironment() {
    const flavorName = String.fromEnvironment(
      'APP_FLAVOR',
      defaultValue: 'dev',
    );
    return AppConfig(
      flavor: AppFlavor.values.asNameMap()[flavorName] ?? AppFlavor.dev,
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabaseAnonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
      aiServiceBaseUrl: const String.fromEnvironment('AI_SERVICE_URL'),
      sentryDsn: const String.fromEnvironment('SENTRY_DSN'),
      privacyPolicyUrl: const String.fromEnvironment('PRIVACY_POLICY_URL'),
      termsUrl: const String.fromEnvironment('TERMS_URL'),
      supportEmail: const String.fromEnvironment('SUPPORT_EMAIL'),
    );
  }
}
