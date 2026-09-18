import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';

/// Job-scoped chat (M4). Text, photo, location and system messages with read
/// receipts; typing indicators and AI moderation are server-side and arrive
/// with the realtime contract — the mock renders what the stream gives it.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  /// One key per message intent (M3.14): kept on failure so a retried send
  /// replays instead of duplicating the message.
  String? _sendKey;

  Future<void> _send({
    ChatMessageType type = ChatMessageType.text,
    String? mediaPath,
    GeoPoint? location,
  }) async {
    final text = _controller.text.trim();
    if (type == ChatMessageType.text && text.isEmpty) return;
    setState(() => _busy = true);
    try {
      _sendKey ??= newIdempotencyKey();
      await ref
          .read(chatRepositoryProvider)
          .sendMessage(
            jobId: widget.jobId,
            type: type,
            idempotencyKey: _sendKey!,
            text: type == ChatMessageType.text ? text : null,
            mediaPath: mediaPath,
            location: location,
          );
      _sendKey = null;
      if (type == ChatMessageType.text) _controller.clear();
    } on Object catch (error) {
      if (mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final messages = ref.watch(chatMessagesProvider(widget.jobId));
    final myId = ref.watch(bootstrapProvider).value?.user?.id;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.chatTitle)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: messages.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, _) => SErrorState(
                  title: l10n.stateErrorGeneric,
                  message: localizedError(l10n, error),
                  retryLabel: l10n.actionRetry,
                  onRetry: () =>
                      ref.invalidate(chatMessagesProvider(widget.jobId)),
                ),
                data: (List<ChatMessage> data) {
                  if (data.isEmpty) {
                    return SEmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: l10n.chatEmpty,
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(SSpacing.lg),
                    itemCount: data.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _MessageTile(
                          message: data[index],
                          isMine: data[index].senderId == myId,
                          readLabel: l10n.chatRead,
                        ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(SSpacing.sm),
              child: Row(
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.photo_outlined),
                    tooltip: l10n.chatSendPhoto,
                    onPressed: _busy
                        ? null
                        : () => _send(
                            type: ChatMessageType.image,
                            mediaPath: 'mock://media/photo.jpg',
                          ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.place_outlined),
                    tooltip: l10n.chatSendLocation,
                    onPressed: _busy
                        ? null
                        : () => _send(
                            type: ChatMessageType.location,
                            location: const GeoPoint(
                              latitude: 6.4311,
                              longitude: 3.4359,
                            ),
                          ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: l10n.chatInputHint,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_rounded),
                    tooltip: l10n.chatSend,
                    onPressed: _busy ? null : () => _send(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.message,
    required this.isMine,
    required this.readLabel,
  });

  final ChatMessage message;
  final bool isMine;
  final String readLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.type == ChatMessageType.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: SSpacing.sm),
        child: Center(
          child: Text(
            message.text ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final scheme = theme.colorScheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: SSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: SSpacing.md,
          vertical: SSpacing.sm,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMine
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(SRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _body(theme),
            if (isMine && message.readAt != null)
              Padding(
                padding: const EdgeInsets.only(top: SSpacing.xs),
                child: Text(readLabel, style: theme.textTheme.labelSmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) => switch (message.type) {
    ChatMessageType.text || ChatMessageType.system => Text(
      message.text ?? '',
      style: theme.textTheme.bodyMedium,
    ),
    ChatMessageType.image => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.photo_outlined, size: 18),
        const SizedBox(width: SSpacing.xs),
        Flexible(
          child: Text(
            (message.mediaPath ?? '').split('/').last,
            style: theme.textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
    ChatMessageType.voiceNote => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.mic_outlined, size: 18),
        const SizedBox(width: SSpacing.xs),
        Text(
          (message.mediaPath ?? '').split('/').last,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    ),
    ChatMessageType.location => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.place_outlined, size: 18),
        const SizedBox(width: SSpacing.xs),
        Text(
          '${message.location?.latitude.toStringAsFixed(4)}, '
          '${message.location?.longitude.toStringAsFixed(4)}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    ),
    ChatMessageType.offerCard => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.handshake_outlined, size: 18),
        const SizedBox(width: SSpacing.xs),
        Text(message.offerId ?? '', style: theme.textTheme.bodyMedium),
      ],
    ),
  };
}
