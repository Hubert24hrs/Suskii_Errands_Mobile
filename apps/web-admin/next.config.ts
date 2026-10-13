import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { NextConfig } from 'next';
import { securityHeaders } from '../../packages/web-config/securityHeaders';

const dirname = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  // Monorepo: trace output files from the repo root, not the user's home dir
  // (Next otherwise picks up a stray package-lock.json above the workspace).
  outputFileTracingRoot: path.join(dirname, '../..'),
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: '/:path*',
        headers: securityHeaders({
          supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
          production: process.env.NODE_ENV === 'production',
          allowGeolocation: false,
          // Edge Functions live under the Supabase origin when deployed; a local run
          // may serve them elsewhere (tests/web-admin-e2e).
          connectSrc: process.env.NEXT_PUBLIC_SUPABASE_FUNCTIONS_URL
            ? [new URL(process.env.NEXT_PUBLIC_SUPABASE_FUNCTIONS_URL).origin]
            : [],
        }),
      },
    ];
  },
};

export default nextConfig;
