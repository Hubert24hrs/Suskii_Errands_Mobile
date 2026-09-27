import localFont from 'next/font/local';

// The same font files the Flutter app bundles (packages/suskii_design),
// self-hosted by Next: no request to a font CDN, nothing to block on.
export const bodyFont = localFont({
  src: '../../../../packages/suskii_design/assets/fonts/Manrope-Variable.ttf',
  variable: '--font-body',
  display: 'swap',
  weight: '200 800',
});

export const displayFont = localFont({
  src: '../../../../packages/suskii_design/assets/fonts/Sora-Variable.ttf',
  variable: '--font-display',
  display: 'swap',
  weight: '100 800',
});
