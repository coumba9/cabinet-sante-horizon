import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-bootstrap-admin-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);

  const expected = Deno.env.get('BOOTSTRAP_ADMIN_SECRET');
  if (!expected || req.headers.get('x-bootstrap-admin-secret') !== expected) return reply({ error: 'forbidden' }, 403);

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return reply({ error: 'server_not_configured' }, 503);

  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { count, error: countError } = await admin.from('user_roles')
    .select('*', { count: 'exact', head: true }).eq('role', 'administrateur');
  if (countError) return reply({ error: 'database_error' }, 500);
  if ((count ?? 0) > 0) return reply({ error: 'bootstrap_closed' }, 409);

  const payload = await req.json();
  const identifier = String(payload.identifiant ?? 'admin.demo').trim().toLowerCase();
  const password = String(payload.password ?? '');
  const prenom = String(payload.prenom ?? 'Admin').trim();
  const nom = String(payload.nom ?? 'Cabinet').trim();
  const telephone = String(payload.telephone ?? '').replace(/[^0-9+]/g, '');
  if (!/^[a-z0-9._-]{3,50}$/.test(identifier) || password.length < 12 || !prenom || !nom || !telephone) {
    return reply({ error: 'invalid_input', message: 'Identifiant invalide ou champs manquants (mot de passe: 12 caractères minimum).' }, 400);
  }

  const { data: created, error: authError } = await admin.auth.admin.createUser({
    email: identifier + '@cabinet.local',
    password,
    email_confirm: true,
    user_metadata: { identifier },
  });
  if (authError || !created.user) return reply({ error: 'account_creation_failed', message: authError?.message }, 400);

  const id = created.user.id;
  const { error: profileError } = await admin.from('profiles').insert({
    id, nom, prenom, telephone, identifiant: identifier, status: 'actif',
  });
  const { error: roleError } = profileError ? { error: null } :
    await admin.from('user_roles').insert({ user_id: id, role: 'administrateur' });
  const { error: subtypeError } = (profileError || roleError) ? { error: null } :
    await admin.from('administrators').insert({ id, niveau_acces: 'standard' });

  if (profileError || roleError || subtypeError) {
    await admin.auth.admin.deleteUser(id);
    return reply({ error: 'account_setup_failed', message: profileError?.message ?? roleError?.message ?? subtypeError?.message }, 400);
  }
  return reply({ success: true, id, identifiant: identifier, role: 'administrateur' });
});
