import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

// Le mode démonstration reste disponible tant que les variables Supabase ne sont pas renseignées.
// Les Edge Functions du projet autorisent authorization/apikey/content-type en CORS,
// mais leur configuration actuelle n'inclut pas x-client-info. Retirer cet en-tête
// seulement pour les appels Functions évite que le navigateur bloque le prévol CORS.
const fetchWithoutFunctionClientInfo: typeof fetch = (input, init) => {
  const requestUrl = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (!requestUrl.includes('/functions/v1/')) return fetch(input, init);
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
  headers.delete('x-client-info');
  return fetch(input, { ...init, headers });
};

export const supabase = url && anonKey
  ? createClient(url, anonKey, { global: { fetch: fetchWithoutFunctionClientInfo } })
  : null;

export async function requestAppointment(specialtyId: number, startsAt: string, smsRemindersEnabled = false) {
  if (!supabase) throw new Error('Le service de réservation n’est pas configuré.');
  const { data, error } = await supabase.rpc('request_appointment', {
    p_specialty_id: specialtyId,
    p_starts_at: startsAt,
    p_sms_reminders_enabled: smsRemindersEnabled,
  });
  if (error) throw new Error(error.message.includes('slot_full') ? 'Ce créneau est complet. Rechargez les disponibilités.' : error.message);
  return data as string;
}

export async function requestAppointmentByName(specialtyName: string, date: string, time: string, smsRemindersEnabled = false) {
  if (!supabase) throw new Error('Le service de réservation n’est pas configuré.');
  const { data: specialty, error: specialtyError } = await supabase.from('specialties').select('id').eq('nom', specialtyName).single();
  if (specialtyError || !specialty) throw new Error('Cette spécialité n’est pas disponible. Rechargez la page.');
  const startsAt = new Date(`${date}T${time}:00`).toISOString();
  const { data, error } = await supabase.rpc('request_appointment', { p_specialty_id: specialty.id, p_starts_at: startsAt, p_sms_reminders_enabled: smsRemindersEnabled });
  if (error) throw new Error(error.message.includes('slot_full') ? 'Ce créneau est complet. Rechargez les disponibilités.' : 'Impossible de réserver ce créneau. Réessayez.');
  return data as string;
}

export async function signInWithIdentifier(identifier: string, password: string) {
  if (!supabase) throw new Error('Le service d’identification n’est pas configuré.');
  const { data, error } = await supabase.functions.invoke('identifier-login', { body: { identifier: identifier.trim(), password } });
  if (error || data?.error) throw new Error(data?.message || 'Identifiant ou mot de passe incorrect.');
  const { data: session, error: sessionError } = await supabase.auth.setSession({ access_token: data.access_token, refresh_token: data.refresh_token });
  if (sessionError || !session.user) throw new Error('La connexion n’a pas pu être finalisée.');
  return session;
}

export async function createPatientAccount(input: Record<string, string>) {
  if (!supabase) throw new Error('Le service de création de compte n’est pas configuré.');
  const { data, error } = await supabase.functions.invoke('create-account', {
    body: { role: 'patient', ...input },
  });
  if (error || data?.error) throw new Error(data?.message || error?.message || 'La création du compte a échoué.');
  return data as { id: string; role: string };
}
