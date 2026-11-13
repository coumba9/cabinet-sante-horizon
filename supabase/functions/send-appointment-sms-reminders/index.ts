import { createClient } from 'npm:@supabase/supabase-js@2';

const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { 'Content-Type': 'application/json' },
});

const normalizeSenegalNumber = (raw: string) => {
  let digits = raw.replace(/\D/g, '');
  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('0')) digits = digits.slice(1);
  if (!digits.startsWith('221')) digits = `221${digits}`;
  return `+${digits}`;
};

const reminderText = (kind: string, date: Date, specialty: string) => {
  const when = new Intl.DateTimeFormat('fr-FR', {
    timeZone: 'Africa/Dakar', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(date);
  const lead = kind === 'confirmation' ? 'confirme' : kind === 'reprogrammed' ? 'reprogramme' : kind === '24h' ? 'rappel : demain' : 'rappel : dans 5 heures';
  const plainSpecialty = specialty.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  return `Cabinet Sante Horizon: rendez-vous ${lead} le ${when}, specialite ${plainSpecialty}. Pour annuler, connectez-vous a votre espace patient ou contactez le cabinet.`;
};

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);

  // Cette fonction est invoquée par pg_cron via pg_net avec une clé secrète en-tête.
  const keySet = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
  const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? keySet.default ?? Object.values(keySet)[0];
  const cronSecret = Deno.env.get('SMS_CRON_SECRET');
  if (!supabaseKey || !cronSecret || req.headers.get('apikey') !== cronSecret) return reply({ error: 'unauthorized' }, 401);
  const apiKey = Deno.env.get('DEXNOTIFY_API_KEY');
  const sender = Deno.env.get('DEXNOTIFY_SMS_SENDER') ?? 'DSMS';
  if (!apiKey) return reply({ error: 'sms_provider_not_configured' }, 503);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, supabaseKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const now = new Date();

  // Reprend les envois interrompus, puis récupère les notifications arrivées à échéance.
  await admin.from('appointment_sms_jobs').update({ status: 'pending', updated_at: now.toISOString() })
    .eq('status', 'sending').lt('updated_at', new Date(now.getTime() - 5 * 60_000).toISOString());

  const { data: jobs, error } = await admin.from('appointment_sms_jobs')
    .select('id,kind,attempts,appointment:appointments!inner(id,date,statut,sms_reminders_enabled,patient:patients!appointments_patient_id_fkey(profile:profiles!patients_id_fkey(telephone,telephone_verified_at,sms_consent_at)),specialty:specialties!appointments_specialite_id_fkey(nom))')
    .eq('status', 'pending').lte('scheduled_at', now.toISOString()).order('scheduled_at').limit(50);
  if (error) return reply({ error: 'queue_read_failed' }, 500);

  let sent = 0;
  for (const job of jobs ?? []) {
    const claim = await admin.from('appointment_sms_jobs').update({ status: 'sending', updated_at: new Date().toISOString() })
      .eq('id', job.id).eq('status', 'pending').select('id').maybeSingle();
    if (claim.error || !claim.data) continue;

    const appointment = Array.isArray(job.appointment) ? job.appointment[0] : job.appointment;
    const patient = Array.isArray(appointment?.patient) ? appointment.patient[0] : appointment?.patient;
    const profile = Array.isArray(patient?.profile) ? patient.profile[0] : patient?.profile;
    const validStatus = job.kind === 'confirmation' ? appointment?.statut === 'confirmé'
      : job.kind === 'reprogrammed' ? appointment?.statut === 'reprogrammé'
      : ['confirmé', 'reprogrammé'].includes(appointment?.statut ?? '');
    const hasConsent = Boolean(profile?.sms_consent_at || appointment?.sms_reminders_enabled);
    const isReminder = ['24h', '5h', 'reprogrammed'].includes(job.kind);
    if ((isReminder && !appointment?.sms_reminders_enabled) || (job.kind === 'confirmation' && !hasConsent) || !validStatus || !profile?.telephone || !profile?.telephone_verified_at) {
      await admin.from('appointment_sms_jobs').update({ status: 'cancelled', updated_at: new Date().toISOString() }).eq('id', job.id);
      continue;
    }

    try {
      // Revalider immédiatement avant l'appel externe : un report/annulation
      // intervenu après la lecture de la file ne doit pas envoyer l'ancien rappel.
      const { data: currentJob } = await admin.from('appointment_sms_jobs').select('status,kind,scheduled_at').eq('id', job.id).maybeSingle();
      const { data: currentAppt } = await admin.from('appointments').select('date,statut,sms_reminders_enabled,patient:patients!appointments_patient_id_fkey(profile:profiles!patients_id_fkey(telephone,telephone_verified_at,sms_consent_at)),specialty:specialties!appointments_specialite_id_fkey(nom)').eq('id', appointment.id).maybeSingle();
      const freshAppt = currentAppt as any;
      const freshPatient = Array.isArray(freshAppt?.patient) ? freshAppt.patient[0] : freshAppt?.patient;
      const freshProfile = Array.isArray(freshPatient?.profile) ? freshPatient.profile[0] : freshPatient?.profile;
      const freshSpecialty = Array.isArray(freshAppt?.specialty) ? freshAppt.specialty[0] : freshAppt?.specialty;
      const unchangedSchedule = freshAppt && new Date(freshAppt.date).getTime() === new Date(appointment.date).getTime();
      const freshHasConsent = Boolean(freshProfile?.sms_consent_at || freshAppt?.sms_reminders_enabled);
      const stillValid = currentJob?.status === 'sending' && unchangedSchedule && freshProfile?.telephone_verified_at && (job.kind === 'confirmation' ? freshAppt.statut === 'confirmé' && freshHasConsent : job.kind === 'reprogrammed' ? freshAppt.statut === 'reprogrammé' && freshAppt.sms_reminders_enabled : ['confirmé','reprogrammé'].includes(freshAppt.statut) && freshAppt.sms_reminders_enabled);
      if (!stillValid) {
        await admin.from('appointment_sms_jobs').update({ status: 'cancelled', updated_at: new Date().toISOString() }).eq('id', job.id).eq('status', 'sending');
        continue;
      }
      const deliveryResponse = await fetch('https://api.dexnotify.com/api/v1/sms/messages', {
        method: 'POST',
        headers: {
          'x-api-key': apiKey,
          'content-type': 'application/json',
          'idempotency-key': `appointment-${job.id}-${job.kind}`,
        },
        body: JSON.stringify({
          sender,
          to: normalizeSenegalNumber(freshProfile.telephone),
          type: 'single',
          content: reminderText(job.kind, new Date(freshAppt.date), freshSpecialty?.nom ?? 'consultation'),
        }),
      });
      const delivery = await deliveryResponse.json().catch(() => ({})) as Record<string, unknown>;
      if (!deliveryResponse.ok) {
        const providerError = delivery.message ?? delivery.error;
        const message = typeof providerError === 'string'
          ? providerError
          : JSON.stringify(providerError ?? { error: `DexNotify SMS HTTP ${deliveryResponse.status}` });
        throw new Error(message.slice(0, 120));
      }
      const providerId = String(delivery.id ?? delivery.messageId ?? delivery.message_id ?? delivery.message?.id ?? '') || null;
      await admin.from('appointment_sms_jobs').update({ status: 'sent', provider_message_id: providerId, last_error: null, sent_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', job.id);
      await admin.from('audit_log').insert({ action: 'sms rendez-vous envoyé', entity: 'sms_job', entity_id: String(job.id), details: { kind: job.kind, provider: 'dexnotify' } });
      sent++;
    } catch (cause) {
      const attempts = Number(job.attempts ?? 0) + 1;
      await admin.from('appointment_sms_jobs').update({
        status: attempts >= 3 ? 'failed' : 'pending', attempts,
        last_error: cause instanceof Error ? cause.message.slice(0, 120) : 'provider_error',
        updated_at: new Date().toISOString(),
      }).eq('id', job.id);
    }
  }
  return reply({ processed: jobs?.length ?? 0, sent });
});
