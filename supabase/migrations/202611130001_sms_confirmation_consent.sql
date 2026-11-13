-- Envoie la confirmation lorsque le patient a consenti aux SMS à l'inscription,
-- même s'il n'a pas activé les rappels 24 h et 5 h pour ce rendez-vous.
create or replace function public.queue_appointment_sms_jobs()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_changed boolean;
  v_rescheduled boolean;
  v_sms_consent boolean := false;
begin
  v_changed := tg_op='INSERT'
    or new.statut is distinct from old.statut
    or new.date is distinct from old.date
    or new.sms_reminders_enabled is distinct from old.sms_reminders_enabled;
  if not v_changed then return new; end if;

  if new.statut in ('annulé','terminé') then
    update public.appointment_sms_jobs set status='cancelled',updated_at=now()
     where appointment_id=new.id and status in ('pending','sending');
    return new;
  end if;

  select p.sms_consent_at is not null and p.telephone_verified_at is not null
    into v_sms_consent from public.profiles p where p.id=new.patient_id;
  v_sms_consent := coalesce(v_sms_consent,false);

  if not new.sms_reminders_enabled then
    update public.appointment_sms_jobs set status='cancelled',updated_at=now()
     where appointment_id=new.id and kind in ('24h','5h') and status in ('pending','sending');
  end if;

  -- La confirmation est un SMS distinct des rappels; l'accord donné au compte
  -- ou à cette réservation suffit pour l'envoyer.
  if new.statut='confirmé' and (v_sms_consent or new.sms_reminders_enabled)
     and (tg_op='INSERT' or old.statut is distinct from 'confirmé' or old.date is distinct from new.date) then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      values(new.id,'confirmation',now())
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,
            updated_at=now(),sent_at=null,provider_message_id=null
      where public.appointment_sms_jobs.status in ('pending','cancelled','failed');
  end if;

  v_rescheduled := tg_op='UPDATE' and old.date is distinct from new.date;
  if v_rescheduled and new.statut='reprogrammé' and new.sms_reminders_enabled then
    insert into public.appointment_sms_jobs(appointment_id,kind,scheduled_at)
      values(new.id,'reprogrammed',now())
      on conflict(appointment_id,kind) do update
        set scheduled_at=excluded.scheduled_at,status='pending',attempts=0,last_error=null,
            updated_at=now(),sent_at=null,provider_message_id=null;
  end if;

  if new.sms_reminders_enabled and new.statut in ('confirmé','reprogrammé')
     and (tg_op='INSERT' or old.statut is distinct from new.statut or old.date is distinct from new.date or old.sms_reminders_enabled is distinct from new.sms_reminders_enabled) then
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
