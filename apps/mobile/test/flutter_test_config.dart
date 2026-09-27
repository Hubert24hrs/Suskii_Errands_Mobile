import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/golden_comparator.dart';

/// Goldens are compared with a small tolerance: anti-aliasing differs a
/// little between machines, and a golden that fails on a runner it was not
/// recorded on is noise, not a regression.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (goldenFileComparator is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenComparator(
      (goldenFileComparator as LocalFileComparator).basedir.resolve('x.dart'),
      tolerance: 0.005,
    );
  }
  await testMain();
}
