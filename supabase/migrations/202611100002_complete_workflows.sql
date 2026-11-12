-- Réglage centralisé du délai de modification patient (valeur par défaut : 24 h).
create table public.app_settings (
  id boolean primary key default true check (id),
  appointment_change_hours integer not null default 24 check (appointment_change_hours between 0 and 720),
  updated_at timestamptz not null default now()
);
insert into public.app_settings(id) values(true) on conflict(id) do nothing;
alter table public.app_settings enable row level security;
create policy settings_read_signed on public.app_settings for select to authenticated using(true);
create policy settings_admin_update on public.app_settings for update to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
grant select on public.app_settings to authenticated;
grant update on public.app_settings to authenticated;

-- Créneaux que le patient peut réserver. Les disponibilités de tous les médecins sont regroupées.
create or replace function public.available_slots(p_specialty_id uuid, p_day date)
returns table(starts_at timestamptz, capacity bigint, booked bigint, remaining bigint)
language plpgsql stable security definer set search_path=public as $$
declare v_from timestamptz; v_to timestamptz;
begin
  if auth.uid() is null or public.current_role() <> 'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  v_from := p_day::timestamp at time zone 'Africa/Dakar';
  v_to := (p_day + 1)::timestamp at time zone 'Africa/Dakar';
  return query
  with doctor_slots as (
    select distinct a.medecin_id, slot.starts_at
      from public.doctors d join public.availabilities a on a.medecin_id=d.id
      cross join lateral generate_series(a.date_debut, a.date_fin - make_interval(mins=>a.duree_creneau_min), make_interval(mins=>a.duree_creneau_min)) as slot(starts_at)
     where d.specialite_id=p_specialty_id and a.status='actif'
       and a.date_debut < v_to and a.date_fin > v_from
       and slot.starts_at >= v_from and slot.starts_at < v_to
  ), caps as (
    select ds.starts_at,count(distinct ds.medecin_id)::bigint as capacity from doctor_slots ds group by ds.starts_at
  ), occupancy as (
    select a.date,count(*)::bigint as booked from public.appointments a
     where a.specialite_id=p_specialty_id and a.date>=v_from and a.date<v_to and a.statut<>'annulé' group by a.date
  )
  select c.starts_at,c.capacity,coalesce(o.booked,0),greatest(c.capacity-coalesce(o.booked,0),0)
    from caps c left join occupancy o on o.date=c.starts_at order by c.starts_at;
end $$;
grant execute on function public.available_slots(uuid,date) to authenticated;

create or replace function public.request_appointment(p_specialty_id uuid,p_starts_at timestamptz)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_capacity integer;v_taken integer;v_result uuid;
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  if p_starts_at<=now() then raise exception 'slot_past'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_specialty_id::text||p_starts_at::text,0));
  select count(distinct d.id) into v_capacity from public.doctors d join public.availabilities a on a.medecin_id=d.id
   where d.specialite_id=p_specialty_id and a.status='actif' and a.date_debut<=p_starts_at
     and a.date_fin>=p_starts_at+make_interval(mins=>a.duree_creneau_min)
     and mod(extract(epoch from (p_starts_at-a.date_debut))::integer,a.duree_creneau_min*60)=0;
  select count(*) into v_taken from public.appointments where specialite_id=p_specialty_id and date=p_starts_at and statut<>'annulé';
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;
  insert into public.appointments(patient_id,specialite_id,date,statut) values(auth.uid(),p_specialty_id,p_starts_at,'demandé') returning id into v_result;
  insert into public.audit_log(actor_id,action,entity,entity_id) values(auth.uid(),'création','rendez_vous',v_result::text);
  return v_result;
end $$;
grant execute on function public.request_appointment(uuid,timestamptz) to authenticated;

