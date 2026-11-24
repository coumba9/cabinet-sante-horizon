import { addDays, format, parseISO } from 'date-fns';
import { supabase } from './supabase';

const stableSpecId = (name: string) => name === 'Médecine générale' ? 1 : name === 'Cardiologie' ? 2 : name === 'Pédiatrie' ? 3 : 100 + name.toLowerCase().split('').reduce((n, c) => (n * 31 + c.charCodeAt(0)) % 100000, 0);
const requireClient = () => { if (!supabase) throw new Error('Supabase n’est pas configuré.'); return supabase; };
export type SpecialtyRecord = { id: number; databaseId: string; name: string; displayName?: string; description: string; color: string; icon: string };
export type ProfileRecord = { id: string; nom: string; prenom: string; telephone: string; telephone_verified_at?: string | null; sms_consent_at?: string | null; status: 'actif'|'bloqué'; role: 'patient'|'medecin'|'administrateur'; specialtyId?: number };
export type AppointmentRecord = { id: string; patientId: string; patient: string; phone: string; blood: string; history: string; specialty: number; date: string; time: string; status: 'demandé'|'confirmé'|'reprogrammé'|'annulé'|'terminé'; smsRemindersEnabled: boolean };
export type AvailabilityRecord = { id: string; start: string; end: string; duration: number; status: 'actif'|'bloqué'|'libéré'; reason?: string | null };
export type ImpedimentAlert = { id:string; date:string; time:string; specialtyId:string; specialty:string; appointments:number; capacity:number; excess:number; status:'à traiter'|'traitée'; createdAt:string };
export type ImpedimentAppointment = { id:string; patient:string; phone:string; startsAt:string; specialty:string; bookedAt:string; excessOrder:number; isExcess:boolean };
export type AdminPaymentAppointment = { id:string; patient:string; phone:string; startsAt:string; specialty:string; appointmentStatus:string; paymentStatus:string; paymentMethod:string|null; paymentReference:string|null; invoiceNumber:string|null; amount:number|null };
export type PatientInvoiceRecord = { paymentId:string; appointmentId:string; invoiceNumber:string; paidAt:string; patientName:string; patientPhone:string; appointmentAt:string; specialty:string; paymentMethod:string; paymentReference:string|null; amount:number };
export type PatientNotificationRecord = { id:string; appointmentId:string|null; title:string; message:string; createdAt:string; read:boolean };
export type MessageRecord = { id: string; senderId: string; recipientId: string; content: string; date: string; mine: boolean; sender: string; recipient: string };

export async function loadCurrentProfile(): Promise<ProfileRecord> {
  const client = requireClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) throw new Error('Session expirée. Identifiez-vous de nouveau.');
  const [{ data: profile, error }, { data: roleRow, error: roleError }, { data: doctor }] = await Promise.all([
    client.from('profiles').select('id,nom,prenom,telephone,telephone_verified_at,sms_consent_at,status').eq('id', user.id).single(),
    client.from('user_roles').select('role').eq('user_id', user.id).single(),
    client.from('doctors').select('specialite_id').eq('id', user.id).maybeSingle(),
  ]);
  if (error || roleError || !profile || !roleRow) throw new Error('Impossible de charger votre profil. Vérifiez la configuration de vos tables.');
  const { data: specs } = await client.from('specialties').select('id,nom');
  const match = specs?.find(s => s.id === doctor?.specialite_id);
  return { ...profile, role: roleRow.role, specialtyId: match ? stableSpecId(match.nom) : undefined };
}

export async function loadSpecialties(): Promise<SpecialtyRecord[]> {
  const { data, error } = await requireClient().from('specialties').select('id,nom,description').order('nom');
  if (error) throw new Error('Impossible de charger les spécialités.');
  const priority=(name:string)=>name==='Médecine générale'?0:name==='Pédiatrie'?1:name==='Dentiste'?2:name.startsWith('Gyn')?3:name==='Cardiologie'?4:5;
  return (data ?? []).map(s => ({ id: stableSpecId(s.nom), databaseId: s.id, name: s.nom, displayName:s.nom==='Médecine générale'?'Médecin pour tout':undefined, description:s.nom==='Médecine générale'?'Pour tout problème. Si vous ne savez pas quoi choisir, commencez ici.':s.description, color: s.nom === 'Cardiologie'||s.nom.startsWith('Gyn') ? 'rose' : s.nom === 'Pédiatrie'||s.nom==='Dentiste' ? 'blue' : 'sage', icon: s.nom === 'Médecine générale' ? 'stethoscope' : s.nom === 'Cardiologie' ? '♡' : s.nom === 'Pédiatrie' ? '⌂' : s.nom === 'Dentiste' ? '✦' : s.nom.startsWith('Gyn') ? '✿' : '✳' })).sort((a,b)=>priority(a.name)-priority(b.name)||a.name.localeCompare(b.name,'fr'));
}

