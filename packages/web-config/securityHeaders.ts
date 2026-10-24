/**
 * Security headers shared by the three Next.js apps (audit 2026-09-27 Y.11;
 * spec security.web: strict CSP, HSTS). Imported by each app's
 * next.config.ts so the three cannot drift apart.
 *
 * `script-src` keeps 'unsafe-inline' because Next's App Router inlines its
 * bootstrap scripts; nonce-based CSP needs middleware on every request and
 * turns every page dynamic, which is a later decision, not a default.
 * 'unsafe-eval' is development-only (React Refresh).
 */
export type Header = { key: string; value: string };

export function securityHeaders(options: {
  supabaseUrl?: string;
  production: boolean;
  /** Extra origins a page may connect to (analytics, maps). */
  connectSrc?: string[];
  /** Browser APIs this app may use; everything else is denied. */
  allowGeolocation?: boolean;
  /** Allow the Google Maps JavaScript API: the origins Google's CSP guide for
   * Maps lists (developers.google.com/maps/documentation/javascript/content-security-policy).
   * Only when a Maps key is configured, so a build without maps keeps the
   * tighter policy. */
  googleMaps?: boolean;
}): Header[] {
  const supabase = options.supabaseUrl ? new URL(options.supabaseUrl) : undefined;
  // Realtime's socket follows the API's scheme: wss in every deployed environment, ws
  // against a local stack on plain http.
  const supabaseOrigins = supabase
    ? [supabase.origin, `${supabase.protocol === 'https:' ? 'wss' : 'ws'}://${supabase.host}`]
    : [];
  const maps = options.googleMaps
    ? {
        script: ' https://*.googleapis.com https://*.gstatic.com *.google.com https://*.ggpht.com *.googleusercontent.com blob:',
        img: ' https://*.googleapis.com https://*.gstatic.com *.google.com *.googleusercontent.com',
        connect: ['https://*.googleapis.com', '*.google.com', 'https://*.gstatic.com', 'data:', 'blob:'],
        font: ' https://fonts.gstatic.com',
        style: ' https://fonts.googleapis.com',
      }
    : { script: '', img: '', connect: [] as string[], font: '', style: '' };
  const csp = [
    "default-src 'self'",
    `script-src 'self' 'unsafe-inline'${options.production ? '' : " 'unsafe-eval'"}${maps.script}`,
    `style-src 'self' 'unsafe-inline'${maps.style}`,
    `img-src 'self' data: blob:${supabase ? ` ${supabase.origin}` : ''}${maps.img}`,
    `font-src 'self' data:${maps.font}`,
    `connect-src 'self' ${[...supabaseOrigins, ...(options.connectSrc ?? []), ...maps.connect].join(' ')}`.trim(),
    ...(options.googleMaps ? ['frame-src *.google.com', 'worker-src blob:'] : []),
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
    // Never against a plain-http Supabase: that is a local stack, and upgrading its requests
    // to https would break every call. Deployed projects are https only.
    ...(options.production && supabase?.protocol !== 'http:' ? ['upgrade-insecure-requests'] : []),
  ].join('; ');

  const headers: Header[] = [
    { key: 'Content-Security-Policy', value: csp },
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'X-Frame-Options', value: 'DENY' },
    { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
    { key: 'Cross-Origin-Opener-Policy', value: 'same-origin' },
    {
      key: 'Permissions-Policy',
      value: [
        'camera=()',
        'microphone=()',
        `geolocation=(${options.allowGeolocation ? 'self' : ''})`,
        'payment=()',
        'usb=()',
        'interest-cohort=()',
      ].join(', '),
    },
  ];
  if (options.production) {
    headers.push({
      key: 'Strict-Transport-Security',
      value: 'max-age=63072000; includeSubDomains; preload',
    });
  }
  return headers;
}
