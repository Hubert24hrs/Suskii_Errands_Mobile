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

/// Optional prefill when the concierge hands off to the form (A.3) or the
/// home category grid preselects a category. Money arrives as minor units +
/// currency — the form is the ONLY place price fields are set (A.2).
class CreateRequestPrefill {
  const CreateRequestPrefill({
    this.categoryId,
    this.description,
    this.pickupLabel,
    this.preferredPrice,
  });

  final String? categoryId;
  final String? description;
  final String? pickupLabel;
  final Money? preferredPrice;
}

/// Create-request form. Creates a DRAFT first (free, verification not
/// required); publishing is a separate explicit action gated server-side by
/// customer verification (ERR_VERIFICATION_REQUIRED → /verify/customer).
class CreateRequestPage extends ConsumerStatefulWidget {
  const CreateRequestPage({super.key, this.prefill});

  final CreateRequestPrefill? prefill;

  @override
  ConsumerState<CreateRequestPage> createState() => _CreateRequestPageState();
}

class _CreateRequestPageState extends ConsumerState<CreateRequestPage> {
  final _descriptionController = TextEditingController();
  final _customCategoryController = TextEditingController();
  final _pickupController = TextEditingController();
  final _destinationController = TextEditingController();
  final _landmarkController = TextEditingController();
  final _priceController = TextEditingController();
  final _itemFloatController = TextEditingController();
  final _declaredValueController = TextEditingController();

  String? _categoryId;
  Urgency _urgency = Urgency.standard;
  DateTime? _scheduledAt;
  final List<String> _mediaPaths = <String>[];
  int? _priceMinor;
  int? _itemFloatMinor;
  int? _declaredValueMinor;
  bool _busy = false;
  String? _draftId;
  String? _createKey;
  String? _publishKey;

