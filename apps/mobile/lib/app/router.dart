import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../features/auth/auth_page.dart';
import '../features/auth/mfa_prompt_page.dart';
import '../features/customer/customer_home_page.dart';
import '../features/customer/customer_shell.dart';
import '../features/customer/messages_page.dart';
import '../features/customer/profile_page.dart';
import '../features/customer/requests_page.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/provider/earnings_page.dart';
import '../features/provider/provider_feed_page.dart';
import '../features/provider/provider_jobs_page.dart';
import '../features/provider/provider_kyc_page.dart';
import '../features/provider/provider_onboarding_page.dart';
import '../features/provider/provider_shell.dart';
import '../features/splash/splash_page.dart';
import '../features/startup/startup_error_page.dart';
import '../features/verification/customer_verification_page.dart';
import '../features/welcome/welcome_page.dart';
import 'providers.dart';

/// Route paths — centralized until typed routes (go_router_builder) land in M2.
abstract final class AppRoutes {
  static const String splash = '/splash';
  static const String startupError = '/startup-error';
  static const String welcome = '/welcome';
  static const String onboarding = '/onboarding';
  static const String auth = '/auth';
  static const String authMfa = '/auth/mfa';

  static const String verifyCustomer = '/verify/customer';

  static const String providerOnboarding = '/provider/onboarding';
  static const String providerKyc = '/provider/kyc';

  static const String customerHome = '/customer/home';
  static const String customerRequests = '/customer/requests';
  static const String customerMessages = '/customer/messages';
  static const String customerProfile = '/customer/profile';

  static const String providerFeed = '/provider/feed';
  static const String providerJobs = '/provider/jobs';
  static const String providerEarnings = '/provider/earnings';
  static const String providerProfile = '/provider/profile';
}

/// Simple boolean flag controller (Riverpod 3 has no legacy StateProvider).
class BoolFlag extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// First-run flag (M2: in-memory only — no persistence layer yet). Until it
/// is set, signed-out users see welcome → onboarding → auth.
final welcomeSeenProvider = NotifierProvider<BoolFlag, bool>(BoolFlag.new);

/// M2 placeholder: the post-sign-in MFA prompt shows once per session until
/// acknowledged. Reset on sign-out.
final mfaAcknowledgedProvider = NotifierProvider<BoolFlag, bool>(BoolFlag.new);

/// Triggers redirect re-evaluation when session, bootstrap or mode change.
final _routerRefreshProvider = Provider<ValueNotifier<int>>((ref) {
  final notifier = ValueNotifier<int>(0);
  ref
    ..listen(authStateProvider, (_, _) => notifier.value++)
    ..listen(modeControllerProvider, (_, _) => notifier.value++)
    ..listen(bootstrapProvider, (_, _) => notifier.value++)
    ..listen(welcomeSeenProvider, (_, _) => notifier.value++)
    ..listen(mfaAcknowledgedProvider, (_, _) => notifier.value++);
  ref.onDispose(notifier.dispose);
  return notifier;
});

bool _isKycFlowRoute(String loc) =>
    loc == AppRoutes.providerOnboarding || loc == AppRoutes.providerKyc;

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: ref.read(_routerRefreshProvider),
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final boot = ref.read(bootstrapProvider);

      // 1. Bootstrap still loading → splash.
      if (boot.isLoading && loc != AppRoutes.splash) return AppRoutes.splash;

      // 2. Bootstrap failed (e.g. country disabled, offline) → startup error.
      if (boot.hasError && loc != AppRoutes.startupError) {
        return AppRoutes.startupError;
      }

      // 3. Auth gate. Signed-out first run: welcome → onboarding → auth.
      final auth = ref.read(authStateProvider).value;
      final signedIn = auth?.status == AuthStatus.signedIn;
      if (!signedIn) {
        ref.read(mfaAcknowledgedProvider.notifier).set(false);
        final welcomeSeen = ref.read(welcomeSeenProvider);
        if (!welcomeSeen) {
          return loc == AppRoutes.welcome ? null : AppRoutes.welcome;
        }
        final isPublicRoute =
            loc == AppRoutes.auth || loc == AppRoutes.onboarding;
        return isPublicRoute ? null : AppRoutes.auth;
      }

      // 4. MFA prompt placeholder (M2): shown once after sign-in until
      // acknowledged; the page itself just acknowledges and returns here.
      if (!ref.read(mfaAcknowledgedProvider) && loc != AppRoutes.authMfa) {
        return AppRoutes.authMfa;
      }
      final isPublicRoute =
          loc == AppRoutes.auth ||
          loc == AppRoutes.onboarding ||
          loc == AppRoutes.welcome;
      if (isPublicRoute || loc == AppRoutes.splash) {
        return ref.read(modeControllerProvider) == UserMode.provider
            ? AppRoutes.providerFeed
            : AppRoutes.customerHome;
      }

      // 5. Mode guard: each mode owns its shell. KYC/onboarding routes stay
      // reachable from customer mode — that is where provider verification
      // starts. Unverified provider-mode attempts open provider onboarding.
      final mode = ref.read(modeControllerProvider);
      if (loc.startsWith('/provider')) {
        if (_isKycFlowRoute(loc)) return null;
        final user = auth?.user ?? boot.value?.user;
        final verified =
            user?.providerVerification == VerificationStatus.verified;
        if (!verified) return AppRoutes.providerOnboarding;
        if (mode != UserMode.provider) return AppRoutes.customerHome;
      }
      if (loc.startsWith('/customer') && mode == UserMode.provider) {
        return AppRoutes.providerFeed;
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashPage(),
      ),
      GoRoute(
        path: AppRoutes.startupError,
        builder: (context, state) => const StartupErrorPage(),
      ),
      GoRoute(
        path: AppRoutes.welcome,
        builder: (context, state) => const WelcomePage(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingPage(),
      ),
      GoRoute(
        path: AppRoutes.auth,
        builder: (context, state) => const AuthPage(),
      ),
      GoRoute(
        path: AppRoutes.authMfa,
        builder: (context, state) => const MfaPromptPage(),
      ),
      GoRoute(
        path: AppRoutes.verifyCustomer,
        builder: (context, state) => const CustomerVerificationPage(),
      ),
      GoRoute(
        path: AppRoutes.providerOnboarding,
        builder: (context, state) => const ProviderOnboardingPage(),
      ),
      GoRoute(
        path: AppRoutes.providerKyc,
        builder: (context, state) => const ProviderKycPage(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            CustomerShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.customerHome,
                builder: (context, state) => const CustomerHomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.customerRequests,
                builder: (context, state) => const CustomerRequestsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.customerMessages,
                builder: (context, state) => const MessagesPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.customerProfile,
                builder: (context, state) => const ProfilePage(),
              ),
            ],
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            ProviderShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.providerFeed,
                builder: (context, state) => const ProviderFeedPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.providerJobs,
                builder: (context, state) => const ProviderJobsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.providerEarnings,
                builder: (context, state) => const EarningsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.providerProfile,
                builder: (context, state) => const ProfilePage(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
