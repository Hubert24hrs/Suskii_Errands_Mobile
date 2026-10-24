import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/device_country.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/secure_screen.dart';
import '../customer/wallet_page.dart';
import 'provider_tools_page.dart';

/// The account header of the provider dashboard, laid out after the
/// sportsbook account panels the owner pointed at (2026-10-24): who you are
/// and your tier, progress towards the earnings goal, the balance hidden
/// until asked for, and the two ways money leaves.
class ProviderDashboardHeader extends ConsumerStatefulWidget {
  const ProviderDashboardHeader({super.key});

  @override
  ConsumerState<ProviderDashboardHeader> createState() =>
      _ProviderDashboardHeaderState();
}

class _ProviderDashboardHeaderState
    extends ConsumerState<ProviderDashboardHeader> {
  // Hidden on every visit: a balance on the first screen is read over a
  // shoulder more often than it is needed.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = context.sColors;
    final locale = Localizations.localeOf(context).languageCode;
    final user =
        ref.watch(authStateProvider).value?.user ??
        ref.watch(bootstrapProvider).value?.user;
    final wallet = ref.watch(walletSummaryProvider).value;
    final goal = ref.watch(earningsGoalProvider).value;
    final onSuccess = _onColor(palette.success);

    final total = wallet == null ? null : wallet.available + wallet.pending;
    final currency =
        total?.currencyCode ??
        ref.watch(bootstrapProvider).value?.countryPack.currencyCode ??
        'NGN';

    final header = Card(
      key: const ValueKey<String>('providerDash.header'),
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    button: true,
                    label: l10n.providerDashAccount,
                    child: InkWell(
                      key: const ValueKey<String>('providerDash.account'),
                      borderRadius: SRadius.borderSm,
                      onTap: () => context.go(AppRoutes.providerProfile),
                      child: Row(
                        children: <Widget>[
                          _TierAvatar(
                            name: user?.displayName,
                            tier: _tierNumeral(user?.trustLevel),
                          ),
                          const SizedBox(width: SSpacing.md),
                          Flexible(
                            child: Text(
                              _accountLabel(l10n, user),
                              style: theme.textTheme.titleMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('providerDash.settings'),
                  tooltip: l10n.settingsTitle,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () =>
                      unawaited(context.push(AppRoutes.customerSettings)),
                ),
              ],
            ),
            const SizedBox(height: SSpacing.md),
            if (user != null)
              Text(
                l10n.providerDashTrustTier(
                  _tierNumeral(user.trustLevel),
                  _trustLabel(l10n, user.trustLevel),
                ),
                style: theme.textTheme.labelLarge,
              ),
            const SizedBox(height: SSpacing.sm),
            ClipRRect(
              borderRadius: const BorderRadius.all(
                Radius.circular(SRadius.pill),
              ),
              child: LinearProgressIndicator(
                key: const ValueKey<String>('providerDash.goalBar'),
                value: goal == null || goal.target.minorUnits <= 0
                    ? 0
                    : (goal.progress.minorUnits / goal.target.minorUnits).clamp(
                        0.0,
                        1.0,
                      ),
                minHeight: 6,
                color: palette.warning,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: SSpacing.xs),
            Row(
              children: <Widget>[
                Expanded(
                  child: goal == null
                      ? Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => unawaited(
                              context.push(AppRoutes.providerTools),
                            ),
                            child: Text(l10n.providerDashNoGoal),
                          ),
                        )
                      : Text(
                          l10n.providerDashGoalProgress(
                            goal.progress.format(locale: locale),
                            goal.target.format(locale: locale),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                if (goal != null)
                  Text(
                    l10n.providerDashGoalResets(
                      MaterialLocalizations.of(context).formatShortMonthDay(
                        goalPeriodEnd(goal.period, DateTime.now()),
                      ),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: SSpacing.lg),
            Text(
              l10n.providerDashTotalBalance,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              children: <Widget>[
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      _revealed && total != null
                          ? total.format(locale: locale)
                          : '$currency *****',
                      key: const ValueKey<String>('providerDash.balance'),
                      style: theme.textTheme.headlineMedium,
                      maxLines: 1,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('providerDash.toggleBalance'),
                  tooltip: _revealed
                      ? l10n.providerDashHideBalance
                      : l10n.providerDashShowBalance,
                  icon: Icon(
                    _revealed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _revealed = !_revealed),
                ),
              ],
            ),
            if (_revealed && wallet != null)
              Text(
                l10n.providerDashBalanceSplit(
                  wallet.available.format(locale: locale),
                  wallet.pending.format(locale: locale),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: SSpacing.lg),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton(
                    key: const ValueKey<String>('providerDash.withdraw'),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.success,
                      foregroundColor: onSuccess,
                      minimumSize: const Size.fromHeight(48),
                      shape: const RoundedRectangleBorder(
                        borderRadius: SRadius.borderSm,
                      ),
                    ),
                    onPressed: wallet == null
                        ? null
                        : () => unawaited(
                            showWithdrawSheet(
                              context,
                              currencyCode: wallet.available.currencyCode,
                            ),
                          ),
                    child: Text(l10n.walletWithdraw),
                  ),
                ),
                const SizedBox(width: SSpacing.md),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey<String>('providerDash.instantPayout'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.success,
                      side: BorderSide(color: palette.success, width: 1.5),
                      minimumSize: const Size.fromHeight(48),
                      shape: const RoundedRectangleBorder(
                        borderRadius: SRadius.borderSm,
                      ),
                    ),
                    onPressed: () => unawaited(showInstantPayoutSheet(context)),
                    child: Text(l10n.toolsInstantPayoutTitle),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    // A revealed balance is a wallet screen (audit Y.16): no screenshots.
    return _revealed ? SecureScreen(child: header) : header;
  }
}

/// Phone numbers as the sportsbook shows them: the first two national
/// digits and the last, `80*******5`. Email accounts keep the first letter
/// and the domain.
@visibleForTesting
String maskAccount({String? phoneE164, String? email}) {
  if (phoneE164 != null && phoneE164.isNotEmpty) {
    var digits = phoneE164.replaceAll(RegExp('[^0-9]'), '');
    for (final String code in countryDialCodes.values) {
      if (digits.startsWith(code) && digits.length - code.length >= 6) {
        digits = digits.substring(code.length);
        break;
      }
    }
    if (digits.length < 4) return '*' * digits.length;
    return '${digits.substring(0, 2)}${'*' * (digits.length - 3)}'
        '${digits.substring(digits.length - 1)}';
  }
  if (email != null && email.contains('@')) {
    final at = email.indexOf('@');
    return '${email.substring(0, at > 0 ? 1 : 0)}***${email.substring(at)}';
  }
  return '';
}

/// When the goal starts again, as `my_earnings_goal` counts it: weeks start
/// on Monday (Postgres `date_trunc('week')`), months on the first.
@visibleForTesting
DateTime goalPeriodEnd(GoalPeriod period, DateTime now) => switch (period) {
  GoalPeriod.weekly => DateTime(now.year, now.month, now.day + 8 - now.weekday),
  GoalPeriod.monthly => DateTime(now.year, now.month + 1),
};

String _accountLabel(AppLocalizations l10n, AppUser? user) {
  if (user == null) return '';
  final masked = maskAccount(phoneE164: user.phoneE164, email: user.email);
  if (masked.isNotEmpty) return masked;
  return user.displayName.trim().isEmpty
      ? l10n.profileAddName
      : user.displayName;
}

String _tierNumeral(TrustLevel? level) => switch (level) {
  null || TrustLevel.new_ => 'I',
  TrustLevel.verified => 'II',
  TrustLevel.trusted => 'III',
  TrustLevel.elite => 'IV',
};

String _trustLabel(AppLocalizations l10n, TrustLevel level) => switch (level) {
  TrustLevel.new_ => l10n.trustLevelNew,
  TrustLevel.verified => l10n.trustLevelVerified,
  TrustLevel.trusted => l10n.trustLevelTrusted,
  TrustLevel.elite => l10n.trustLevelElite,
};

Color _onColor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark
    ? Colors.white
    : SColors.brandNavy;

class _TierAvatar extends StatelessWidget {
  const _TierAvatar({required this.name, required this.tier});

  final String? name;
  final String tier;

  @override
  Widget build(BuildContext context) {
    final badge = context.sColors.warning;
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          SAvatar(name: name),
          PositionedDirectional(
            end: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: badge,
                borderRadius: const BorderRadius.all(
                  Radius.circular(SRadius.pill),
                ),
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
              child: Text(
                tier,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: _onColor(badge),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
