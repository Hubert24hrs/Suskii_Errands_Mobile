import 'dart:async';

import 'package:flutter/material.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/labels.dart';

/// The one way the app picks services (2026-11-03): a field that opens a
/// searchable list of every active service. Customers pick one for a request;
/// providers pick the ones they offer. Both read the same catalogue, so a
/// service an admin adds appears in both without an app release.
class ServicePickerField extends StatelessWidget {
  const ServicePickerField({
    required this.categories,
    required this.selectedId,
    required this.onChanged,
    super.key,
  });

  /// The whole catalogue; inactive services are left out of the list.
  final List<ServiceCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    ServiceCategory? selected;
    for (final c in categories) {
      if (c.id == selectedId) selected = c;
    }

    Future<void> open() async {
      final picked = await showServicePickerSheet(
        context,
        categories: categories,
        selectedIds: <String>{?selectedId},
        multiple: false,
      );
      if (picked != null && picked.isNotEmpty) onChanged(picked.first);
    }

    if (selected == null) {
      return _FieldFrame(
        key: const Key('service-picker-field'),
        onTap: () => unawaited(open()),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: SSpacing.sm),
            Expanded(
              child: Text(
                l10n.servicePickerPlaceholder,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      );
    }

    final description = serviceDescription(l10n, selected);
    return _FieldFrame(
      key: const Key('service-picker-field'),
      onTap: () => unawaited(open()),
      selected: true,
      child: Row(
        children: <Widget>[
          Icon(serviceIcon(selected.iconKey), color: theme.colorScheme.primary),
          const SizedBox(width: SSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  serviceName(l10n, selected),
                  style: theme.textTheme.titleSmall,
                ),
                if (description != null)
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            key: const Key('service-picker-change'),
            onPressed: () => unawaited(open()),
            child: Text(l10n.servicePickerChange),
          ),
          IconButton(
            key: const Key('service-picker-remove'),
            tooltip: l10n.servicePickerRemove,
            icon: const Icon(Icons.close),
            onPressed: () => onChanged(null),
          ),
        ],
      ),
    );
  }
}

/// The provider's version: several services, shown as removable chips.
class ServiceMultiPickerField extends StatelessWidget {
  const ServiceMultiPickerField({
    required this.categories,
    required this.selectedIds,
    required this.onChanged,
    super.key,
  });

  final List<ServiceCategory> categories;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final selected = <ServiceCategory>[
      for (final c in categories)
        if (selectedIds.contains(c.id)) c,
    ];

    Future<void> open() async {
      final picked = await showServicePickerSheet(
        context,
        categories: categories,
        selectedIds: selectedIds,
        multiple: true,
      );
      if (picked != null) onChanged(picked);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FieldFrame(
          key: const Key('service-picker-field'),
          onTap: () => unawaited(open()),
          selected: selected.isNotEmpty,
          child: Row(
            children: <Widget>[
              Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: SSpacing.sm),
              Expanded(
                child: Text(
                  selected.isEmpty
                      ? l10n.servicePickerProviderPlaceholder
                      : l10n.servicePickerSelectedCount(selected.length),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: selected.isEmpty
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        if (selected.isNotEmpty) ...<Widget>[
          const SizedBox(height: SSpacing.sm),
          Wrap(
            spacing: SSpacing.xs,
            runSpacing: SSpacing.xs,
            children: <Widget>[
              for (final c in selected)
                InputChip(
                  avatar: Icon(serviceIcon(c.iconKey), size: 18),
                  label: Text(serviceName(l10n, c)),
                  deleteButtonTooltipMessage: l10n.servicePickerRemove,
                  onDeleted: () =>
                      onChanged(<String>{...selectedIds}..remove(c.id)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _FieldFrame extends StatelessWidget {
  const _FieldFrame({
    required this.child,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SSpacing.md,
                vertical: SSpacing.xs,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the searchable list. Returns the chosen ids, or null when dismissed.
Future<Set<String>?> showServicePickerSheet(
  BuildContext context, {
  required List<ServiceCategory> categories,
  required Set<String> selectedIds,
  required bool multiple,
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (BuildContext context) => _ServicePickerSheet(
    categories: <ServiceCategory>[
      for (final c in categories)
        if (c.active) c,
    ],
    initial: selectedIds,
    multiple: multiple,
  ),
);

class _ServicePickerSheet extends StatefulWidget {
  const _ServicePickerSheet({
    required this.categories,
    required this.initial,
    required this.multiple,
  });

  final List<ServiceCategory> categories;
  final Set<String> initial;
  final bool multiple;

  @override
  State<_ServicePickerSheet> createState() => _ServicePickerSheetState();
}

class _ServicePickerSheetState extends State<_ServicePickerSheet> {
  final TextEditingController _search = TextEditingController();
  late final Set<String> _chosen = <String>{...widget.initial};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(AppLocalizations l10n, ServiceCategory c) {
    if (_query.isEmpty) return true;
    final haystack = <String>[
      serviceName(l10n, c),
      serviceDescription(l10n, c) ?? '',
      ...c.displayNames.values,
      c.id.replaceAll('_', ' '),
    ].join(' ').toLowerCase();
    return _query
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .every(haystack.contains);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shown = <ServiceCategory>[
      for (final c in widget.categories)
        if (_matches(l10n, c)) c,
    ];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) => Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SSpacing.lg,
              0,
              SSpacing.lg,
              SSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  l10n.servicesAllAvailable,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: SSpacing.sm),
                TextField(
                  key: const Key('service-picker-search'),
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: (String v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: l10n.servicePickerSearch,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: MaterialLocalizations.of(context)
                                .deleteButtonTooltip,
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? SEmptyState(
                    icon: Icons.search_off,
                    title: l10n.servicePickerEmpty(_search.text.trim()),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: shown.length,
                    itemBuilder: (BuildContext context, int i) {
                      final c = shown[i];
                      final description = serviceDescription(l10n, c);
                      final chosen = _chosen.contains(c.id);
                      return ListTile(
                        key: Key('service-option-${c.id}'),
                        leading: Icon(serviceIcon(c.iconKey)),
                        title: Text(serviceName(l10n, c)),
                        subtitle: description == null
                            ? null
                            : Text(
                                description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        selected: chosen,
                        trailing: widget.multiple
                            ? Checkbox(
                                value: chosen,
                                onChanged: (_) => _toggle(c.id),
                              )
                            : (chosen ? const Icon(Icons.check) : null),
                        onTap: () {
                          if (widget.multiple) {
                            _toggle(c.id);
                          } else {
                            Navigator.of(context).pop(<String>{c.id});
                          }
                        },
                      );
                    },
                  ),
          ),
          if (widget.multiple)
            Padding(
              padding: const EdgeInsets.all(SSpacing.md),
              child: SButton(
                key: const Key('service-picker-done'),
                label: _chosen.isEmpty
                    ? l10n.servicePickerDone
                    : '${l10n.servicePickerDone} · '
                          '${l10n.servicePickerSelectedCount(_chosen.length)}',
                onPressed: () => Navigator.of(context).pop(_chosen),
              ),
            ),
        ],
      ),
    );
  }

  void _toggle(String id) => setState(() {
    if (!_chosen.remove(id)) _chosen.add(id);
  });
}
