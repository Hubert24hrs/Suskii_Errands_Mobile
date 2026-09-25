import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import 'supabase_gateway.dart';
import 'supabase_mappers.dart';

/// OfferRepository over Supabase: negotiation mutations go through the
/// contract RPCs (rounds, turn-taking and expiry are server-enforced); reads
/// are RLS-scoped selects on `offers` joined with a `get_provider_card`
/// lookup per provider for the display fields the offers table does not
/// denormalize.
class SupabaseOfferRepository implements OfferRepository {
  SupabaseOfferRepository(this._gateway);

  final SupabaseGateway _gateway;

  static const String _columns =
      'id, thread_id, request_id, provider_id, author_side, amount_minor, '
      'currency, message, status, round, expires_at, created_at';

  /// provider id → get_provider_card row, cached for the session (ratings and
  /// trust levels drift slowly; offers arrive faster than cards change).
  final Map<String, Map<String, dynamic>?> _providerCards =
      <String, Map<String, dynamic>?>{};

  @override
  Stream<List<Offer>> watchOffers(String requestId) => _gateway
      .streamRows(
        'offers',
        primaryKey: <String>['id'],
        filterColumn: 'request_id',
        filterValue: requestId,
      )
      .asyncMap(_mapOffers);

  Future<List<Offer>> _mapOffers(List<Map<String, dynamic>> rows) async {
    final offers = <Offer>[
      for (final row in rows)
        offerFromRow(
          row,
          card: await _providerCard(SupabaseGateway.asId(row['provider_id'])),
        ),
    ];
    offers.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List<Offer>.unmodifiable(offers);
  }

  @override
  Future<List<RankedOffer>> getRankedOffers(String requestId) async {
    // rank_offers returns rows in server score order — kept as-is; the board
    // never re-sorts (it is not a price sort).
    final rows = await _gateway.rpc('rank_offers', <String, Object?>{
      'p_request_id': requestId,
    });
    final list = List<Map<String, dynamic>>.from(rows as List<dynamic>);
    return List<RankedOffer>.unmodifiable(list.map(rankedOfferFromRow));
  }

  @override
  Future<Offer> acceptOffer(String offerId, {required String idempotencyKey}) =>
      _mutate('accept_offer', offerId, <String, Object?>{
        'p_idempotency_key': idempotencyKey,
      });

  @override
  Future<Offer> declineOffer(
    String offerId, {
    required String idempotencyKey,
  }) => _mutate('decline_offer', offerId, <String, Object?>{
    'p_idempotency_key': idempotencyKey,
  });

  @override
  Future<Offer> withdrawOffer(
    String offerId, {
    required String idempotencyKey,
  }) => _mutate('withdraw_offer', offerId, <String, Object?>{
    'p_idempotency_key': idempotencyKey,
  });

  @override
  Future<Offer> counterOffer({
    required String offerId,
    required Money amount,
    required String idempotencyKey,
    String? message,
  }) async {
    // counter_offer returns the NEW offer's uuid (the countered offer row
    // keeps its own id), so this re-selects that row instead.
    final newId = await _gateway.rpc('counter_offer', <String, Object?>{
      'p_idempotency_key': idempotencyKey,
      'p_offer_id': offerId,
      'p_amount_minor': amount.minorUnits,
      'p_message': message,
    });
    return _loadOffer(SupabaseGateway.asId(newId));
  }

  /// The status-mutation RPCs return scalars; the entity needs the full row,
  /// so every mutation re-selects.
  Future<Offer> _mutate(
    String function,
    String offerId,
    Map<String, Object?> args,
  ) async {
    await _gateway.rpc(function, <String, Object?>{
      'p_offer_id': offerId,
      ...args,
    });
    return _loadOffer(offerId);
  }

  Future<Offer> _loadOffer(String offerId) async {
    final row = await _gateway.selectSingle(
      'offers',
      _columns,
      column: 'id',
      value: offerId,
    );
    if (row == null) throw const AppError(ErrorCodes.unknown);
    return offerFromRow(
      row,
      card: await _providerCard(SupabaseGateway.asId(row['provider_id'])),
    );
  }

  Future<Map<String, dynamic>?> _providerCard(String providerId) async {
    if (_providerCards.containsKey(providerId)) {
      return _providerCards[providerId];
    }
    final rows = await _gateway.rpc('get_provider_card', <String, Object?>{
      'p_provider_id': providerId,
    });
    final list = List<Map<String, dynamic>>.from(rows as List<dynamic>);
    final card = list.isEmpty ? null : list.first;
    _providerCards[providerId] = card;
    return card;
  }
}
