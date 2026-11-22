-- Gestion transactionnelle des empêchements sans affecter un rendez-vous à un médecin.
alter table public.availabilities
  add column if not exists motif_empechement text;

create table if not exists public.alertes_empechement (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  heure time without time zone not null,
  specialite_id uuid not null references public.specialties(id) on delete restrict,
  nb_rendez_vous integer not null check (nb_rendez_vous >= 0),
  capacite integer not null check (capacite >= 0),
  nb_excedent integer not null check (nb_excedent > 0),
  statut text not null default 'à traiter' check (statut in ('à traiter','traitée')),
  created_at timestamptz not null default now()
);
create unique index if not exists alertes_empechement_open_slot_idx
  on public.alertes_empechement(specialite_id,date,heure) where statut='à traiter';
create index if not exists alertes_empechement_period_idx on public.alertes_empechement(date,statut);
alter table public.alertes_empechement enable row level security;
drop policy if exists alertes_empechement_admin_read on public.alertes_empechement;
create policy alertes_empechement_admin_read on public.alertes_empechement
  for select to authenticated using(public.current_role()='administrateur' and public.is_active_user());
revoke all on public.alertes_empechement from anon,authenticated;
grant select on public.alertes_empechement to authenticated;

create table if not exists public.patient_notifications (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete cascade,
  appointment_id uuid references public.appointments(id) on delete set null,
  title text not null,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists patient_notifications_patient_created_idx
  on public.patient_notifications(patient_id,created_at desc);
alter table public.patient_notifications enable row level security;
drop policy if exists patient_notifications_owner_read on public.patient_notifications;
drop policy if exists patient_notifications_owner_update on public.patient_notifications;
create policy patient_notifications_owner_read on public.patient_notifications
  for select to authenticated using(patient_id=auth.uid());
create policy patient_notifications_owner_update on public.patient_notifications
  for update to authenticated using(patient_id=auth.uid()) with check(patient_id=auth.uid());
revoke all on public.patient_notifications from anon,authenticated;
grant select on public.patient_notifications to authenticated;
grant update(read_at) on public.patient_notifications to authenticated;

alter table public.appointment_sms_jobs add column if not exists message_override text;
alter table public.appointment_sms_jobs drop constraint if exists appointment_sms_jobs_kind_check;
alter table public.appointment_sms_jobs add constraint appointment_sms_jobs_kind_check
  check (kind in ('confirmation','reprogrammed','24h','5h','impediment_cancelled'));

-- Recalcule une alerte ouverte uniquement si les rendez-vous confirmés ou reportés
-- dépassent la capacité encore assurée par les médecins actifs de la spécialité.
create or replace function public.recompute_impediment_alert(p_specialty_id uuid,p_starts_at timestamptz)
returns void language plpgsql security definer set search_path=public as $$
declare v_capacity integer; v_booked integer; v_local_date date; v_local_time time;
begin
  if p_starts_at is null or p_starts_at<=now() then return; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_specialty_id::text||p_starts_at::text,0));
  select count(distinct d.id)::integer into v_capacity
  from public.doctors d join public.availabilities av on av.medecin_id=d.id
  where d.specialite_id=p_specialty_id and av.status='actif'
    and exists(select 1 from generate_series(av.date_debut,av.date_fin-make_interval(mins=>av.duree_creneau_min),make_interval(mins=>av.duree_creneau_min)) slot(starts_at) where slot.starts_at=p_starts_at);
  select count(*)::integer into v_booked from public.appointments a
   where a.specialite_id=p_specialty_id and a.date=p_starts_at and a.statut in ('confirmé','reprogrammé');
  v_local_date:=(p_starts_at at time zone 'Africa/Dakar')::date;
  v_local_time:=(p_starts_at at time zone 'Africa/Dakar')::time;
  if v_booked>v_capacity then
    insert into public.alertes_empechement(date,heure,specialite_id,nb_rendez_vous,capacite,nb_excedent,statut)
      values(v_local_date,v_local_time,p_specialty_id,v_booked,v_capacity,v_booked-v_capacity,'à traiter')
    on conflict(specialite_id,date,heure) where statut='à traiter'
      do update set nb_rendez_vous=excluded.nb_rendez_vous,capacite=excluded.capacite,nb_excedent=excluded.nb_excedent;
  else
    update public.alertes_empechement set statut='traitée',nb_rendez_vous=v_booked,capacite=v_capacity,nb_excedent=0
     where specialite_id=p_specialty_id and date=v_local_date and heure=v_local_time and statut='à traiter';
  end if;
