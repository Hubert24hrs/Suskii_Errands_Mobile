import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/idempotency_keys.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import 'provider_kyc_step_forms.dart';

final _kycProfileProvider = StreamProvider<ProviderKycProfile>(
  (ref) => ref.watch(providerKycRepositoryProvider).watchKycProfile(),
);

/// Provider KYC checklist: every step with its server-owned status, per-step
/// forms in modal sheets, and final submission for Verification Officer
/// review. Step states flip live via [ProviderKycRepository.watchKycProfile].
class ProviderKycPage extends ConsumerWidget {
  const ProviderKycPage({super.key});

  Future<void> _openStep(BuildContext context, KycStep step) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => KycStepForm(kind: step.kind),
    );
  }

  Future<void> _submitForReview(BuildContext context, WidgetRef ref) async {
    // Held per intent (M3.14): this page is a ConsumerWidget with nowhere to
    // put a field, and a retry with a fresh key would submit a second review.
    final keys = ref.read(idempotencyKeysProvider);
    const intent = 'kyc.submitForReview';
    try {
      await ref
          .read(providerKycRepositoryProvider)
          .submitForReview(idempotencyKey: keys.forIntent(intent));
      keys.done(intent);
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final profile = ref.watch(_kycProfileProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.kycTitle)),
      body: SafeArea(
        child: profile.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.xl),
            child: Column(
              children: <Widget>[
                SSkeletonListTile(),
                SSkeletonListTile(),
                SSkeletonListTile(),
              ],
            ),
          ),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(_kycProfileProvider),
          ),
          data: (ProviderKycProfile data) => ListView(
            padding: const EdgeInsets.all(SSpacing.lg),
            children: <Widget>[
              Text(
                l10n.kycChecklistIntro,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: SSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: _OverallChip(status: data.overallStatus),
              ),
              const SizedBox(height: SSpacing.lg),
              for (final KycStep step in data.steps)
                _StepTile(
                  step: step,
                  onTap:
                      step.status == KycStepStatus.inReview ||
                          step.status == KycStepStatus.verified
                      ? null
                      : () => unawaited(_openStep(context, step)),
                ),
              const SizedBox(height: SSpacing.xl),
              SButton(
                label: l10n.kycSubmitForReview,
                onPressed: data.submittedForReviewAt != null
                    ? null
                    : () => unawaited(_submitForReview(context, ref)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverallChip extends StatelessWidget {
  const _OverallChip({required this.status});

  final KycStepStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      KycStepStatus.verified => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      KycStepStatus.inReview => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      KycStepStatus.rejected ||
      KycStepStatus.expired => (scheme.errorContainer, scheme.onErrorContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SSpacing.md,
        vertical: SSpacing.xs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: SRadius.borderSm),
      child: Text(
        kycStepStatusLabel(l10n, status),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step, this.onTap});

  final KycStep step;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locked = onTap == null;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: SRadius.borderMd,
        child: Padding(
          padding: const EdgeInsets.all(SSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      kycStepKindLabel(l10n, step.kind),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  _StepStatusChip(status: step.status),
                ],
              ),
              const SizedBox(height: SSpacing.xs),
              Text(
                kycStepKindBody(l10n, step.kind),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (step.status == KycStepStatus.rejected) ...<Widget>[
                const SizedBox(height: SSpacing.sm),
                Text(
                  kycRejectionReasonLabel(l10n, step.rejectionReasonKey),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (step.status == KycStepStatus.inReview) ...<Widget>[
                const SizedBox(height: SSpacing.sm),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: SSpacing.sm),
                    Text(
                      l10n.providerVerificationPending,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (locked)
                const SizedBox.shrink()
              else
                const SizedBox(height: SSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepStatusChip extends StatelessWidget {
  const _StepStatusChip({required this.status});

  final KycStepStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      KycStepStatus.verified => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      KycStepStatus.inReview || KycStepStatus.inProgress => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      KycStepStatus.rejected ||
      KycStepStatus.expired => (scheme.errorContainer, scheme.onErrorContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SSpacing.sm,
        vertical: SSpacing.xs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: SRadius.borderSm),
      child: Text(
        kycStepStatusLabel(l10n, status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
