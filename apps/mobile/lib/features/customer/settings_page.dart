import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/idempotency_keys.dart';
import '../../app/providers.dart';

/// Settings (M5): notification preferences with quiet hours, trusted
/// contacts (max 5), GDPR-style data export and account deletion with a
/// 30-day grace period. All of it is server-persisted via SettingsRepository.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  String _fmtMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Future<void> _updatePrefs(
    BuildContext context,
    WidgetRef ref,
    NotificationPreferences prefs,
  ) async {
    try {
      // Each toggle is a fresh intent, so a fresh key per call is correct.
      await ref
          .read(settingsRepositoryProvider)
          .updateNotificationPreferences(
            prefs,
            idempotencyKey: newIdempotencyKey(),
          );
      ref.invalidate(notificationPrefsProvider);
      if (context.mounted) {
        showSToast(context, AppLocalizations.of(context).settingsSaved);
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

  Future<void> _pickQuietHours(
    BuildContext context,
    WidgetRef ref,
    NotificationPreferences prefs,
  ) async {
    final l10n = AppLocalizations.of(context);
    int? startHour = prefs.quietStartMinutes == null
        ? null
        : prefs.quietStartMinutes! ~/ 60;
    int? endHour = prefs.quietEndMinutes == null
        ? null
        : prefs.quietEndMinutes! ~/ 60;
    final saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) set) {
          DropdownButton<int?> hourDropdown(
            int? value,
            ValueChanged<int?> onChanged,
          ) {
            return DropdownButton<int?>(
              value: value,
              hint: Text(l10n.settingsQuietOff),
              items: <DropdownMenuItem<int?>>[
                DropdownMenuItem<int?>(child: Text(l10n.settingsQuietOff)),
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem<int?>(
                    value: h,
                    child: Text('${h.toString().padLeft(2, '0')}:00'),
                  ),
              ],
              onChanged: onChanged,
            );
          }

          return AlertDialog(
            title: Text(l10n.settingsQuietHours),
            content: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(l10n.settingsQuietFrom),
                      hourDropdown(
                        startHour,
                        (int? v) => set(() => startHour = v),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(l10n.settingsQuietTo),
                      hourDropdown(endHour, (int? v) => set(() => endHour = v)),
                    ],
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.settingsSaved),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true || !context.mounted) return;
    await _updatePrefs(
      context,
      ref,
      prefs.copyWith(
        quietStartMinutes: startHour == null ? null : startHour! * 60,
        quietEndMinutes: endHour == null ? null : endHour! * 60,
      ),
    );
  }

  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    // One export per intent (M3.14): a retry after a timeout should return
    // the first export rather than queue a second one.
    final keys = ref.read(idempotencyKeysProvider);
    const intent = 'settings.exportData';
    try {
      final exportRef = await ref
          .read(settingsRepositoryProvider)
          .requestDataExport(idempotencyKey: keys.forIntent(intent));
      keys.done(intent);
      if (context.mounted) {
        showSToast(context, l10n.settingsExportRequested(exportRef));
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(context, localizedError(l10n, error), isError: true);
      }
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showSConfirmDialog(
      context: context,
      title: l10n.settingsDeleteConfirmTitle,
      message: l10n.settingsDeleteConfirmBody,
      confirmLabel: l10n.settingsDeleteAccount,
      cancelLabel: l10n.actionCancel,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final keys = ref.read(idempotencyKeysProvider);
    const intent = 'settings.deleteAccount';
    try {
      final when = await ref
          .read(settingsRepositoryProvider)
          .requestAccountDeletion(idempotencyKey: keys.forIntent(intent));
      keys.done(intent);
      if (context.mounted) {
        showSToast(
          context,
          l10n.settingsDeleteScheduled(
            MaterialLocalizations.of(context).formatShortDate(when),
          ),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        showSToast(context, localizedError(l10n, error), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final prefs = ref.watch(notificationPrefsProvider);
    final contacts = ref.watch(trustedContactsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(SSpacing.lg),
        children: <Widget>[
          Text(l10n.settingsNotifications, style: theme.textTheme.titleMedium),
          const SizedBox(height: SSpacing.sm),
          prefs.when(
            loading: () => const SSkeletonListTile(),
            error: (Object error, _) => SErrorState(
              title: l10n.stateErrorGeneric,
              message: localizedError(l10n, error),
              retryLabel: l10n.actionRetry,
              onRetry: () => ref.invalidate(notificationPrefsProvider),
            ),
            data: (NotificationPreferences data) => Card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    title: Text(l10n.settingsPush),
                    value: data.push,
                    onChanged: (bool v) => unawaited(
                      _updatePrefs(context, ref, data.copyWith(push: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l10n.settingsSms),
                    value: data.sms,
                    onChanged: (bool v) => unawaited(
                      _updatePrefs(context, ref, data.copyWith(sms: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l10n.settingsEmail),
                    value: data.email,
                    onChanged: (bool v) => unawaited(
                      _updatePrefs(context, ref, data.copyWith(email: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l10n.settingsMarketing),
                    value: data.marketing,
                    onChanged: (bool v) => unawaited(
                      _updatePrefs(context, ref, data.copyWith(marketing: v)),
                    ),
                  ),
                  ListTile(
                    title: Text(l10n.settingsQuietHours),
                    subtitle: Text(
                      data.quietStartMinutes == null ||
                              data.quietEndMinutes == null
                          ? l10n.settingsQuietOff
                          : '${l10n.settingsQuietFrom} '
                                '${_fmtMinutes(data.quietStartMinutes!)} · '
                                '${l10n.settingsQuietTo} '
                                '${_fmtMinutes(data.quietEndMinutes!)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(_pickQuietHours(context, ref, data)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SSpacing.xl),

          Text(
            l10n.settingsTrustedContacts,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: SSpacing.sm),
          contacts.when(
            loading: () => const SSkeletonListTile(),
            error: (Object error, _) => SErrorState(
              title: l10n.stateErrorGeneric,
              message: localizedError(l10n, error),
              retryLabel: l10n.actionRetry,
              onRetry: () => ref.invalidate(trustedContactsProvider),
            ),
            data: (List<TrustedContact> data) => Card(
              child: Column(
                children: <Widget>[
                  if (data.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Text(
                        l10n.settingsTrustedEmpty,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final TrustedContact contact in data)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(contact.name),
                      subtitle: Text(contact.phoneE164),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final keys = ref.read(idempotencyKeysProvider);
                          final intent = 'settings.removeContact:${contact.id}';
                          try {
                            await ref
                                .read(settingsRepositoryProvider)
                                .removeTrustedContact(
                                  contact.id,
                                  idempotencyKey: keys.forIntent(intent),
                                );
                            keys.done(intent);
                            ref.invalidate(trustedContactsProvider);
                          } on Object catch (error) {
                            if (context.mounted) {
                              showSToast(
                                context,
                                localizedError(l10n, error),
                                isError: true,
                              );
                            }
                          }
                        },
                      ),
                    ),
                  const Divider(height: 1),
                  if (data.length >= 5)
                    Padding(
                      padding: const EdgeInsets.all(SSpacing.lg),
                      child: Text(
                        l10n.settingsContactLimitReached,
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.person_add_outlined),
                      title: Text(l10n.settingsAddContact),
                      onTap: () => showAddContactSheet(context),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SSpacing.xl),

          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l10n.settingsDataExport),
                  onTap: () => unawaited(_exportData(context, ref)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    l10n.settingsDeleteAccount,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: () => unawaited(_deleteAccount(context, ref)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Add-trusted-contact sheet.
Future<void> showAddContactSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => const AddContactSheet(),
  );
}

class AddContactSheet extends ConsumerStatefulWidget {
  const AddContactSheet({super.key});

  @override
  ConsumerState<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends ConsumerState<AddContactSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  bool _busy = false;

  /// One key per add-contact intent (M3.14).
  String? _addKey;

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty || phone.isEmpty) return;
    setState(() => _busy = true);
    try {
      _addKey ??= newIdempotencyKey();
      await ref
          .read(settingsRepositoryProvider)
          .addTrustedContact(
            name: name,
            phoneE164: phone,
            idempotencyKey: _addKey!,
          );
      _addKey = null;
      ref.invalidate(trustedContactsProvider);
      if (mounted) Navigator.of(context).pop();
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
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: SSpacing.lg,
          right: SSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.settingsAddContact, style: theme.textTheme.titleLarge),
            const SizedBox(height: SSpacing.md),
            STextField(label: l10n.settingsContactName, controller: _name),
            const SizedBox(height: SSpacing.md),
            STextField(
              label: l10n.settingsContactPhone,
              controller: _phone,
              keyboardType: TextInputType.phone,
              hint: '+234…',
            ),
            const SizedBox(height: SSpacing.lg),
            SButton(
              label: l10n.settingsAddContact,
              loading: _busy,
              onPressed: _busy ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