end $$;
revoke all on function public.recompute_impediment_alert(uuid,timestamptz) from public,anon,authenticated;

create or replace function public.recompute_impediments_for_availability()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_specialty_id uuid; v_slot record; v_av public.availabilities%rowtype;
begin
  if tg_op='DELETE' then
    v_av:=old;
    select specialite_id into v_specialty_id from public.doctors where id=v_av.medecin_id;
    for v_slot in select generate_series(v_av.date_debut,v_av.date_fin-make_interval(mins=>v_av.duree_creneau_min),make_interval(mins=>v_av.duree_creneau_min)) starts_at loop
      perform public.recompute_impediment_alert(v_specialty_id,v_slot.starts_at);
    end loop;
  elsif tg_op='INSERT' then
    v_av:=new;
    select specialite_id into v_specialty_id from public.doctors where id=v_av.medecin_id;
    if v_av.status='actif' then
      for v_slot in select generate_series(v_av.date_debut,v_av.date_fin-make_interval(mins=>v_av.duree_creneau_min),make_interval(mins=>v_av.duree_creneau_min)) starts_at loop
        perform public.recompute_impediment_alert(v_specialty_id,v_slot.starts_at);
      end loop;
    end if;
  else
    select specialite_id into v_specialty_id from public.doctors where id=new.medecin_id;
    if old.status='actif' then
      for v_slot in select generate_series(old.date_debut,old.date_fin-make_interval(mins=>old.duree_creneau_min),make_interval(mins=>old.duree_creneau_min)) starts_at loop
        perform public.recompute_impediment_alert(v_specialty_id,v_slot.starts_at);
      end loop;
    end if;
    if new.status='actif' then
      v_av:=new;
      for v_slot in select generate_series(v_av.date_debut,v_av.date_fin-make_interval(mins=>v_av.duree_creneau_min),make_interval(mins=>v_av.duree_creneau_min)) starts_at loop
      perform public.recompute_impediment_alert(v_specialty_id,v_slot.starts_at);
      end loop;
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists recompute_impediments_availability on public.availabilities;
create trigger recompute_impediments_availability after insert or update of status,date_debut,date_fin,duree_creneau_min or delete on public.availabilities
for each row execute function public.recompute_impediments_for_availability();

create or replace function public.recompute_impediments_for_appointment()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    if new.statut in ('confirmé','reprogrammé') then perform public.recompute_impediment_alert(new.specialite_id,new.date); end if;
  elsif tg_op='DELETE' then
    if old.statut in ('confirmé','reprogrammé') then perform public.recompute_impediment_alert(old.specialite_id,old.date); end if;
    return old;
  else
    if old.statut in ('confirmé','reprogrammé') then perform public.recompute_impediment_alert(old.specialite_id,old.date); end if;
    if new.statut in ('confirmé','reprogrammé') then perform public.recompute_impediment_alert(new.specialite_id,new.date); end if;
  end if;
  return new;
end $$;
drop trigger if exists recompute_impediments_appointment on public.appointments;
create trigger recompute_impediments_appointment after insert or update of date,statut or delete on public.appointments
for each row execute function public.recompute_impediments_for_appointment();

