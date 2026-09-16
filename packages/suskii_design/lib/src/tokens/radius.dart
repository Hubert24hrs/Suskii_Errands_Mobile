import 'package:flutter/material.dart';

/// Corner radius tokens.
abstract final class SRadius {
  static const double sm = 6;
  static const double md = 12;
  static const double lg = 20;
  static const double pill = 999;

  static const BorderRadius borderSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius borderMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius borderLg = BorderRadius.all(Radius.circular(lg));
}