-- Le créneau doit finir avant la fin de disponibilité; les créneaux déjà passés ne sont pas proposés.
create or replace function public.available_slots(p_specialty_id uuid, p_day date)
returns table(starts_at timestamptz, capacity bigint, booked bigint, remaining bigint)
language plpgsql stable security definer set search_path=public as $$
declare v_from timestamptz;v_to timestamptz;
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  v_from:=p_day::timestamp at time zone 'Africa/Dakar';v_to:=(p_day+1)::timestamp at time zone 'Africa/Dakar';
  return query with doctor_slots as (
    select distinct a.medecin_id,slot.starts_at from public.doctors d join public.availabilities a on a.medecin_id=d.id
    cross join lateral generate_series(a.date_debut,a.date_fin-make_interval(mins=>a.duree_creneau_min),make_interval(mins=>a.duree_creneau_min)) as slot(starts_at)
    where d.specialite_id=p_specialty_id and a.status='actif' and a.date_debut<v_to and a.date_fin>v_from and slot.starts_at>=v_from and slot.starts_at<v_to and slot.starts_at>now()
  ), caps as (select ds.starts_at,count(distinct ds.medecin_id)::bigint as capacity from doctor_slots ds group by ds.starts_at),
  occupancy as (select a.date,count(*)::bigint as booked from public.appointments a where a.specialite_id=p_specialty_id and a.date>=v_from and a.date<v_to and a.statut<>'annulé' group by a.date)
  select c.starts_at,c.capacity,coalesce(o.booked,0),greatest(c.capacity-coalesce(o.booked,0),0) from caps c left join occupancy o on o.date=c.starts_at order by c.starts_at;
end $$;
grant execute on function public.available_slots(uuid,date) to authenticated;

-- RPC unique pour reprogrammer ou annuler, avec délai et capacité vérifiés dans la transaction.
create or replace function public.change_appointment(p_appointment_id uuid, p_new_starts_at timestamptz default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_old public.appointments%rowtype; v_window integer; v_capacity integer; v_taken integer;
begin
  if public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_old from public.appointments where id=p_appointment_id and patient_id=auth.uid() for update;
  if not found or v_old.statut not in ('demandé','confirmé') then raise exception 'appointment_not_changeable'; end if;
  select appointment_change_hours into v_window from public.app_settings where id=true;
  if v_old.date<=now()+make_interval(hours=>coalesce(v_window,24)) then raise exception 'change_window_closed'; end if;
  if p_new_starts_at is null then
    update public.appointments set statut='annulé',updated_at=now() where id=p_appointment_id;
    return;
  end if;
  if p_new_starts_at<=now()+make_interval(hours=>coalesce(v_window,24)) then raise exception 'change_window_closed'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_old.specialite_id::text || p_new_starts_at::text,0));
  select count(distinct d.id) into v_capacity from public.doctors d join public.availabilities a on a.medecin_id=d.id
   where d.specialite_id=v_old.specialite_id and a.status='actif' and a.date_debut<=p_new_starts_at and a.date_fin>=p_new_starts_at+make_interval(mins=>a.duree_creneau_min)
   and mod(extract(epoch from (p_new_starts_at-a.date_debut))::integer,a.duree_creneau_min*60)=0;
  select count(*) into v_taken from public.appointments where specialite_id=v_old.specialite_id and date=p_new_starts_at and statut<>'annulé' and id<>p_appointment_id;
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;
  update public.appointments set date=p_new_starts_at,statut='reprogrammé',updated_at=now() where id=p_appointment_id;
end $$;
grant execute on function public.change_appointment(uuid,timestamptz) to authenticated;