-- Le médecin obtient seulement le nombre prévisionnel avant de déclarer son empêchement.
create or replace function public.doctor_availability_impediment_impact(p_availability_id uuid)
returns integer language plpgsql stable security definer set search_path=public as $$
declare v_av public.availabilities%rowtype; v_specialty uuid; v_total integer:=0; v_row record; v_capacity integer; v_booked integer;
begin
  if auth.uid() is null or public.current_role()<>'medecin' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_av from public.availabilities where id=p_availability_id and medecin_id=auth.uid();
  if not found then raise exception 'availability_not_found'; end if;
  select specialite_id into v_specialty from public.doctors where id=auth.uid();
  for v_row in select distinct a.date starts_at from public.appointments a
    where a.specialite_id=v_specialty and a.date between v_av.date_debut and v_av.date_fin
      and a.date+make_interval(mins=>v_av.duree_creneau_min)<=v_av.date_fin and a.statut in ('confirmé','reprogrammé')
      and mod(extract(epoch from(a.date-v_av.date_debut))::integer,v_av.duree_creneau_min*60)=0 loop
    select count(distinct d.id)::integer into v_capacity from public.doctors d join public.availabilities av on av.medecin_id=d.id
     where d.specialite_id=v_specialty and av.status='actif' and d.id<>auth.uid()
       and exists(select 1 from generate_series(av.date_debut,av.date_fin-make_interval(mins=>av.duree_creneau_min),make_interval(mins=>av.duree_creneau_min)) slot(starts_at) where slot.starts_at=v_row.starts_at);
    select count(*)::integer into v_booked from public.appointments a where a.specialite_id=v_specialty and a.date=v_row.starts_at and a.statut in ('confirmé','reprogrammé');
    v_total:=v_total+greatest(v_booked-v_capacity,0);
  end loop;
  return v_total;
end $$;
grant execute on function public.doctor_availability_impediment_impact(uuid) to authenticated;

-- Le changement est autorisé uniquement au médecin propriétaire de la disponibilité.
create or replace function public.doctor_change_availability(p_availability_id uuid,p_status text default null,p_delete boolean default false,p_reason text default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_av public.availabilities%rowtype; v_specialty uuid; v_slot record;
begin
  if auth.uid() is null or public.current_role()<>'medecin' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  if not p_delete and (p_status is null or p_status not in ('actif','bloqué','libéré')) then raise exception 'invalid_availability_status'; end if;
  if p_status in ('bloqué','libéré') and coalesce(length(trim(p_reason)),0)<3 then raise exception 'impediment_reason_required'; end if;
  select * into v_av from public.availabilities where id=p_availability_id and medecin_id=auth.uid() for update;
  if not found then raise exception 'availability_not_found'; end if;
  select specialite_id into v_specialty from public.doctors where id=auth.uid();
  for v_slot in select generate_series(v_av.date_debut,v_av.date_fin-make_interval(mins=>v_av.duree_creneau_min),make_interval(mins=>v_av.duree_creneau_min)) starts_at order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended(v_specialty::text||v_slot.starts_at::text,0));
  end loop;
  if p_delete then
    if exists(select 1 from public.appointments a where a.specialite_id=v_specialty and a.date>=v_av.date_debut and a.date+make_interval(mins=>v_av.duree_creneau_min)<=v_av.date_fin and mod(extract(epoch from(a.date-v_av.date_debut))::integer,v_av.duree_creneau_min*60)=0 and a.statut<>'annulé') then raise exception 'availability_has_appointments'; end if;
    update public.availabilities set status='libéré',motif_empechement=trim(p_reason) where id=p_availability_id;
  else
    if v_av.status=p_status then return; end if;
    update public.availabilities set status=p_status,motif_empechement=case when p_status='actif' then null else trim(p_reason) end where id=p_availability_id;
  end if;
  insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),case when p_delete then 'retrait disponibilité' when p_status='actif' then 'réactivation disponibilité' else 'empêchement disponibilité' end,
      'disponibilite',p_availability_id::text,jsonb_build_object('statut',case when p_delete then 'libéré' else p_status end,'motif',case when p_delete then trim(p_reason) when p_status='actif' then null else trim(p_reason) end));
