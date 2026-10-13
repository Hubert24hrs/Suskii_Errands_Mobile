import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// Promos against the real backend. A promo code is applied at payment
/// (`start_payment`'s `p_promo_code`, previewed by `preview_promo`); an
/// account-level voucher wallet does not exist and is a client decision
/// (CR-20260923-04). So the wallet is empty and redeeming outside a job says
/// it is not available — never the mock's invented promos.
class SupabasePromoRepository implements PromoRepository {
  const SupabasePromoRepository();

  @override
  Future<List<Promo>> getPromos() async => const <Promo>[];

  @override
  Future<Promo> redeemPromo(String code, {required String idempotencyKey}) =>
      throw const AppError(ErrorCodes.featureUnavailable);
}

/// The concierge needs the AI service, which waits on Vertex AI and GCP
/// billing (client action 1). Until then it is unavailable, not simulated.
class SupabaseConciergeRepository implements ConciergeRepository {
  const SupabaseConciergeRepository();

  @override
  Future<ConciergeConversation> startConversation({
    required String idempotencyKey,
  }) => throw const AppError(ErrorCodes.featureUnavailable);

  @override
  Stream<List<ConciergeMessage>> watchMessages(String conversationId) =>
      Stream<List<ConciergeMessage>>.error(
        const AppError(ErrorCodes.featureUnavailable),
      );

  @override
  Stream<String> sendMessage(
    String conversationId,
    String text, {
    required String idempotencyKey,
  }) => Stream<String>.error(const AppError(ErrorCodes.featureUnavailable));
}
