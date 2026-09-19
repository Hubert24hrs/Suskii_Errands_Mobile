import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';

/// Support-ticket thread (M5). Messages stream live; AI triage replies are
/// labeled as automated. The mock's AI replies a couple of seconds after
/// every user message.
class SupportTicketPage extends ConsumerStatefulWidget {
  const SupportTicketPage({required this.ticketId, super.key});

  final String ticketId;

  @override
  ConsumerState<SupportTicketPage> createState() => _SupportTicketPageState();
}

class _SupportTicketPageState extends ConsumerState<SupportTicketPage> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  /// One key per reply intent (M3.14): kept on failure so a retried send
  /// replays instead of duplicating the reply.
  String? _sendKey;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      _sendKey ??= newIdempotencyKey();
      await ref
          .read(supportRepositoryProvider)
          .replyToTicket(widget.ticketId, text, idempotencyKey: _sendKey!);
      _sendKey = null;
      _controller.clear();
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
    final tickets = ref.watch(supportTicketsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.supportTitle)),
      body: SafeArea(
        child: tickets.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(supportTicketsProvider),
          ),
          data: (List<SupportTicket> data) {
            final ticket = data
                .where((SupportTicket t) => t.id == widget.ticketId)
                .firstOrNull;
            if (ticket == null) {
              return SEmptyState(
                icon: Icons.confirmation_number_outlined,
                title: l10n.supportEmpty,
              );
            }
            return Column(
              children: <Widget>[
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(SSpacing.lg),
                    itemCount: ticket.messages.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _SupportMessageTile(message: ticket.messages[index]),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(SSpacing.sm),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: l10n.supportReplyHint,
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send_rounded),
                        tooltip: l10n.supportSend,
                        onPressed: _busy ? null : _send,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SupportMessageTile extends StatelessWidget {
  const _SupportMessageTile({required this.message});

  final SupportMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: message.fromUser
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: SSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: SSpacing.md,
          vertical: SSpacing.sm,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: message.fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(SRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (message.aiTriage)
              Padding(
                padding: const EdgeInsets.only(bottom: SSpacing.xs),
                child: Text(
                  l10n.supportAiTriageBadge,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ),
            Text(message.body, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
