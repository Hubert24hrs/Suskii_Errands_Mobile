import 'package:url_launcher/url_launcher.dart';

/// Opens an https URL outside the app (hosted checkout, legal pages).
/// Anything that is not https is refused: a checkout URL comes from the
/// server, and the one thing it must never be is a scheme that runs
/// something on the device. Returns false when nothing was opened.
Future<bool> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Opens the mail app addressed to [email]. Returns false when unavailable.
Future<bool> openEmail(String email) async {
  if (!email.contains('@')) return false;
  return launchUrl(Uri(scheme: 'mailto', path: email));
}
