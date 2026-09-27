# web-config

Configuration shared by the three Next.js apps, imported by relative path from each
`next.config.ts` (it is not an npm workspace, so it cannot be installed on its own).

- `securityHeaders.ts` — CSP, HSTS and the rest of the header set (audit 2026-09-27 Y.11).
