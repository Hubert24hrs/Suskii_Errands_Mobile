import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/labels.dart';
import '../../app/providers.dart';

final _customerVerificationProvider = StreamProvider<VerificationSession?>(
  (ref) =>
      ref.watch(verificationRepositoryProvider).watchCustomerVerification(),
);

/// Nigerian government-ID types offered for lookup (country-pack driven on
/// the backend; fixed set until the pack carries them).
const List<String> _idTypes = <String>[
  'nin',
  'bvn',
  'votersCard',
  'driversLicence',
  'passport',
];

/// Customer facial verification: biometric consent → liveness capture (via
/// the vendor-neutral adapter) → government-ID lookup → result. All outcomes
/// are decided by the repository; this page only requests and renders them.
class CustomerVerificationPage extends ConsumerStatefulWidget {
  const CustomerVerificationPage({super.key});

  @override
  ConsumerState<CustomerVerificationPage> createState() =>
      _CustomerVerificationPageState();
}

class _CustomerVerificationPageState
    extends ConsumerState<CustomerVerificationPage> {
  final TextEditingController _idNumberController = TextEditingController();

  bool _consentChecked = false;
  bool _busy = false;
  bool _livenessDone = false;
  String _idType = _idTypes.first;
  Object? _error;
  String? _livenessFailureKey;

  @override
  void dispose() {
    _idNumberController.dispose();
    super.dispose();
  }

  /// One key per intent, cleared only on success (M3.14). `_run` swallows the
  /// error, so a key that survives it is what makes the next tap a replay
  /// rather than a second consent record or a second verification session --
  /// `start_verification_session` has no natural uniqueness behind it, which
  /// is what audit N.1 singled out.
  String? _consentKey;
  String? _startKey;
  String? _idLookupKey;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _giveConsent() => _run(() async {
    _consentKey ??= newIdempotencyKey();
    await ref
        .read(verificationRepositoryProvider)
        .giveBiometricConsent(idempotencyKey: _consentKey!);
    _consentKey = null;
  });

  Future<void> _retryFlow() async {
    setState(() {
      _livenessDone = false;
      _livenessFailureKey = null;
    });
    // Starting over is a new intent and gets a new key; a failed start keeps
    // its key so tapping again replays rather than opening a second session.
    await _run(() async {
      _startKey ??= newIdempotencyKey();
      await ref
          .read(verificationRepositoryProvider)
          .startFacialVerification(idempotencyKey: _startKey!);
      _startKey = null;
    });
  }

  Future<void> _captureLiveness() async {
    setState(() {
      _busy = true;
      _error = null;
      _livenessFailureKey = null;
    });
    try {
      final adapter = ref.read(identityVerificationAdapterProvider);
      final session = await adapter.startLivenessSession();
      final result = await adapter.captureLiveness(session.sessionId);
      if (!mounted) return;
      switch (result.outcome) {
        case IdentityCheckOutcome.success:
          setState(() => _livenessDone = true);
        case IdentityCheckOutcome.retry:
        case IdentityCheckOutcome.failed:
          setState(() => _livenessFailureKey = result.reasonKey);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitIdLookup(String sessionId) => _run(() async {
    _idLookupKey ??= newIdempotencyKey();
    await ref
        .read(verificationRepositoryProvider)
        .submitIdLookup(
          sessionId,
          _idType,
          _idNumberController.text.trim(),
          idempotencyKey: _idLookupKey!,
        );
    _idLookupKey = null;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(_customerVerificationProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.verifyTitle)),
      body: SafeArea(
        child: session.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SSpacing.xl),
            child: Column(
              children: <Widget>[SSkeletonListTile(), SSkeletonListTile()],
            ),
          ),
          error: (Object error, _) => SErrorState(
            title: l10n.stateErrorGeneric,
            message: localizedError(l10n, error),
            retryLabel: l10n.actionRetry,
            onRetry: () => ref.invalidate(_customerVerificationProvider),
          ),
          data: (VerificationSession? data) => _buildStage(l10n, data),
        ),
      ),
    );
  }

  Widget _buildStage(AppLocalizations l10n, VerificationSession? session) {
    final status = session?.status;
    return ListView(
      padding: const EdgeInsets.all(SSpacing.xl),
      children: <Widget>[
        if (_error != null) ...<Widget>[
          Text(
            localizedError(l10n, _error!),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: SSpacing.md),
        ],
        if (session == null || status == KycStepStatus.consentPending)
          _buildConsent(l10n)
        else if (status == KycStepStatus.inProgress)
          _livenessDone ? _buildIdForm(l10n, session.id) : _buildLiveness(l10n)
        else if (status == KycStepStatus.inReview)
          _StageMessage(
            icon: Icons.hourglass_top_outlined,
            title: l10n.verifyInReviewTitle,
            body: l10n.verifyInReviewBody,
            loading: true,
          )
        else if (status == KycStepStatus.verified)
          _StageMessage(
            icon: Icons.verified_outlined,
            title: l10n.verifySuccessTitle,
            body: l10n.verifySuccessBody,
          )
        else
          _buildRejected(l10n, session),
      ],
    );
  }

  Widget _buildConsent(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.verifyConsentTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: SSpacing.md),
        Text(
          l10n.verifyConsentBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SSpacing.lg),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.verifyConsentCheckbox),
          value: _consentChecked,
          onChanged: (bool? value) =>
              setState(() => _consentChecked = value ?? false),
        ),
        const SizedBox(height: SSpacing.lg),
        SButton(
          label: l10n.verifyConsentAction,
          loading: _busy,
          onPressed: _consentChecked ? _giveConsent : null,
        ),
      ],
    );
  }

  Widget _buildLiveness(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final failureKey = _livenessFailureKey;
    return Column(
      children: <Widget>[
        const SizedBox(height: SSpacing.xl),
        Icon(
          Icons.face_outlined,
          size: 96,
          color: failureKey == null
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        const SizedBox(height: SSpacing.lg),
        Text(l10n.verifyLivenessTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: SSpacing.sm),
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
        const SizedBox(height: SSpacing.xl),
        if (_busy)
          Column(
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: SSpacing.md),
              Text(l10n.verifyLivenessCapturing),
            ],
          )
        else
          SButton(
            label: failureKey == null
                ? l10n.verifyLivenessTitle
                : l10n.verifyLivenessRetry,
            onPressed: () => unawaited(_captureLiveness()),
          ),
      ],
    );
  }

  Widget _buildIdForm(AppLocalizations l10n, String sessionId) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.verifyIdTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: SSpacing.lg),
        Text(l10n.verifyIdTypeLabel, style: theme.textTheme.labelLarge),
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
        const SizedBox(height: SSpacing.lg),
        STextField(
          label: l10n.verifyIdNumberLabel,
          controller: _idNumberController,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: SSpacing.xl),
        SButton(
          label: l10n.verifySubmit,
          loading: _busy,
          onPressed: _idNumberController.text.trim().isEmpty
              ? null
              : () => unawaited(_submitIdLookup(sessionId)),
        ),
      ],
    );
  }

  Widget _buildRejected(AppLocalizations l10n, VerificationSession session) {
    return Column(
      children: <Widget>[
        _StageMessage(
          icon: Icons.error_outline,
          title: l10n.verifyRejectedTitle,
          body: kycRejectionReasonLabel(l10n, session.rejectionReasonKey),
        ),
        const SizedBox(height: SSpacing.xl),
        SButton(
          label: l10n.actionRetry,
          loading: _busy,
          onPressed: () => unawaited(_retryFlow()),
        ),
      ],
    );
  }
}

class _StageMessage extends StatelessWidget {
  const _StageMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        const SizedBox(height: SSpacing.xl),
        Icon(icon, size: 96, color: theme.colorScheme.primary),
        const SizedBox(height: SSpacing.lg),
        Text(
          title,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: SSpacing.sm),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        if (loading) ...<Widget>[
          const SizedBox(height: SSpacing.xl),
          const CircularProgressIndicator(),
        ],
      ],
    );
  }
}
