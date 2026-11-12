-- Ajoute à l'administration la liste des rendez-vous situés sur un créneau
-- dont le nombre de réservations actives dépasse la capacité disponible.
create or replace function public.admin_overbooked_appointments(
  p_from timestamptz,
  p_to timestamptz
)
returns table(
  appointment_id uuid,
  patient_name text,
  specialty text,
  starts_at timestamptz,
  appointment_status public.appointment_status,
  slot_capacity bigint,
  slot_booked bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or public.current_role()<>'administrateur' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;

  return query
  with doctor_slots as (
    select distinct d.specialite_id, a.medecin_id, slot.starts_at
    from public.doctors d
    join public.availabilities a on a.medecin_id=d.id
    cross join lateral generate_series(
      a.date_debut,
      a.date_fin-make_interval(mins=>a.duree_creneau_min),
      make_interval(mins=>a.duree_creneau_min)
    ) as slot(starts_at)
    where a.status='actif'
      and a.date_debut<p_to and a.date_fin>p_from
      and slot.starts_at>=p_from and slot.starts_at<p_to
  ), capacities as (
    select ds.specialite_id,ds.starts_at,count(distinct ds.medecin_id)::bigint as capacity
    from doctor_slots ds
    group by ds.specialite_id,ds.starts_at
  ), occupancy as (
    select a.specialite_id,a.date,count(*)::bigint as booked
    from public.appointments a
    where a.date>=p_from and a.date<p_to and a.statut<>'annulé'
    group by a.specialite_id,a.date
  ), overloaded as (
    select o.specialite_id,o.date as starts_at,coalesce(c.capacity,0)::bigint as capacity,o.booked
    from occupancy o
    left join capacities c on c.specialite_id=o.specialite_id and c.starts_at=o.date
    where o.booked>coalesce(c.capacity,0)
  )
  select a.id,
         trim(concat(p.prenom,' ',p.nom)),
         s.nom,
         a.date,
         a.statut,
         o.capacity,
         o.booked
  from overloaded o
  join public.appointments a on a.specialite_id=o.specialite_id and a.date=o.starts_at and a.statut<>'annulé'
  join public.patients pat on pat.id=a.patient_id
  join public.profiles p on p.id=pat.id
  join public.specialties s on s.id=a.specialite_id
  order by a.date,s.nom,p.nom,p.prenom;
end $$;
grant execute on function public.admin_overbooked_appointments(timestamptz,timestamptz) to authenticated;
