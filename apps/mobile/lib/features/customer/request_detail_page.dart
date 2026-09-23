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
import 'offers_board.dart';
import 'open_dispute_sheet.dart';
import 'rating_sheet.dart';
import 'sos_sheet.dart';

/// Request detail: status timeline, fields summary, publish (drafts),
/// cancel with a localized reason key, and the live offers board.
class RequestDetailPage extends ConsumerStatefulWidget {
  const RequestDetailPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<RequestDetailPage> createState() => _RequestDetailPageState();
}

class _RequestDetailPageState extends ConsumerState<RequestDetailPage> {
  bool _busy = false;
  String? _publishKey;
  String? _cancelKey;
  String? _confirmKey;

  static const List<JobStatus> _milestones = <JobStatus>[
    JobStatus.published,
    JobStatus.agreed,
    JobStatus.paidHeld,
    JobStatus.inProgress,
    JobStatus.confirmed,
  ];

  static const List<String> _cancelReasons = <String>[
    'changedMind',
    'priceTooHigh',
    'foundElsewhere',
    'other',
  ];

  static const Set<JobStatus> _cancellable = <JobStatus>{
    JobStatus.draft,
    JobStatus.published,
    JobStatus.offersReceived,
    JobStatus.negotiating,
    JobStatus.agreed,
    JobStatus.paymentPending,
  };

  static const Set<JobStatus> _showsOffers = <JobStatus>{
    JobStatus.published,
    JobStatus.offersReceived,
    JobStatus.negotiating,
  };

  /// States where the parties are in contact: chat/call/track/SOS (M4).
  static const Set<JobStatus> _contactStates = <JobStatus>{
    JobStatus.agreed,
    JobStatus.paymentPending,
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
  };

  /// States where a live tracking view makes sense.
  static const Set<JobStatus> _trackableStates = <JobStatus>{
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
  };

  static const Set<JobStatus> _rateableStates = <JobStatus>{
    JobStatus.confirmed,
    JobStatus.settled,
    JobStatus.closed,
  };

  /// States in which a dispute can be opened (mirrors the mock's set — the
  /// server owns the real rule).
  static const Set<JobStatus> _disputableStates = <JobStatus>{
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
    JobStatus.confirmed,
  };

