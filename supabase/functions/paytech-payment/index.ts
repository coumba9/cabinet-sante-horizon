import { createClient } from 'npm:@supabase/supabase-js@2';
import { supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const paymentMethods = new Set(['Wave', 'Orange Money', 'Free Money']);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);

  const serviceKey = supabaseSecretKey();
  const apiKey = Deno.env.get('PAYTECH_API_KEY');
  const apiSecret = Deno.env.get('PAYTECH_API_SECRET');
  if (!serviceKey || !apiKey || !apiSecret) return reply({ error: 'payment_provider_not_configured', message: 'Le paiement PayTech n’est pas configuré.' }, 503);

  const authorization = req.headers.get('Authorization') ?? '';
  const accessToken = authorization.replace(/^Bearer\s+/i, '');
  if (!accessToken || accessToken === authorization) return reply({ error: 'unauthorized' }, 401);
  const admin = createClient(supabaseUrl(), serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: { user } } = await admin.auth.getUser(accessToken);
  if (!user) return reply({ error: 'unauthorized' }, 401);
  const [{ data: role }, { data: profile }] = await Promise.all([
    admin.from('user_roles').select('role').eq('user_id', user.id).maybeSingle(),
    admin.from('profiles').select('status').eq('id', user.id).maybeSingle(),
  ]);
  if (role?.role !== 'administrateur' || profile?.status !== 'actif') return reply({ error: 'forbidden' }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply({ error: 'invalid_json' }, 400); }
  const appointmentId = String(body.appointment_id ?? '');
  const amount = Number(body.amount);
  const method = String(body.method ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(appointmentId) || !Number.isSafeInteger(amount) || amount < 1 || !paymentMethods.has(method)) {
    return reply({ error: 'invalid_payment', message: 'Vérifiez le montant et le mode de paiement.' }, 400);
  }

  const { data: appointment, error: appointmentError } = await admin.from('appointments')
    .select('id,date,statut,specialty:specialties!appointments_specialite_id_fkey(nom),patient:patients!appointments_patient_id_fkey(profile:profiles!patients_id_fkey(prenom,nom,telephone))')
    .eq('id', appointmentId).maybeSingle();
  if (appointmentError || !appointment || !['confirmé', 'reprogrammé', 'terminé'].includes(appointment.statut)) return reply({ error: 'appointment_not_payable', message: 'Ce rendez-vous ne peut pas être réglé.' }, 404);
  const starts = new Date(appointment.date);
  const dakarToday = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Dakar', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const appointmentDay = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Dakar', year: 'numeric', month: '2-digit', day: '2-digit' }).format(starts);
  if (appointmentDay !== dakarToday) return reply({ error: 'appointment_not_today', message: 'Le paiement au cabinet est réservé aux rendez-vous du jour.' }, 400);

  const { data: existing } = await admin.from('payments').select('id,statut,paytech_redirect_url')
    .eq('rendez_vous_id', appointmentId).in('statut', ['payé', 'en attente']).limit(1).maybeSingle();
  if (existing?.statut === 'payé') return reply({ error: 'appointment_already_paid', message: 'Ce rendez-vous est déjà réglé.' }, 409);
  if (existing?.statut === 'en attente') {
    if (existing.paytech_redirect_url) return reply({ redirect_url: existing.paytech_redirect_url, reused: true });
    return reply({ error: 'payment_already_processing', message: 'Un paiement est déjà en cours pour ce rendez-vous.' }, 409);
  }

  const refCommand = `JSH${crypto.randomUUID().replaceAll('-', '').slice(0, 24).toUpperCase()}`;
  const pendingInvoice = `ATT-${refCommand}`;
  const { data: payment, error: insertError } = await admin.from('payments').insert({
    rendez_vous_id: appointmentId, montant: amount, methode: 'mobile_money', statut: 'en attente',
    numero_facture: pendingInvoice, enregistre_par: user.id, canal_paiement: method, paytech_ref_command: refCommand,
  }).select('id').single();
  if (insertError || !payment) return reply({ error: 'payment_create_failed', message: insertError?.code === '23505' ? 'Un paiement est déjà en cours pour ce rendez-vous.' : 'Impossible de préparer le paiement.' }, 409);

  const origin = req.headers.get('origin');
  let returnBase = 'https://cabinet-sante-horizon-coumba.netlify.app';
  if (origin) {
    try {
      const parsed = new URL(origin);
      if (parsed.protocol === 'https:' && parsed.hostname.endsWith('.netlify.app')) returnBase = parsed.origin;
      if (parsed.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(parsed.hostname)) returnBase = parsed.origin;
    } catch { /* retain configured Netlify fallback */ }
  }
  const payload = {
    item_name: 'Consultation médicale',
    item_price: amount,
    currency: 'XOF',
    ref_command: refCommand,
    command_name: 'Règlement consultation Cabinet Ya Salam',
    target_payment: method,
    env: Deno.env.get('PAYTECH_ENV') === 'prod' ? 'prod' : 'test',
    ipn_url: `${supabaseUrl()}/functions/v1/paytech-ipn`,
    success_url: `${returnBase}/?paytech=success`,
    cancel_url: `${returnBase}/?paytech=cancelled`,
  };

  try {
    const response = await fetch('https://paytech.sn/api/payment/request-payment', {
      method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/json', API_KEY: apiKey, API_SECRET: apiSecret }, body: JSON.stringify(payload),
    });
    const result = await response.json().catch(() => ({})) as Record<string, unknown>;
    const redirectUrl = result.redirect_url ?? result.redirectUrl;
    if (!response.ok || result.success !== 1 || typeof redirectUrl !== 'string' || !redirectUrl.startsWith('https://paytech.sn/')) {
      await admin.from('payments').update({ statut: 'échoué', paytech_error: `PayTech HTTP ${response.status}` }).eq('id', payment.id);
      return reply({ error: 'provider_rejected', message: 'PayTech n’a pas pu préparer le paiement. Vérifiez l’activation et les clés de votre compte.' }, 502);
    }
    await admin.from('payments').update({ paytech_token: typeof result.token === 'string' ? result.token : null, paytech_redirect_url: redirectUrl }).eq('id', payment.id);
    return reply({ redirect_url: redirectUrl });
  } catch {
    await admin.from('payments').update({ statut: 'échoué', paytech_error: 'provider_unreachable' }).eq('id', payment.id);
    return reply({ error: 'provider_unreachable', message: 'PayTech est momentanément inaccessible. Réessayez dans quelques instants.' }, 502);
  }
});
