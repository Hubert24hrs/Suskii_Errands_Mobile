// The local stack's URL and keys, as `supabase status -o env` prints them (CI exports them).

export const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
export const ANON_KEY = required('SUPABASE_ANON_KEY');
export const SERVICE_KEY = required('SUPABASE_SERVICE_ROLE_KEY');
export const FUNCTIONS_PORT = 54390;
export const ADMIN_PORT = 3203;
export const PASSWORD = 'e2e-Admin-Password-123!';

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set: export it from \`supabase status -o env\``);
  return value;
}