export async function loadAppointments(role: ProfileRecord['role']): Promise<AppointmentRecord[]> {
  const client = requireClient();
  const { data, error } = await client.from('appointments').select('id,patient_id,specialite_id,date,statut,sms_reminders_enabled, patient:patients!appointments_patient_id_fkey(id,groupe_sanguin,antecedents,profile:profiles!patients_id_fkey(nom,prenom,telephone)), specialty:specialties!appointments_specialite_id_fkey(nom)').order('date', { ascending: true });
  if (error) throw new Error('Impossible de charger les rendez-vous.');
  return (data ?? []).map((row: any) => {
    const patient = Array.isArray(row.patient) ? row.patient[0] : row.patient;
    const profile = Array.isArray(patient?.profile) ? patient.profile[0] : patient?.profile;
    const spec = Array.isArray(row.specialty) ? row.specialty[0] : row.specialty;
    const date = new Date(row.date);
    return { id: row.id, patientId: row.patient_id, patient: role === 'patient' ? `${profile?.prenom ?? ''} ${profile?.nom ?? ''}`.trim() : `${profile?.prenom ?? ''} ${profile?.nom ?? ''}`.trim() || 'Patient', phone: profile?.telephone ?? '', blood: patient?.groupe_sanguin ?? 'Non renseigné', history: patient?.antecedents ?? '', specialty: stableSpecId(spec?.nom ?? ''), date: date.toISOString().slice(0, 10), time: date.toISOString().slice(11, 16), status: row.statut, smsRemindersEnabled: row.sms_reminders_enabled === true };
  });
}

export async function loadAdminPaymentAppointments(): Promise<AdminPaymentAppointment[]> {
  const { data, error } = await requireClient().rpc('admin_today_payment_appointments');
  if (error) throw new Error('Impossible de charger les rendez-vous du jour pour le règlement.');
  return (data ?? []).map((row: any) => ({
    id: row.appointment_id,
    patient: row.patient_name,
    phone: row.patient_phone,
    startsAt: row.starts_at,
    specialty: row.specialty,
    appointmentStatus: row.appointment_status,
    paymentStatus: row.payment_status,
    paymentMethod: row.payment_method,
    paymentReference: row.payment_reference,
    invoiceNumber: row.invoice_number,
    amount: row.amount == null ? null : Number(row.amount),
  }));
}

export async function loadPatientInvoices(): Promise<PatientInvoiceRecord[]> {
  const { data, error } = await requireClient().rpc('patient_paid_invoices');
  if (error) throw new Error('Impossible de charger vos factures.');
  return (data ?? []).map((row: any) => ({
    paymentId: row.payment_id,
    appointmentId: row.appointment_id,
    invoiceNumber: row.invoice_number,
    paidAt: row.paid_at,
    patientName: row.patient_name,
    patientPhone: row.patient_phone,
    appointmentAt: row.appointment_at,
    specialty: row.specialty,
    paymentMethod: row.payment_method,
    paymentReference: row.transaction_reference,
    amount: Number(row.amount),
  }));
}

export async function loadAdminPaidInvoice(appointmentId: string): Promise<PatientInvoiceRecord> {
  const { data, error } = await requireClient().rpc('admin_paid_invoice_details', { p_appointment_id: appointmentId });
  if (error || !data?.length) throw new Error('Facture payée introuvable ou accès non autorisé.');
  const row = data[0];
  return {
    paymentId: row.payment_id,
    appointmentId: row.appointment_id,
    invoiceNumber: row.invoice_number,
    paidAt: row.paid_at,
    patientName: row.patient_name,
    patientPhone: row.patient_phone,
    appointmentAt: row.appointment_at,
    specialty: row.specialty,
    paymentMethod: row.payment_method,
    paymentReference: row.transaction_reference,
    amount: Number(row.amount),
  };
}

