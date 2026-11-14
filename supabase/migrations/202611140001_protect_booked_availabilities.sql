-- Une disponibilité avec des rendez-vous ne peut pas être supprimée.
-- La règle est vérifiée dans le RPC sécurisé afin d’éviter les courses côté navigateur.
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

  -- Verrouille les créneaux à venir pendant la mise à jour ou la suppression.
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
    if exists (
      select 1 from public.appointments a
      where a.specialite_id=v_specialty_id
        and a.date>=v_availability.date_debut
        and a.date+make_interval(mins=>v_availability.duree_creneau_min)<=v_availability.date_fin
        and mod(extract(epoch from (a.date-v_availability.date_debut))::integer,v_availability.duree_creneau_min*60)=0
        and a.statut<>'annulé'
    ) then
      raise exception 'availability_has_appointments';
    end if;
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

revoke all on function public.doctor_change_availability(uuid,text,boolean) from public,anon;
grant execute on function public.doctor_change_availability(uuid,text,boolean) to authenticated;
