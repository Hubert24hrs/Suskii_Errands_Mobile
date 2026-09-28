import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds the SIL Open Font License notices for the bundled fonts to the
/// app's licence registry (shown by `showLicensePage`).
void registerDesignLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (String family, String file) in const <(String, String)>[
      ('Sora', 'OFL-Sora.txt'),
      ('Manrope', 'OFL-Manrope.txt'),
    ]) {
      final text = await rootBundle.loadString(
        'packages/suskii_design/assets/fonts/$file',
      );
      yield LicenseEntryWithLineBreaks(<String>[family], text);
    }
  });
}
