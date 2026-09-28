import 'dart:math';

import 'package:suskii_core/suskii_core.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../mock/mock_repositories.dart' show mediaExtensionFor;
import 'supabase_gateway.dart';

/// MediaUploadRepository over Supabase Storage. Each bucket's policy checks
/// the first folder of the path — the request id for job-scoped buckets, the
/// uploader's own id otherwise — so the path is built here, once, the way
/// the policies read it. The file name is random: it is never shown, and a
/// guessable name would only help someone who already has access.
class SupabaseMediaUploadRepository implements MediaUploadRepository {
  SupabaseMediaUploadRepository(this._gateway, {Random? random})
    : _random = random ?? Random.secure();

  final SupabaseGateway _gateway;
  final Random _random;

  @override
  Future<String> upload({
    required UploadBucket bucket,
    required List<int> bytes,
    required String contentType,
    String? requestId,
  }) async {
    if (bytes.isEmpty) throw const AppError(ErrorCodes.invalidArgument);
    final uid = _gateway.currentAuthUserId;
    if (uid == null) throw const AppError(ErrorCodes.unauthenticated);
    final folder = switch (bucket) {
      UploadBucket.jobProofs || UploadBucket.receipts =>
        requestId ?? (throw const AppError(ErrorCodes.invalidArgument)),
      _ => uid,
    };
    final name = List<String>.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '$folder/$name.${mediaExtensionFor(contentType)}';
    await _gateway.uploadBinary(
      bucketIdFor(bucket),
      path,
      bytes,
      contentType: contentType,
    );
    return path;
  }

  /// The storage bucket id behind each [UploadBucket] (contracts v1
  /// `storage/buckets.json`).
  static String bucketIdFor(UploadBucket bucket) => switch (bucket) {
    UploadBucket.jobProofs => 'job-proofs',
    UploadBucket.receipts => 'receipts',
    UploadBucket.kycDocuments => 'kyc-docs',
    UploadBucket.requestMedia => 'request-media',
    UploadBucket.avatars => 'avatars',
  };
}
