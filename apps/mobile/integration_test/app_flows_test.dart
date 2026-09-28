import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/flows/app_flows.dart';

/// The same journeys as `test/flows/flows_test.dart`, on a device or an
/// emulator, against the mock backend:
///
///   flutter test integration_test -d <device>
///
/// Real rendering, real fonts, real platform channels (secure storage,
/// shared preferences); the image picker and location are faked by the flows
/// that need them.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final MapEntry<String, Flow> flow in appFlows.entries) {
    testWidgets(flow.key, flow.value);
  }
}
