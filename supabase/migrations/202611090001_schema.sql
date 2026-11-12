-- Prérequis : exécuter avec le rôle postgres dans le SQL editor Supabase.
create extension if not exists pgcrypto;

create type public.app_role as enum ('patient','medecin','administrateur');
create type public.account_status as enum ('actif','bloqué');
create type public.appointment_status as enum ('demandé','confirmé','reprogrammé','annulé','terminé');
create type public.payment_method as enum ('espèces','mobile_money','carte');

-- Classe de base Utilisateur et spécialisation des profils.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nom text not null,
  prenom text not null,
  telephone text not null,
  identifiant text not null unique,
  status public.account_status not null default 'actif',
  created_at timestamptz not null default now()
);
create table public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null,
  primary key (user_id, role),
  unique(user_id)
);
create table public.patients (
  id uuid primary key references public.profiles(id) on delete cascade,
  date_naissance date,
  sexe text check (sexe is null or sexe in ('Femme','Homme','Autre','Non renseigné')),
  groupe_sanguin text,
  antecedents text not null default ''
);
create table public.specialties (
  id uuid primary key default gen_random_uuid(),
  nom text not null unique,
  description text not null,
  created_at timestamptz not null default now()
);
create table public.doctors (
  id uuid primary key references public.profiles(id) on delete cascade,
  numero_licence text not null unique,
  specialite_id uuid not null references public.specialties(id) on delete restrict
);
create table public.administrators (
  id uuid primary key references public.profiles(id) on delete cascade,
  niveau_acces text not null default 'standard'
);
create table public.availabilities (
  id uuid primary key default gen_random_uuid(),
  medecin_id uuid not null references public.doctors(id) on delete cascade,
  date_debut timestamptz not null,
  date_fin timestamptz not null,
  duree_creneau_min integer not null check (duree_creneau_min between 10 and 240),
  status text not null default 'actif' check (status in ('actif','bloqué','libéré')),
  check (date_fin > date_debut)
);
create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete restrict,
  specialite_id uuid not null references public.specialties(id) on delete restrict,
  date timestamptz not null,
  statut public.appointment_status not null default 'demandé',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index appointments_slot_idx on public.appointments(specialite_id, date) where statut not in ('annulé');
create index availabilities_doctor_time_idx on public.availabilities(medecin_id,date_debut,date_fin) where status='actif';
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  rendez_vous_id uuid not null references public.appointments(id) on delete restrict,
  montant numeric(12,2) not null check (montant >= 0),
  methode public.payment_method not null,
  statut text not null check (statut in ('enregistré','en attente','échoué','remboursé')),
  reference_transaction text,
  numero_facture text not null,
  enregistre_par uuid not null references public.doctors(id) on delete restrict,
  created_at timestamptz not null default now()
);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  expediteur_id uuid not null references public.profiles(id) on delete restrict,
  destinataire_id uuid not null references public.profiles(id) on delete restrict,
  contenu text not null check (length(contenu) between 1 and 4000),
  date timestamptz not null default now(),
  rendez_vous_id uuid references public.appointments(id) on delete set null
);
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.current_role() returns public.app_role
language sql stable security definer set search_path=public as $$
  select role from public.user_roles where user_id=auth.uid() limit 1
$$;
create or replace function public.current_specialty() returns uuid
language sql stable security definer set search_path=public as $$
  select specialite_id from public.doctors where id=auth.uid()
$$;
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and status='actif')
$$;

