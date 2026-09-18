import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// Conversation list (M4): one job-scoped chat per active job with an
/// assigned provider. Tapping opens the job chat.
class MessagesPage extends ConsumerWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final jobs = ref.watch(activeJobsProvider);
    final categories = ref.watch(categoriesProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navMessages)),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, _) => SErrorState(
          title: l10n.stateErrorGeneric,
          message: localizedError(l10n, error),
          retryLabel: l10n.actionRetry,
          onRetry: () => ref.invalidate(activeJobsProvider),
        ),
        data: (List<JobRequest> data) {
          final chatJobs = data
              .where((JobRequest j) => j.providerId != null)
              .toList();
          if (chatJobs.isEmpty) {
            return SEmptyState(
              icon: Icons.chat_bubble_outline,
              title: l10n.messagesEmptyTitle,
              message: l10n.messagesEmptyBody,
            );
          }
          return ListView.builder(
            itemCount: chatJobs.length,
            itemBuilder: (BuildContext context, int index) {
              final job = chatJobs[index];
              return ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  categoryLabel(l10n, _categoryKey(categories, job)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  job.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: SStatusChip(
                  status: job.status,
                  label: jobStatusLabel(l10n, job.status),
                ),
                onTap: () => unawaited(
                  context.push(AppRoutes.customerRequestChatPath(job.id)),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _categoryKey(List<ServiceCategory> categories, JobRequest job) {
    for (final c in categories) {
      if (c.id == job.categoryId) return c.labelKey;
    }
    return 'catCustom';
  }
}