export async function recordAdminOnsitePayment(appointmentId: string, amount: number, method: string, reference: string): Promise<string> {
  const { data, error } = await requireClient().rpc('admin_record_onsite_payment', {
    p_appointment_id: appointmentId,
    p_amount: amount,
    p_method: method,
    p_reference: reference || null,
  });
  if (error) {
    const message = error.message;
    if (message.includes('payment_reference_required')) throw new Error('Saisissez la référence de transaction pour ce paiement mobile.');
    if (message.includes('payment_reference_already_used')) throw new Error('Cette référence de transaction a déjà été enregistrée.');
    if (message.includes('paytech_payment_pending')) throw new Error('Un paiement PayTech est déjà en cours. Reprenez-le ou attendez son résultat.');
    if (message.includes('appointment_already_paid')) throw new Error('Ce rendez-vous est déjà réglé.');
    if (message.includes('appointment_not_today')) throw new Error('Le règlement ne peut être enregistré que pour un rendez-vous du jour.');
    if (message.includes('invalid_payment_amount')) throw new Error('Saisissez un montant supérieur à zéro.');
    throw new Error('Impossible d’enregistrer le règlement. Actualisez la page puis réessayez.');
  }
  return String(data);
}

export async function startPaytechPayment(appointmentId: string, amount: number, method: string): Promise<string> {
  const { data, error } = await requireClient().functions.invoke('paytech-payment', { body: { appointment_id: appointmentId, amount, method } });
  if (error || data?.error) {
    if (data?.error === 'appointment_already_paid') throw new Error(data.message || 'Ce rendez-vous est déjà réglé.');
    if (data?.error === 'appointment_not_today') throw new Error(data.message || 'Le paiement PayTech est réservé aux rendez-vous du jour.');
    if (data?.error === 'payment_already_processing') throw new Error(data.message || 'Un paiement est déjà en cours pour ce rendez-vous.');
    throw new Error(data?.message || error?.message || 'Impossible de préparer le paiement PayTech.');
  }
  if (typeof data?.redirect_url !== 'string' || !data.redirect_url.startsWith('https://paytech.sn/')) throw new Error('PayTech n’a pas renvoyé de lien de paiement valide.');
  return data.redirect_url;
}

export async function loadAvailableSlots(specialtyId: number, date: string): Promise<Array<{ time: string; remaining: number }>> {
  const client = requireClient();
  const specialty = (await loadSpecialties()).find(s => s.id === specialtyId);
  if (!specialty) return [];
  const { data, error } = await client.rpc('available_slots', { p_specialty_id: specialty.databaseId, p_day: date });
  if (error) throw new Error('Impossible de charger les créneaux disponibles.');
  return (data ?? []).map((slot: any) => ({ time: new Date(slot.starts_at).toISOString().slice(11, 16), remaining: Number(slot.remaining) })).filter((s: { remaining: number }) => s.remaining > 0);
}

export async function changeAppointment(id: string, newDateTime: string | null) {
  const { error } = await requireClient().rpc('change_appointment', { p_appointment_id: id, p_new_starts_at: newDateTime ? new Date(newDateTime.includes('+') || /Z$/.test(newDateTime) ? newDateTime : `${newDateTime}+00:00`).toISOString() : null });
  if (error) throw new Error(error.message.includes('change_window') ? 'La modification est possible jusqu’à 24 h avant le rendez-vous.' : error.message.includes('slot_full') ? 'Ce créneau vient d’être réservé, choisissez-en un autre.' : error.message.includes('slot_past') ? 'La nouvelle date est déjà passée. Choisissez un autre créneau.' : 'Impossible de modifier ce rendez-vous. Actualisez la page puis réessayez.');
}

export async function doctorChangeAppointment(id: string, newDateTime: string | null) {
  const { error } = await requireClient().rpc('doctor_change_appointment', { p_appointment_id: id, p_new_starts_at: newDateTime ? new Date(newDateTime.includes('+') || /Z$/.test(newDateTime) ? newDateTime : `${newDateTime}+00:00`).toISOString() : null });
  if (error) throw new Error(error.message.includes('slot_full') ? 'Ce créneau vient d’être réservé, choisissez-en un autre.' : error.message.includes('slot_past') ? 'La nouvelle date est déjà passée. Choisissez un autre créneau.' : 'Impossible de modifier ce rendez-vous. Actualisez la page puis réessayez.');
}

export async function setAppointmentSmsReminders(id: string, enabled: boolean) {
  const { error } = await requireClient().rpc('set_appointment_sms_reminders', { p_appointment_id: id, p_enabled: enabled });
  if (error) throw new Error(error.message.includes('phone_not_verified') ? 'Vérifiez votre numéro de téléphone avant d’activer les rappels SMS.' : 'Impossible de modifier les rappels SMS de ce rendez-vous.');
}

