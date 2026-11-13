import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const url = Deno.env.get('SUPABASE_URL')!;
const keySet = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? keySet.default ?? Object.values(keySet)[0];

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, 'Content-Type': 'application/json' },
});

function normalizeSenegalPhone(raw: unknown) {
  let digits = String(raw ?? '').replace(/\D/g, '');
  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('0')) digits = digits.slice(1);
  if (!digits.startsWith('221')) digits = `221${digits}`;
  const phone = `+${digits}`;
  return /^\+221[7-9]\d{8}$/.test(phone) ? phone : null;
}

async function hashCode(challengeId: string, code: string) {
  const bytes = new TextEncoder().encode(`${challengeId}:${code}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);

  const apiKey = Deno.env.get('DEXNOTIFY_API_KEY');
  if (!apiKey) return reply({ error: 'sms_provider_not_configured', message: 'La vérification par SMS n’est pas configurée.' }, 503);
  if (!serviceKey) return reply({ error: 'server_not_configured' }, 503);
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply({ error: 'invalid_json' }, 400); }
  const phone = normalizeSenegalPhone(body.phone);
  if (!phone) return reply({ error: 'invalid_phone', message: 'Saisissez un numéro mobile sénégalais valide, par exemple 77 000 00 00.' }, 400);

  let accountId: string | null = null;
  const bearer = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (body.action === 'verify' && bearer) {
    const { data: { user } } = await admin.auth.getUser(bearer);
    if (user) {
      const [{ data: role }, { data: profile }] = await Promise.all([
        admin.from('user_roles').select('role').eq('user_id', user.id).maybeSingle(),
        admin.from('profiles').select('status').eq('id', user.id).maybeSingle(),
      ]);
      if (role?.role !== 'patient' || profile?.status !== 'actif') return reply({ error: 'forbidden' }, 403);
      accountId = user.id;
    }
  }

  if (body.action === 'start') {
    const since = new Date(Date.now() - 60 * 60_000).toISOString();
    const { data: recent, error: rateError } = await admin.from('sms_phone_verifications')
      .select('id,created_at').eq('phone_e164', phone).gte('created_at', since)
      .order('created_at', { ascending: false }).limit(3);
    if (rateError) return reply({ error: 'verification_unavailable', message: 'Impossible de vérifier le numéro pour le moment.' }, 503);
    if ((recent?.length ?? 0) >= 3 || (recent?.[0] && Date.now() - new Date(recent[0].created_at).getTime() < 60_000)) {
      return reply({ error: 'rate_limited', message: 'Attendez une minute avant de demander un nouveau code.' }, 429);
    }

    const challengeId = crypto.randomUUID();
    const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, '0');
    const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
    const { error: insertError } = await admin.from('sms_phone_verifications').insert({
      id: challengeId, phone_e164: phone, code_hash: await hashCode(challengeId, code), expires_at: expiresAt,
    });
    if (insertError) return reply({ error: 'verification_unavailable', message: 'Impossible de créer le code de vérification.' }, 503);

    try {
      const sms = await fetch('https://api.dexnotify.com/api/v1/sms/messages', {
        method: 'POST',
        headers: { 'x-api-key': apiKey, 'content-type': 'application/json', 'idempotency-key': `phone-verification-${challengeId}` },
        body: JSON.stringify({
          sender: Deno.env.get('DEXNOTIFY_SMS_SENDER') ?? 'DSMS',
          to: phone,
          type: 'single',
          content: `Cabinet Sante Horizon: votre code de verification est ${code}. Il expire dans 10 minutes.`,
        }),
      });
      if (!sms.ok) throw new Error(`provider_http_${sms.status}`);
      await admin.from('sms_phone_verifications').update({ delivery_status: 'sent', last_error: null }).eq('id', challengeId);
      return reply({ challenge_id: challengeId, expires_in: 600 });
    } catch (cause) {
      const reason = cause instanceof Error && cause.message.startsWith('provider_http_') ? cause.message : 'provider_unreachable';
      await admin.from('sms_phone_verifications').update({ status: 'failed', delivery_status: 'failed', last_error: reason }).eq('id', challengeId);
      return reply({ error: 'sms_send_failed', message: 'Le SMS de vérification n’a pas pu être envoyé. Vérifiez le numéro et réessayez.' }, 502);
    }
  }

  if (body.action === 'verify') {
    const challengeId = String(body.challenge_id ?? '');
    const code = String(body.code ?? '').trim();
    if (!/^[0-9a-f-]{36}$/i.test(challengeId) || !/^\d{6}$/.test(code)) {
      return reply({ error: 'invalid_code', message: 'Saisissez le code à six chiffres reçu par SMS.' }, 400);
    }
    const { data: challenge, error: challengeError } = await admin.from('sms_phone_verifications')
      .select('id,code_hash,status,attempts,expires_at')
      .eq('id', challengeId).eq('phone_e164', phone).maybeSingle();
    if (challengeError || !challenge || challenge.status !== 'pending' || challenge.attempts >= 5 || new Date(challenge.expires_at) <= new Date()) {
      return reply({ error: 'verification_expired', message: 'Ce code a expiré. Demandez-en un nouveau.' }, 400);
    }

    if (await hashCode(challengeId, code) !== challenge.code_hash) {
      const attempts = challenge.attempts + 1;
      await admin.from('sms_phone_verifications').update({ attempts, ...(attempts >= 5 ? { status: 'failed' } : {}) })
        .eq('id', challengeId).eq('status', 'pending');
      return reply({ error: 'invalid_code', message: attempts >= 5 ? 'Trop de tentatives. Demandez un nouveau code.' : 'Code incorrect. Vérifiez le SMS et réessayez.' }, 400);
    }

    const verifiedAt = new Date().toISOString();
    const { data: verified, error: verifyError } = await admin.from('sms_phone_verifications').update({ status: 'verified', verified_at: verifiedAt, attempts: challenge.attempts + 1 })
      .eq('id', challengeId).eq('status', 'pending').lt('attempts', 5).select('id').maybeSingle();
    if (verifyError || !verified) return reply({ error: 'verification_expired', message: 'Ce code ne peut plus être utilisé. Demandez-en un nouveau.' }, 400);

    if (accountId) {
      const { error: profileError } = await admin.from('profiles').update({ telephone: phone, telephone_verified_at: verifiedAt }).eq('id', accountId);
      if (profileError) return reply({ error: 'profile_update_failed', message: 'Le numéro est vérifié, mais le profil n’a pas pu être mis à jour.' }, 500);
      await admin.from('audit_log').insert({ actor_id: accountId, action: 'téléphone patient vérifié', entity: 'profile', entity_id: accountId, details: { verified_at: verifiedAt } });
    }
    return reply({ verified: true, phone, verified_at: verifiedAt });
  }

  return reply({ error: 'invalid_action' }, 400);
});