end $$;
revoke all on function public.doctor_change_availability(uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.doctor_change_availability(uuid,text,boolean,text) from public,anon;
grant execute on function public.doctor_change_availability(uuid,text,boolean,text) to authenticated;

-- Aucun médecin ne peut agir sur le rendez-vous d'un patient : l'empêchement se déclare sur la disponibilité.
revoke all on function public.doctor_change_appointment(uuid,timestamptz) from public,anon,authenticated;

create or replace function public.admin_list_impediment_appointments(p_alert_id uuid)
returns table(appointment_id uuid,patient_name text,patient_phone text,starts_at timestamptz,specialty text,booked_at timestamptz,excess_order integer,is_excess boolean)
language plpgsql stable security definer set search_path=public as $$
declare v_alert public.alertes_empechement%rowtype; v_slot timestamptz;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_alert from public.alertes_empechement where id=p_alert_id;
  if not found then raise exception 'impediment_alert_not_found'; end if;
  v_slot:=((v_alert.date::timestamp+v_alert.heure) at time zone 'Africa/Dakar');
  return query with ranked as (
    select a.id,a.patient_id,a.specialite_id,a.date,a.created_at,
      row_number() over(order by a.created_at desc,a.id desc)::integer as excess_rank
    from public.appointments a where a.specialite_id=v_alert.specialite_id and a.date=v_slot and a.statut in ('confirmé','reprogrammé')
  ) select r.id,trim(concat(p.prenom,' ',p.nom)),p.telephone,r.date,s.nom,r.created_at,r.excess_rank,r.excess_rank<=v_alert.nb_excedent
    from ranked r join public.profiles p on p.id=r.patient_id join public.specialties s on s.id=r.specialite_id
    order by (r.excess_rank<=v_alert.nb_excedent) desc,r.created_at desc,r.id desc;
end $$;
grant execute on function public.admin_list_impediment_appointments(uuid) to authenticated;

create or replace function public.admin_impediment_available_slots(p_appointment_id uuid,p_day date)
returns table(starts_at timestamptz,capacity bigint,booked bigint,remaining bigint)
language plpgsql stable security definer set search_path=public as $$
declare v_specialty uuid; v_from timestamptz; v_to timestamptz;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select specialite_id into v_specialty from public.appointments where id=p_appointment_id and statut in ('confirmé','reprogrammé');
  if v_specialty is null then raise exception 'appointment_not_changeable'; end if;
  v_from:=p_day::timestamp at time zone 'Africa/Dakar';v_to:=(p_day+1)::timestamp at time zone 'Africa/Dakar';
  return query with doctor_slots as (
    select distinct av.medecin_id,slot.starts_at from public.doctors d join public.availabilities av on av.medecin_id=d.id
    cross join lateral generate_series(av.date_debut,av.date_fin-make_interval(mins=>av.duree_creneau_min),make_interval(mins=>av.duree_creneau_min)) slot(starts_at)
    where d.specialite_id=v_specialty and av.status='actif' and slot.starts_at>=v_from and slot.starts_at<v_to and slot.starts_at>now()
  ), caps as (select ds.starts_at,count(distinct ds.medecin_id)::bigint cap from doctor_slots ds group by ds.starts_at),
  occupancy as (select a.date,count(*)::bigint booked from public.appointments a where a.specialite_id=v_specialty and a.statut in ('confirmé','reprogrammé') group by a.date)
  select c.starts_at,c.cap,coalesce(o.booked,0),greatest(c.cap-coalesce(o.booked,0),0) from caps c left join occupancy o on o.date=c.starts_at
  where coalesce(o.booked,0)<c.cap order by c.starts_at;
end $$;
grant execute on function public.admin_impediment_available_slots(uuid,date) to authenticated;

create or replace function public.admin_reschedule_impediment_appointment(p_appointment_id uuid,p_new_starts_at timestamptz)
returns void language plpgsql security definer set search_path=public as $$
declare v_appt public.appointments%rowtype; v_capacity integer;v_taken integer;v_spec text;v_patient_name text;v_old_local text;v_new_local text;v_consent boolean;v_verified boolean;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_appt from public.appointments where id=p_appointment_id and statut in ('confirmé','reprogrammé') for update;
  if not found or v_appt.date<=now() then raise exception 'appointment_not_changeable'; end if;
  if not exists(select 1 from public.alertes_empechement e where e.specialite_id=v_appt.specialite_id and e.date=(v_appt.date at time zone 'Africa/Dakar')::date and e.heure=(v_appt.date at time zone 'Africa/Dakar')::time and e.statut='à traiter') then raise exception 'impediment_alert_resolved'; end if;
  if p_new_starts_at<=now() then raise exception 'slot_past'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_appt.specialite_id::text||least(v_appt.date,p_new_starts_at)::text,0));
  perform pg_advisory_xact_lock(hashtextextended(v_appt.specialite_id::text||greatest(v_appt.date,p_new_starts_at)::text,0));
  select count(distinct d.id)::integer into v_capacity from public.doctors d join public.availabilities av on av.medecin_id=d.id
    where d.specialite_id=v_appt.specialite_id and av.status='actif' and exists(select 1 from generate_series(av.date_debut,av.date_fin-make_interval(mins=>av.duree_creneau_min),make_interval(mins=>av.duree_creneau_min)) slot(starts_at) where slot.starts_at=p_new_starts_at);
  select count(*)::integer into v_taken from public.appointments a where a.specialite_id=v_appt.specialite_id and a.date=p_new_starts_at and a.statut in ('confirmé','reprogrammé') and a.id<>v_appt.id;
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;
  select nom into v_spec from public.specialties where id=v_appt.specialite_id;
  select trim(concat(prenom,' ',nom)),coalesce(sms_consent_at is not null,false) or v_appt.sms_reminders_enabled,telephone_verified_at is not null
    into v_patient_name,v_consent,v_verified from public.profiles where id=v_appt.patient_id;
  v_old_local:=to_char(v_appt.date at time zone 'Africa/Dakar','DD/MM/YYYY à HH24:MI');
  v_new_local:=to_char(p_new_starts_at at time zone 'Africa/Dakar','DD/MM/YYYY à HH24:MI');
  update public.appointments set date=p_new_starts_at,statut='reprogrammé',updated_at=now() where id=v_appt.id;
  insert into public.patient_notifications(patient_id,appointment_id,title,body)
    values(v_appt.patient_id,v_appt.id,'Rendez-vous reporté','Votre rendez-vous de '||v_spec||' du '||v_old_local||' est reporté au '||v_new_local||'.');
  insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'report par empêchement','rendez_vous',v_appt.id::text,jsonb_build_object('motif','empêchement médecin','specialite_id',v_appt.specialite_id,'ancien_creneau',v_appt.date,'nouveau_creneau',p_new_starts_at));
  if v_consent and v_verified then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at,status,message_override)
      values(v_appt.id,'reprogrammed',now(),'pending','Cabinet Sante Horizon: votre rendez-vous de '||coalesce(v_spec,'consultation')||' prevu le '||v_old_local||' est reporte au '||v_new_local||'. Connectez-vous a votre espace pour le gerer.')
      on conflict(appointment_id,kind) do update set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,updated_at=now(),sent_at=null,provider_message_id=null,message_override=excluded.message_override;
  end if;
