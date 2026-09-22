import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../customer/rating_sheet.dart';

/// Provider-side job execution (M8.6): status timeline, display-only money
/// summary, and the per-status action the server state machine expects next —
/// start journey, mark arrived, verify handover PINs, submit proofs and mark
/// complete. All transitions go through `JobProgressRepository`; the client
/// never decides what is allowed, it only offers the action and surfaces the
/// server's error. One idempotency key per intent, kept across retries.
class ProviderJobExecutionPage extends ConsumerStatefulWidget {
  const ProviderJobExecutionPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<ProviderJobExecutionPage> createState() =>
      _ProviderJobExecutionPageState();
}

class _ProviderJobExecutionPageState
    extends ConsumerState<ProviderJobExecutionPage> {
  static const List<JobStatus> _milestones = <JobStatus>[
    JobStatus.paidHeld,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
    JobStatus.confirmed,
  ];

  /// States where the parties are in contact (chat CTA).
  static const Set<JobStatus> _contactStates = <JobStatus>{
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
  };

  static const Set<JobStatus> _rateableStates = <JobStatus>{
    JobStatus.confirmed,
    JobStatus.settled,
    JobStatus.closed,
  };

  bool _busy = false;
  String? _transitionKey;
  String? _pinKey;
  String? _proofKey;

  /// The mock keeps verified PINs repo-internal, so a successful delivery-PIN
  /// verification is remembered here for the rest of this page session.
  bool _deliveryPinVerified = false;

  /// Set when the server rejected "mark complete" with ERR_PROOF_REQUIRED, so
  /// the proofs card can show the requirement note.
  bool _proofNudge = false;

  int _milestoneReached(JobStatus status) {
    if (status == JobStatus.assigned) return 0;
    if (status == JobStatus.settlementPending ||
        status == JobStatus.settled ||
        status == JobStatus.closed) {
      return _milestones.length - 1;
    }
    return _milestones.indexOf(status);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        if (error is AppError && error.code == ErrorCodes.proofRequired) {
          setState(() => _proofNudge = true);
          ref.invalidate(jobProofsProvider(widget.jobId));
          showSToast(context, l10n.jobProofsRequiredNote, isError: true);
        } else {
          showSToast(context, localizedError(l10n, error), isError: true);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _transition(JobStatus target) => _run(() async {
    _transitionKey ??= newIdempotencyKey();
    await ref
        .read(jobProgressRepositoryProvider)
        .requestStatusChange(
          widget.jobId,
          target,
          idempotencyKey: _transitionKey!,
        );
    _transitionKey = null;
  });

  /// PIN entry for pickup (arrived) and delivery (in_progress). A verified
  /// pickup PIN moves the job to IN_PROGRESS inside the verify call — that
  /// transition is not settable directly; a verified delivery PIN only
  /// satisfies the completion gate. The key is scoped to kind + PIN value so
  /// a retry of the same entry replays without spending another attempt.
  Future<void> _openPinSheet({required HandoverPinKind kind}) async {
    final l10n = AppLocalizations.of(context);
    final pinController = TextEditingController();
    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          SSpacing.lg,
          0,
          SSpacing.lg,
          MediaQuery.of(sheetContext).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.pinEntryTitle,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.pinEntryHint,
              style: Theme.of(sheetContext).textTheme.bodySmall,
            ),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.pinEntryTitle,
              controller: pinController,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.actionConfirm,
              onPressed: () {
                final value = pinController.text.trim();
                if (RegExp(r'^\d{4}$').hasMatch(value)) {
                  Navigator.of(sheetContext).pop(value);
                }
              },
            ),
          ],
        ),
      ),
    );
    if (pin == null || !mounted) return;
    _pinKey = 'pin-${widget.jobId}-${kind.name}-$pin';
    await _run(() async {
      final result = await ref
          .read(jobProgressRepositoryProvider)
          .verifyHandoverPin(
            widget.jobId,
            pin,
            kind: kind,
            idempotencyKey: _pinKey!,
          );
      if (!mounted) return;
      if (!result.verified) {
        showSToast(
          context,
          AppLocalizations.of(context)
              .pinAttemptsRemaining(result.attemptsRemaining),
          isError: true,
        );
        return;
      }
      setState(() {
        if (kind == HandoverPinKind.delivery) _deliveryPinVerified = true;
      });
      // A verified pickup PIN has already moved the job to IN_PROGRESS
      // inside the verify call — no separate transition to make.
    });
  }

  Future<void> _addProof(ProofKind kind) => _run(() async {
    _proofKey = 'proof-${widget.jobId}-${kind.name}';
    await ref
        .read(jobProgressRepositoryProvider)
        .submitProof(
          jobId: widget.jobId,
          kind: kind,
          // Placeholder object until M9 wires camera/upload — the server
          // signs uploads only into the job's own prefix.
          storagePath:
              '${widget.jobId}/proof-${DateTime.now().millisecondsSinceEpoch}.jpg',
          idempotencyKey: _proofKey!,
          capturedAt: DateTime.now(),
        );
    _proofKey = null;
    _proofNudge = false;
    ref.invalidate(jobProofsProvider(widget.jobId));
  });

  String _proofActionLabel(AppLocalizations l10n, ProofKind kind) =>
      switch (kind) {
        ProofKind.photo => l10n.jobActionAddProofPhoto,
        ProofKind.receipt => l10n.jobActionAddProofReceipt,
        ProofKind.signature => l10n.jobActionAddProofSignature,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final job = ref.watch(requestDetailProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.myJobsTitle)),
      body: SafeArea(
        child: job.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.lg),
            child: Column(
              children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
            ),
          ),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(requestDetailProvider(widget.jobId)),
          ),
          data: (JobRequest request) => _buildDetail(l10n, request),
        ),
      ),
    );
  }

  Widget _buildDetail(AppLocalizations l10n, JobRequest request) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final reached = _milestoneReached(request.status);
    final terminal = request.status.isTerminal;

    return ListView(
      padding: const EdgeInsets.all(SSpacing.lg),
      children: <Widget>[
        Row(
          children: <Widget>[
            SStatusChip(
              status: request.status,
              label: jobStatusLabel(l10n, request.status),
            ),
            const Spacer(),
            Text(
              categoryLabel(l10n, _categoryKey(request.categoryId)),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: SSpacing.md),
        if (!terminal && reached >= 0)
          SStatusTimeline(
            steps: <SStatusStep>[
              for (var i = 0; i < _milestones.length; i++)
                SStatusStep(
                  label: jobStatusLabel(l10n, _milestones[i]),
                  state: i < reached
                      ? STimelineStepState.done
                      : i == reached
                      ? STimelineStepState.current
                      : STimelineStepState.upcoming,
                ),
            ],
          ),
        const SizedBox(height: SSpacing.lg),
        _row(l10n.detailDescriptionLabel, request.description),
        _row(l10n.detailPickupLabel, request.pickup.label),
        if (request.pickup.landmarkNote != null)
          _row(l10n.createLandmarkLabel, request.pickup.landmarkNote!),
        if (request.destination != null)
          _row(l10n.detailDestinationLabel, request.destination!.label),
        _row(l10n.detailUrgencyLabel, urgencyLabel(l10n, request.urgency)),
        if (request.scheduledAt != null)
          _row(
            l10n.detailScheduledLabel,
            MaterialLocalizations.of(context)
                .formatMediumDate(request.scheduledAt!),
          ),
        if (request.agreedPrice != null)
          _row(
            l10n.detailAgreedPriceLabel,
            request.agreedPrice!.format(locale: locale),
          ),
        if (request.itemFloat != null)
          _row(
            l10n.detailItemFloatLabel,
            request.itemFloat!.format(locale: locale),
          ),
        if (request.agreedBreakdown != null)
          _row(
            l10n.detailAgreedPriceLabel,
            l10n.toolsInstantPayoutQuote(
              request.agreedBreakdown!.platformCommission.format(
                locale: locale,
              ),
              request.agreedBreakdown!.providerPayout.format(locale: locale),
            ),
          ),
        const SizedBox(height: SSpacing.lg),
        if (request.status == JobStatus.paidHeld ||
            request.status == JobStatus.assigned)
          SButton(
            label: l10n.jobActionStartJourney,
            icon: Icons.route_outlined,
            loading: _busy,
            onPressed: _busy ? null : () => _transition(JobStatus.enRoute),
          ),
        if (request.status == JobStatus.enRoute) ...<Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: Text(
                l10n.jobArrivalGeofenceNote,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: SSpacing.sm),
          SButton(
            label: l10n.jobActionArrived,
            icon: Icons.place_outlined,
            loading: _busy,
            onPressed: _busy ? null : () => _transition(JobStatus.arrived),
          ),
        ],
        if (request.status == JobStatus.arrived)
          SButton(
            label: l10n.jobActionVerifyPickupPin,
            icon: Icons.pin_outlined,
            loading: _busy,
            onPressed: _busy
                ? null
                : () => _openPinSheet(kind: HandoverPinKind.pickup),
          ),
        if (request.status == JobStatus.inProgress)
          _executionSection(l10n, theme, request),
        if (request.status == JobStatus.completedByProvider)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: Text(l10n.jobWaitingCustomerConfirmation),
            ),
          ),
        if (_rateableStates.contains(request.status))
          _RatingSection(jobId: widget.jobId),
        if (_contactStates.contains(request.status)) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          SButton(
            label: l10n.detailChat,
            variant: SButtonVariant.secondary,
            icon: Icons.chat_bubble_outline,
            onPressed: () => unawaited(
              context.push(AppRoutes.providerJobChatPath(widget.jobId)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: SSpacing.xs),
            child: Text(
              l10n.trackingLiveHint,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }

  /// IN_PROGRESS: missing proofs, the delivery PIN gate and mark-complete.
  Widget _executionSection(
    AppLocalizations l10n,
    ThemeData theme,
    JobRequest request,
  ) {
    final proofs =
        ref.watch(jobProofsProvider(widget.jobId)).value ?? const <Proof>[];
    final requirements = _proofRequirements(request.categoryId);
    final missing = <ProofKind>[];
    for (final entry in requirements.entries) {
      final submitted = proofs.where((p) => p.kind.name == entry.key).length;
      if (submitted >= entry.value) continue;
      for (final kind in ProofKind.values) {
        if (kind.name == entry.key) missing.add(kind);
      }
    }
    final needsDeliveryPin =
        request.destination != null && !_deliveryPinVerified;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_proofNudge)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: Text(
                l10n.jobProofsRequiredNote,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        for (final kind in missing) ...<Widget>[
          const SizedBox(height: SSpacing.sm),
          SButton(
            label: _proofActionLabel(l10n, kind),
            variant: SButtonVariant.secondary,
            icon: Icons.photo_camera_outlined,
            loading: _busy,
            onPressed: _busy ? null : () => _addProof(kind),
          ),
        ],
        if (needsDeliveryPin) ...<Widget>[
          const SizedBox(height: SSpacing.sm),
          SButton(
            label: l10n.jobActionVerifyDeliveryPin,
            variant: SButtonVariant.secondary,
            icon: Icons.pin_outlined,
            loading: _busy,
            onPressed: _busy
                ? null
                : () => _openPinSheet(kind: HandoverPinKind.delivery),
          ),
        ],
        const SizedBox(height: SSpacing.md),
        SButton(
          label: l10n.jobActionMarkComplete,
          icon: Icons.check_circle_outline,
          loading: _busy,
          onPressed: _busy
              ? null
              : () => _transition(JobStatus.completedByProvider),
        ),
      ],
    );
  }

  String _categoryKey(String categoryId) {
    final cats =
        ref.read(categoriesProvider).value ?? const <ServiceCategory>[];
    for (final c in cats) {
      if (c.id == categoryId) return c.labelKey;
    }
    return 'catCustom';
  }

  Map<String, int> _proofRequirements(String categoryId) {
    final cats =
        ref.read(categoriesProvider).value ?? const <ServiceCategory>[];
    for (final c in cats) {
      if (c.id == categoryId) return c.proofRequirements;
    }
    return const <String, int>{};
  }

  Widget _row(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Rating prompt on completed jobs: the provider rates the customer. Same
/// contract as the customer-side section — a rate button until the rating
/// exists, then the recorded stars.
class _RatingSection extends ConsumerWidget {
  const _RatingSection({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rating = ref.watch(myRatingProvider(jobId));
    return rating.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (Rating? existing) => Padding(
        padding: const EdgeInsets.only(top: SSpacing.md),
        child: existing == null
            ? SButton(
                label: l10n.ratingTitle,
                variant: SButtonVariant.secondary,
                icon: Icons.star_outline_rounded,
                onPressed: () => showRatingSheet(context, jobId),
              )
            : Row(
                children: <Widget>[
                  SRatingInput(value: existing.stars, size: 20),
                  const SizedBox(width: SSpacing.sm),
                  Text(
                    l10n.ratingDoneLabel(existing.stars),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }
}
