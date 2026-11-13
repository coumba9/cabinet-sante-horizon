-- Un créneau ouvert est confirmé dès que sa capacité est réservée avec succès.
-- Le verrou transactionnel protège les réservations concurrentes et les SMS
-- de confirmation sont préparés par le trigger appointment_sms_jobs existant.
create or replace function public.request_appointment(
  p_specialty_id uuid,
  p_starts_at timestamptz,
  p_sms_reminders_enabled boolean default false
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_capacity integer;
  v_taken integer;
  v_result uuid;
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  if coalesce(p_sms_reminders_enabled,false)
     and not exists(select 1 from public.profiles where id=auth.uid() and telephone_verified_at is not null) then
    raise exception 'phone_not_verified';
  end if;
  if p_starts_at<=now() then raise exception 'slot_past'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_specialty_id::text||p_starts_at::text,0));

  select count(distinct d.id)::integer into v_capacity
  from public.doctors d
  join public.availabilities a on a.medecin_id=d.id
  where d.specialite_id=p_specialty_id
    and a.status='actif'
    and a.date_debut<=p_starts_at
    and a.date_fin>=p_starts_at+make_interval(mins=>a.duree_creneau_min)
    and mod(extract(epoch from (p_starts_at-a.date_debut))::integer,a.duree_creneau_min*60)=0;

  select count(*)::integer into v_taken
  from public.appointments
  where specialite_id=p_specialty_id and date=p_starts_at and statut<>'annulé';

  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;

  insert into public.appointments(patient_id,specialite_id,date,statut,sms_reminders_enabled)
  values(auth.uid(),p_specialty_id,p_starts_at,'confirmé',coalesce(p_sms_reminders_enabled,false))
  returning id into v_result;

  insert into public.audit_log(actor_id,action,entity,entity_id,details)
  values(auth.uid(),'confirmation automatique','rendez_vous',v_result::text,
    jsonb_build_object('specialty_id',p_specialty_id,'starts_at',p_starts_at,
      'sms_reminders_enabled',coalesce(p_sms_reminders_enabled,false)));

  return v_result;
end;
$$;

revoke all on function public.request_appointment(uuid,timestamptz,boolean) from public,anon;
grant execute on function public.request_appointment(uuid,timestamptz,boolean) to authenticated;
