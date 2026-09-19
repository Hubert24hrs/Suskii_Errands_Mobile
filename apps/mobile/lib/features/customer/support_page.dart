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

/// Help center (M5): support tickets with AI first-line triage.
class SupportPage extends ConsumerWidget {
  const SupportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tickets = ref.watch(supportTicketsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.supportTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showNewTicketSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.supportNewTicket),
      ),
      body: tickets.when(
        loading: () => ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: const <Widget>[SSkeletonListTile(), SSkeletonListTile()],
        ),
        error: (Object error, _) => ListView(
          padding: const EdgeInsets.all(SSpacing.lg),
          children: <Widget>[
            SErrorState(
              title: l10n.stateErrorGeneric,
              message: localizedError(l10n, error),
              retryLabel: l10n.actionRetry,
              onRetry: () => ref.invalidate(supportTicketsProvider),
            ),
          ],
        ),
        data: (List<SupportTicket> data) {
          if (data.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(SSpacing.lg),
              children: <Widget>[
                SEmptyState(
                  icon: Icons.support_agent_outlined,
                  title: l10n.supportEmpty,
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(SSpacing.lg),
            children: <Widget>[
              for (final SupportTicket ticket in data)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.confirmation_number_outlined),
                    title: Text(ticket.subject),
                    subtitle: Text(
                      MaterialLocalizations.of(context)
                          .formatShortDate(ticket.createdAt),
                    ),
                    trailing: Chip(
                      label: Text(
                        ticketStatusLabel(l10n, ticket.status),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    onTap: () => context.push(
                      AppRoutes.customerSupportTicketPath(ticket.id),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// New-ticket sheet: subject + body, one idempotency key per intent.
Future<void> showNewTicketSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => const NewTicketSheet(),
  );
}

class NewTicketSheet extends ConsumerStatefulWidget {
  const NewTicketSheet({super.key});

  @override
  ConsumerState<NewTicketSheet> createState() => _NewTicketSheetState();
}

class _NewTicketSheetState extends ConsumerState<NewTicketSheet> {
  final TextEditingController _subject = TextEditingController();
  final TextEditingController _body = TextEditingController();
  bool _busy = false;

  /// One key per ticket intent (M3.14).
  String? _ticketKey;

  Future<void> _submit() async {
    final subject = _subject.text.trim();
    final body = _body.text.trim();
    if (subject.isEmpty || body.isEmpty) return;
    setState(() => _busy = true);
    try {
      _ticketKey ??= newIdempotencyKey();
      await ref
          .read(supportRepositoryProvider)
          .createTicket(
            subject: subject,
            body: body,
            idempotencyKey: _ticketKey!,
          );
      _ticketKey = null;
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        Navigator.of(context).pop();
        showSToast(context, l10n.supportCreatedToast);
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
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.supportNewTicket, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.md),
            STextField(label: l10n.supportSubjectHint, controller: _subject),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.supportBodyHint,
              controller: _body,
              maxLines: 4,
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.supportCreateCta,
              loading: _busy,
              onPressed: _busy ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
