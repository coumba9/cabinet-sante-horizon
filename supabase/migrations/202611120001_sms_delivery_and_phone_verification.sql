-- Fiabilise les rappels, les changements de créneau et la validation du téléphone.
alter table public.profiles
  add column if not exists telephone_verified_at timestamptz,
  add column if not exists sms_consent_at timestamptz;

create table if not exists public.sms_phone_verifications (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  code_hash text not null,
  status text not null default 'pending' check (status in ('pending','verified','consumed','failed')),
  delivery_status text not null default 'pending' check (delivery_status in ('pending','sent','failed')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  last_error text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  consumed_at timestamptz
);
create index if not exists sms_phone_verifications_rate_idx
  on public.sms_phone_verifications(phone_e164, created_at desc);
alter table public.sms_phone_verifications enable row level security;
revoke all on public.sms_phone_verifications from anon, authenticated;

create or replace function public.set_appointment_sms_reminders(p_appointment_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  if p_enabled and not exists(select 1 from public.profiles where id=auth.uid() and telephone_verified_at is not null) then
    raise exception 'phone_not_verified';
  end if;
  update public.appointments set sms_reminders_enabled=p_enabled,updated_at=now()
   where id=p_appointment_id and patient_id=auth.uid() and statut in ('demandé','confirmé','reprogrammé') and date>now();
  if not found then raise exception 'appointment_not_changeable'; end if;
end $$;
grant execute on function public.set_appointment_sms_reminders(uuid,boolean) to authenticated;

create or replace function public.request_appointment(
  p_specialty_id uuid,
  p_starts_at timestamptz,
  p_sms_reminders_enabled boolean default false
)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_capacity integer;v_taken integer;v_result uuid;
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  if coalesce(p_sms_reminders_enabled,false) and not exists(select 1 from public.profiles where id=auth.uid() and telephone_verified_at is not null) then raise exception 'phone_not_verified'; end if;
  if p_starts_at<=now() then raise exception 'slot_past'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_specialty_id::text||p_starts_at::text,0));
  select count(distinct d.id) into v_capacity from public.doctors d join public.availabilities a on a.medecin_id=d.id
   where d.specialite_id=p_specialty_id and a.status='actif' and a.date_debut<=p_starts_at
     and a.date_fin>=p_starts_at+make_interval(mins=>a.duree_creneau_min)
     and mod(extract(epoch from (p_starts_at-a.date_debut))::integer,a.duree_creneau_min*60)=0;
  select count(*) into v_taken from public.appointments where specialite_id=p_specialty_id and date=p_starts_at and statut<>'annulé';
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;
  insert into public.appointments(patient_id,specialite_id,date,statut,sms_reminders_enabled)
    values(auth.uid(),p_specialty_id,p_starts_at,'demandé',coalesce(p_sms_reminders_enabled,false)) returning id into v_result;
  insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'création','rendez_vous',v_result::text,jsonb_build_object('sms_reminders_enabled',coalesce(p_sms_reminders_enabled,false)));
  return v_result;
end $$;
grant execute on function public.request_appointment(uuid,timestamptz,boolean) to authenticated;

alter table public.appointment_sms_jobs
  drop constraint if exists appointment_sms_jobs_kind_check;
alter table public.appointment_sms_jobs
  add constraint appointment_sms_jobs_kind_check check (kind in ('confirmation','reprogrammed','24h','5h'));

create or replace function public.queue_appointment_sms_jobs()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_changed boolean; v_rescheduled boolean;
begin
  v_changed := tg_op='INSERT'
    or new.statut is distinct from old.statut
    or new.date is distinct from old.date
    or new.sms_reminders_enabled is distinct from old.sms_reminders_enabled;
  if not v_changed then return new; end if;

  if new.statut in ('annulé','terminé') or not new.sms_reminders_enabled then
    update public.appointment_sms_jobs set status='cancelled',updated_at=now()
     where appointment_id=new.id and status in ('pending','sending');
    return new;
  end if;

  v_rescheduled := tg_op='UPDATE' and old.date is distinct from new.date;
  if new.sms_reminders_enabled and new.statut='confirmé'
     and (tg_op='INSERT' or old.statut is distinct from 'confirmé' or old.sms_reminders_enabled is distinct from true) then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      values(new.id,'confirmation',now())
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,
            updated_at=now(),sent_at=null,provider_message_id=null
      where public.appointment_sms_jobs.status in ('pending','cancelled','failed');
  end if;

  if v_rescheduled and new.statut='reprogrammé' and new.sms_reminders_enabled then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      values(new.id,'reprogrammed',now())
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,
            updated_at=now(),sent_at=null,provider_message_id=null;
  end if;

  if new.sms_reminders_enabled and new.statut in ('confirmé','reprogrammé')
     and (tg_op='INSERT' or old.statut is distinct from new.statut or old.date is distinct from new.date or old.sms_reminders_enabled is distinct from new.sms_reminders_enabled) then
    -- Recalcule les deux rappels à chaque changement. Un rappel dont l’échéance
    -- est déjà passée est marqué annulé au lieu de conserver l’ancien horaire.
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at,status)
      select new.id,reminder.kind,reminder.at,
             case when reminder.at>now() then 'pending' else 'cancelled' end
      from (values ('24h'::text,new.date-interval '24 hours'),('5h'::text,new.date-interval '5 hours')) as reminder(kind,at)
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status=excluded.status,attempts=0,last_error=null,
            updated_at=now(),sent_at=null,provider_message_id=null;
  end if;
  return new;
end $$;

create or replace function public.audit_appointment_sms_consent()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' and new.sms_reminders_enabled then
    insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'consentement SMS accordé','rendez_vous',new.id::text,
      jsonb_build_object('enabled',true,'recorded_at',now()));
  elsif tg_op='UPDATE' and new.sms_reminders_enabled is distinct from old.sms_reminders_enabled then
    insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'consentement SMS '||case when new.sms_reminders_enabled then 'accordé' else 'retiré' end,
      'rendez_vous',new.id::text,jsonb_build_object('enabled',new.sms_reminders_enabled,'recorded_at',now()));
  end if;
  return new;
end $$;
drop trigger if exists audit_appointment_sms_consent on public.appointments;
create trigger audit_appointment_sms_consent after insert or update of sms_reminders_enabled on public.appointments
for each row execute function public.audit_appointment_sms_consent();
