import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// First run after sign-up: "How would you like to use Suskii Errands?"
/// Asked once per account (`select_initial_role`). Both roles live on one
/// account, and the other can be added later from the profile.
///
/// Choosing Service Provider leads into provider onboarding. Provider mode
/// itself opens only once the provider is approved; the server enforces it.
class RoleSelectionPage extends ConsumerStatefulWidget {
  const RoleSelectionPage({super.key});

  @override
  ConsumerState<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends ConsumerState<RoleSelectionPage> {
  UserMode? _choice;
  bool _saving = false;

  /// One key per answer: kept on failure so a retry replays the same answer,
  /// replaced when the person picks the other card.
  String? _key;

  Future<void> _continue() async {
    final choice = _choice;
    if (choice == null || _saving) return;
    setState(() => _saving = true);
    _key ??= newIdempotencyKey();
    try {
      await ref
          .read(userRepositoryProvider)
          .selectInitialRole(choice, idempotencyKey: _key!);
      ref.read(roleAnsweredProvider.notifier).set(true);
      ref.invalidate(bootstrapProvider);
      if (!mounted) return;
      context.go(
        choice == UserMode.provider
            ? AppRoutes.providerOnboarding
            : AppRoutes.customerHome,
      );
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _pick(UserMode mode) => setState(() {
    if (_choice != mode) _key = null;
    _choice = mode;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.xl),
          children: <Widget>[
            const SizedBox(height: SSpacing.lg),
            Text(
              l10n.roleTitle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SSpacing.sm),
            Text(
              l10n.roleSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SSpacing.xl),
            _RoleCard(
              key: const Key('role-customer'),
              icon: Icons.shopping_bag_outlined,
              title: l10n.roleCustomerTitle,
              body: l10n.roleCustomerBody,
              selected: _choice == UserMode.customer,
              onTap: () => _pick(UserMode.customer),
            ),
            const SizedBox(height: SSpacing.md),
            _RoleCard(
              key: const Key('role-provider'),
              icon: Icons.work_outline,
              title: l10n.roleProviderTitle,
              body: l10n.roleProviderBody,
              selected: _choice == UserMode.provider,
              onTap: () => _pick(UserMode.provider),
            ),
            if (_choice == UserMode.provider) ...<Widget>[
              const SizedBox(height: SSpacing.md),
              Text(
                l10n.roleProviderNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: SSpacing.xl),
            SButton(
              key: const Key('role-continue'),
              label: l10n.actionContinue,
              loading: _saving,
              onPressed: _choice == null || _saving
                  ? null
                  : () => unawaited(_continue()),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(16);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(SSpacing.lg),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 28,
                  backgroundColor: selected
                      ? scheme.primary
                      : scheme.secondaryContainer,
                  foregroundColor: selected
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                  child: Icon(icon, size: 28),
                ),
                const SizedBox(width: SSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: SSpacing.xs / 2),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
