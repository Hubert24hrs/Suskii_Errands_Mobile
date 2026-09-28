/**
 * iOS Universal Links verification (RB-15), fetched by Apple's CDN when the app is installed.
 * Only /app/... paths open the app; the rest of the site stays on the web. The Team ID comes
 * from the client's Apple Developer account; until it is set there is nothing to associate.
 *
 *   APPLE_TEAM_ID       10 characters
 *   IOS_BUNDLE_ID       default com.suskiierrands.app
 */
export const dynamic = 'force-dynamic';

export function GET(): Response {
  const team = process.env.APPLE_TEAM_ID;
  if (!team) return new Response('Not found', { status: 404 });
  const appId = `${team}.${process.env.IOS_BUNDLE_ID || 'com.suskiierrands.app'}`;
  return Response.json(
    {
      applinks: {
        details: [{ appIDs: [appId], components: [{ '/': '/app/*' }] }],
      },
    },
    { headers: { 'Cache-Control': 'public, max-age=3600' } },
  );
}
