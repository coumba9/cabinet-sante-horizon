-- Paiement hébergé PayTech : secrets côté serveur, IPN vérifié, aucune donnée médicale transmise.
alter table public.payments
  add column if not exists paytech_ref_command text,
  add column if not exists paytech_token text,
  add column if not exists paytech_redirect_url text,
  add column if not exists paytech_error text;

create unique index if not exists payments_paytech_ref_command_unique
  on public.payments(paytech_ref_command) where paytech_ref_command is not null;
create unique index if not exists payments_one_pending_paytech_per_appointment_idx
  on public.payments(rendez_vous_id) where statut='en attente' and paytech_ref_command is not null;

create or replace function public.prevent_manual_paid_with_pending_paytech()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.statut='payé' and exists (
    select 1 from public.payments p
     where p.rendez_vous_id=new.rendez_vous_id and p.statut='en attente'
       and p.paytech_ref_command is not null and p.id is distinct from new.id
  ) then raise exception 'paytech_payment_pending'; end if;
  return new;
end $$;
drop trigger if exists prevent_manual_paid_with_pending_paytech on public.payments;
create trigger prevent_manual_paid_with_pending_paytech before insert or update of statut on public.payments
for each row execute function public.prevent_manual_paid_with_pending_paytech();

-- Le paiement confirme ne termine jamais le rendez-vous : seul le médecin le fait après la consultation.
drop trigger if exists finish_after_paytech_ipn on public.payments;
drop trigger if exists finish_after_payment on public.payments;
drop function if exists public.finish_appointment_after_payment();

create or replace function public.paytech_process_ipn(
  p_ref_command text,
  p_amount numeric,
  p_method text,
  p_token text,
  p_event text
)
returns text language plpgsql security definer set search_path=public as $$
declare
  v_payment public.payments%rowtype;
  v_invoice text;
  v_method text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'unauthorized'; end if;
  if p_event not in ('sale_complete','sale_canceled') then raise exception 'invalid_event'; end if;
  select * into v_payment from public.payments
   where paytech_ref_command=p_ref_command for update;
  if not found then return 'unknown_reference'; end if;
  if p_amount is distinct from v_payment.montant then return 'amount_mismatch'; end if;
  if v_payment.statut='payé' then return 'already_paid'; end if;
  if v_payment.statut<>'en attente' then return 'already_closed'; end if;

  if p_event='sale_canceled' then
    update public.payments set statut='échoué',paytech_error='payment_cancelled'
      where id=v_payment.id;
    return 'cancelled';
  end if;

  v_method:=case when p_method in ('Wave','Orange Money','Free Money') then p_method else v_payment.canal_paiement end;
  v_invoice:='JSH-'||to_char(now() at time zone 'Africa/Dakar','YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  update public.payments set statut='payé',reference_transaction=nullif(p_token,''),paytech_token=coalesce(nullif(p_token,''),paytech_token),
      canal_paiement=v_method,numero_facture=v_invoice,paytech_error=null
    where id=v_payment.id;
  return v_invoice;
exception when unique_violation then
  return 'duplicate_transaction';
end $$;
revoke all on function public.paytech_process_ipn(text,numeric,text,text,text) from public,anon,authenticated;
grant execute on function public.paytech_process_ipn(text,numeric,text,text,text) to service_role;
