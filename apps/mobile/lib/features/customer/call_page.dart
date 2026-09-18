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

/// Masked in-app call (M4). The session token is minted server-side and the
/// adapter is vendor-neutral (LiveKit at M9); this page only renders call
/// state and local audio controls. One active call per job — a second start
/// is refused with ERR_CALL_IN_PROGRESS.
class CallPage extends ConsumerStatefulWidget {
  const CallPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<CallPage> createState() => _CallPageState();
}

class _CallPageState extends ConsumerState<CallPage> {
  CallSession? _session;
  CallState _state = CallState.connecting;
  Object? _error;
  bool _muted = false;
  StreamSubscription<CallEvent>? _events;

  /// One key per call intent (M3.14).
  String? _callKey;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _state = CallState.connecting;
    });
    try {
      _callKey ??= newIdempotencyKey();
      final session = await ref
          .read(callAdapterProvider)
          .startCall(widget.jobId, idempotencyKey: _callKey!);
      if (!mounted) return;
      _session = session;
      _events = ref.read(callAdapterProvider).events(session.sessionId).listen((
        CallEvent event,
      ) {
        if (!mounted) return;
        setState(() => _state = event.state);
        if (event.state == CallState.ended) {
          context.pop();
        }
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _toggleMute() async {
    final session = _session;
    if (session == null) return;
    final next = !_muted;
    await ref
        .read(callAdapterProvider)
        .setMuted(session.sessionId, muted: next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _end() async {
    final session = _session;
    if (session == null) {
      if (mounted) context.pop();
      return;
    }
    await ref.read(callAdapterProvider).endCall(session.sessionId);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    final session = _session;
    if (session != null && _state != CallState.ended) {
      unawaited(ref.read(callAdapterProvider).endCall(session.sessionId));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.inverseSurface,
      body: SafeArea(
        child: Center(
          child: _error != null
              ? _ErrorBody(
                  message: localizedError(l10n, _error!),
                  closeLabel: l10n.actionCancel,
                  onClose: () => context.pop(),
                  onRetry: _start,
                  retryLabel: l10n.actionRetry,
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: theme.colorScheme.primary,
                      child: Icon(
                        Icons.person_outline,
                        size: 48,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                    const SizedBox(height: SSpacing.xl),
                    Text(
                      switch (_state) {
                        CallState.connecting => l10n.callConnecting,
                        CallState.ringing => l10n.callRinging,
                        CallState.active => l10n.callActive,
                        CallState.ended => l10n.callEnded,
                        CallState.failed => l10n.callFailed,
                      },
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                    const SizedBox(height: SSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SSpacing.xl,
                      ),
                      child: Text(
                        l10n.callMaskedNote,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onInverseSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: SSpacing.xxl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        IconButton.filledTonal(
                          iconSize: 32,
                          tooltip: _muted ? l10n.callUnmute : l10n.callMute,
                          onPressed: _state == CallState.active
                              ? _toggleMute
                              : null,
                          icon: Icon(_muted ? Icons.mic_off : Icons.mic_none),
                        ),
                        const SizedBox(width: SSpacing.xl),
                        IconButton.filled(
                          iconSize: 32,
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.error,
                            foregroundColor: theme.colorScheme.onError,
                          ),
                          tooltip: l10n.callEnd,
                          onPressed: _end,
                          icon: const Icon(Icons.call_end),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({
    required this.message,
    required this.closeLabel,
    required this.onClose,
    required this.onRetry,
    required this.retryLabel,
  });

  final String message;
  final String closeLabel;
  final VoidCallback onClose;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(SSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.error_outline,
            size: 48,
            color: theme.colorScheme.onInverseSurface,
          ),
          const SizedBox(height: SSpacing.lg),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
          const SizedBox(height: SSpacing.xl),
          SButton(label: retryLabel, onPressed: onRetry),
          const SizedBox(height: SSpacing.sm),
          SButton(
            label: closeLabel,
            variant: SButtonVariant.ghost,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
