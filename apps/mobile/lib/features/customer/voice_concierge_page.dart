import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Voice concierge session UI. Availability is per-language from bootstrap
/// (A.7/OD-17); the adapter is the vendor seam — no real audio until the
/// LiveKit/Gemini integration lands (S-08). Text fallback is always offered.
class VoiceConciergePage extends ConsumerStatefulWidget {
  const VoiceConciergePage({required this.conversationId, super.key});

  final String conversationId;

  @override
  ConsumerState<VoiceConciergePage> createState() => _VoiceConciergePageState();
}

class _VoiceConciergePageState extends ConsumerState<VoiceConciergePage> {
  VoiceSession? _session;
  VoiceSessionState? _state;
  Object? _error;
  final List<String> _transcript = <String>[];
  StreamSubscription<VoiceEvent>? _events;

  /// Held from initState: `ref` is unusable in dispose, which is where an
  /// abandoned session still has to be ended.
  late final VoiceConciergeAdapter _adapter;

  @override
  void initState() {
    super.initState();
    _adapter = ref.read(voiceConciergeAdapterProvider);
    unawaited(_start());
  }

  void _close() {
    if (mounted) context.leave(AppRoutes.customerConcierge);
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _state = null;
    });
    try {
      final session = await _adapter.startSession(
        widget.conversationId,
        language: Localizations.localeOf(context).languageCode,
      );
      if (!mounted) return;
      _session = session;
      _events = _adapter.events(session.sessionId).listen((VoiceEvent event) {
        if (!mounted) return;
        setState(() {
          if (event.state != null) _state = event.state;
          if (event.text != null) _transcript.add(event.text!);
        });
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _end() async {
    final session = _session;
    await _events?.cancel();
    if (session != null) {
      await _adapter.endSession(session.sessionId);
    }
    _close();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    final session = _session;
    if (session != null) {
      unawaited(_adapter.endSession(session.sessionId));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.conciergeVoice)),
      body: SafeArea(
        child: error != null
            ? SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: _start,
              )
            : Padding(
                padding: const EdgeInsets.all(SSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Spacer(),
                    Icon(
                      _state == VoiceSessionState.listening
                          ? Icons.mic
                          : Icons.mic_none,
                      size: 72,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: SSpacing.md),
                    Text(
                      _state == VoiceSessionState.listening
                          ? l10n.voiceListening
                          : l10n.voiceConnecting,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (_transcript.isNotEmpty) ...<Widget>[
                      const SizedBox(height: SSpacing.lg),
                      for (final line in _transcript)
                        Text(
                          line,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                    ],
                    const Spacer(),
                    SButton(label: l10n.voiceEnd, onPressed: _end),
                    TextButton(
                      onPressed: _close,
                      child: Text(l10n.voiceFallback),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
