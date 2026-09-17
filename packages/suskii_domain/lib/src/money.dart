import 'package:intl/intl.dart';

/// Money is ALWAYS integer minor units + an ISO 4217 currency code.
/// Never floating point. The UI never computes derived amounts (commission,
/// fees, payouts) — those arrive from the server inside [PriceBreakdown].
final class Money implements Comparable<Money> {
  const Money(this.minorUnits, this.currencyCode);

  final int minorUnits;
  final String currencyCode;

  factory Money.fromJson(Map<String, dynamic> json) =>
      Money(json['minorUnits'] as int, json['currency'] as String);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'minorUnits': minorUnits,
    'currency': currencyCode,
  };

  /// ISO 4217 minor-unit exponents that differ from the common default of 2.
  static const Map<String, int> _exponents = <String, int>{
    'XOF': 0, 'XAF': 0, 'JPY': 0, 'KRW': 0, 'UGX': 0, 'RWF': 0, //
    'VUV': 0, 'CLP': 0, 'GNF': 0,
    'BHD': 3, 'JOD': 3, 'KWD': 3, 'OMR': 3, 'TND': 3, 'LYD': 3, 'IQD': 3,
  };

  /// Known two-exponent codes. An unknown code asserts in debug instead of
  /// silently defaulting to 2 (review C.6: a missing zero-exponent currency
  /// would render 100× too small). Exponents ship in the country pack in
  /// contracts v1; until then, extend these tables when adding a currency.
  static const Set<String> _twoExponent = <String>{
    'NGN', 'KES', 'GHS', 'ZAR', 'USD', 'EUR', 'GBP', //
    'CAD', 'AUD', 'NZD', 'CHF', 'SEK', 'NOK', 'DKK',
    'INR', 'BRL', 'MXN', 'ZMW', 'TZS', 'EGP', 'MAD',
  };

  static int exponentOf(String currencyCode) {
    final code = currencyCode.toUpperCase();
    final known = _exponents[code];
    if (known != null) return known;
    assert(
      _twoExponent.contains(code),
      'Unknown currency exponent for $code — add it to the exponent table '
      'instead of defaulting to 2.',
    );
    return 2;
  }

  int get exponent => exponentOf(currencyCode);

  static int _pow10(int exponent) {
    var factor = 1;
    for (var i = 0; i < exponent; i++) {
      factor *= 10;
    }
    return factor;
  }

  factory Money.fromMajorUnits(int majorUnits, String currencyCode) =>
      Money(majorUnits * _pow10(exponentOf(currencyCode)), currencyCode);

  Money operator +(Money other) {
    _checkSameCurrency(other);
    return Money(minorUnits + other.minorUnits, currencyCode);
  }

  Money operator -(Money other) {
    _checkSameCurrency(other);
    return Money(minorUnits - other.minorUnits, currencyCode);
  }

  Money operator -() => Money(-minorUnits, currencyCode);

  bool get isNegative => minorUnits < 0;
  bool get isZero => minorUnits == 0;

  @override
  int compareTo(Money other) {
    _checkSameCurrency(other);
    return minorUnits.compareTo(other.minorUnits);
  }

  bool operator <(Money other) => compareTo(other) < 0;
  bool operator <=(Money other) => compareTo(other) <= 0;
  bool operator >(Money other) => compareTo(other) > 0;
  bool operator >=(Money other) => compareTo(other) >= 0;

  void _checkSameCurrency(Money other) {
    if (currencyCode.toUpperCase() != other.currencyCode.toUpperCase()) {
      throw ArgumentError(
        'Currency mismatch: $currencyCode vs ${other.currencyCode}',
      );
    }
  }

  static const Map<String, String> _symbols = <String, String>{
    'NGN': '₦',
    'KES': 'KSh ',
    'GHS': 'GH₵',
    'ZAR': 'R',
    'USD': r'$',
    'EUR': '€',
    'GBP': '£',
    'XOF': 'CFA ',
    'XAF': 'FCFA ',
  };

  String get symbol => _symbols[currencyCode.toUpperCase()] ?? '$currencyCode ';

  /// Locale-aware display string, e.g. `₦12,500.00`, `CFA 4,500`, `-$5.25`.
  String format({String locale = 'en'}) {
    final exp = exponent;
    final sign = minorUnits < 0 ? '-' : '';
    final abs = minorUnits.abs();
    final factor = _pow10(exp);
    final intPart = abs ~/ factor;
    final grouped = NumberFormat('#,##0', locale).format(intPart);
    if (exp == 0) {
      return '$sign$symbol$grouped';
    }
    final frac = (abs % factor).toString().padLeft(exp, '0');
    return '$sign$symbol$grouped.$frac';
  }

  @override
  bool operator ==(Object other) =>
      other is Money &&
      other.minorUnits == minorUnits &&
      other.currencyCode.toUpperCase() == currencyCode.toUpperCase();

  @override
  int get hashCode => Object.hash(minorUnits, currencyCode.toUpperCase());

  @override
  String toString() => format();
}
