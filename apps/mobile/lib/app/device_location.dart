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

/// One-shot device position for a check the server makes (the arrival
/// geofence). Never throws and never blocks for long: the caller falls back
/// to a manual path with a reason code.
abstract interface class DeviceLocation {
  Future<LocationReading> current();
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
}

final deviceLocationProvider = Provider<DeviceLocation>(
  (ref) => const GeolocatorDeviceLocation(),
);