end $$;
grant execute on function public.admin_reschedule_impediment_appointment(uuid,timestamptz) to authenticated;

create or replace function public.admin_cancel_impediment_appointment(p_appointment_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_appt public.appointments%rowtype;v_spec text;v_old_local text;v_consent boolean;v_verified boolean;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  if coalesce(length(trim(p_reason)),0)<3 then raise exception 'cancellation_reason_required'; end if;
  select * into v_appt from public.appointments where id=p_appointment_id and statut in ('confirmé','reprogrammé') for update;
  if not found or v_appt.date<=now() then raise exception 'appointment_not_changeable'; end if;
  if not exists(select 1 from public.alertes_empechement e where e.specialite_id=v_appt.specialite_id and e.date=(v_appt.date at time zone 'Africa/Dakar')::date and e.heure=(v_appt.date at time zone 'Africa/Dakar')::time and e.statut='à traiter') then raise exception 'impediment_alert_resolved'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_appt.specialite_id::text||v_appt.date::text,0));
  select nom into v_spec from public.specialties where id=v_appt.specialite_id;
  select coalesce(sms_consent_at is not null,false) or v_appt.sms_reminders_enabled,telephone_verified_at is not null
    into v_consent,v_verified from public.profiles where id=v_appt.patient_id;
  v_old_local:=to_char(v_appt.date at time zone 'Africa/Dakar','DD/MM/YYYY à HH24:MI');
  update public.appointments set statut='annulé',updated_at=now() where id=v_appt.id;
  insert into public.patient_notifications(patient_id,appointment_id,title,body)
    values(v_appt.patient_id,v_appt.id,'Rendez-vous annulé','Votre rendez-vous de '||v_spec||' du '||v_old_local||' a été annulé. Connectez-vous à votre espace pour choisir un autre créneau ou contactez le cabinet.');
  insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'annulation par empêchement','rendez_vous',v_appt.id::text,jsonb_build_object('motif',trim(p_reason),'specialite_id',v_appt.specialite_id,'ancien_creneau',v_appt.date));
  if v_consent and v_verified then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at,status,message_override)
      values(v_appt.id,'impediment_cancelled',now(),'pending','Cabinet Sante Horizon: votre rendez-vous de '||coalesce(v_spec,'consultation')||' du '||v_old_local||' est annule. Connectez-vous a votre espace pour choisir un autre creneau ou contactez le cabinet.')
      on conflict(appointment_id,kind) do update set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,updated_at=now(),sent_at=null,provider_message_id=null,message_override=excluded.message_override;
  end if;
