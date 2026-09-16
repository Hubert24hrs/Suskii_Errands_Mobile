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

/// Provider onboarding (step 1 of provider KYC): account kind, services,
/// service areas and vehicle. Saves via the KYC repository, then continues
/// to the checklist.
class ProviderOnboardingPage extends ConsumerStatefulWidget {
  const ProviderOnboardingPage({super.key});

  @override
  ConsumerState<ProviderOnboardingPage> createState() =>
      _ProviderOnboardingPageState();
}

class _ProviderOnboardingPageState
    extends ConsumerState<ProviderOnboardingPage> {
  final TextEditingController _businessNameController = TextEditingController();

  ProviderKind _kind = ProviderKind.individual;
  final Set<String> _categoryIds = <String>{};
  final Set<String> _areaIds = <String>{};
  VehicleType _vehicleType = VehicleType.walking;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _businessNameController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _categoryIds.isNotEmpty &&
      _areaIds.isNotEmpty &&
      (_kind == ProviderKind.individual ||
          _businessNameController.text.trim().isNotEmpty);

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(providerKycRepositoryProvider)
          .saveOnboarding(
            ProviderOnboardingInput(
              kind: _kind,
              serviceCategoryIds: _categoryIds.toList(),
              serviceAreaIds: _areaIds.toList(),
              vehicleType: _vehicleType,
              businessName: _kind == ProviderKind.business
                  ? _businessNameController.text.trim()
                  : null,
            ),
          );
      if (mounted) context.go(AppRoutes.providerKyc);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final categories = ref.watch(categoriesProvider);
    final areas =
        ref.watch(bootstrapProvider).value?.countryPack.launchCities ??
        const <String>[];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.providerOnboardingTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.xl),
          children: <Widget>[
            Text(l10n.providerKindLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            SegmentedButton<ProviderKind>(
              segments: <ButtonSegment<ProviderKind>>[
                ButtonSegment<ProviderKind>(
                  value: ProviderKind.individual,
                  label: Text(l10n.providerKindIndividual),
                  icon: const Icon(Icons.person_outline),
                ),
                ButtonSegment<ProviderKind>(
                  value: ProviderKind.business,
                  label: Text(l10n.providerKindBusiness),
                  icon: const Icon(Icons.business_outlined),
                ),
              ],
              selected: <ProviderKind>{_kind},
              onSelectionChanged: (Set<ProviderKind> selection) =>
                  setState(() => _kind = selection.first),
            ),
            if (_kind == ProviderKind.business) ...<Widget>[
              const SizedBox(height: SSpacing.lg),
              STextField(
                label: l10n.providerBusinessName,
                controller: _businessNameController,
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: SSpacing.xl),
            Text(
              l10n.providerServicesLabel,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: SSpacing.sm),
            categories.when(
              loading: () => const SSkeletonListTile(),
              error: (Object error, _) => SErrorState(
                title: l10n.stateErrorGeneric,
                message: localizedError(l10n, error),
                retryLabel: l10n.actionRetry,
                onRetry: () => ref.invalidate(categoriesProvider),
              ),
              data: (List<ServiceCategory> data) => Wrap(
                spacing: SSpacing.sm,
                runSpacing: SSpacing.sm,
                children: <Widget>[
                  for (final ServiceCategory category in data)
                    FilterChip(
                      label: Text(categoryLabel(l10n, category.labelKey)),
                      selected: _categoryIds.contains(category.id),
                      onSelected: (bool selected) => setState(() {
                        if (selected) {
                          _categoryIds.add(category.id);
                        } else {
                          _categoryIds.remove(category.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.providerAreasLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            Wrap(
              spacing: SSpacing.sm,
              runSpacing: SSpacing.sm,
              children: <Widget>[
                for (final String area in areas)
                  FilterChip(
                    label: Text(area),
                    selected: _areaIds.contains(area),
                    onSelected: (bool selected) => setState(() {
                      if (selected) {
                        _areaIds.add(area);
                      } else {
                        _areaIds.remove(area);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: SSpacing.xl),
            Text(l10n.providerVehicleLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: SSpacing.sm),
            DropdownMenu<VehicleType>(
              initialSelection: _vehicleType,
              expandedInsets: EdgeInsets.zero,
              dropdownMenuEntries: <DropdownMenuEntry<VehicleType>>[
                for (final VehicleType type in VehicleType.values)
                  DropdownMenuEntry<VehicleType>(
                    value: type,
                    label: vehicleTypeLabel(l10n, type),
                  ),
              ],
              onSelected: (VehicleType? value) {
                if (value != null) setState(() => _vehicleType = value);
              },
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: SSpacing.lg),
              Text(
                localizedError(l10n, _error!),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: SSpacing.xxl),
            SButton(
              label: l10n.actionContinue,
              loading: _busy,
              onPressed: _canSave ? () => unawaited(_save()) : null,
            ),
          ],
        ),
      ),
    );
  }
}
