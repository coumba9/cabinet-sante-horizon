-- Les créneaux disponibles sont toujours dérivés des disponibilités actives.
-- Quand une disponibilité est bloquée ou supprimée, prévenir les réservations
-- qui dépassent la nouvelle capacité (sans annuler un rendez-vous à la place du patient).
create or replace function public.notify_availability_capacity_impact(
  p_doctor_id uuid,
  p_specialty_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_duration_min integer
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_slot record;
  v_capacity bigint;
begin
  for v_slot in
    select a.date as starts_at, count(*)::bigint as booked
    from public.appointments a
    where a.specialite_id=p_specialty_id
      and a.date>now()
      and a.date>=p_starts_at
      and a.date+make_interval(mins=>p_duration_min)<=p_ends_at
      and mod(extract(epoch from (a.date-p_starts_at))::integer,p_duration_min*60)=0
      and a.statut<>'annulé'
    group by a.date
  loop
    select count(distinct d.id)::bigint into v_capacity
    from public.doctors d
    join public.availabilities av on av.medecin_id=d.id
    where d.specialite_id=p_specialty_id
      and av.status='actif'
      and av.date_debut<=v_slot.starts_at
      and av.date_fin>=v_slot.starts_at+make_interval(mins=>av.duree_creneau_min)
      and mod(extract(epoch from (v_slot.starts_at-av.date_debut))::integer,av.duree_creneau_min*60)=0;

    if v_slot.booked>v_capacity then
      insert into public.messages(expediteur_id,destinataire_id,contenu,date,rendez_vous_id)
      select p_doctor_id, impacted.patient_id,
             'Une disponibilité a changé et la capacité de ce créneau est réduite. Votre rendez-vous du '
             ||to_char(v_slot.starts_at at time zone 'Africa/Dakar','DD/MM/YYYY à HH24:MI')
             ||' doit être reprogrammé. Contactez le cabinet ou choisissez un autre créneau.',
             now(),impacted.id
      from (
        select a.id,a.patient_id,
               row_number() over(order by a.created_at,a.id) as booking_number
        from public.appointments a
        where a.specialite_id=p_specialty_id
          and a.date=v_slot.starts_at
          and a.statut<>'annulé'
      ) impacted
      where impacted.booking_number>v_capacity;
    end if;
  end loop;
end;
$$;

create or replace function public.doctor_change_availability(
  p_availability_id uuid,
  p_status text default null,
  p_delete boolean default false
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_availability public.availabilities%rowtype;
  v_specialty_id uuid;
  v_slot record;
begin
  if auth.uid() is null or public.current_role()<>'medecin' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  if not p_delete and (p_status is null or p_status not in ('actif','bloqué','libéré')) then
    raise exception 'invalid_availability_status';
  end if;

  select * into v_availability
  from public.availabilities
  where id=p_availability_id and medecin_id=auth.uid()
  for update;
  if not found then raise exception 'availability_not_found'; end if;
  select specialite_id into v_specialty_id from public.doctors where id=auth.uid();

  -- Sérialise chaque créneau touché avec les réservations et reports simultanés.
  for v_slot in
    select distinct a.date
    from public.appointments a
    where a.specialite_id=v_specialty_id
      and a.date>now()
      and a.date>=v_availability.date_debut
      and a.date+make_interval(mins=>v_availability.duree_creneau_min)<=v_availability.date_fin
      and mod(extract(epoch from (a.date-v_availability.date_debut))::integer,v_availability.duree_creneau_min*60)=0
      and a.statut<>'annulé'
    order by a.date
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_specialty_id::text||v_slot.date::text,0));
  end loop;

  if p_delete then
    delete from public.availabilities where id=p_availability_id;
  else
    if v_availability.status=p_status then return; end if;
    update public.availabilities set status=p_status where id=p_availability_id;
    if p_status='actif' then return; end if;
  end if;

  perform public.notify_availability_capacity_impact(
    auth.uid(),v_specialty_id,v_availability.date_debut,v_availability.date_fin,v_availability.duree_creneau_min
  );
end;
$$;

-- Les changements passent par le RPC afin d'appliquer les contrôles, notifications et audit.
revoke update,delete on public.availabilities from authenticated;
revoke all on function public.notify_availability_capacity_impact(uuid,uuid,timestamptz,timestamptz,integer) from public,anon,authenticated;
revoke all on function public.doctor_change_availability(uuid,text,boolean) from public,anon;
grant execute on function public.doctor_change_availability(uuid,text,boolean) to authenticated;
