-- Le paiement ne change plus le statut d’un rendez-vous.
drop trigger if exists finish_after_payment on public.payments;
drop trigger if exists finish_after_paytech_ipn on public.payments;
drop function if exists public.finish_appointment_after_payment();
drop function if exists public.record_onsite_payment(uuid,numeric,public.payment_method,text,text);

-- Répare les rendez-vous encore dans le futur qui auraient été terminés par un ancien paiement.
update public.appointments set statut='confirmé',updated_at=now()
 where statut='terminé' and date>now();

-- Seul le médecin de la spécialité peut terminer un rendez-vous, à partir de son heure prévue.
create or replace function public.complete_appointment(p_appointment_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype;
begin
  if auth.uid() is null or public.current_role()<>'medecin' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  select * into v_appointment from public.appointments
   where id=p_appointment_id and specialite_id=public.current_specialty() for update;
  if not found or v_appointment.statut<>'confirmé' then raise exception 'appointment_not_completable'; end if;
  if v_appointment.date>now() then raise exception 'appointment_not_due'; end if;
  update public.appointments set statut='terminé',updated_at=now() where id=p_appointment_id;
end $$;
grant execute on function public.complete_appointment(uuid) to authenticated;

-- Active les événements Realtime pour que les participants reçoivent les nouveaux messages.
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='messages') then
    execute 'alter publication supabase_realtime add table public.messages';
  end if;
end $$;