export async function confirmAppointment(id: string) {
  const { error } = await requireClient().rpc('confirm_appointment', { p_appointment_id: id });
  if (error) throw new Error('Ce rendez-vous ne peut pas être confirmé. Actualisez la page.');
}

export async function completeAppointment(id: string) {
  const { error } = await requireClient().rpc('complete_appointment', { p_appointment_id: id });
  if (error) throw new Error(error.message.includes('appointment_not_due') ? 'Le rendez-vous ne peut être terminé qu’à partir de l’heure prévue.' : 'Ce rendez-vous ne peut pas être terminé. Actualisez la page.');
}

export async function loadAvailabilities(): Promise<AvailabilityRecord[]> {
  const client = requireClient(); const { data: { user } } = await client.auth.getUser();
  if (!user) throw new Error('Session expirée.');
  const { data, error } = await client.from('availabilities').select('id,date_debut,date_fin,duree_creneau_min,status,motif_empechement').eq('medecin_id',user.id).order('date_debut');
  if (error) throw new Error('Impossible de charger vos disponibilités.');
  return (data ?? []).map(a => ({ id: a.id, start: a.date_debut, end: a.date_fin, duration: a.duree_creneau_min, status: a.status, reason:a.motif_empechement }));
}

export async function saveAvailability(input: { start: string; end: string; duration: number }) {
  const { data: { user } } = await requireClient().auth.getUser();
  if (!user) throw new Error('Session expirée.');
  const { error } = await requireClient().from('availabilities').insert({ medecin_id: user.id, date_debut: new Date(input.start).toISOString(), date_fin: new Date(input.end).toISOString(), duree_creneau_min: input.duration, status: 'actif' });
  if (error) throw new Error('Impossible d’enregistrer cette disponibilité. Vérifiez les horaires.');
}

export async function doctorAvailabilityImpact(id:string) {
  const {data,error}=await requireClient().rpc('doctor_availability_impediment_impact',{p_availability_id:id});
  if(error)throw new Error('Impossible de calculer les rendez-vous qui pourraient être concernés.');
  return Number(data||0);
}

export async function updateAvailability(id: string, status: 'actif'|'bloqué'|'libéré',reason='') {
  const { error } = await requireClient().rpc('doctor_change_availability', { p_availability_id: id, p_status: status, p_delete: false,p_reason:reason });
  if (error) throw new Error(error.message.includes('impediment_reason_required') ? 'Indiquez le motif de l’empêchement (au moins 3 caractères).' : error.message.includes('unauthorized') ? 'Action réservée au médecin concerné.' : 'Impossible de modifier cette disponibilité.');
}

export async function deleteAvailability(id: string,reason='') {
  const { error } = await requireClient().rpc('doctor_change_availability', { p_availability_id: id, p_status: null, p_delete: true,p_reason:reason });
  if (error) throw new Error(error.message.includes('impediment_reason_required') ? 'Indiquez le motif du retrait (au moins 3 caractères).' : error.message.includes('unauthorized') ? 'Action réservée au médecin concerné.' : error.message.includes('availability_has_appointments') ? 'Retrait impossible : un rendez-vous est déjà réservé sur cette plage. Bloquez la disponibilité avec un motif pour déclencher le recalcul.' : 'Impossible de retirer cette disponibilité. Actualisez la page puis réessayez.');
}

export async function loadImpedimentAlerts():Promise<ImpedimentAlert[]> {
 const {data,error}=await requireClient().from('alertes_empechement').select('id,date,heure,specialite_id,nb_rendez_vous,capacite,nb_excedent,statut,created_at,specialty:specialties!alertes_empechement_specialite_id_fkey(nom)').order('date',{ascending:false}).order('heure',{ascending:false});
 if(error)throw new Error('Impossible de charger les alertes d’empêchement. Appliquez la migration Supabase.');
 return (data??[]).map((r:any)=>{const s=Array.isArray(r.specialty)?r.specialty[0]:r.specialty;return{id:r.id,date:r.date,time:String(r.heure).slice(0,5),specialtyId:r.specialite_id,specialty:s?.nom??'Spécialité',appointments:Number(r.nb_rendez_vous),capacity:Number(r.capacite),excess:Number(r.nb_excedent),status:r.statut,createdAt:r.created_at}});
}

