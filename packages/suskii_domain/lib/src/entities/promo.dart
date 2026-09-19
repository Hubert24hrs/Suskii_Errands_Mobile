import 'package:freezed_annotation/freezed_annotation.dart';

import '../money.dart';

part 'promo.freezed.dart';
part 'promo.g.dart';

/// A promo/coupon campaign (spec: added_features — platform-funded discounts
/// never reduce provider earnings). All discount math is server-side; the
/// client renders the server-computed percent/cap.
@freezed
abstract class Promo with _$Promo {
  const factory Promo({
    required String code,
    required String titleKey,
    required String descriptionKey,
    required int percentOff,
    required DateTime expiresAt,
    Money? maxDiscount,
    @Default(false) bool redeemed,
  }) = _Promo;

  factory Promo.fromJson(Map<String, dynamic> json) => _$PromoFromJson(json);
}
