import 'package:freezed_annotation/freezed_annotation.dart';

import '../enums.dart';
import '../money.dart';

part 'payment.freezed.dart';
part 'payment.g.dart';

/// A payment for one job. Server-initialized only — the client never marks a
/// payment successful; [status] flips when the gateway webhook + server-side
/// verify confirm it (spec: payment_gateways.rules).
@freezed
abstract class Payment with _$Payment {
  const factory Payment({
    required String id,
    required String jobId,
    required Money amount,
    required PaymentMethod method,
    required PaymentStatus status,
    required DateTime createdAt,
    String? gatewayReference,
    DateTime? paidAt,

    /// Payment TTL (PAYMENT_PENDING window). Server timestamp — render
    /// countdowns against the measured server-clock offset.
    DateTime? expiresAt,

    /// Localizable reason key when [status] is failed.
    String? failureReasonKey,
  }) = _Payment;

  factory Payment.fromJson(Map<String, dynamic> json) =>
      _$PaymentFromJson(json);
}

/// Result of server-side payment initialization: the created [Payment] plus
/// whatever the customer needs to complete it off-app (USSD code to dial,
/// transfer reference to quote). Card/mobile-money completion happens in the
/// gateway's own UI; the app only watches the status.
class PaymentSession {
  const PaymentSession({required this.payment, this.ussdCode, this.reference});

  final Payment payment;

  /// USSD code to dial (method = ussd).
  final String? ussdCode;

  /// Reference to quote on a bank transfer (method = bankTransfer).
  final String? reference;
}
