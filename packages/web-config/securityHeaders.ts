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
}): Header[] {
  const supabase = options.supabaseUrl ? new URL(options.supabaseUrl) : undefined;
  const supabaseOrigins = supabase
    ? [supabase.origin, `wss://${supabase.host}`]
    : [];
  const csp = [
    "default-src 'self'",
    `script-src 'self' 'unsafe-inline'${options.production ? '' : " 'unsafe-eval'"}`,
    "style-src 'self' 'unsafe-inline'",
    `img-src 'self' data: blob:${supabase ? ` ${supabase.origin}` : ''}`,
    "font-src 'self' data:",
    `connect-src 'self' ${[...supabaseOrigins, ...(options.connectSrc ?? [])].join(' ')}`.trim(),
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
    ...(options.production ? ['upgrade-insecure-requests'] : []),
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
