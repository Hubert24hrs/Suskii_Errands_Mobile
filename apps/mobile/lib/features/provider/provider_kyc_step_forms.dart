import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

const List<String> _idTypes = <String>[
  'nin',
  'bvn',
  'votersCard',
  'driversLicence',
  'passport',
];

/// Simulated upload: produces an opaque upload reference (signed-URL upload
/// arrives with the real backend; clients never read KYC files back).
String _newUploadRef() =>
    'upload://mock/${DateTime.now().millisecondsSinceEpoch}';

/// Per-step KYC form, shown in a modal sheet from the checklist. Builds the
/// typed input for [kind] and submits via the KYC repository — the mock
/// "server" validates and moves the step to in-review (or rejects it).
class KycStepForm extends ConsumerStatefulWidget {
  const KycStepForm({required this.kind, super.key});

  final KycStepKind kind;

  @override
  ConsumerState<KycStepForm> createState() => _KycStepFormState();
}

class _KycStepFormState extends ConsumerState<KycStepForm> {
  final TextEditingController _idNumber = TextEditingController();
  final TextEditingController _certNumber = TextEditingController();
  final TextEditingController _line1 = TextEditingController();
  final TextEditingController _line2 = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _state = TextEditingController();
  final TextEditingController _landmark = TextEditingController();
  final TextEditingController _guarantorName = TextEditingController();
  final TextEditingController _guarantorPhone = TextEditingController();
  final TextEditingController _guarantorRelationship = TextEditingController();
  final TextEditingController _bankCode = TextEditingController();
  final TextEditingController _accountNumber = TextEditingController();
  final TextEditingController _credentialsDescription = TextEditingController();

