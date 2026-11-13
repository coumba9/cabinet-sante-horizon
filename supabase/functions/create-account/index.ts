import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const keySet = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? keySet.default ?? Object.values(keySet)[0];

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);
  if (!supabaseServiceKey) return reply({ error: 'server_not_configured' }, 503);
  const admin = createClient(supabaseUrl, supabaseServiceKey, { auth: { autoRefreshToken: false, persistSession: false } });
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
  let phoneDigits = String(payload.telephone ?? '').replace(/\D/g, '');
  if (phoneDigits.startsWith('00')) phoneDigits = phoneDigits.slice(2);
  if (phoneDigits.startsWith('0')) phoneDigits = phoneDigits.slice(1);
  if (!phoneDigits.startsWith('221')) phoneDigits = `221${phoneDigits}`;
  const telephone = `+${phoneDigits}`;
  if (!/^[a-z0-9._-]{3,50}$/.test(identifier) || password.length < 8 || !prenom || !nom || !/^\+221[7-9]\d{8}$/.test(telephone)) {
    return reply({ error: 'invalid_input', message: 'Vérifiez les champs obligatoires et le mot de passe (8 caractères minimum).' }, 400);
  }
  let verificationId: string | null = null;
  if (role === 'patient') {
    verificationId = String(payload.phone_verification_id ?? '');
    const { data: verified, error: verificationError } = await admin.from('sms_phone_verifications')
      .select('id').eq('id', verificationId).eq('phone_e164', telephone).eq('status', 'verified')
      .is('consumed_at', null).gt('expires_at', new Date().toISOString()).maybeSingle();
    if (verificationError || !verified) return reply({ error: 'phone_not_verified', message: 'Vérifiez votre numéro de téléphone par le code SMS avant de créer le compte.' }, 400);
  }
  const technicalEmail = `${identifier}@cabinet.local`;
  const { data: created, error: authError } = await admin.auth.admin.createUser({ email: technicalEmail, password, email_confirm: true, user_metadata: { identifier } });
  if (authError || !created.user) return reply({ error: 'account_creation_failed', message: authError?.message ?? 'Création impossible.' }, 400);
  const id = created.user.id;
  const now = new Date().toISOString();
  const smsConsent = ['true', 'on'].includes(String(payload.sms_consent ?? '').toLowerCase());
  const profile = await admin.from('profiles').insert({ id, nom, prenom, telephone, identifiant, status: 'actif', ...(role === 'patient' ? { telephone_verified_at: now, sms_consent_at: smsConsent ? now : null } : {}) });
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
  if (verificationId) {
    const { data: consumed, error: consumeError } = await admin.from('sms_phone_verifications').update({ status: 'consumed', consumed_at: now })
      .eq('id', verificationId).eq('status', 'verified').is('consumed_at', null).select('id').maybeSingle();
    if (consumeError || !consumed) {
      await admin.from('patients').delete().eq('id', id);
      await admin.from('user_roles').delete().eq('user_id', id);
      await admin.from('profiles').delete().eq('id', id);
      await admin.auth.admin.deleteUser(id);
      return reply({ error: 'phone_verification_already_used', message: 'Ce code a déjà été utilisé. Vérifiez votre numéro avec un nouveau code.' }, 400);
    }
  }
  if (smsConsent) await admin.from('audit_log').insert({ actor_id: id, action: 'consentement SMS accordé', entity: 'profile', entity_id: id, details: { recorded_at: now, source: 'inscription' } });
  return reply({ id, role });
});
