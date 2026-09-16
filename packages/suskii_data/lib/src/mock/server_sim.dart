import 'package:suskii_domain/suskii_domain.dart';

/// Integer-math money rounding exactly as the server's ledger will do it:
/// round half-even at minor units. The mock layer plays "server" here so the
/// UI never computes prices itself.
int roundHalfEven(int numerator, int denominator) {
  final quotient = numerator ~/ denominator;
  final remainder = numerator % denominator;
  final twice = remainder * 2;
  if (twice > denominator) return quotient + 1;
  if (twice < denominator) return quotient;
  return quotient.isEven ? quotient : quotient + 1;
}

/// Server-side quote simulation (commission rate snapshotted per job).
PriceBreakdown simulateQuote(
  Money gross, {
  int commissionRateBps = 1250,
  Money? estimatedGatewayFee,
  Money? tip,
}) {
  final commission = Money(
    roundHalfEven(gross.minorUnits * commissionRateBps, 10000),
    gross.currencyCode,
  );
  final net = gross - commission;
  final gateway = estimatedGatewayFee ?? Money(0, gross.currencyCode);
  final tipAmount = tip ?? Money(0, gross.currencyCode);
  return PriceBreakdown(
    gross: gross,
    platformCommission: commission,
    net: net,
    providerPayout: net - gateway + tipAmount,
    commissionRateBps: commissionRateBps,
    estimatedGatewayFee: estimatedGatewayFee,
    tip: tip,
  );
}
