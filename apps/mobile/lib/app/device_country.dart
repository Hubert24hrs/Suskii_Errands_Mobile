import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Calling codes of the countries the app can place somebody in: the five
/// with a country pack. Whether one is open today is the server's answer
/// (`get_bootstrap` falls back to the live country when it is not).
const Map<String, String> countryDialCodes = <String, String>{
  'NG': '234',
  'KE': '254',
  'GH': '233',
  'ZA': '27',
  'UG': '256',
};

/// The launch country, used when nothing on the device names a served one.
const String fallbackCountryCode = 'NG';

/// IANA zones of the served countries. Phones set their zone from the mobile
/// network by default, so the zone is a good witness of where the phone is.
const Map<String, String> _zoneCountries = <String, String>{
  'Africa/Lagos': 'NG',
  'Africa/Nairobi': 'KE',
  'Africa/Accra': 'GH',
  'Africa/Johannesburg': 'ZA',
  'Africa/Kampala': 'UG',
};

const MethodChannel _channel = MethodChannel('suskii/device_region');

/// The country the phone is in, or null when no signal names one the app
/// serves. Nobody picks a country any more (owner, 2026-10-24): a customer
/// uses the country they are in. Android answers with the network the phone
/// is registered on and the SIM's country (`MainActivity`, no permission
/// needed); iOS no longer exposes a carrier, so it answers with the time zone
/// and the region setting (`AppDelegate`).
Future<String?> detectDeviceCountry() async {
  var signals = const <String, String>{};
  if (!kIsWeb) {
    try {
      signals =
          await _channel.invokeMapMethod<String, String>('signals') ?? signals;
    } on MissingPluginException {
      // Tests and platforms without the channel: the locale still answers.
    } on PlatformException {
      // Never fail a launch over a hint.
    }
  }
  return countryFromSignals(
    network: signals['network'],
    sim: signals['sim'],
    timeZone: signals['timeZone'],
    localeRegions: <String?>[
      signals['region'],
      for (final ui.Locale locale in ui.PlatformDispatcher.instance.locales)
        locale.countryCode,
    ],
  );
}

/// Strongest first: where the phone is registered, the SIM, the time zone,
/// then the region the person set. The first served country wins, so a phone
/// roaming somewhere the app does not serve still lands in its SIM's country.
@visibleForTesting
String? countryFromSignals({
  String? network,
  String? sim,
  String? timeZone,
  Iterable<String?> localeRegions = const <String?>[],
}) {
  String? served(String? code) {
    final upper = code?.trim().toUpperCase();
    return countryDialCodes.containsKey(upper) ? upper : null;
  }

  return served(network) ??
      served(sim) ??
      served(_zoneCountries[timeZone]) ??
      localeRegions.map(served).nonNulls.firstOrNull;
}