-- Réservation atomique : verrou par spécialité/créneau, capacité calculée à partir des médecins disponibles.
create or replace function public.request_appointment(p_specialty_id uuid, p_starts_at timestamptz)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_capacity integer; v_taken integer; v_result uuid; v_patient uuid;
begin
  if auth.uid() is null or public.current_role() <> 'patient' or not public.is_active_user() then
    raise exception 'unauthorized';
  end if;
  v_patient := auth.uid();
  perform pg_advisory_xact_lock(hashtextextended(p_specialty_id::text || p_starts_at::text,0));
  select count(distinct d.id) into v_capacity
    from public.doctors d join public.availabilities a on a.medecin_id=d.id
   where d.specialite_id=p_specialty_id and a.status='actif'
     and a.date_debut <= p_starts_at and a.date_fin > p_starts_at
     and mod(extract(epoch from (p_starts_at-a.date_debut))::integer, a.duree_creneau_min*60)=0;
  select count(*) into v_taken from public.appointments
   where specialite_id=p_specialty_id and date=p_starts_at and statut not in ('annulé');
  if v_capacity=0 or v_taken>=v_capacity then raise exception 'slot_full'; end if;
  insert into public.appointments(patient_id,specialite_id,date,statut)
    values(v_patient,p_specialty_id,p_starts_at,'demandé') returning id into v_result;
  insert into public.audit_log(actor_id,action,entity,entity_id)
    values(auth.uid(),'création','rendez_vous',v_result::text);
  return v_result;
end $$;

create or replace function public.write_audit() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_action text; v_id text;
begin
  v_action:=case when tg_op='INSERT' then 'création' when tg_op='DELETE' then 'suppression' else 'modification' end;
  v_id:=case when tg_op='DELETE' then old.id::text else new.id::text end;
  insert into public.audit_log(actor_id,action,entity,entity_id)
  values(auth.uid(),v_action,tg_table_name,v_id);
  return coalesce(new,old);
end $$;
create or replace function public.finish_appointment_after_payment() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_specialty uuid;
begin
  select specialite_id into v_specialty from public.appointments where id=new.rendez_vous_id;
  if new.enregistre_par <> auth.uid() or v_specialty is distinct from public.current_specialty() then
    raise exception 'payment_outside_doctor_specialty';
  end if;
  if new.statut='enregistré' then
    update public.appointments set statut='terminé', updated_at=now() where id=new.rendez_vous_id;
  end if;
  return new;
end $$;
create trigger finish_after_payment after insert on public.payments for each row execute function public.finish_appointment_after_payment();

