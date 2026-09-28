/**
 * Android App Links verification (RB-15). The fingerprints are the SHA-256 of the app signing
 * key Play holds and of the upload key, from Play Console > App integrity; neither is known
 * until the client creates the Play app, so the file is empty until the variables are set and
 * Android simply does not verify the links, which fall back to the browser.
 *
 *   ANDROID_APP_ID          default com.suskiierrands.app
 *   ANDROID_CERT_SHA256     comma-separated, e.g. "AB:CD:...,12:34:..."
 */
export const dynamic = 'force-dynamic';

export function GET(): Response {
  const packageName = process.env.ANDROID_APP_ID || 'com.suskiierrands.app';
  const fingerprints = (process.env.ANDROID_CERT_SHA256 ?? '')
    .split(',')
    .map((f) => f.trim())
    .filter(Boolean);
  const body =
    fingerprints.length === 0
      ? []
      : [
          {
            relation: ['delegate_permission/common.handle_all_urls'],
            target: {
              namespace: 'android_app',
              package_name: packageName,
              sha256_cert_fingerprints: fingerprints,
            },
          },
        ];
  return Response.json(body, { headers: { 'Cache-Control': 'public, max-age=3600' } });
}
