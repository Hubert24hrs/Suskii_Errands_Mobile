import 'dart:io';

import 'package:supabase/supabase.dart';
import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_data/suskii_data.dart';
import 'package:test/test.dart';

/// M9.0 foundation: the Supabase calling conventions — error mapping to the
/// stable wire codes, named-arg shaping, and the numeric/bigint parsing rules
/// contracts v1 warns about.
void main() {
  group('mapSupabaseError', () {
    test('recovers the ERR_* wire code from the PostgREST message', () {
      final error = mapSupabaseError(
        const PostgrestException(
          message: 'ERR_PROOF_REQUIRED',
          code: 'P0001',
          details: '["photo"]',
        ),
      );
      expect(error.code, ErrorCodes.proofRequired);
      expect(error.details, '["photo"]');
    });

    test('grant denial without a wire code maps to permission denied', () {
      expect(
        mapSupabaseError(
          const PostgrestException(
            message: 'permission denied for table payments',
            code: '42501',
          ),
        ).code,
        ErrorCodes.permissionDenied,
      );
    });

    test('JWT failures map to unauthenticated', () {
      expect(
        mapSupabaseError(
          const PostgrestException(message: 'JWT expired', code: 'PGRST303'),
        ).code,
        ErrorCodes.unauthenticated,
      );
    });

    test('OTP errors map to the OTP codes', () {
      expect(
        mapSupabaseError(const AuthException('expired', code: 'otp_expired'))
            .code,
        ErrorCodes.otpInvalid,
      );
      expect(
        mapSupabaseError(
          const AuthException('slow down', code: 'over_sms_send_rate_limit'),
        ).code,
        ErrorCodes.otpRateLimited,
      );
    });

    test('network failures map to ERR_NETWORK', () {
      expect(
        mapSupabaseError(AuthRetryableFetchException()).code,
        ErrorCodes.network,
      );
      expect(
        mapSupabaseError(const SocketException('no route')).code,
        ErrorCodes.network,
      );
    });

    test('anything else is unknown', () {
      expect(mapSupabaseError(Exception('wat')).code, ErrorCodes.unknown);
      expect(
        mapSupabaseError(
          const PostgrestException(message: 'syntax error', code: '42601'),
        ).code,
        ErrorCodes.unknown,
      );
    });
  });

  group('rpcParams', () {
    test('omits nulls, keeps falsy values', () {
      expect(
        SupabaseGateway.rpcParams(<String, Object?>{
          'p_idempotency_key': 'key-1',
          'p_reason_code': null,
          'p_approve': false,
          'p_amount_minor': 0,
          'p_note': '',
        }),
        <String, dynamic>{
          'p_idempotency_key': 'key-1',
          'p_approve': false,
          'p_amount_minor': 0,
          'p_note': '',
        },
      );
    });
  });

  group('wire value parsing', () {
    test('numeric arrives as a string; minor units parse exactly', () {
      expect(SupabaseGateway.asMinorUnits('150000'), 150000);
      expect(SupabaseGateway.asMinorUnits(150000), 150000);
      expect(SupabaseGateway.asMinorUnits(150000.0), 150000);
      // Beyond 2^53 — must not go through a double.
      expect(
        SupabaseGateway.asMinorUnits('9007199254740993'),
        9007199254740993,
      );
    });

    test('score-like numerics parse as decimal', () {
      expect(SupabaseGateway.asDecimal('0.634'), 0.634);
      expect(SupabaseGateway.asDecimal(0.634), 0.634);
    });

    test('ids are opaque strings (bigint-safe)', () {
      expect(SupabaseGateway.asId(9223372036854775807), '9223372036854775807');
      expect(SupabaseGateway.asId('3f2a91c4-…'), '3f2a91c4-…');
    });
  });
}