-- Agrégats sans noms ni données de soins pour le tableau de bord administratif.
create or replace function public.admin_summary(p_from timestamptz default now()-interval '30 days', p_to timestamptz default now())
returns table(kind text, label text, total bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_role() <> 'administrateur' or not public.is_active_user() then raise exception 'unauthorized'; end if;
  return query
    select 'statut'::text, a.statut::text, count(*)::bigint from public.appointments a
     where a.date>=p_from and a.date<p_to group by a.statut
    union all
    select 'spécialité'::text, s.nom, count(*)::bigint from public.appointments a
     join public.specialties s on s.id=a.specialite_id where a.date>=p_from and a.date<p_to group by s.nom;
end $$;

create trigger audit_appointments after insert or update or delete on public.appointments for each row execute function public.write_audit();
create trigger audit_profiles after insert or update or delete on public.profiles for each row execute function public.write_audit();
create trigger audit_doctors after insert or update or delete on public.doctors for each row execute function public.write_audit();

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.patients enable row level security;
alter table public.specialties enable row level security;
alter table public.doctors enable row level security;
alter table public.administrators enable row level security;
alter table public.availabilities enable row level security;
alter table public.appointments enable row level security;
alter table public.payments enable row level security;
alter table public.messages enable row level security;
alter table public.audit_log enable row level security;

-- Patient: ses informations ; médecin: patients et rendez-vous de sa spécialité ; admin: gestion de comptes uniquement.
create policy profiles_read_self_or_doctor on public.profiles for select to authenticated using (
  id=auth.uid() or (public.current_role()='medecin' and exists(select 1 from public.appointments a join public.patients p on p.id=a.patient_id where p.id=profiles.id and a.specialite_id=public.current_specialty()))
);
create policy profiles_admin_manage on public.profiles for all to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
create policy profiles_update_self on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy roles_read_self_or_admin on public.user_roles for select to authenticated using(user_id=auth.uid() or public.current_role()='administrateur');
create policy roles_admin_manage on public.user_roles for all to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
create policy patients_read_self_or_specialty_doctor on public.patients for select to authenticated using(id=auth.uid() or (public.current_role()='medecin' and exists(select 1 from public.appointments a where a.patient_id=patients.id and a.specialite_id=public.current_specialty())));
create policy patients_update_self on public.patients for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy specialties_public_read on public.specialties for select using(true);
create policy specialties_admin_manage on public.specialties for all to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
create policy doctors_read_signed on public.doctors for select to authenticated using(true);
create policy doctors_admin_manage on public.doctors for all to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
create policy admin_self_read on public.administrators for select to authenticated using(id=auth.uid());
create policy admin_manage on public.administrators for all to authenticated using(public.current_role()='administrateur') with check(public.current_role()='administrateur');
create policy availability_read_signed on public.availabilities for select to authenticated using(status='actif' or medecin_id=auth.uid());
create policy availability_doctor_manage on public.availabilities for all to authenticated using(medecin_id=auth.uid() and public.current_role()='medecin') with check(medecin_id=auth.uid() and public.current_role()='medecin');
create policy appointment_patient_read on public.appointments for select to authenticated using(patient_id=auth.uid());
create policy appointment_doctor_read on public.appointments for select to authenticated using(public.current_role()='medecin' and specialite_id=public.current_specialty());
create policy appointment_patient_update on public.appointments for update to authenticated using(patient_id=auth.uid() and statut in ('demandé','confirmé') and date > now()+interval '24 hours') with check(patient_id=auth.uid());
create policy appointment_doctor_update on public.appointments for update to authenticated using(public.current_role()='medecin' and specialite_id=public.current_specialty()) with check(public.current_role()='medecin' and specialite_id=public.current_specialty());
create policy payment_doctor_manage on public.payments for all to authenticated using(public.current_role()='medecin' and enregistre_par=auth.uid()) with check(public.current_role()='medecin' and enregistre_par=auth.uid());
create policy payment_patient_read on public.payments for select to authenticated using(exists(select 1 from public.appointments a where a.id=rendez_vous_id and a.patient_id=auth.uid()));
create policy message_participant_read on public.messages for select to authenticated using(expediteur_id=auth.uid() or destinataire_id=auth.uid());
create policy message_participant_send on public.messages for insert to authenticated with check(expediteur_id=auth.uid() and public.is_active_user());
create policy audit_admin_read on public.audit_log for select to authenticated using(public.current_role()='administrateur');

-- Bloquer l'ouverture de session d'un compte suspendu (refus également appliqué dans les politiques/RPC).
create or replace function public.reject_blocked_login()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.profiles where id=new.user_id and status='bloqué') then
    raise exception 'account_blocked';
  end if;
  return new;
end $$;
create trigger reject_blocked_login before insert on auth.sessions for each row execute function public.reject_blocked_login();

grant usage on schema public to anon, authenticated;
grant select on public.specialties to anon, authenticated;
grant select,update on public.profiles, public.patients to authenticated;
grant select on public.user_roles, public.doctors, public.availabilities, public.appointments, public.messages, public.payments to authenticated;
grant insert,update,delete on public.specialties, public.doctors, public.profiles, public.user_roles to authenticated;
grant insert,update,delete on public.availabilities, public.appointments, public.payments, public.messages to authenticated;
grant execute on function public.request_appointment(uuid,timestamptz) to authenticated;
grant execute on function public.admin_summary(timestamptz,timestamptz) to authenticated;

insert into public.specialties(nom,description) values
 ('Médecine générale','Consultations courantes et suivi de santé.'),
 ('Cardiologie','Prévention et santé du cœur.'),
 ('Pédiatrie','Soins et suivi de santé des enfants.')
on conflict(nom) do nothing;
