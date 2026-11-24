-- Paiements sur place enregistrés par l'administration.
-- Le statut clinique du rendez-vous n'est jamais modifié par le paiement.
alter table public.payments
  drop constraint if exists payments_statut_check;
alter table public.payments
  add constraint payments_statut_check
  check (statut in ('enregistré','en attente','échoué','remboursé','payé'));

alter table public.payments
  add column if not exists canal_paiement text;
alter table public.payments
  drop constraint if exists payments_canal_paiement_check;
alter table public.payments
  add constraint payments_canal_paiement_check
  check (canal_paiement is null or canal_paiement in ('Wave','Orange Money','Free Money','Espèces'));

-- Les administrateurs saisissent les règlements; doctor IDs remain profile IDs.
alter table public.payments drop constraint if exists payments_enregistre_par_fkey;
alter table public.payments add constraint payments_enregistre_par_fkey
  foreign key (enregistre_par) references public.profiles(id) on delete restrict;

create unique index if not exists payments_one_paid_per_appointment_idx
  on public.payments(rendez_vous_id) where statut='payé';

create or replace function public.admin_today_payment_appointments()
returns table(
  appointment_id uuid,
  patient_name text,
  patient_phone text,
  starts_at timestamptz,
  specialty text,
  appointment_status text,
  payment_status text,
  payment_method text,
  payment_reference text,
  invoice_number text,
  amount numeric
)
language plpgsql stable security definer set search_path=public as $$
declare v_from timestamptz; v_to timestamptz;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  v_from:=((now() at time zone 'Africa/Dakar')::date::timestamp at time zone 'Africa/Dakar');
  v_to:=(((now() at time zone 'Africa/Dakar')::date+1)::timestamp at time zone 'Africa/Dakar');
  return query
  select a.id,trim(concat(p.prenom,' ',p.nom)),p.telephone,a.date,s.nom,a.statut::text,
         coalesce(pay.statut,'à régler'),pay.canal_paiement,pay.reference_transaction,pay.numero_facture,pay.montant
  from public.appointments a
  join public.profiles p on p.id=a.patient_id
  join public.specialties s on s.id=a.specialite_id
  left join lateral (
    select x.statut,x.canal_paiement,x.reference_transaction,x.numero_facture,x.montant
    from public.payments x where x.rendez_vous_id=a.id
    order by (x.statut='payé') desc,x.created_at desc limit 1
  ) pay on true
  where a.date>=v_from and a.date<v_to and a.statut in ('confirmé','reprogrammé','terminé')
  order by a.date;
end $$;
grant execute on function public.admin_today_payment_appointments() to authenticated;

create or replace function public.admin_record_onsite_payment(
  p_appointment_id uuid,
  p_amount numeric,
  p_method text,
  p_reference text default null
)
returns text language plpgsql security definer set search_path=public as $$
declare
  v_appointment public.appointments%rowtype;
  v_invoice text;
  v_reference text:=nullif(trim(p_reference),'');
  v_payment_method public.payment_method;
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  if p_method not in ('Wave','Orange Money','Free Money','Espèces') then raise exception 'invalid_payment_method'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'invalid_payment_amount'; end if;
  if p_method<>'Espèces' and v_reference is null then raise exception 'payment_reference_required'; end if;
  select * into v_appointment from public.appointments
   where id=p_appointment_id and statut in ('confirmé','reprogrammé','terminé') for update;
  if not found then raise exception 'appointment_not_payable'; end if;
  if v_appointment.date < ((now() at time zone 'Africa/Dakar')::date::timestamp at time zone 'Africa/Dakar')
     or v_appointment.date >= (((now() at time zone 'Africa/Dakar')::date+1)::timestamp at time zone 'Africa/Dakar') then
    raise exception 'appointment_not_today';
  end if;
  if exists(select 1 from public.payments where rendez_vous_id=p_appointment_id and statut='payé') then
    raise exception 'appointment_already_paid';
  end if;
  v_payment_method:=case when p_method='Espèces' then 'espèces'::public.payment_method else 'mobile_money'::public.payment_method end;
  v_invoice:='JSH-'||to_char(now() at time zone 'Africa/Dakar','YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.payments(rendez_vous_id,montant,methode,statut,reference_transaction,numero_facture,enregistre_par,canal_paiement)
   values(p_appointment_id,p_amount,v_payment_method,'payé',v_reference,v_invoice,auth.uid(),p_method);
  return v_invoice;
exception
  when unique_violation then
    if v_reference is not null and exists(select 1 from public.payments where reference_transaction=v_reference) then raise exception 'payment_reference_already_used'; end if;
    raise exception 'appointment_already_paid';
end $$;
grant execute on function public.admin_record_onsite_payment(uuid,numeric,text,text) to authenticated;
revoke all on function public.admin_today_payment_appointments() from public,anon;
revoke all on function public.admin_record_onsite_payment(uuid,numeric,text,text) from public,anon;
