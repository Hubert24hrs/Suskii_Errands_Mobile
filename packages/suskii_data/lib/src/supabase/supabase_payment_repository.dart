import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// PaymentRepository over Supabase: `start_payment` creates the attempt
/// server-side (status flips arrive via webhook + server-side verify — the
/// client only watches); `get_payment_checkout` supplies the gateway page for
/// card/mobile-money completion.
class SupabasePaymentRepository implements PaymentRepository {
  SupabasePaymentRepository(this._gateway);

  final SupabaseGateway _gateway;

  /// Column grants on payments deliberately exclude `checkout_url` — the
  /// checkout page only ever comes from `get_payment_checkout`.
  static const String _columns =
      'id, request_id, payer_id, gateway, gateway_reference, method, '
      'amount_minor, currency, status, expires_at, confirmed_at, '
      'failed_reason_key, created_at';

  @override
  Future<Payment?> getPaymentForJob(String jobId) async {
    // A job can have several attempts (failed retries); the latest is the
    // one that matters.
    final rows = await _gateway.selectList(
      'payments',
      _columns,
      column: 'request_id',
      value: jobId,
      orderBy: 'created_at',
      ascending: false,
      limit: 1,
    );
    return rows.isEmpty ? null : paymentFromRow(rows.first);
  }

  @override
  Stream<Payment?> watchPaymentForJob(String jobId) => _gateway
      .streamRows(
        'payments',
        primaryKey: <String>['id'],
        filterColumn: 'request_id',
        filterValue: jobId,
      )
      .map((rows) {
        if (rows.isEmpty) return null;
        rows.sort(
          (a, b) =>
              (a['created_at'] as String).compareTo(b['created_at'] as String),
        );
        return paymentFromRow(rows.last);
      });

  @override
  Future<PaymentSession> initializePayment({
    required String jobId,
    required PaymentMethod method,
    required String idempotencyKey,
  }) async {
    final rows = await _gateway.rpc('start_payment', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_request_id': jobId,
      'p_method': paymentMethodToWire(method),
    });
    final list = List<Map<String, dynamic>>.from(rows as List<dynamic>);
    final paymentId = SupabaseGateway.asId(list.first['payment_id']);
    final payment = await _gateway.selectSingle(
      'payments',
      _columns,
      column: 'id',
      value: paymentId,
    );
    // Card/mobile-money complete on the gateway's own page; the checkout URL
    // is an RPC read, not a table column (see the grants note above). USSD /
    // bank-transfer instructions are not in the contract yet — tracked as
    // CR-20260923-02; the session fields stay null until then.
    String? checkoutUrl;
    if (method == PaymentMethod.card || method == PaymentMethod.mobileMoney) {
      final checkout = await _gateway.rpc(
        'get_payment_checkout',
        <String, Object?>{'p_request_id': jobId},
      );
      final checkoutRows = List<Map<String, dynamic>>.from(
        checkout as List<dynamic>,
      );
      if (checkoutRows.isNotEmpty) {
        checkoutUrl = checkoutRows.first['checkout_url'] as String?;
      }
    }
    return PaymentSession(
      payment: paymentFromRow(payment!),
      checkoutUrl: checkoutUrl,
    );
  }
}
