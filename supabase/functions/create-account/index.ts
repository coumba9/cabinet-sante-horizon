import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);
  const url = supabaseUrl();
  const serviceKey = supabaseSecretKey();
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const payload = await req.json();
  const role = payload.role === 'medecin' ? 'medecin' : 'patient';

  // Seul un administrateur connecté peut provisionner un médecin; aucun endpoint public d’auto-inscription médecin.
  if (role === 'medecin') {
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
    if (!token) return reply({ error: 'unauthorized' }, 401);
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return reply({ error: 'unauthorized' }, 401);
    const { data: actorRole } = await admin.from('user_roles').select('role').eq('user_id', user.id).maybeSingle();
    const { data: actorProfile } = await admin.from('profiles').select('status').eq('id', user.id).maybeSingle();
    if (actorRole?.role !== 'administrateur' || actorProfile?.status !== 'actif') return reply({ error: 'forbidden' }, 403);
  }

  const identifier = String(payload.identifiant ?? '').trim().toLowerCase();
  const password = String(payload.password ?? '');
  const prenom = String(payload.prenom ?? '').trim();
  const nom = String(payload.nom ?? '').trim();
  const telephone = String(payload.telephone ?? '').replace(/[^0-9+]/g, '');
  if (!/^[a-z0-9._-]{3,50}$/.test(identifier) || password.length < 8 || !prenom || !nom || !telephone) {
    return reply({ error: 'invalid_input', message: 'Vérifiez les champs obligatoires et le mot de passe (8 caractères minimum).' }, 400);
  }
  const technicalEmail = `${identifier}@cabinet.local`;
  const { data: created, error: authError } = await admin.auth.admin.createUser({ email: technicalEmail, password, email_confirm: true, user_metadata: { identifier } });
  if (authError || !created.user) return reply({ error: 'account_creation_failed', message: authError?.message ?? 'Création impossible.' }, 400);
  const id = created.user.id;
  const profile = await admin.from('profiles').insert({ id, nom, prenom, telephone, identifiant, status: 'actif' });
  const roleRow = profile.error ? null : await admin.from('user_roles').insert({ user_id: id, role });
  let subtypeError = roleRow?.error;
  if (!subtypeError && role === 'patient') {
    const { error } = await admin.from('patients').insert({ id, date_naissance: payload.date_naissance || null, sexe: payload.sexe || null, groupe_sanguin: payload.groupe_sanguin || null, antecedents: payload.antecedents || '' });
    subtypeError = error;
  } else if (!subtypeError && role === 'medecin') {
    if (!payload.numero_licence || !payload.specialite_id) subtypeError = new Error('Licence et spécialité requises.');
    else {
      const { error } = await admin.from('doctors').insert({ id, numero_licence: payload.numero_licence, specialite_id: payload.specialite_id });
      subtypeError = error;
    }
  }
  if (profile.error || subtypeError) {
    await admin.auth.admin.deleteUser(id);
    return reply({ error: 'account_setup_failed', message: profile.error?.message ?? subtypeError?.message }, 400);
  }
  return reply({ id, role });
});
