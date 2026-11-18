-- Keep the canonical names used by existing appointment records while adding
-- patient-friendly catalogue entries and a primary-care fallback.
update public.specialties
set description='Pour tout problème. Si vous ne savez pas quoi choisir, commencez ici.'
where nom='Médecine générale';

insert into public.specialties(nom,description) values
  ('Dentiste','Soins des dents et de la bouche.'),
  ('Gynécologie','Santé et suivi gynécologique.')
on conflict(nom) do nothing;

-- The primary-care row is required by the app's default booking flow and
-- remains the canonical target for existing doctor and appointment records.
create or replace function public.keep_primary_care_specialty()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op='DELETE' then
    if old.nom='Médecine générale' then
      raise exception 'primary_care_specialty_required';
    end if;
    return old;
  end if;

  if old.nom='Médecine générale' and new.nom is distinct from old.nom then
    raise exception 'primary_care_specialty_required';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_primary_care_specialty on public.specialties;
create trigger protect_primary_care_specialty
before update or delete on public.specialties
for each row execute function public.keep_primary_care_specialty();
