import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/idempotency_keys.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Business console (M6): organization overview, team members, vehicles and
/// job dispatch. Member earnings are already redacted server-side (null for
/// non-owners) — the page only renders what it is given.
class OrganizationPage extends ConsumerWidget {
  const OrganizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final org = ref.watch(myOrganizationProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.orgTitle)),
      body: switch (org) {
        AsyncData(:final value) =>
          value == null
              ? SEmptyState(
                  icon: Icons.business_outlined,
                  title: l10n.orgNotAvailable,
                )
              : _OrgBody(organization: value),
        AsyncError(:final error) => SErrorState(
          title: l10n.stateErrorGeneric,
          message: localizedError(l10n, error),
          retryLabel: l10n.actionRetry,
          onRetry: () => ref.invalidate(myOrganizationProvider),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _OrgBody extends ConsumerWidget {
  const _OrgBody({required this.organization});

  final Organization organization;

  Future<void> _inviteMember(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final phoneController = TextEditingController();
    var role = BusinessRole.worker;

    final invited = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: SSpacing.lg,
              right: SSpacing.lg,
              bottom:
                  MediaQuery.of(sheetContext).viewInsets.bottom + SSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  l10n.orgInvite,
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: SSpacing.lg),
                STextField(
                  label: l10n.orgInvitePhone,
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: SSpacing.md),
                SegmentedButton<BusinessRole>(
                  segments: <ButtonSegment<BusinessRole>>[
                    ButtonSegment<BusinessRole>(
                      value: BusinessRole.dispatcher,
                      label: Text(
                        businessRoleLabel(l10n, BusinessRole.dispatcher),
                      ),
                    ),
                    ButtonSegment<BusinessRole>(
                      value: BusinessRole.worker,
                      label: Text(businessRoleLabel(l10n, BusinessRole.worker)),
                    ),
                  ],
                  selected: <BusinessRole>{role},
                  onSelectionChanged: (selection) =>
                      setState(() => role = selection.first),
                ),
                const SizedBox(height: SSpacing.lg),
                SButton(
                  label: l10n.orgInviteSend,
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (invited != true || !context.mounted) return;
    // Keyed per phone number, not per screen (M3.14): two invitations can be
    // in flight, and they are different intents.
    final keys = ref.read(idempotencyKeysProvider);
    final phone = phoneController.text.trim();
    final intent = 'org.invite:$phone';
    try {
      await ref
          .read(organizationRepositoryProvider)
          .inviteMember(
            phoneE164: phone,
            role: role,
            idempotencyKey: keys.forIntent(intent),
          );
      keys.done(intent);
      ref.invalidate(orgMembersProvider);
      if (context.mounted) {
        showSToast(context, l10n.orgInviteSent);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    OrgMember member,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showSConfirmDialog(
      context: context,
      title: l10n.orgRemoveMemberTitle,
      message: l10n.orgRemoveMemberBody,
      confirmLabel: l10n.orgRemoveMember,
      cancelLabel: l10n.actionCancel,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final keys = ref.read(idempotencyKeysProvider);
    final intent = 'org.removeMember:${member.userId}';
    try {
      await ref
          .read(organizationRepositoryProvider)
          .removeMember(member.userId, idempotencyKey: keys.forIntent(intent));
      keys.done(intent);
      ref.invalidate(orgMembersProvider);
      if (context.mounted) {
        showSToast(context, l10n.orgMemberRemoved);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  Future<void> _addVehicle(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final plateController = TextEditingController();
    var type = VehicleType.motorcycle;

    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: SSpacing.lg,
              right: SSpacing.lg,
              bottom:
                  MediaQuery.of(sheetContext).viewInsets.bottom + SSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  l10n.orgVehicleAdd,
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: SSpacing.lg),
                Wrap(
                  spacing: SSpacing.sm,
                  children: <Widget>[
                    for (final t in VehicleType.values)
                      ChoiceChip(
                        label: Text(vehicleTypeLabel(l10n, t)),
                        selected: type == t,
                        onSelected: (_) => setState(() => type = t),
                      ),
                  ],
                ),
                const SizedBox(height: SSpacing.md),
                STextField(
                  label: l10n.orgVehiclePlate,
                  controller: plateController,
                ),
                const SizedBox(height: SSpacing.lg),
                SButton(
                  label: l10n.orgVehicleSave,
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (added != true || !context.mounted) return;
    final keys = ref.read(idempotencyKeysProvider);
    final plate = plateController.text.trim();
    final intent = 'org.addVehicle:$plate';
    try {
      await ref
          .read(organizationRepositoryProvider)
          .upsertVehicle(
            Vehicle(
              id: 'veh-${DateTime.now().millisecondsSinceEpoch}',
              organizationId: '',
              type: type,
              plate: plate,
            ),
            idempotencyKey: keys.forIntent(intent),
          );
      keys.done(intent);
      ref.invalidate(orgVehiclesProvider);
      if (context.mounted) {
        showSToast(context, l10n.orgVehicleSaved);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  /// Bottom sheet listing verified workers; returns the picked user id.
  Future<String?> _pickWorker(
    BuildContext context,
    WidgetRef ref,
    String title,
  ) async {
    final l10n = AppLocalizations.of(context);
    final members = await ref.read(orgMembersProvider.future);
    if (!context.mounted) return null;
    final workers = members
        .where(
          (m) =>
              m.role == BusinessRole.worker &&
              m.verificationStatus == VerificationStatus.verified,
        )
        .toList();
    if (workers.isEmpty) {
      showSToast(context, l10n.orgNoVerifiedWorkers, isError: true);
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(SSpacing.lg),
              child: Text(
                title,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final worker in workers)
              ListTile(
                leading: const Icon(Icons.engineering_outlined),
                title: Text(worker.displayName),
                onTap: () => Navigator.of(sheetContext).pop(worker.userId),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _assignVehicle(
    BuildContext context,
    WidgetRef ref,
    Vehicle vehicle,
  ) async {
    final l10n = AppLocalizations.of(context);
    final workerId = await _pickWorker(context, ref, l10n.orgVehicleAssign);
    if (workerId == null || !context.mounted) return;
    final keys = ref.read(idempotencyKeysProvider);
    final intent = 'org.assignVehicle:${vehicle.id}:$workerId';
    try {
      await ref
          .read(organizationRepositoryProvider)
          .assignVehicle(
            vehicle.id,
            workerId,
            idempotencyKey: keys.forIntent(intent),
          );
      keys.done(intent);
      ref.invalidate(orgVehiclesProvider);
      if (context.mounted) {
        showSToast(context, l10n.orgVehicleSaved);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  Future<void> _dispatchJob(
    BuildContext context,
    WidgetRef ref,
    JobRequest job,
  ) async {
    final l10n = AppLocalizations.of(context);
    final workerId = await _pickWorker(
      context,
      ref,
      l10n.orgDispatchPickWorker,
    );
    if (workerId == null || !context.mounted) return;
    final keys = ref.read(idempotencyKeysProvider);
    final intent = 'org.dispatchJob:${job.id}:$workerId';
    try {
      await ref
          .read(organizationRepositoryProvider)
          .assignJob(
            jobId: job.id,
            workerId: workerId,
            idempotencyKey: keys.forIntent(intent),
          );
      keys.done(intent);
      ref.invalidate(orgAssignableJobsProvider);
      if (context.mounted) {
        showSToast(context, l10n.orgDispatchAssigned);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(
          context,
          localizedError(AppLocalizations.of(context), error),
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final membersAsync = ref.watch(orgMembersProvider);
    final vehiclesAsync = ref.watch(orgVehiclesProvider);
    final jobsAsync = ref.watch(orgAssignableJobsProvider);
    final members = membersAsync.value ?? const <OrgMember>[];
    final vehicles = vehiclesAsync.value ?? const <Vehicle>[];
    final jobs = jobsAsync.value ?? const <JobRequest>[];
    final memberNames = <String, String>{
      for (final m in members) m.userId: m.displayName,
    };

    return ListView(
      padding: const EdgeInsets.all(SSpacing.lg),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(SSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(organization.name, style: theme.textTheme.titleLarge),
                const SizedBox(height: SSpacing.sm),
                Wrap(
                  spacing: SSpacing.sm,
                  children: <Widget>[
                    Chip(
                      label: Text(
                        verificationStatusLabel(
                          l10n,
                          organization.verificationStatus,
                        ),
                      ),
                    ),
                    Chip(
                      label: Text(
                        organization.payoutAccountSet
                            ? l10n.orgPayoutReady
                            : l10n.orgPayoutMissing,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SSpacing.sm),
                Text(
                  l10n.orgMembersCount(organization.memberCount),
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  l10n.orgVehiclesCount(organization.activeVehicleCount),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: SSpacing.lg),
        _SectionHeader(
          title: l10n.orgMembers,
          actionLabel: l10n.orgInvite,
          onAction: () => _inviteMember(context, ref),
        ),
        if (membersAsync.isLoading && members.isEmpty)
          const SSkeletonListTile()
        else if (membersAsync.hasError && members.isEmpty)
          SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, membersAsync.error!),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(orgMembersProvider),
          )
        else if (members.isEmpty)
          SEmptyState(icon: Icons.group_outlined, title: l10n.orgMembersEmpty)
        else
          for (final member in members) ...<Widget>[
            _memberTile(context, ref, member, theme, locale),
            const SizedBox(height: SSpacing.sm),
          ],
        const SizedBox(height: SSpacing.lg),
        _SectionHeader(
          title: l10n.orgVehicles,
          actionLabel: l10n.orgVehicleAdd,
          onAction: () => _addVehicle(context, ref),
        ),
        if (vehiclesAsync.isLoading && vehicles.isEmpty)
          const SSkeletonListTile()
        else if (vehiclesAsync.hasError && vehicles.isEmpty)
          SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, vehiclesAsync.error!),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(orgVehiclesProvider),
          )
        else if (vehicles.isEmpty)
          SEmptyState(
            icon: Icons.two_wheeler_outlined,
            title: l10n.orgVehiclesEmpty,
          )
        else
          for (final vehicle in vehicles) ...<Widget>[
            _vehicleTile(context, ref, vehicle, memberNames, theme, l10n),
            const SizedBox(height: SSpacing.sm),
          ],
        const SizedBox(height: SSpacing.lg),
        _SectionHeader(title: l10n.orgDispatch),
        if (jobsAsync.isLoading && jobs.isEmpty)
          const SSkeletonListTile()
        else if (jobsAsync.hasError && jobs.isEmpty)
          SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, jobsAsync.error!),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(orgAssignableJobsProvider),
          )
        else if (jobs.isEmpty)
          SEmptyState(
            icon: Icons.local_shipping_outlined,
            title: l10n.orgDispatchEmpty,
          )
        else
          for (final job in jobs) ...<Widget>[
            _jobTile(context, ref, job, theme, locale, l10n),
            const SizedBox(height: SSpacing.sm),
          ],
      ],
    );
  }

  Widget _memberTile(
    BuildContext context,
    WidgetRef ref,
    OrgMember member,
    ThemeData theme,
    String locale,
  ) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(member.displayName, style: theme.textTheme.titleSmall),
                  const SizedBox(height: SSpacing.xs),
                  Text(
                    l10n.orgMemberJobs(member.jobsCompleted),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (member.earningsToDate != null)
                    Text(
                      l10n.orgMemberEarnings(
                        member.earningsToDate!.format(locale: locale),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Chip(label: Text(businessRoleLabel(l10n, member.role))),
            if (member.role != BusinessRole.owner)
              IconButton(
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: l10n.orgRemoveMember,
                onPressed: () => _removeMember(context, ref, member),
              ),
          ],
        ),
      ),
    );
  }

  Widget _vehicleTile(
    BuildContext context,
    WidgetRef ref,
    Vehicle vehicle,
    Map<String, String> memberNames,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final expiry = vehicle.documentExpiry;
    final daysLeft = expiry?.difference(DateTime.now()).inDays;
    final expiringSoon = daysLeft != null && daysLeft <= 30;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${vehicleTypeLabel(l10n, vehicle.type)} · '
                    '${vehicle.plate}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: SSpacing.xs),
                  Text(
                    vehicle.assignedWorkerId == null
                        ? l10n.orgVehicleUnassigned
                        : memberNames[vehicle.assignedWorkerId] ??
                              vehicle.assignedWorkerId!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (expiry != null)
                    Text(
                      expiringSoon
                          ? l10n.orgVehicleExpiryWarning(daysLeft)
                          : l10n.orgVehicleExpiry(_fmtDate(expiry)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: expiringSoon
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.assignment_ind_outlined),
              tooltip: l10n.orgVehicleAssign,
              onPressed: () => _assignVehicle(context, ref, vehicle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobTile(
    BuildContext context,
    WidgetRef ref,
    JobRequest job,
    ThemeData theme,
    String locale,
    AppLocalizations l10n,
  ) {
    final price = job.agreedPrice ?? job.preferredPrice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.lg),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    job.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (price != null) ...<Widget>[
                    const SizedBox(height: SSpacing.xs),
                    Text(
                      price.format(locale: locale),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: SSpacing.sm),
            SButton(
              label: l10n.orgDispatchAssign,
              variant: SButtonVariant.secondary,
              expand: false,
              onPressed: () => _dispatchJob(context, ref, job),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
