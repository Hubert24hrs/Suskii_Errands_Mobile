import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/device_location.dart';
import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/media_capture.dart';
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

  /// States in which the customer's map follows the provider (ADR-0009).
  static const Set<JobStatus> _liveStates = <JobStatus>{
    JobStatus.enRoute,
    JobStatus.arrived,
    JobStatus.inProgress,
  };

  static const Set<JobStatus> _rateableStates = <JobStatus>{
    JobStatus.confirmed,
    JobStatus.settled,
    JobStatus.closed,
  };

  bool _busy = false;
  String? _transitionKey;
  String? _pinKey;

  /// A proof uploaded but not yet filed (see [_addProof]).
  ({ProofKind kind, String path, String key, DateTime capturedAt})?
  _pendingProof;

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

  /// Asks for location at the moment it is needed (just-in-time
  /// permissions), after saying why: the journey is what the customer's live
  /// map follows. Declining does not stop the journey; it only means no map.
  Future<void> _startJourney() async {
    final location = ref.read(deviceLocationProvider);
    if (await location.canAsk() && mounted) {
      final l10n = AppLocalizations.of(context);
      final share = await showSConfirmDialog(
        context: context,
        title: l10n.locationRationaleTitle,
        message: l10n.locationRationaleBody,
        confirmLabel: l10n.actionContinue,
        cancelLabel: l10n.actionNotNow,
      );
      if (share) await location.current();
    }
    if (mounted) await _transition(JobStatus.enRoute);
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

  /// Arrival is checked against the pickup geofence on the server. The
  /// device's position goes with the request; when there is none, or the
  /// server finds it outside the fence, the provider may still confirm, and
  /// the reason code travels with the transition for the dispute file.
  Future<void> _markArrived() => _run(() async {
    final reading = await ref.read(deviceLocationProvider).current();
    var reason = reading.missingReason;
    if (reason != null && !await _confirmManualArrival()) return;
    final repo = ref.read(jobProgressRepositoryProvider);
    _transitionKey ??= newIdempotencyKey();
    try {
      await repo.requestStatusChange(
        widget.jobId,
        JobStatus.arrived,
        idempotencyKey: _transitionKey!,
        location: reading.point,
        reasonCode: reason,
      );
    } on AppError catch (error) {
      if (error.code != ErrorCodes.notAtPickup || reason != null) rethrow;
      if (!await _confirmManualArrival()) return;
      reason = 'outside_geofence';
      // The refusal rolled back the server's idempotency claim, so the same
      // key is still unspent and still means this one arrival.
      await repo.requestStatusChange(
        widget.jobId,
        JobStatus.arrived,
        idempotencyKey: _transitionKey!,
        location: reading.point,
        reasonCode: reason,
      );
    }
    _transitionKey = null;
  });

  Future<bool> _confirmManualArrival() async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showSConfirmDialog(
      context: context,
      title: l10n.jobArrivalManualTitle,
      message: l10n.jobArrivalManualBody,
      confirmLabel: l10n.jobArrivalManualConfirm,
      cancelLabel: l10n.actionCancel,
    );
    return confirmed && mounted;
  }

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

  /// Captures a photo, uploads it into `job-proofs/<request id>/…`, then
  /// files it. Upload first, file second: the server refuses a path with
  /// nothing behind it (audit 2026-09-27 Y.5). A filed-but-failed proof is
  /// retried with the same path and key, never uploaded twice.
  Future<void> _addProof(ProofKind kind) async {
    var pending = _pendingProof;
    if (pending == null || pending.kind != kind) {
      final media = await captureImage(context);
      if (media == null || !mounted) return;
      await _run(() async {
        final path = await ref
            .read(mediaUploadRepositoryProvider)
            .upload(
              bucket: UploadBucket.jobProofs,
              requestId: widget.jobId,
              bytes: media.bytes,
              contentType: media.contentType,
            );
        _pendingProof = (
          kind: kind,
          path: path,
          key: newIdempotencyKey(),
          capturedAt: DateTime.now(),
        );
      });
      pending = _pendingProof;
      if (pending == null || !mounted) return;
    }
    final proof = pending;
    await _run(() async {
      await ref
          .read(jobProgressRepositoryProvider)
          .submitProof(
            jobId: widget.jobId,
            kind: proof.kind,
            storagePath: proof.path,
            idempotencyKey: proof.key,
            capturedAt: proof.capturedAt,
          );
      _pendingProof = null;
      _proofNudge = false;
      unawaited(HapticFeedback.lightImpact());
      ref.invalidate(jobProofsProvider(widget.jobId));
    });
  }

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
          data: (JobRequest request) => _LivePositionPublisher(
            jobId: widget.jobId,
            active: _liveStates.contains(request.status),
            child: _buildDetail(l10n, request),
          ),
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
        // Only from ASSIGNED (transition 12): a job still PAID_HELD is
        // waiting on assignment, and the server would refuse the tap.
        if (request.status == JobStatus.assigned)
          SButton(
            label: l10n.jobActionStartJourney,
            icon: Icons.route_outlined,
            loading: _busy,
            onPressed: _busy ? null : _startJourney,
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
            onPressed: _busy ? null : _markArrived,
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
                  Flexible(
                    child: Text(
                      l10n.ratingDoneLabel(existing.stars),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Publishes the provider's position while the job is live (ADR-0009): only
/// while this screen is open with the app in the foreground, and never
/// between jobs. Tracking in the background needs a foreground service on
/// Android and the location background mode on iOS, each a store declaration
/// of its own (RB-15 §6), so it waits for that decision.
class _LivePositionPublisher extends ConsumerStatefulWidget {
  const _LivePositionPublisher({
    required this.jobId,
    required this.active,
    required this.child,
  });

  final String jobId;
  final bool active;
  final Widget child;

  @override
  ConsumerState<_LivePositionPublisher> createState() =>
      _LivePositionPublisherState();
}

class _LivePositionPublisherState
    extends ConsumerState<_LivePositionPublisher> {
  /// The en-route ping cadence ADR-0009 sets; the server gates the heartbeat
  /// on movement as well.
  static const Duration _minInterval = Duration(seconds: 5);

  late final TrackingRepository _tracking;
  late final DeviceLocation _location;
  late final AppLogger _logger;
  StreamSubscription<LiveFix>? _positions;
  DateTime? _lastSent;

  @override
  void initState() {
    super.initState();
    _tracking = ref.read(trackingRepositoryProvider);
    _location = ref.read(deviceLocationProvider);
    _logger = ref.read(loggerProvider);
    _sync();
  }

  @override
  void didUpdateWidget(_LivePositionPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.jobId != widget.jobId) {
      _stop();
      _sync();
    }
  }

  void _sync() {
    if (widget.active && _positions == null) {
      _positions = _location.watch().listen(_publish);
    }
  }

  void _stop() {
    unawaited(_positions?.cancel());
    _positions = null;
  }

  void _publish(LiveFix fix) {
    final now = DateTime.now();
    final last = _lastSent;
    if (last != null && now.difference(last) < _minInterval) return;
    _lastSent = now;
    unawaited(
      _tracking
          .publishProviderLocation(widget.jobId, fix)
          .catchError(
            (Object error) => _logger.log(
              LogLevel.warning,
              'live position not published',
              error: error,
            ),
          ),
    );
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
