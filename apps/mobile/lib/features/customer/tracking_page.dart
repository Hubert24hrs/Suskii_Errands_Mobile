import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import 'sos_sheet.dart';

/// Live provider tracking for an active job (M4). The location stream is
/// server-pushed (Realtime Broadcast in the real backend); no map SDK ships in
/// the mock build, so a simple canvas plots pickup, destination and the live
/// provider position.
class TrackingPage extends ConsumerStatefulWidget {
  const TrackingPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends ConsumerState<TrackingPage> {
  bool _shareBusy = false;
  String? _shareKey;

  Future<void> _shareTrip() async {
    setState(() => _shareBusy = true);
    try {
      _shareKey ??= newIdempotencyKey();
      final share = await ref
          .read(safetyRepositoryProvider)
          .createTripShareLink(widget.jobId, idempotencyKey: _shareKey!);
      await Clipboard.setData(ClipboardData(text: share.url));
      if (mounted) {
        showSToast(context, AppLocalizations.of(context).sosTripShared);
      }
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _shareBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final job = ref.watch(requestDetailProvider(widget.jobId));
    final location = ref.watch(providerLocationProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.trackingTitle),
        actions: <Widget>[
          IconButton(
            icon: Icon(
              Icons.sos_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            tooltip: l10n.sosButton,
            onPressed: () => showSosSheet(context, widget.jobId),
          ),
        ],
      ),
      body: SafeArea(
        child: job.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(requestDetailProvider(widget.jobId)),
          ),
          data: (JobRequest request) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(SSpacing.lg),
                  child: Card(
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) =>
                          CustomPaint(
                            size: Size(c.maxWidth, c.maxHeight),
                            painter: _TrackingPainter(
                              pickup: request.pickup.point,
                              destination: request.destination?.point,
                              provider: location.value,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      _headline(l10n, request.status),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: SSpacing.xs),
                    Text(
                      l10n.trackingLiveHint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (location.hasError) ...<Widget>[
                      const SizedBox(height: SSpacing.xs),
                      Text(
                        localizedError(l10n, location.error!),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: SSpacing.lg),
                    SButton(
                      label: l10n.trackingShareTrip,
                      variant: SButtonVariant.secondary,
                      icon: Icons.share_outlined,
                      loading: _shareBusy,
                      onPressed: _shareBusy ? null : _shareTrip,
                    ),
                    const SizedBox(height: SSpacing.lg),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _headline(AppLocalizations l10n, JobStatus status) => switch (status) {
    JobStatus.enRoute => l10n.trackingEnRoute,
    JobStatus.arrived => l10n.trackingArrived,
    JobStatus.inProgress => l10n.trackingInProgress,
    _ => jobStatusLabel(l10n, status),
  };
}

class _TrackingPainter extends CustomPainter {
  _TrackingPainter({
    required this.pickup,
    required this.destination,
    required this.provider,
    required this.color,
  });

  final GeoPoint? pickup;
  final GeoPoint? destination;
  final GeoPoint? provider;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final points = <GeoPoint>[
      if (pickup != null) pickup!,
      if (destination != null) destination!,
      if (provider != null) provider!,
    ];
    if (points.isEmpty) return;
    final minLat = points
        .map((GeoPoint p) => p.latitude)
        .reduce((a, b) => a < b ? a : b);
    final maxLat = points
        .map((GeoPoint p) => p.latitude)
        .reduce((a, b) => a > b ? a : b);
    final minLng = points
        .map((GeoPoint p) => p.longitude)
        .reduce((a, b) => a < b ? a : b);
    final maxLng = points
        .map((GeoPoint p) => p.longitude)
        .reduce((a, b) => a > b ? a : b);
    const pad = 28.0;
    Offset project(GeoPoint p) {
      final dx = (maxLng - minLng).abs() < 1e-9
          ? 0.5
          : (p.longitude - minLng) / (maxLng - minLng);
      final dy = (maxLat - minLat).abs() < 1e-9
          ? 0.5
          : (p.latitude - minLat) / (maxLat - minLat);
      return Offset(
        pad + dx * (size.width - 2 * pad),
        size.height - pad - dy * (size.height - 2 * pad),
      );
    }

    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..strokeWidth = 2;
    if (pickup != null && destination != null) {
      canvas.drawLine(project(pickup!), project(destination!), linePaint);
    }
    final spotPaint = Paint()..color = color;
    if (pickup != null) {
      canvas.drawCircle(project(pickup!), 6, Paint()..color = Colors.green);
    }
    if (destination != null) {
      canvas.drawCircle(project(destination!), 6, Paint()..color = Colors.red);
    }
    if (provider != null) {
      final center = project(provider!);
      canvas.drawCircle(center, 12, linePaint..style = PaintingStyle.fill);
      canvas.drawCircle(center, 7, spotPaint);
    }
  }

  @override
  bool shouldRepaint(_TrackingPainter oldDelegate) =>
      oldDelegate.provider != provider;
}
