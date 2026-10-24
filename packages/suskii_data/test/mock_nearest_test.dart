import 'package:suskii_data/suskii_data.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:test/test.dart';

void main() {
  late MockDatabase db;
  late MockBehavior behavior;

  setUp(() {
    db = MockDatabase();
    behavior = MockBehavior(latency: Duration.zero);
  });

  test('Nigeria offers its 36 states and the FCT as service areas', () async {
    final pack = await MockCatalogRepository(db, behavior).getCountryPack('NG');
    expect(pack.serviceAreas, hasLength(37));
    expect(
      pack.serviceAreas.map((a) => a.code),
      containsAll(<String>['lagos', 'kano', 'abuja']),
    );
  });

  test(
    'nearby providers: a count and blurred areas, never a position',
    () async {
      final nearby = await MockCatalogRepository(
        db,
        behavior,
      ).getNearbyProviders(at: const GeoPoint(latitude: 6.45, longitude: 3.40));
      expect(nearby.total, greaterThan(0));
      expect(nearby.areas, isNotEmpty);
    },
  );

  test(
    'ranked offers say how far each provider is, in half kilometres',
    () async {
      final ranked = await MockOfferRepository(
        db,
        behavior,
      ).getRankedOffers('req-1');
      expect(ranked, isNotEmpty);
      for (final r in ranked) {
        expect(r.distanceKm, isNotNull);
        expect((r.distanceKm! * 2) % 1, 0);
        expect(r.distanceKm, greaterThanOrEqualTo(0.5));
      }
    },
  );
}
