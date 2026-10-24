import 'package:flutter_test/flutter_test.dart';
import 'package:suskii_mobile/app/device_country.dart';

void main() {
  group('countryFromSignals', () {
    test('the network the phone is on wins over the SIM', () {
      expect(countryFromSignals(network: 'ke', sim: 'ng'), 'KE');
    });

    test('a network the app does not serve falls through to the SIM', () {
      expect(countryFromSignals(network: 'us', sim: 'ng'), 'NG');
    });

    test('with no carrier (iOS, Wi-Fi only) the time zone answers', () {
      expect(countryFromSignals(timeZone: 'Africa/Accra'), 'GH');
      expect(countryFromSignals(network: '', timeZone: 'Africa/Kampala'), 'UG');
    });

    test('then the region the person set, first served one', () {
      expect(
        countryFromSignals(
          timeZone: 'Europe/London',
          localeRegions: <String?>[null, 'GB', 'za'],
        ),
        'ZA',
      );
    });

    test('nothing served: null, and the server falls back', () {
      expect(
        countryFromSignals(
          network: 'fr',
          timeZone: 'Europe/Paris',
          localeRegions: <String?>['FR'],
        ),
        isNull,
      );
    });
  });
}
