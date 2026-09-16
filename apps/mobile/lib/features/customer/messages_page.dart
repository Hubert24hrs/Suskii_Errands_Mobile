import 'package:flutter/material.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// Conversation list. The chat repository only exposes per-job message
/// streams in M1 (conversations start from an active job), so this surface
/// shows the empty state until job-linked chat lands in M4.
class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navMessages)),
      body: SEmptyState(
        icon: Icons.chat_bubble_outline,
        title: l10n.messagesEmptyTitle,
        message: l10n.messagesEmptyBody,
      ),
    );
  }
}
