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
  });

  final AppFlavor flavor;

  /// Placeholder until Claude Code provisions Supabase projects.
  final String supabaseUrl;

  /// PUBLIC anon key only. Placeholder until backend exists.
  final String supabaseAnonKey;

  final String aiServiceBaseUrl;

  bool get isProd => flavor == AppFlavor.prod;

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
    );
  }
}
