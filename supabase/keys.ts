export function supabaseUrl(): string {
  const value = Deno.env.get('SUPABASE_URL');
  if (!value) throw new Error('SUPABASE_URL is not configured');
  return value;
}

export function supabaseSecretKey(): string {
  const value = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!value) throw new Error('Supabase server secret is not configured');
  return value;
}
