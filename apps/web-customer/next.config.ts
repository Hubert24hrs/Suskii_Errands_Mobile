import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { NextConfig } from 'next';

const dirname = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  // Monorepo: trace output files from the repo root, not the user's home dir
  // (Next otherwise picks up a stray package-lock.json above the workspace).
  outputFileTracingRoot: path.join(dirname, '../..'),
};

export default nextConfig;
