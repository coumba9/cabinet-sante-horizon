create or replace function public.patient_paid_invoices()
returns table(
  payment_id uuid,
  appointment_id uuid,
  invoice_number text,
  paid_at timestamptz,
  patient_name text,
  patient_phone text,
  appointment_at timestamptz,
  specialty text,
  payment_method text,
  transaction_reference text,
  amount numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.current_role() <> 'patient' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  return query
  select p.id,
         a.id,
         p.numero_facture,
         p.created_at,
         trim(concat(pr.prenom, ' ', pr.nom)),
         pr.telephone,
         a.date,
         s.nom,
         coalesce(p.canal_paiement, case p.methode::text
           when 'espèces' then 'Espèces'
           when 'mobile_money' then 'Paiement mobile'
           else p.methode::text end),
         p.reference_transaction,
         p.montant
  from public.payments p
  join public.appointments a on a.id = p.rendez_vous_id
  join public.profiles pr on pr.id = a.patient_id
  join public.specialties s on s.id = a.specialite_id
  where a.patient_id = auth.uid()
    and p.statut = 'payé'
  order by p.created_at desc;
end;
$$;
revoke all on function public.patient_paid_invoices() from public, anon;
grant execute on function public.patient_paid_invoices() to authenticated;

-- Un administrateur peut consulter une facture acquittée pour l'imprimer au patient.
create or replace function public.admin_paid_invoice_details(p_appointment_id uuid)
returns table(
  payment_id uuid,
  appointment_id uuid,
  invoice_number text,
  paid_at timestamptz,
  patient_name text,
  patient_phone text,
  appointment_at timestamptz,
  specialty text,
  payment_method text,
  transaction_reference text,
  amount numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.current_role() <> 'administrateur' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  return query
  select p.id,
         a.id,
         p.numero_facture,
         p.created_at,
         trim(concat(pr.prenom, ' ', pr.nom)),
         pr.telephone,
         a.date,
         s.nom,
         coalesce(p.canal_paiement, case p.methode::text
           when 'espèces' then 'Espèces'
           when 'mobile_money' then 'Paiement mobile'
           else p.methode::text end),
         p.reference_transaction,
         p.montant
  from public.payments p
  join public.appointments a on a.id = p.rendez_vous_id
  join public.profiles pr on pr.id = a.patient_id
  join public.specialties s on s.id = a.specialite_id
  where a.id = p_appointment_id
    and p.statut = 'payé';
end;
$$;
revoke all on function public.admin_paid_invoice_details(uuid) from public, anon;
grant execute on function public.admin_paid_invoice_details(uuid) to authenticated;