  @override
  void initState() {
    super.initState();
    final prefill = widget.prefill;
    if (prefill != null) {
      _categoryId = prefill.categoryId;
      _descriptionController.text = prefill.description ?? '';
      _pickupController.text = prefill.pickupLabel ?? '';
      final price = prefill.preferredPrice;
      if (price != null) {
        _priceMinor = price.minorUnits;
        // The currency's exponent decides where the point goes; a hardcoded
        // /100 shows 100x too little in a zero-exponent currency such as UGX,
        // and the field would then submit that amount back.
        final exponent = Money.exponentOf(price.currencyCode);
        var factor = 1;
        for (var i = 0; i < exponent; i++) {
          factor *= 10;
        }
        final whole = price.minorUnits ~/ factor;
        final fraction = price.minorUnits % factor;
        _priceController.text = fraction == 0
            ? '$whole'
            : '$whole.${fraction.toString().padLeft(exponent, '0')}';
      }
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _customCategoryController.dispose();
    _pickupController.dispose();
    _destinationController.dispose();
    _landmarkController.dispose();
    _priceController.dispose();
    _itemFloatController.dispose();
    _declaredValueController.dispose();
    super.dispose();
  }

  String get _currency =>
      ref.read(bootstrapProvider).value?.countryPack.currencyCode ?? 'NGN';

  bool get _isCustom => _categoryId == 'custom';

  bool get _valid =>
      _descriptionController.text.trim().isNotEmpty &&
      _pickupController.text.trim().isNotEmpty &&
      _categoryId != null &&
      (!_isCustom || _customCategoryController.text.trim().isNotEmpty);

  Money? _money(int? minor) => minor == null ? null : Money(minor, _currency);

  CreateRequestInput _input() {
    final landmark = _landmarkController.text.trim();
    return CreateRequestInput(
      categoryId: _isCustom ? 'custom' : _categoryId!,
      isCustomCategory: _isCustom,
      description: _isCustom
          ? '${_customCategoryController.text.trim()}: '
                '${_descriptionController.text.trim()}'
          : _descriptionController.text.trim(),
      mediaPaths: _mediaPaths,
      pickup: PlaceRef(
        label: _pickupController.text.trim(),
        landmarkNote: landmark.isEmpty ? null : landmark,
      ),
      destination: _destinationController.text.trim().isEmpty
          ? null
          : PlaceRef(label: _destinationController.text.trim()),
      urgency: _urgency,
      scheduledAt: _scheduledAt,
      preferredPrice: _money(_priceMinor),
      itemFloat: _money(_itemFloatMinor),
      declaredValue: _money(_declaredValueMinor),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        if (error is AppError &&
            error.code == ErrorCodes.verificationRequired) {
          showSToast(context, localizedError(l10n, error), isError: true);
          unawaited(context.push(AppRoutes.verifyCustomer));
        } else {
          showSToast(context, localizedError(l10n, error), isError: true);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<JobRequest> _ensureDraft() async {
    final existing = _draftId;
    if (existing != null) {
      return ref.read(requestRepositoryProvider).watchJob(existing).first;
    }
    // One key per intent, kept in state so a retried publish replays the
    // same create instead of making a second draft.
    _createKey ??= newIdempotencyKey();
    final draft = await ref
        .read(requestRepositoryProvider)
        .createRequest(_input(), idempotencyKey: _createKey!);
    _draftId = draft.id;
    return draft;
  }

  Future<void> _saveDraft() => _run(() async {
    final draft = await _ensureDraft();
    if (mounted) {
      showSToast(context, AppLocalizations.of(context).createDraftSavedToast);
      unawaited(context.push(AppRoutes.customerRequestDetailPath(draft.id)));
    }
  });

  Future<void> _publish() => _run(() async {
    final draft = await _ensureDraft();
    _publishKey ??= newIdempotencyKey();
    final published = await ref
        .read(requestRepositoryProvider)
        .publishRequest(draft.id, idempotencyKey: _publishKey!);
    if (mounted) {
      showSToast(context, AppLocalizations.of(context).createPublishedToast);
      unawaited(
        context.push(AppRoutes.customerRequestDetailPath(published.id)),
      );
    }
  });

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
      initialDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;
    setState(
      () => _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.createTitle)),
      body: SafeArea(
        child: categories.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.lg),
            child: Column(
              children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
            ),
          ),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(categoriesProvider),
          ),
          data: (List<ServiceCategory> cats) => _buildForm(l10n, cats),
        ),
      ),
    );
  }

  Widget _buildForm(AppLocalizations l10n, List<ServiceCategory> cats) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(SSpacing.lg),
      children: <Widget>[
        Text(l10n.createCategoryLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: SSpacing.sm),
        Wrap(
          spacing: SSpacing.sm,
          runSpacing: SSpacing.sm,
          children: cats.map((ServiceCategory c) {
            return ChoiceChip(
              label: Text(categoryLabel(l10n, c.labelKey)),
              selected: _categoryId == c.id,
              onSelected: (_) => setState(() => _categoryId = c.id),
            );
          }).toList(),
        ),
        if (_isCustom) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          STextField(
            label: l10n.createCustomCategoryLabel,
            controller: _customCategoryController,
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: SSpacing.lg),
        STextField(
          label: l10n.createDescriptionLabel,
          hint: l10n.createDescriptionHint,
          controller: _descriptionController,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.createPickupLabel,
          hint: l10n.createPickupHint,
          controller: _pickupController,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.createDestinationLabel,
          controller: _destinationController,
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.createLandmarkLabel,
          controller: _landmarkController,
        ),
        const SizedBox(height: SSpacing.lg),
        Text(l10n.createUrgencyLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: SSpacing.sm),
        Wrap(
          spacing: SSpacing.sm,
          children: Urgency.values.map((Urgency u) {
            return ChoiceChip(
              label: Text(urgencyLabel(l10n, u)),
              selected: _urgency == u,
              onSelected: (_) => setState(() => _urgency = u),
            );
          }).toList(),
        ),
        const SizedBox(height: SSpacing.lg),
        Text(l10n.createScheduleLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: SSpacing.sm),
        Wrap(
          spacing: SSpacing.sm,
          children: <Widget>[
            ChoiceChip(
              label: Text(l10n.createScheduleNow),
              selected: _scheduledAt == null,
              onSelected: (_) => setState(() => _scheduledAt = null),
            ),
            ChoiceChip(
              label: Text(
                _scheduledAt == null
                    ? l10n.createScheduleLater
                    : MaterialLocalizations.of(context)
                          .formatMediumDate(_scheduledAt!),
              ),
              selected: _scheduledAt != null,
              onSelected: (_) => _pickSchedule(),
            ),
          ],
        ),
        const SizedBox(height: SSpacing.lg),
        SMoneyField(
          label: l10n.createPreferredPriceLabel,
          currencyCode: _currency,
          controller: _priceController,
          onChangedMinorUnits: (int? minor) => _priceMinor = minor,
        ),
        if (_categoryId != null) _PriceBandHint(categoryId: _categoryId!),
        const SizedBox(height: SSpacing.md),
        SMoneyField(
          label: l10n.createItemFloatLabel,
          currencyCode: _currency,
          controller: _itemFloatController,
          onChangedMinorUnits: (int? minor) => _itemFloatMinor = minor,
        ),
        Padding(
          padding: const EdgeInsets.only(top: SSpacing.xs),
          child: Text(
            l10n.createItemFloatHint,
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: SSpacing.md),
        SMoneyField(
          label: l10n.createDeclaredValueLabel,
          currencyCode: _currency,
          controller: _declaredValueController,
          onChangedMinorUnits: (int? minor) => _declaredValueMinor = minor,
        ),
        const SizedBox(height: SSpacing.md),
        Wrap(
          spacing: SSpacing.sm,
          runSpacing: SSpacing.sm,
          children: <Widget>[
            for (final path in _mediaPaths)
              Chip(label: Text(path.split('/').last)),
            ActionChip(
              avatar: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(l10n.createPhotosAdd),
              onPressed: () => setState(
                () => _mediaPaths.add('mock://photos/${_mediaPaths.length}'),
              ),
            ),
          ],
        ),
        const SizedBox(height: SSpacing.xl),
        SButton(
          label: l10n.createPublish,
          onPressed: _valid && !_busy ? () => _publish() : null,
          loading: _busy,
        ),
        const SizedBox(height: SSpacing.sm),
        SButton(
          label: l10n.createSaveDraft,
          variant: SButtonVariant.secondary,
          onPressed: _valid && !_busy ? () => _saveDraft() : null,
        ),
      ],
    );
  }
}

/// Advisory price band next to the preferred-price field. Rules-based bands
/// are labelled a rough guide (ai-design §9); never used to set the price.
class _PriceBandHint extends ConsumerWidget {
  const _PriceBandHint({required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final band = ref.watch(priceBandProvider(categoryId));
    final theme = Theme.of(context);
    return band.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (PriceBand b) => Padding(
        padding: const EdgeInsets.only(top: SSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.priceBandTitle('${b.p25.format()} – ${b.p75.format()}'),
              style: theme.textTheme.bodySmall,
            ),
            Text(
              b.basis == PriceBandBasis.rules
                  ? l10n.priceBandRoughGuide
                  : l10n.priceBandSample(b.sampleSize),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
