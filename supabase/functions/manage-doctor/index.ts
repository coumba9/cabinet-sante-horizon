import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);
  const client = createClient(supabaseUrl(), supabaseSecretKey(), { auth: { autoRefreshToken: false, persistSession: false } });
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) return reply({ error: 'unauthorized' }, 401);
  const { data: { user: actor } } = await client.auth.getUser(token);
  if (!actor) return reply({ error: 'unauthorized' }, 401);
  const [{ data: role }, { data: actorProfile }] = await Promise.all([
    client.from('user_roles').select('role').eq('user_id', actor.id).maybeSingle(),
    client.from('profiles').select('status').eq('id', actor.id).maybeSingle(),
  ]);
  if (role?.role !== 'administrateur' || actorProfile?.status !== 'actif') return reply({ error: 'forbidden' }, 403);
  const payload = await req.json();
  const id = String(payload.id ?? '');
  const action = String(payload.action ?? '');
  if (!id || !['block','unblock','update','delete'].includes(action)) return reply({ error: 'invalid_action' }, 400);
  const { data: doctor } = await client.from('doctors').select('id,numero_licence').eq('id', id).maybeSingle();
  if (!doctor) return reply({ error: 'doctor_not_found' }, 404);

  if (action === 'block' || action === 'unblock') {
    const status = action === 'block' ? 'bloqué' : 'actif';
    const { error } = await client.from('profiles').update({ status }).eq('id', id);
    if (error) return reply({ error: 'update_failed', message: error.message }, 400);
    await client.from('audit_log').insert({ actor_id: actor.id, action: action === 'block' ? 'blocage' : 'déblocage', entity: 'compte_medecin', entity_id: id });
    return reply({ success: true });
  }

  if (action === 'delete') {
    const { count } = await client.from('payments').select('*', { count: 'exact', head: true }).eq('enregistre_par', id);
    if ((count ?? 0) > 0) return reply({ error: 'doctor_has_payments', message: 'Ce compte possède des paiements liés. Bloquez-le pour préserver l’historique.' }, 409);
    const { error } = await client.auth.admin.deleteUser(id);
    if (error) return reply({ error: 'delete_failed', message: error.message }, 400);
    await client.from('audit_log').insert({ actor_id: actor.id, action: 'suppression', entity: 'compte_medecin', entity_id: id });
    return reply({ success: true });
  }

  const profile = payload.profile ?? {};
  const doctorInput = payload.doctor ?? {};
  const changes: Record<string,string> = {};
  for (const key of ['nom','prenom','identifiant']) if (profile[key] !== undefined) changes[key] = String(profile[key]).trim();
  if (profile.telephone !== undefined) changes.telephone = String(profile.telephone).replace(/[^0-9+]/g, '');
  if (profile.identifiant) {
    const { error } = await client.auth.admin.updateUserById(id, { email: `${String(profile.identifiant).trim().toLowerCase()}@cabinet.local`, ...(profile.password ? { password: String(profile.password) } : {}) });
    if (error) return reply({ error: 'auth_update_failed', message: error.message }, 400);
  } else if (profile.password) {
    const { error } = await client.auth.admin.updateUserById(id, { password: String(profile.password) });
    if (error) return reply({ error: 'password_update_failed', message: error.message }, 400);
  }
  if (Object.keys(changes).length) {
    const { error } = await client.from('profiles').update(changes).eq('id', id);
    if (error) return reply({ error: 'profile_update_failed', message: error.message }, 400);
  }
  const doctorChanges: Record<string,string> = {};
  if (doctorInput.numero_licence) doctorChanges.numero_licence = String(doctorInput.numero_licence).trim();
  if (doctorInput.specialite_id) doctorChanges.specialite_id = String(doctorInput.specialite_id);
  if (Object.keys(doctorChanges).length) {
    const { error } = await client.from('doctors').update(doctorChanges).eq('id', id);
    if (error) return reply({ error: 'doctor_update_failed', message: error.message }, 400);
  }
  await client.from('audit_log').insert({ actor_id: actor.id, action: 'modification', entity: 'compte_medecin', entity_id: id });
  return reply({ success: true });
});
