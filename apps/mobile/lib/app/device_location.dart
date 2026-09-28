import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:suskii_domain/suskii_domain.dart';

/// A one-shot position, or the reason there is none. The reason is what the
/// server records against a manual arrival, so it is a short stable code.
class LocationReading {
  const LocationReading.fix(GeoPoint this.point) : missingReason = null;
  const LocationReading.missing(String this.missingReason) : point = null;

  final GeoPoint? point;
  final String? missingReason;
}

/// The device's position: one reading for a check the server makes (the
/// arrival geofence), or a stream while a provider is on a job (the
/// customer's live map, ADR-0009). Neither throws nor blocks for long; the
/// caller falls back to a manual path, or to no map.
abstract interface class DeviceLocation {
  Future<LocationReading> current();

  /// Positions while the app is in the foreground, one per [distanceFilter]
  /// metres moved. Empty (not an error) when location is off or refused:
  /// the job goes on without a live map rather than failing.
  Stream<LiveFix> watch({int distanceFilter = 20});
}

class GeolocatorDeviceLocation implements DeviceLocation {
  const GeolocatorDeviceLocation();

  @override
  Future<LocationReading> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationReading.missing('location_off');
      }
      // Asked at the moment of use, never at launch (just-in-time
      // permissions); the rationale is the platform usage string.
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const LocationReading.missing('location_denied');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 15),
        ),
      );
      // A mocked fix must not satisfy the geofence (threat model: GPS
      // spoofing to fake arrival); it becomes a manual arrival on the record.
      if (position.isMocked) {
        return const LocationReading.missing('location_mocked');
      }
      return LocationReading.fix(
        GeoPoint(latitude: position.latitude, longitude: position.longitude),
      );
    } on Object {
      return const LocationReading.missing('location_unavailable');
    }
  }

  @override
  Stream<LiveFix> watch({int distanceFilter = 20}) async* {
    // Never asks: the permission was asked for at "Start journey".
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      return;
    }
    final positions = Geolocator.getPositionStream(
      locationSettings: LocationSettings(distanceFilter: distanceFilter),
    ).handleError((Object _) {}, test: (_) => true);
    await for (final position in positions) {
      yield LiveFix(
        point: GeoPoint(
          latitude: position.latitude,
          longitude: position.longitude,
        ),
        headingDegrees: position.heading >= 0 ? position.heading : null,
        speedMetresPerSecond: position.speed >= 0 ? position.speed : null,
        accuracyMetres: position.accuracy,
        isMock: position.isMocked,
      );
    }
  }
}

final deviceLocationProvider = Provider<DeviceLocation>(
  (ref) => const GeolocatorDeviceLocation(),
);