export async function loadImpedimentAppointments(alertId:string):Promise<ImpedimentAppointment[]> {
 const {data,error}=await requireClient().rpc('admin_list_impediment_appointments',{p_alert_id:alertId});
 if(error)throw new Error('Impossible de charger la liste des rendez-vous de ce créneau.');
 return (data??[]).map((r:any)=>({id:r.appointment_id,patient:r.patient_name,phone:r.patient_phone,startsAt:r.starts_at,specialty:r.specialty,bookedAt:r.booked_at,excessOrder:Number(r.excess_order),isExcess:r.is_excess}));
}

export async function loadAdminImpedimentSlots(appointmentId:string,day:string):Promise<Array<{startsAt:string;time:string;remaining:number}>> {
 const {data,error}=await requireClient().rpc('admin_impediment_available_slots',{p_appointment_id:appointmentId,p_day:day});
 if(error)throw new Error('Impossible de charger les créneaux disponibles de cette spécialité.');
 return (data??[]).map((r:any)=>({startsAt:r.starts_at,time:new Date(r.starts_at).toISOString().slice(11,16),remaining:Number(r.remaining)}));
}

export async function adminRescheduleImpedimentAppointment(id:string,startsAt:string) {
 const {error}=await requireClient().rpc('admin_reschedule_impediment_appointment',{p_appointment_id:id,p_new_starts_at:startsAt});
 if(error)throw new Error(error.message.includes('slot_full')?'Ce créneau vient d’être réservé, choisissez-en un autre.':error.message.includes('slot_past')?'La nouvelle date est déjà passée.':error.message.includes('impediment_alert_resolved')?'La capacité a été recalculée et cette alerte est déjà traitée. Actualisez la liste.':error.message.includes('appointment_not_changeable')?'Ce rendez-vous a déjà été traité. Actualisez la liste.':'Impossible de reporter ce rendez-vous.');
}

export async function adminCancelImpedimentAppointment(id:string,reason:string) {
 const {error}=await requireClient().rpc('admin_cancel_impediment_appointment',{p_appointment_id:id,p_reason:reason});
 if(error)throw new Error(error.message.includes('cancellation_reason_required')?'Le motif d’annulation est obligatoire.':error.message.includes('impediment_alert_resolved')?'La capacité a été recalculée et cette alerte est déjà traitée. Actualisez la liste.':error.message.includes('appointment_not_changeable')?'Ce rendez-vous a déjà été traité. Actualisez la liste.':'Impossible d’annuler ce rendez-vous.');
}

export async function loadPatientNotifications():Promise<PatientNotificationRecord[]> {
 const {data,error}=await requireClient().from('patient_notifications').select('id,appointment_id,title,body,created_at,read_at').order('created_at',{ascending:false}).limit(50);
 if(error)throw new Error('Impossible de charger les notifications.');
 return (data??[]).map((r:any)=>({id:r.id,appointmentId:r.appointment_id,title:r.title,message:r.body,createdAt:r.created_at,read:Boolean(r.read_at)}));
}

export async function markPatientNotificationsRead(ids:string[]) {
 if(!ids.length)return;
 const {error}=await requireClient().from('patient_notifications').update({read_at:new Date().toISOString()}).in('id',ids).is('read_at',null);
 if(error)throw new Error('Impossible de marquer les notifications comme lues.');
}

export async function loadMessages(): Promise<MessageRecord[]> {
  const client = requireClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) throw new Error('Session expirée.');
  const { data, error } = await client.from('messages').select('id,expediteur_id,destinataire_id,contenu,date').or(`expediteur_id.eq.${user.id},destinataire_id.eq.${user.id}`).order('date');
  if (error) throw new Error('Impossible de charger les messages.');
  const partnerIds = [...new Set((data ?? []).flatMap(m => [m.expediteur_id, m.destinataire_id]).filter(id => id !== user.id))];
  const { data: profiles } = partnerIds.length ? await client.from('profiles').select('id,prenom,nom').in('id', partnerIds) : { data: [] };
  const names = new Map((profiles ?? []).map(p => [p.id, `${p.prenom} ${p.nom}`]));
  return (data ?? []).map(m => ({ id: m.id, senderId: m.expediteur_id, recipientId: m.destinataire_id, content: m.contenu, date: m.date, mine: m.expediteur_id === user.id, sender: names.get(m.expediteur_id) ?? 'Moi', recipient: names.get(m.destinataire_id) ?? 'Cabinet' }));
}