  String _idType = _idTypes.first;
  DateTime? _issueDate;
  DateTime? _expiryDate;
  bool _criminalConsent = false;
  String? _idUploadRef;
  String? _policeUploadRef;
  String? _licenceRef;
  String? _registrationRef;
  String? _insuranceRef;
  final List<String> _credentialRefs = <String>[];
  PayoutAccountResult? _payoutResult;
  bool _livenessBusy = false;
  String? _livenessFailureKey;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _idNumber.dispose();
    _certNumber.dispose();
    _line1.dispose();
    _line2.dispose();
    _city.dispose();
    _state.dispose();
    _landmark.dispose();
    _guarantorName.dispose();
    _guarantorPhone.dispose();
    _guarantorRelationship.dispose();
    _bankCode.dispose();
    _accountNumber.dispose();
    _credentialsDescription.dispose();
    super.dispose();
  }

  Future<void> _submit(Object input) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(providerKycRepositoryProvider)
          .submitStep(widget.kind, input);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolvePayout() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(providerKycRepositoryProvider)
          .resolvePayoutAccount(
            PayoutAccountInput(
              bankCode: _bankCode.text.trim(),
              accountNumber: _accountNumber.text.trim(),
            ),
          );
      if (mounted) setState(() => _payoutResult = result);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _captureProviderFacial() async {
    setState(() {
      _livenessBusy = true;
      _error = null;
      _livenessFailureKey = null;
    });
    try {
      final adapter = ref.read(identityVerificationAdapterProvider);
      final session = await adapter.startLivenessSession();
      final result = await adapter.captureLiveness(session.sessionId);
      if (!mounted) return;
      if (result.outcome == IdentityCheckOutcome.success) {
        await _submit(session.sessionId);
      } else {
        setState(() => _livenessFailureKey = result.reasonKey);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _livenessBusy = false);
    }
  }

  Future<void> _pickDate({required bool isIssue}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isIssue) {
        _issueDate = picked;
      } else {
        _expiryDate = picked;
      }
    });
  }

  bool get _canSubmit => switch (widget.kind) {
    KycStepKind.governmentId => _idNumber.text.trim().isNotEmpty,
    KycStepKind.providerFacial => false, // submits via the capture button
    KycStepKind.idDocumentCapture =>
      _idNumber.text.trim().isNotEmpty && _idUploadRef != null,
    KycStepKind.policeClearance =>
      _certNumber.text.trim().isNotEmpty &&
          _issueDate != null &&
          _expiryDate != null &&
          _policeUploadRef != null &&
          _criminalConsent,
    KycStepKind.address =>
      _line1.text.trim().isNotEmpty &&
          _city.text.trim().isNotEmpty &&
          _state.text.trim().isNotEmpty,
    KycStepKind.guarantor =>
      _guarantorName.text.trim().isNotEmpty &&
          _guarantorPhone.text.trim().isNotEmpty &&
          _guarantorRelationship.text.trim().isNotEmpty,
    KycStepKind.payoutAccount => _payoutResult != null,
    KycStepKind.vehicleDocuments =>
      _licenceRef != null && _registrationRef != null,
    KycStepKind.credentials =>
      _credentialsDescription.text.trim().isNotEmpty &&
          _credentialRefs.isNotEmpty,
    KycStepKind.customerFacial => false,
  };

  Object _buildInput() => switch (widget.kind) {
    KycStepKind.governmentId => IdDocumentInput(
      idType: _idType,
      idNumber: _idNumber.text.trim(),
    ),
    KycStepKind.idDocumentCapture => IdDocumentInput(
      idType: _idType,
      idNumber: _idNumber.text.trim(),
      uploadRef: _idUploadRef,
    ),
    KycStepKind.policeClearance => PoliceClearanceInput(
      certificateNumber: _certNumber.text.trim(),
      issueDate: _issueDate!,
      expiryDate: _expiryDate!,
      uploadRef: _policeUploadRef!,
    ),
    KycStepKind.address => AddressInput(
      line1: _line1.text.trim(),
      line2: _line2.text.trim().isEmpty ? null : _line2.text.trim(),
      city: _city.text.trim(),
      state: _state.text.trim(),
      landmarkNote: _landmark.text.trim().isEmpty
          ? null
          : _landmark.text.trim(),
    ),
    KycStepKind.guarantor => GuarantorInput(
      fullName: _guarantorName.text.trim(),
      phoneE164: _guarantorPhone.text.trim(),
      relationship: _guarantorRelationship.text.trim(),
    ),
    KycStepKind.payoutAccount => PayoutAccountInput(
      bankCode: _bankCode.text.trim(),
      accountNumber: _accountNumber.text.trim(),
    ),
    KycStepKind.vehicleDocuments => VehicleDocumentsInput(
      licenceUploadRef: _licenceRef!,
      registrationUploadRef: _registrationRef!,
      insuranceUploadRef: _insuranceRef,
    ),
    KycStepKind.credentials => CredentialsInput(
      description: _credentialsDescription.text.trim(),
      uploadRefs: List<String>.unmodifiable(_credentialRefs),
    ),
    _ => throw StateError('No form for ${widget.kind}'),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: SSpacing.xl,
        right: SSpacing.xl,
        top: SSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + SSpacing.xl,
      ),
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          Text(
            kycStepKindLabel(l10n, widget.kind),
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: SSpacing.xs),
          Text(
            kycStepKindBody(l10n, widget.kind),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SSpacing.lg),
          _buildFields(l10n),
          if (_error != null) ...<Widget>[
            const SizedBox(height: SSpacing.md),
            Text(
              localizedError(l10n, _error!),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: SSpacing.xl),
          if (widget.kind != KycStepKind.providerFacial)
            SButton(
              label: l10n.verifySubmit,
              loading: _busy,
              onPressed: _canSubmit
                  ? () => unawaited(_submit(_buildInput()))
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildFields(AppLocalizations l10n) => switch (widget.kind) {
    KycStepKind.governmentId => _idLookupFields(l10n),
    KycStepKind.providerFacial => _providerFacialFields(l10n),
    KycStepKind.idDocumentCapture => _idCaptureFields(l10n),
    KycStepKind.policeClearance => _policeClearanceFields(l10n),
    KycStepKind.address => _addressFields(l10n),
    KycStepKind.guarantor => _guarantorFields(l10n),
    KycStepKind.payoutAccount => _payoutFields(l10n),
    KycStepKind.vehicleDocuments => _vehicleFields(l10n),
    KycStepKind.credentials => _credentialsFields(l10n),
    KycStepKind.customerFacial => const SizedBox.shrink(),
  };

  Widget _idTypeDropdown(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.verifyIdTypeLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: SSpacing.xs),
        DropdownMenu<String>(
          initialSelection: _idType,
          expandedInsets: EdgeInsets.zero,
          dropdownMenuEntries: <DropdownMenuEntry<String>>[
            for (final String type in _idTypes)
              DropdownMenuEntry<String>(
                value: type,
                label: idTypeLabel(l10n, type),
              ),
          ],
          onSelected: (String? value) {
            if (value != null) setState(() => _idType = value);
          },
        ),
      ],
    );
  }

  Widget _idLookupFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        _idTypeDropdown(l10n),
        const SizedBox(height: SSpacing.lg),
        STextField(
          label: l10n.verifyIdNumberLabel,
          controller: _idNumber,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _providerFacialFields(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final failureKey = _livenessFailureKey;
    return Column(
      children: <Widget>[
        Icon(
          Icons.face_outlined,
          size: 72,
          color: failureKey == null
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        const SizedBox(height: SSpacing.md),
        Text(
          l10n.verifyLivenessInstruction,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        if (failureKey != null) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          Text(
            failureKey == 'livenessCheckFailed'
                ? l10n.livenessCheckFailed
                : failureKey,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: SSpacing.lg),
        if (_livenessBusy || _busy)
          Column(
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: SSpacing.sm),
              Text(l10n.verifyLivenessCapturing),
            ],
          )
        else
          SButton(
            label: failureKey == null
                ? l10n.verifyLivenessTitle
                : l10n.verifyLivenessRetry,
            onPressed: () => unawaited(_captureProviderFacial()),
          ),
      ],
    );
  }

  Widget _idCaptureFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        _idLookupFields(l10n),
        const SizedBox(height: SSpacing.lg),
        _CaptureTile(
          captured: _idUploadRef != null,
          onCapture: () => setState(() => _idUploadRef = _newUploadRef()),
        ),
      ],
    );
  }

  Widget _policeClearanceFields(AppLocalizations l10n) {
    final material = MaterialLocalizations.of(context);
    return Column(
      children: <Widget>[
        STextField(
          label: l10n.kycCertNumber,
          controller: _certNumber,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.lg),
        Row(
          children: <Widget>[
            Expanded(
              child: _DateTile(
                label: l10n.kycIssueDate,
                value: _issueDate == null
                    ? null
                    : material.formatShortDate(_issueDate!),
                onTap: () => unawaited(_pickDate(isIssue: true)),
              ),
            ),
            const SizedBox(width: SSpacing.sm),
            Expanded(
              child: _DateTile(
                label: l10n.kycExpiryDate,
                value: _expiryDate == null
                    ? null
                    : material.formatShortDate(_expiryDate!),
                onTap: () => unawaited(_pickDate(isIssue: false)),
              ),
            ),
          ],
        ),
        const SizedBox(height: SSpacing.lg),
        _CaptureTile(
          captured: _policeUploadRef != null,
          onCapture: () => setState(() => _policeUploadRef = _newUploadRef()),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.kycCriminalConsent),
          value: _criminalConsent,
          onChanged: (bool? value) =>
              setState(() => _criminalConsent = value ?? false),
        ),
      ],
    );
  }

  Widget _addressFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        STextField(
          label: l10n.addressLine1,
          controller: _line1,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.addressLine2,
          controller: _line2,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: STextField(
                label: l10n.addressCity,
                controller: _city,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: SSpacing.sm),
            Expanded(
              child: STextField(
                label: l10n.addressState,
                controller: _state,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.addressLandmark,
          controller: _landmark,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _guarantorFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        STextField(
          label: l10n.guarantorName,
          controller: _guarantorName,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.guarantorPhone,
          controller: _guarantorPhone,
          keyboardType: TextInputType.phone,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.guarantorRelationship,
          controller: _guarantorRelationship,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _payoutFields(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final result = _payoutResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        STextField(
          label: l10n.kycBankCode,
          controller: _bankCode,
          onChanged: (_) => setState(() => _payoutResult = null),
        ),
        const SizedBox(height: SSpacing.md),
        STextField(
          label: l10n.kycAccountNumber,
          controller: _accountNumber,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() => _payoutResult = null),
        ),
        const SizedBox(height: SSpacing.md),
        SButton(
          label: l10n.kycResolveAccount,
          variant: SButtonVariant.secondary,
          loading: _busy && result == null,
          onPressed:
              _bankCode.text.trim().isEmpty ||
                  _accountNumber.text.trim().isEmpty
              ? null
              : () => unawaited(_resolvePayout()),
        ),
        if (result != null) ...<Widget>[
          const SizedBox(height: SSpacing.md),
          Card(
            child: ListTile(
              leading: Icon(
                result.nameMatch
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                color: result.nameMatch
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              title: Text(result.resolvedName),
              subtitle: Text(
                '${l10n.kycAccountNameLabel} · ${result.maskedAccountNumber}',
              ),
              trailing: Text(
                result.nameMatch ? l10n.kycNameMatchYes : l10n.kycNameMatchNo,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: result.nameMatch
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _vehicleFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        _CaptureTile(
          label: l10n.vehicleLicence,
          captured: _licenceRef != null,
          onCapture: () => setState(() => _licenceRef = _newUploadRef()),
        ),
        _CaptureTile(
          label: l10n.vehicleRegistration,
          captured: _registrationRef != null,
          onCapture: () => setState(() => _registrationRef = _newUploadRef()),
        ),
        _CaptureTile(
          label: l10n.vehicleInsurance,
          captured: _insuranceRef != null,
          onCapture: () => setState(() => _insuranceRef = _newUploadRef()),
        ),
      ],
    );
  }

  Widget _credentialsFields(AppLocalizations l10n) {
    return Column(
      children: <Widget>[
        STextField(
          label: l10n.credentialsDescription,
          controller: _credentialsDescription,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.md),
        SButton(
          label: l10n.credentialsAddFile,
          variant: SButtonVariant.secondary,
          icon: Icons.attach_file,
          onPressed: () => setState(() => _credentialRefs.add(_newUploadRef())),
        ),
        if (_credentialRefs.isNotEmpty) ...<Widget>[
          const SizedBox(height: SSpacing.sm),
          for (var i = 0; i < _credentialRefs.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: Text(l10n.kycCaptured),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _credentialRefs.removeAt(i)),
              ),
            ),
        ],
      ],
    );
  }
}

/// Simulated document capture row — no camera plugin in M2 (spike S-05
/// picks the vendor SDK); produces an opaque upload ref.
class _CaptureTile extends StatelessWidget {
  const _CaptureTile({
    required this.captured,
    required this.onCapture,
    this.label,
  });

  final String? label;
  final bool captured;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: captured ? null : onCapture,
      leading: Icon(
        captured ? Icons.check_circle_outline : Icons.document_scanner_outlined,
        color: captured ? theme.colorScheme.primary : null,
      ),
      title: Text(
        label ?? (captured ? l10n.kycCaptured : l10n.kycCaptureDocument),
      ),
      trailing: captured || label == null
          ? null
          : TextButton(
              onPressed: onCapture,
              child: Text(l10n.kycCaptureDocument),
            ),
    );
  }
}

class _DateTile extends StatelessWidget {
  const _DateTile({required this.label, required this.onTap, this.value});

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: SSpacing.xs),
        SizedBox(
          height: SSpacing.minTouchTarget,
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text(value ?? label),
          ),
        ),
      ],
    );
  }
}