end $$;
grant execute on function public.admin_cancel_impediment_appointment(uuid,text) to authenticated;

-- Rapports agrégés : aucun nom, téléphone ou renseignement de santé.
create or replace function public.admin_summary(p_from timestamptz default now()-interval '30 days',p_to timestamptz default now())
returns table(kind text,label text,total bigint) language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  return query
    select 'statut'::text,a.statut::text,count(*)::bigint from public.appointments a where a.date>=p_from and a.date<p_to group by a.statut
    union all select 'spécialité',s.nom,count(*)::bigint from public.appointments a join public.specialties s on s.id=a.specialite_id where a.date>=p_from and a.date<p_to group by s.nom
    union all select 'empêchement',e.statut,count(*)::bigint from public.alertes_empechement e where (e.date+e.heure) at time zone 'Africa/Dakar'>=p_from and (e.date+e.heure) at time zone 'Africa/Dakar'<p_to group by e.statut
    union all select 'rendez-vous empêchement',case when l.action='report par empêchement' then 'reprogrammé' else 'annulé' end,count(*)::bigint
      from public.audit_log l where l.action in ('report par empêchement','annulation par empêchement') and l.created_at>=p_from and l.created_at<p_to
      group by case when l.action='report par empêchement' then 'reprogrammé' else 'annulé' end
    union all select 'rendez-vous reporté par spécialité',s.nom,count(*)::bigint from public.audit_log l
      join public.specialties s on s.id=(l.details->>'specialite_id')::uuid
      where l.action='report par empêchement' and l.created_at>=p_from and l.created_at<p_to group by s.nom
    union all select 'rendez-vous annulé par spécialité',s.nom,count(*)::bigint from public.audit_log l
      join public.specialties s on s.id=(l.details->>'specialite_id')::uuid
      where l.action='annulation par empêchement' and l.created_at>=p_from and l.created_at<p_to group by s.nom;
end $$;
grant execute on function public.admin_summary(timestamptz,timestamptz) to authenticated;

revoke all on function public.doctor_availability_impediment_impact(uuid) from public,anon;
revoke all on function public.admin_list_impediment_appointments(uuid) from public,anon;
revoke all on function public.admin_impediment_available_slots(uuid,date) from public,anon;
revoke all on function public.admin_reschedule_impediment_appointment(uuid,timestamptz) from public,anon;
revoke all on function public.admin_cancel_impediment_appointment(uuid,text) from public,anon;
revoke all on function public.admin_summary(timestamptz,timestamptz) from public,anon;

