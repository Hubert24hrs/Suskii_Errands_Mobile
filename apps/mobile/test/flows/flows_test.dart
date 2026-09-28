import 'package:flutter_test/flutter_test.dart';

import 'app_flows.dart';

/// The end-to-end journeys on the mock backend, headless (see
/// `app_flows.dart`). The same bodies run on a device from
/// `integration_test/app_flows_test.dart`.
void main() {
  for (final MapEntry<String, Flow> flow in appFlows.entries) {
    testWidgets(flow.key, flow.value);
  }
}
