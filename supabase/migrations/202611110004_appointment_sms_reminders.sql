-- Rappels SMS transactionnels: consentement par rendez-vous, files de tâches
-- et envoi uniquement lorsque le rendez-vous est confirmé.
alter table public.appointments
  add column if not exists sms_reminders_enabled boolean not null default false;

create table if not exists public.appointment_sms_jobs (
  id bigint generated always as identity primary key,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  kind text not null check (kind in ('confirmation','24h','5h')),
  scheduled_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending','sending','sent','failed','cancelled')),
  attempts integer not null default 0,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  unique(appointment_id,kind)
);
create index if not exists appointment_sms_jobs_due_idx
  on public.appointment_sms_jobs(scheduled_at) where status='pending';
alter table public.appointment_sms_jobs enable row level security;
revoke all on public.appointment_sms_jobs from anon,authenticated;

create or replace function public.set_appointment_sms_reminders(p_appointment_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or public.current_role()<>'patient' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  update public.appointments set sms_reminders_enabled=p_enabled,updated_at=now()
   where id=p_appointment_id and patient_id=auth.uid() and statut in ('demandé','confirmé','reprogrammé') and date>now();
  if not found then raise exception 'appointment_not_changeable'; end if;
end $$;
grant execute on function public.set_appointment_sms_reminders(uuid,boolean) to authenticated;

drop function if exists public.request_appointment(uuid,timestamptz);
create or replace function public.request_appointment(
  p_specialty_id uuid,
  p_starts_at timestamptz,
  p_sms_reminders_enabled boolean default false
)
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
  insert into public.appointments(patient_id,specialite_id,date,statut,sms_reminders_enabled)
    values(auth.uid(),p_specialty_id,p_starts_at,'demandé',coalesce(p_sms_reminders_enabled,false)) returning id into v_result;
  insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'création','rendez_vous',v_result::text,jsonb_build_object('sms_reminders_enabled',coalesce(p_sms_reminders_enabled,false)));
  return v_result;
end $$;
grant execute on function public.request_appointment(uuid,timestamptz,boolean) to authenticated;

create or replace function public.queue_appointment_sms_jobs()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_changed boolean;
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

  if new.sms_reminders_enabled and new.statut='confirmé'
     and (tg_op='INSERT' or old.statut is distinct from 'confirmé' or old.sms_reminders_enabled is distinct from true) then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      values(new.id,'confirmation',now())
      on conflict(appointment_id,kind) do nothing;
  end if;

  if new.sms_reminders_enabled and new.statut in ('confirmé','reprogrammé')
     and (tg_op='INSERT' or old.statut is distinct from new.statut or old.date is distinct from new.date or old.sms_reminders_enabled is distinct from new.sms_reminders_enabled) then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      select new.id,reminder.kind,reminder.at
      from (values ('24h'::text,new.date-interval '24 hours'),('5h'::text,new.date-interval '5 hours')) as reminder(kind,at)
      where reminder.at>now()
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,updated_at=now(),sent_at=null,provider_message_id=null;
    update public.appointment_sms_jobs set status='cancelled',updated_at=now()
     where appointment_id=new.id and kind in ('24h','5h') and status in ('pending','sending') and scheduled_at<=now();
  end if;
  return new;
end $$;

drop trigger if exists queue_appointment_sms_jobs on public.appointments;
create trigger queue_appointment_sms_jobs after insert or update on public.appointments
for each row execute function public.queue_appointment_sms_jobs();

create or replace function public.audit_appointment_sms_consent()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.sms_reminders_enabled is distinct from old.sms_reminders_enabled then
    insert into public.audit_log(actor_id,action,entity,entity_id,details)
    values(auth.uid(),'consentement SMS '||case when new.sms_reminders_enabled then 'accordé' else 'retiré' end,
      'rendez_vous',new.id::text,jsonb_build_object('enabled',new.sms_reminders_enabled));
  end if;
  return new;
end $$;
drop trigger if exists audit_appointment_sms_consent on public.appointments;
create trigger audit_appointment_sms_consent after update of sms_reminders_enabled on public.appointments
for each row execute function public.audit_appointment_sms_consent();

create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$
declare v_job record;
begin
  if not exists(select 1 from vault.decrypted_secrets where name='project_url') then
    perform vault.create_secret('https://ktfoajmfbnsslspzglyz.supabase.co','project_url');
  end if;
  for v_job in select jobid from cron.job where jobname='send-appointment-sms-reminders' loop
    perform cron.unschedule(v_job.jobid);
  end loop;
  perform cron.schedule('send-appointment-sms-reminders','* * * * *',$job$
    select net.http_post(
      url:=(select decrypted_secret from vault.decrypted_secrets where name='project_url')||'/functions/v1/send-appointment-sms-reminders',
      headers:=jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='sms_cron_secret')
      ),
      body:=jsonb_build_object('time',now()),
      timeout_milliseconds:=10000
    ) where exists(select 1 from vault.decrypted_secrets where name='sms_cron_secret');
  $job$);
end $$;
