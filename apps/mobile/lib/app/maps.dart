import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import 'device_location.dart';
import 'providers.dart';

/// Lagos Island: where the map opens when nothing better is known.
const GeoPoint kDefaultMapCentre = GeoPoint(
  latitude: 6.4550,
  longitude: 3.3941,
);

/// Pick a point by moving the map under a fixed pin, with the blurred
/// "providers near you" areas drawn on top (ADR-0022). The picked point is
/// reported when the map comes to rest.
///
/// Without a Google Maps key ([AppConfig.hasMaps] false: tests, and builds
/// whose CI has no key secret) the native SDK would refuse to start, so this
/// shows a location card instead: "use my location" still sets the point,
/// which is what matching needs.
class PickupMap extends ConsumerStatefulWidget {
  const PickupMap({
    required this.onChanged,
    super.key,
    this.point,
    this.areas = const <NearbyArea>[],
    this.height = 240,
  });

  final GeoPoint? point;
  final ValueChanged<GeoPoint> onChanged;
  final List<NearbyArea> areas;
  final double height;

  @override
  ConsumerState<PickupMap> createState() => _PickupMapState();
}

class _PickupMapState extends ConsumerState<PickupMap> {
  gm.GoogleMapController? _controller;
  GeoPoint? _target;
  bool _locating = false;
  String? _locationError;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _useMyLocation() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    final reading = await ref.read(deviceLocationProvider).current();
    if (!mounted) return;
    setState(() => _locating = false);
    final point = reading.point;
    if (point == null) {
      setState(() => _locationError = reading.missingReason);
      return;
    }
    widget.onChanged(point);
    await _controller?.animateCamera(
      gm.CameraUpdate.newLatLngZoom(_latLng(point), 16),
    );
  }

  static gm.LatLng _latLng(GeoPoint p) => gm.LatLng(p.latitude, p.longitude);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final config = ref.watch(appConfigProvider);
    final point = widget.point;

    final locateButton = OutlinedButton.icon(
      key: const ValueKey<String>('map.useMyLocation'),
      onPressed: _locating ? null : _useMyLocation,
      icon: _locating
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.my_location_rounded),
      label: Text(l10n.mapUseMyLocation),
    );

    if (!config.hasMaps) {
      return SGlass(
        key: const ValueKey<String>('map.fallback'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  point == null ? Icons.location_searching : Icons.place,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: SSpacing.sm),
                Expanded(
                  child: Text(
                    point == null ? l10n.mapPickupNeeded : l10n.mapPickupSet,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SSpacing.xs),
            Text(
              l10n.mapUnavailable,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SSpacing.sm),
            locateButton,
            if (_locationError != null) ...<Widget>[
              const SizedBox(height: SSpacing.xs),
              Text(
                l10n.errLocationUnavailable,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final primary = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: SRadius.borderLg,
          child: SizedBox(
            height: widget.height,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                gm.GoogleMap(
                  key: const ValueKey<String>('map.google'),
                  initialCameraPosition: gm.CameraPosition(
                    target: _latLng(point ?? kDefaultMapCentre),
                    zoom: point == null ? 12 : 16,
                  ),
                  onMapCreated: (c) => _controller = c,
                  onCameraMove: (pos) => _target = GeoPoint(
                    latitude: pos.target.latitude,
                    longitude: pos.target.longitude,
                  ),
                  onCameraIdle: () {
                    final target = _target;
                    if (target != null) widget.onChanged(target);
                  },
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  mapToolbarEnabled: false,
                  circles: <gm.Circle>{
                    for (final (int i, NearbyArea a) in widget.areas.indexed)
                      gm.Circle(
                        circleId: gm.CircleId('area-$i'),
                        center: _latLng(a.center),
                        // About a grid cell across: an area, never a spot.
                        radius: 600,
                        strokeWidth: 0,
                        fillColor: primary.withValues(alpha: 0.18),
                      ),
                  },
                  // Inside a scrolling form the map takes the drag, or the
                  // page would scroll instead of the map panning.
                  gestureRecognizers:
                      const <Factory<OneSequenceGestureRecognizer>>{
                        Factory<OneSequenceGestureRecognizer>(
                          EagerGestureRecognizer.new,
                        ),
                      },
                ),
                // The pin stays in the middle; the map moves under it.
                IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Icon(Icons.location_on, size: 44, color: primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: SSpacing.sm),
        Text(
          l10n.mapPickupHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SSpacing.xs),
        Align(alignment: AlignmentDirectional.centerStart, child: locateButton),
      ],
    );
  }
}