export async function sendAppointmentMessage(appointmentId: string, content: string) {
  const { error } = await requireClient().rpc('send_appointment_message', { p_appointment_id: appointmentId, p_content: content });
  if (error) throw new Error('Impossible d’envoyer ce message pour ce rendez-vous.');
}

export async function loadDoctors() {
  const { data, error } = await requireClient().from('doctors').select('id,numero_licence,specialite_id, profile:profiles!doctors_id_fkey(prenom,nom,telephone,identifiant,status), specialty:specialties!doctors_specialite_id_fkey(nom)').order('numero_licence');
  if (error) throw new Error('Impossible de charger les médecins.');
  return (data ?? []).map((d: any) => { const profile = Array.isArray(d.profile) ? d.profile[0] : d.profile; const spec = Array.isArray(d.specialty) ? d.specialty[0] : d.specialty; return { id: d.id, name: `Dr ${profile?.prenom ?? ''} ${profile?.nom ?? ''}`.trim(), phone: profile?.telephone ?? '', identifier: profile?.identifiant ?? '', specialty: stableSpecId(spec?.nom ?? ''), license: d.numero_licence, active: profile?.status === 'actif' }; });
}

export async function createDoctorAccount(input: { prenom: string; nom: string; telephone: string; identifiant: string; password: string; numero_licence: string; specialite_id: string }) {
  const { data, error } = await requireClient().functions.invoke('create-account', { body: { role: 'medecin', ...input } });
  if (error || data?.error) throw new Error(data?.message || 'La création du compte médecin a échoué.');
}

export async function manageDoctor(input: { action: 'block'|'unblock'|'update'|'delete'; id: string; profile?: Record<string,string>; doctor?: Record<string,string> }) {
  const { data, error } = await requireClient().functions.invoke('manage-doctor', { body: input });
  if (error || data?.error) throw new Error(data?.message || 'Impossible de modifier ce compte médecin.');
}

export async function manageSpecialty(action: 'create'|'update'|'delete', input: { id?: string; nom?: string; description?: string }) {
  const client = requireClient();
  const result = action === 'create' ? await client.from('specialties').insert({ nom: input.nom, description: input.description })
    : action === 'update' ? await client.from('specialties').update({ nom: input.nom, description: input.description }).eq('id', input.id!)
    : await client.from('specialties').delete().eq('id', input.id!);
  if (result.error) throw new Error('Impossible d’enregistrer la spécialité. Elle est peut-être encore utilisée par un médecin ou un rendez-vous.');
}

export async function loadAdminReport(from: string, to: string) {
  const client = requireClient();
  const p_from=new Date(`${from}T00:00:00`).toISOString();
  const exclusiveTo=new Date(`${format(addDays(parseISO(to),1),'yyyy-MM-dd')}T00:00:00`).toISOString();
  const [{ data: summary, error }, { data: overbooked, error: overbookedError }] = await Promise.all([
    client.rpc('admin_summary', { p_from, p_to:exclusiveTo }),
    client.rpc('admin_overbooked_appointments', { p_from, p_to:exclusiveTo }),
  ]);
  if (error) throw new Error('Impossible de charger les rapports.');
  if (overbookedError) throw new Error('Impossible de charger les rendez-vous au-delà de capacité. Appliquez la dernière migration SQL.');
  const [{ count: patients }, { count: doctors }] = await Promise.all([
    client.from('user_roles').select('*', { count: 'exact', head: true }).eq('role', 'patient'),
    client.from('user_roles').select('*', { count: 'exact', head: true }).eq('role', 'medecin'),
  ]);
  return { summary: summary ?? [], overbooked: (overbooked ?? []).map((row:any)=>({id:row.appointment_id,patient:row.patient_name,specialty:row.specialty,startsAt:row.starts_at,status:row.appointment_status,capacity:Number(row.slot_capacity),booked:Number(row.slot_booked)})), patients: patients ?? 0, doctors: doctors ?? 0 };
}

export async function updateAppointmentChangeWindow(hours: number) {
  if(!Number.isInteger(hours)||hours<0||hours>720)throw new Error('Choisissez un délai entre 0 et 720 heures.');
  const {error}=await requireClient().from('app_settings').update({appointment_change_hours:hours,updated_at:new Date().toISOString()}).eq('id',true);
  if(error)throw new Error('Impossible de modifier le délai de reprogrammation.');
}
