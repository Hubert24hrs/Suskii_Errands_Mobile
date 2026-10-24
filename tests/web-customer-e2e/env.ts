// The local stack's URL and keys, as `supabase status -o env` prints them (CI exports them).

export const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
export const ANON_KEY = required('SUPABASE_ANON_KEY');
export const SERVICE_KEY = required('SUPABASE_SERVICE_ROLE_KEY');
export const WEB_PORT = 3204;
export const PASSWORD = 'e2e-Web-Password-123!';

/** Lagos, beside the state's centre: where the request is and where the provider stands. */
export const PICKUP = { latitude: 6.525, longitude: 3.38 };

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set: export it from \`supabase status -o env\``);
  return value;
}