-- Seul un médecin de la spécialité peut confirmer; le patient reçoit un message enregistré en base.
create or replace function public.confirm_appointment(p_appointment_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype;
begin
  if public.current_role()<>'medecin' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and specialite_id=public.current_specialty() for update;
  if not found or v_appointment.statut<>'demandé' then raise exception 'appointment_not_confirmable'; end if;
  if not exists(select 1 from public.availabilities a where a.medecin_id=auth.uid() and a.status='actif' and a.date_debut<=v_appointment.date and a.date_fin>=v_appointment.date+make_interval(mins=>a.duree_creneau_min) and mod(extract(epoch from (v_appointment.date-a.date_debut))::integer,a.duree_creneau_min*60)=0) then raise exception 'outside_availability'; end if;
  update public.appointments set statut='confirmé',updated_at=now() where id=p_appointment_id;
  insert into public.messages(expediteur_id,destinataire_id,contenu,date,rendez_vous_id)
  values(auth.uid(),v_appointment.patient_id,'Votre rendez-vous a été confirmé par le médecin.',now(),v_appointment.id);
end $$;
grant execute on function public.confirm_appointment(uuid) to authenticated;

create or replace function public.send_appointment_message(p_appointment_id uuid,p_content text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_appt public.appointments%rowtype; v_recipient uuid; v_message uuid;
begin
  if not public.is_active_user() or length(trim(coalesce(p_content,''))) not between 1 and 4000 then raise exception 'invalid_message'; end if;
  select * into v_appt from public.appointments where id=p_appointment_id for share;
  if not found then raise exception 'appointment_not_found'; end if;
  if public.current_role()='patient' and v_appt.patient_id=auth.uid() then
    select d.id into v_recipient from public.doctors d join public.profiles p on p.id=d.id where d.specialite_id=v_appt.specialite_id and p.status='actif' order by d.id limit 1;
  elsif public.current_role()='medecin' and v_appt.specialite_id=public.current_specialty() then
    v_recipient:=v_appt.patient_id;
  else
    raise exception 'unauthorized';
  end if;
  if v_recipient is null then raise exception 'no_doctor_available'; end if;
  insert into public.messages(expediteur_id,destinataire_id,contenu,rendez_vous_id) values(auth.uid(),v_recipient,trim(p_content),p_appointment_id) returning id into v_message;
  return v_message;
end $$;
grant execute on function public.send_appointment_message(uuid,text) to authenticated;

-- Paiement sur place vérifié puis marqué terminé au sein d’une transaction.
create or replace function public.record_onsite_payment(p_appointment_id uuid,p_amount numeric,p_method public.payment_method,p_reference text,p_invoice text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_payment uuid;
begin
  if public.current_role()<>'medecin' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and specialite_id=public.current_specialty() for update;
  if not found or v_appointment.statut<>'confirmé' then raise exception 'appointment_not_payable'; end if;
  if p_amount<0 or length(trim(p_invoice))=0 then raise exception 'invalid_payment'; end if;
  insert into public.payments(rendez_vous_id,montant,methode,statut,reference_transaction,numero_facture,enregistre_par)
  values(p_appointment_id,p_amount,p_method,'enregistré',nullif(trim(p_reference),''),trim(p_invoice),auth.uid()) returning id into v_payment;
  update public.appointments set statut='terminé',updated_at=now() where id=p_appointment_id;
  return v_payment;
end $$;
grant execute on function public.record_onsite_payment(uuid,numeric,public.payment_method,text,text) to authenticated;

-- Les écritures de rendez-vous, paiements, messages et identités passent par les RPC/Edge Functions
-- qui vérifient leur contenu. Les privilèges de table accordés par la première migration sont retirés.
revoke insert, update, delete on public.appointments from authenticated;
revoke insert, update, delete on public.payments from authenticated;
revoke insert, update, delete on public.messages from authenticated;
revoke insert, update, delete on public.doctors from authenticated;
revoke insert, update, delete on public.user_roles from authenticated;
revoke update on public.profiles from authenticated;

create trigger audit_availabilities after insert or update or delete on public.availabilities for each row execute function public.write_audit();
create trigger audit_payments after insert or update or delete on public.payments for each row execute function public.write_audit();
create trigger audit_messages after insert or update or delete on public.messages for each row execute function public.write_audit();

create unique index payments_reference_transaction_unique on public.payments(reference_transaction) where reference_transaction is not null;
create unique index payments_invoice_unique on public.payments(numero_facture);

-- IPN PayTech utilise le rôle serveur (auth.uid() est null). Un compte client ne peut pas
-- contourner les vérifications: l’insertion manuelle passe par record_onsite_payment.
create or replace function public.finish_appointment_after_payment() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_specialty uuid;
begin
  select specialite_id into v_specialty from public.appointments where id=new.rendez_vous_id;
  if auth.uid() is not null and (new.enregistre_par <> auth.uid() or v_specialty is distinct from public.current_specialty()) then
    raise exception 'payment_outside_doctor_specialty';
  end if;
  if new.statut='enregistré' then
    update public.appointments set statut='terminé', updated_at=now() where id=new.rendez_vous_id;
  end if;
  return new;
end $$;
create trigger finish_after_paytech_ipn after update of statut on public.payments for each row when (new.statut='enregistré') execute function public.finish_appointment_after_payment();
