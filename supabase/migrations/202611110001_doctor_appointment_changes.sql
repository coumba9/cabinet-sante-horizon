-- Autorise un médecin à reporter ou annuler les rendez-vous de sa spécialité.
-- Le patient reçoit un message dans sa boîte de réception dans la même transaction.
create or replace function public.doctor_change_appointment(p_appointment_id uuid, p_new_starts_at timestamptz default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_old public.appointments%rowtype; v_capacity integer; v_taken integer;
begin
  if auth.uid() is null or public.current_role()<>'medecin' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_old from public.appointments
   where id=p_appointment_id and specialite_id=public.current_specialty() for update;
  if not found or v_old.statut not in ('demandé','confirmé','reprogrammé') then raise exception 'appointment_not_changeable'; end if;
  if v_old.date<=now() then raise exception 'appointment_not_changeable'; end if;

  if p_new_starts_at is null then
    update public.appointments set statut='annulé',updated_at=now() where id=p_appointment_id;
    insert into public.messages(expediteur_id,destinataire_id,contenu,date,rendez_vous_id)
    values(auth.uid(),v_old.patient_id,'Le médecin a annulé votre rendez-vous. Contactez le cabinet si vous souhaitez en réserver un autre.',now(),v_old.id);
    return;
  end if;

  if p_new_starts_at<=now() then raise exception 'appointment_in_past'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_old.specialite_id::text || p_new_starts_at::text,0));
  select count(distinct d.id) into v_capacity from public.doctors d join public.availabilities a on a.medecin_id=d.id
   where d.specialite_id=v_old.specialite_id and a.status='actif'
     and a.date_debut<=p_new_starts_at and a.date_fin>=p_new_starts_at+make_interval(mins=>a.duree_creneau_min)
     and mod(extract(epoch from (p_new_starts_at-a.date_debut))::integer,a.duree_creneau_min*60)=0;
  select count(*) into v_taken from public.appointments
   where specialite_id=v_old.specialite_id and date=p_new_starts_at and statut<>'annulé' and id<>p_appointment_id;
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;

  update public.appointments set date=p_new_starts_at,statut='reprogrammé',updated_at=now() where id=p_appointment_id;
  insert into public.messages(expediteur_id,destinataire_id,contenu,date,rendez_vous_id)
  values(auth.uid(),v_old.patient_id,'Le médecin a reporté votre rendez-vous au '||to_char(p_new_starts_at at time zone 'Africa/Dakar','DD/MM/YYYY à HH24:MI')||'.',now(),v_old.id);
end $$;
grant execute on function public.doctor_change_appointment(uuid,timestamptz) to authenticated;
