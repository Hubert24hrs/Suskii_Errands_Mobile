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

/// Payment checkout for an AGREED job (M4). Server-initialized only: the
/// page picks a method and asks; the payment status arrives over
/// [paymentForJobProvider] (webhook + server-side verify in the real backend).
/// The client NEVER marks a payment successful.
class PaymentPage extends ConsumerStatefulWidget {
  const PaymentPage({required this.jobId, super.key});

  final String jobId;

  @override
  ConsumerState<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends ConsumerState<PaymentPage> {
  PaymentMethod _method = PaymentMethod.card;
  bool _busy = false;

  /// One key per pay intent (M3.14): a retried tap replays the same
  /// initialization instead of creating a second payment.
  String? _payKey;

  /// Off-app completion instructions from the last initialization.
  PaymentSession? _session;

  Future<void> _pay() => _run(() async {
    _payKey ??= newIdempotencyKey();
    final session = await ref
        .read(paymentRepositoryProvider)
        .initializePayment(
          jobId: widget.jobId,
          method: _method,
          idempotencyKey: _payKey!,
        );
    if (mounted) setState(() => _session = session);
  });

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        showSToast(context, localizedError(l10n, error), isError: true);
        if (error is AppError &&
            error.code == ErrorCodes.verificationRequired) {
          unawaited(context.push(AppRoutes.verifyCustomer));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final job = ref.watch(requestDetailProvider(widget.jobId));
    final payment = ref.watch(paymentForJobProvider(widget.jobId));

    // Once HELD is confirmed, give the user a beat to read the success state
    // and return to the request.
    ref.listen(paymentForJobProvider(widget.jobId), (
      AsyncValue<Payment?>? previous,
      AsyncValue<Payment?> next,
    ) {
      final p = next.value;
      if (p != null && p.status == PaymentStatus.held) {
        Timer(const Duration(seconds: 2), () {
          if (mounted) context.pop();
        });
      }
    });

    final showPayBar =
        job.value?.agreedPrice != null &&
        payment.value?.status != PaymentStatus.pending &&
        payment.value?.status != PaymentStatus.held;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.payTitle)),
      body: SafeArea(
        child: job.when(
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
            onRetry: () => ref.invalidate(requestDetailProvider(widget.jobId)),
          ),
          data: (JobRequest request) => payment.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) => SErrorState(
              title: l10n.stateErrorGeneric,
              message: localizedError(l10n, error),
              retryLabel: l10n.actionRetry,
              onRetry: () =>
                  ref.invalidate(paymentForJobProvider(widget.jobId)),
            ),
            data: (Payment? current) => _buildBody(l10n, request, current),
          ),
        ),
      ),
      bottomNavigationBar: showPayBar
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(SSpacing.lg),
                child: SButton(
                  label: l10n.payNow(job.value!.agreedPrice!.format()),
                  onPressed: _busy ? null : _pay,
                  loading: _busy,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    JobRequest request,
    Payment? payment,
  ) {
    final theme = Theme.of(context);
    final clock = ref.watch(serverClockProvider);
    final amount = request.agreedPrice;
    if (amount == null) {
      return SErrorState(
        title: l10n.stateErrorGeneric,
        message: l10n.errInvalidState,
        retryLabel: l10n.actionRetry,
        onRetry: () => ref.invalidate(requestDetailProvider(widget.jobId)),
      );
    }

    if (payment != null && payment.status == PaymentStatus.held) {
      return _CenteredMessage(
        icon: Icons.verified_outlined,
        title: l10n.paySuccess,
      );
    }
    final failed = payment != null && payment.status == PaymentStatus.failed;

    return ListView(
      padding: const EdgeInsets.all(SSpacing.lg),
      children: <Widget>[
        if (failed) ...<Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.lg),
              child: Row(
                children: <Widget>[
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: SSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.payFailedTitle,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          l10n.payDeclinedReason,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SSpacing.lg),
        ],
        Text(l10n.payAmountDue, style: theme.textTheme.titleMedium),
        const SizedBox(height: SSpacing.xs),
        Text(amount.format(), style: theme.textTheme.displaySmall),
        if (payment != null &&
            payment.status == PaymentStatus.pending &&
            payment.expiresAt != null) ...<Widget>[
          const SizedBox(height: SSpacing.sm),
          Row(
            children: <Widget>[
              Text('${l10n.payWindowLabel} ', style: theme.textTheme.bodySmall),
              SCountdownTimer(
                deadline: payment.expiresAt!,
                clockOffset: clock.offset,
              ),
            ],
          ),
        ],
        const SizedBox(height: SSpacing.lg),
        if (payment != null &&
            payment.status == PaymentStatus.pending) ...<Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(SSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: SSpacing.md),
                      Expanded(
                        child: Text(
                          l10n.payWaiting,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: SSpacing.sm),
                  Text(l10n.payWaitingHint, style: theme.textTheme.bodySmall),
                  if (_session?.ussdCode != null) ...<Widget>[
                    const SizedBox(height: SSpacing.sm),
                    Text(
                      l10n.payUssdInstruction(_session!.ussdCode!),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  if (_session?.reference != null) ...<Widget>[
                    const SizedBox(height: SSpacing.sm),
                    Text(
                      l10n.payTransferInstruction(_session!.reference!),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ] else ...<Widget>[
          Text(l10n.payMethodTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: SSpacing.sm),
          RadioGroup<PaymentMethod>(
            groupValue: _method,
            onChanged: (PaymentMethod? m) {
              if (!_busy) {
                setState(() => _method = m ?? PaymentMethod.card);
              }
            },
            child: Column(
              children: <Widget>[
                for (final method in PaymentMethod.values)
                  RadioListTile<PaymentMethod>(
                    value: method,
                    title: Text(paymentMethodLabel(l10n, method)),
                    secondary: Icon(switch (method) {
                      PaymentMethod.card => Icons.credit_card,
                      PaymentMethod.bankTransfer =>
                        Icons.account_balance_outlined,
                      PaymentMethod.mobileMoney => Icons.phone_android_outlined,
                      PaymentMethod.ussd => Icons.dialpad_outlined,
                    }),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: SSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
