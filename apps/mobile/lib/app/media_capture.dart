import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

/// A captured file, ready to upload.
class CapturedMedia {
  const CapturedMedia({required this.bytes, required this.contentType});

  final List<int> bytes;
  final String contentType;
}

/// Asks camera or library, then returns the picked image resized and
/// re-encoded (≤2048px, JPEG quality 80) so an upload stays small on slow
/// networks. Null when the user backs out. The camera and photo-library
/// permissions are requested by the platform at this moment, with the usage
/// strings in Info.plist — never before (spec: just-in-time permissions).
Future<CapturedMedia?> captureImage(
  BuildContext context, {
  ImagePicker? picker,
}) async {
  final l10n = AppLocalizations.of(context);
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: SSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.captureFromCamera),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.captureFromLibrary),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null) return null;
  final file = await (picker ?? ImagePicker()).pickImage(
    source: source,
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 80,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final name = file.name.toLowerCase();
  final contentType = name.endsWith('.png')
      ? 'image/png'
      : name.endsWith('.webp')
      ? 'image/webp'
      : 'image/jpeg';
  return CapturedMedia(bytes: bytes, contentType: contentType);
}