  int _milestoneReached(JobStatus status) {
    if (status == JobStatus.draft) return -1;
    if (status == JobStatus.offersReceived || status == JobStatus.negotiating) {
      return 0;
    }
    if (status == JobStatus.paymentPending) return 1;
    if (status == JobStatus.assigned ||
        status == JobStatus.enRoute ||
        status == JobStatus.arrived) {
      return 2;
    }
    if (status == JobStatus.completedByProvider) return 3;
    if (status == JobStatus.settlementPending ||
        status == JobStatus.settled ||
        status == JobStatus.closed) {
      return 4;
    }
    final idx = _milestones.indexOf(status);
    return idx;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(context, localizedError(l10n, error), isError: true);
        if (error is AppError &&
            error.code == ErrorCodes.verificationRequired) {
          unawaited(context.push(AppRoutes.verifyCustomer));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() => _run(() async {
    _publishKey ??= newIdempotencyKey();
    await ref
        .read(requestRepositoryProvider)
        .publishRequest(widget.jobId, idempotencyKey: _publishKey!);
  });

  Future<void> _confirmCompletion() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showSConfirmDialog(
      context: context,
      title: l10n.detailConfirmCompletion,
      message: l10n.detailConfirmCompletionBody,
      confirmLabel: l10n.actionConfirm,
      cancelLabel: l10n.actionCancel,
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      _confirmKey ??= newIdempotencyKey();
      await ref
          .read(jobProgressRepositoryProvider)
          .confirmCompletion(widget.jobId, idempotencyKey: _confirmKey!);
    });
  }

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context);
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SSpacing.lg),
              child: Text(
                l10n.detailCancelTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final key in _cancelReasons)
              ListTile(
                title: Text(cancelReasonLabel(l10n, key)),
                onTap: () => Navigator.of(sheetContext).pop(key),
              ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    await _run(() async {
      _cancelKey ??= newIdempotencyKey();
      await ref
          .read(requestRepositoryProvider)
          .cancelRequest(widget.jobId, reason, idempotencyKey: _cancelKey!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final job = ref.watch(requestDetailProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.detailTitle)),
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
        if (request.preferredPrice != null)
          _row(l10n.detailPriceLabel, request.preferredPrice!.format()),
        if (request.agreedPrice != null)
          _row(l10n.detailAgreedPriceLabel, request.agreedPrice!.format()),
        if (request.itemFloat != null)
          _row(l10n.detailItemFloatLabel, request.itemFloat!.format()),
        if (request.declaredValue != null)
          _row(l10n.detailDeclaredValueLabel, request.declaredValue!.format()),
        const SizedBox(height: SSpacing.lg),
        if (request.status == JobStatus.draft)
          SButton(
            label: l10n.detailPublishDraft,
            loading: _busy,
            onPressed: _busy ? null : _publish,
          ),
        if (request.status == JobStatus.agreed)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: Text(l10n.offersAcceptedNote),
            ),
          ),
        if (request.status == JobStatus.agreed ||
            request.status == JobStatus.paymentPending) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          SButton(
            label: l10n.detailPayNow,
            icon: Icons.payments_outlined,
            onPressed: () => unawaited(
              context.push(AppRoutes.customerRequestPayPath(widget.jobId)),
            ),
          ),
        ],
        if (_contactStates.contains(request.status)) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: SButton(
                  label: l10n.detailChat,
                  variant: SButtonVariant.secondary,
                  icon: Icons.chat_bubble_outline,
                  onPressed: () => unawaited(
                    context.push(
                      AppRoutes.customerRequestChatPath(widget.jobId),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SSpacing.sm),
              Expanded(
                child: SButton(
                  label: l10n.detailCall,
                  variant: SButtonVariant.secondary,
                  icon: Icons.call_outlined,
                  onPressed: () => unawaited(
                    context.push(
                      AppRoutes.customerRequestCallPath(widget.jobId),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SSpacing.sm),
              Expanded(
                child: SButton(
                  label: l10n.detailTrack,
                  variant: SButtonVariant.secondary,
                  icon: Icons.place_outlined,
                  onPressed: _trackableStates.contains(request.status)
                      ? () => unawaited(
                          context.push(
                            AppRoutes.customerRequestTrackPath(widget.jobId),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: SSpacing.sm),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                tooltip: l10n.sosButton,
                onPressed: () => showSosSheet(context, widget.jobId),
                icon: const Icon(Icons.sos_outlined),
              ),
            ],
          ),
        ],
        if (_contactStates.contains(request.status)) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          _HandoverPinCard(
            jobId: widget.jobId,
            hasDestination: request.destination != null,
          ),
        ],
        if (request.status == JobStatus.completedByProvider) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: Text(l10n.detailCompletedByProvider),
            ),
          ),
          const SizedBox(height: SSpacing.sm),
          SButton(
            label: l10n.detailConfirmCompletion,
            loading: _busy,
            onPressed: _busy ? null : _confirmCompletion,
          ),
        ],
        if (_rateableStates.contains(request.status))
          _RatingSection(jobId: widget.jobId),
        if (_disputableStates.contains(request.status) ||
            request.status == JobStatus.disputed ||
            request.status == JobStatus.refunded)
          _DisputeSection(jobId: widget.jobId, status: request.status),
        if (_showsOffers.contains(request.status)) ...<Widget>[
          Text(l10n.offersTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: SSpacing.sm),
          OffersBoard(requestId: widget.jobId),
        ],
        if (_cancellable.contains(request.status)) ...<Widget>[
          const SizedBox(height: SSpacing.lg),
          SButton(
            label: l10n.detailCancel,
            variant: SButtonVariant.danger,
            onPressed: _busy ? null : _cancel,
          ),
        ],
      ],
    );
  }

  String _categoryKey(String categoryId) {
    final cats = ref.read(categoriesProvider).value ?? const [];
    for (final c in cats) {
      if (c.id == categoryId) return c.labelKey;
    }
    return 'catCustom';
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

/// Rating prompt on completed jobs: a rate button until the user's rating
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

/// Dispute section (M5): an open-dispute button while the job is disputable;
/// once a dispute exists, its live status, SLA, resolution and refund render
/// here instead.
class _DisputeSection extends ConsumerWidget {
  const _DisputeSection({required this.jobId, required this.status});

  final String jobId;
  final JobStatus status;

  static const Set<JobStatus> _disputable = <JobStatus>{
    JobStatus.paidHeld,
    JobStatus.assigned,
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
    JobStatus.completedByProvider,
    JobStatus.confirmed,
  };

  String _resolutionLabel(AppLocalizations l10n, String key) => switch (key) {
    'disputeResolvedPartialRefund' => l10n.disputeResolvedPartialRefund,
    _ => key,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final dispute = ref.watch(disputeForJobProvider(jobId));
    return dispute.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (Dispute? existing) {
        if (existing == null) {
          if (!_disputable.contains(status)) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: SSpacing.md),
            child: SButton(
              label: l10n.disputeOpenCta,
              variant: SButtonVariant.ghost,
              icon: Icons.gavel_outlined,
              onPressed: () => showOpenDisputeSheet(context, jobId),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: SSpacing.md),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          disputeReasonLabel(l10n, existing.reasonKey),
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Chip(
                        label: Text(disputeStatusLabel(l10n, existing.status)),
                      ),
                    ],
                  ),
                  if ((existing.status == DisputeStatus.open ||
                          existing.status == DisputeStatus.inReview) &&
                      existing.slaDeadline != null)
                    Padding(
                      padding: const EdgeInsets.only(top: SSpacing.xs),
                      child: Text(
                        l10n.disputeSlaLabel(
                          MaterialLocalizations.of(context)
                              .formatShortDate(existing.slaDeadline!),
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (existing.resolutionNoteKey != null)
                    Padding(
                      padding: const EdgeInsets.only(top: SSpacing.xs),
                      child: Text(
                        _resolutionLabel(l10n, existing.resolutionNoteKey!),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  if (existing.refundAmount != null)
                    Padding(
                      padding: const EdgeInsets.only(top: SSpacing.xs),
                      child: Text(
                        '${l10n.disputeRefundLabel}: '
                        '${existing.refundAmount!.format(locale: locale)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Handover PIN card (M9.2): PINs are never carried on the job entity — the
/// server hands them out on demand via `reveal_job_pin`, so the card reveals
/// on tap instead of rendering a stored value. Jobs with a destination have
/// both a pickup and a delivery PIN.
class _HandoverPinCard extends ConsumerStatefulWidget {
  const _HandoverPinCard({required this.jobId, required this.hasDestination});

  final String jobId;
  final bool hasDestination;

  @override
  ConsumerState<_HandoverPinCard> createState() => _HandoverPinCardState();
}

class _HandoverPinCardState extends ConsumerState<_HandoverPinCard> {
  bool _busy = false;
  String? _pickupPin;
  String? _deliveryPin;

  Future<void> _reveal() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(jobProgressRepositoryProvider);
      final pickup = await repo.revealHandoverPin(
        widget.jobId,
        kind: HandoverPinKind.pickup,
      );
      String? delivery;
      if (widget.hasDestination) {
        delivery = await repo.revealHandoverPin(
          widget.jobId,
          kind: HandoverPinKind.delivery,
        );
      }
      if (!mounted) return;
      setState(() {
        _pickupPin = pickup;
        _deliveryPin = delivery;
      });
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(context, localizedError(l10n, error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.detailHandoverPinTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: SSpacing.xs),
            if (_pickupPin == null) ...<Widget>[
              Text(
                l10n.detailHandoverPinBody,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: SSpacing.sm),
              SButton(
                label: l10n.detailRevealPin,
                variant: SButtonVariant.secondary,
                icon: Icons.pin_outlined,
                loading: _busy,
                onPressed: _busy ? null : _reveal,
              ),
            ] else ...<Widget>[
              _pinRow(l10n.detailPickupLabel, _pickupPin!, theme),
              if (_deliveryPin != null) ...<Widget>[
                const SizedBox(height: SSpacing.xs),
                _pinRow(l10n.detailDestinationLabel, _deliveryPin!, theme),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _pinRow(String label, String pin, ThemeData theme) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: Text(
            pin,
            style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 8),
          ),
        ),
      ],
    );
  }
}
