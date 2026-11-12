import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';
const cors={ 'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type, x-demo-seed-secret','Access-Control-Allow-Methods':'POST, OPTIONS' };
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});
const users=[
  {identifier:'admin.demo',role:'administrateur',prenom:'Admin',nom:'Cabinet',phone:'770000001',license:'',specialty:''},
  {identifier:'awa.demo',role:'medecin',prenom:'Awa',nom:'Ndiaye',phone:'770000002',license:'SN-2021-0482',specialty:'Médecine générale'},
  {identifier:'ibrahima.demo',role:'medecin',prenom:'Ibrahima',nom:'Ba',phone:'770000003',license:'SN-2018-0207',specialty:'Médecine générale'},
  {identifier:'mamadou.demo',role:'medecin',prenom:'Mamadou',nom:'Fall',phone:'770000004',license:'SN-2019-0314',specialty:'Cardiologie'},
  {identifier:'fatou.med.demo',role:'medecin',prenom:'Fatou',nom:'Diop',phone:'770000005',license:'SN-2022-0591',specialty:'Pédiatrie'},
  {identifier:'aminata.demo',role:'patient',prenom:'Aminata',nom:'Diallo',phone:'770000006',license:'',specialty:'',blood:'O+',history:'Allergie aux arachides'},
  {identifier:'moussa.demo',role:'patient',prenom:'Moussa',nom:'Sarr',phone:'770000007',license:'',specialty:'',blood:'A+',history:'Aucun antécédent déclaré'},
  {identifier:'fatou.patient.demo',role:'patient',prenom:'Fatou',nom:'Cissé',phone:'770000008',license:'',specialty:'',blood:'B+',history:'Asthme léger'},
  {identifier:'ibrahima.patient.demo',role:'patient',prenom:'Ibrahima',nom:'Sy',phone:'770000009',license:'',specialty:'',blood:'O-',history:'Aucun antécédent déclaré'},
  {identifier:'mariama.demo',role:'patient',prenom:'Mariama',nom:'Gaye',phone:'770000010',license:'',specialty:'',blood:'AB+',history:'Hypertension'},
];
Deno.serve(async req=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return reply({error:'method_not_allowed'},405);
  const expected=Deno.env.get('DEMO_SEED_SECRET'),password=Deno.env.get('DEMO_PASSWORD');
  if(!expected||req.headers.get('x-demo-seed-secret')!==expected)return reply({error:'forbidden'},403);
  if(!password||password.length<10)return reply({error:'set_demo_password',message:'Configurez DEMO_PASSWORD (10 caractères minimum) comme secret serveur.'},503);
  const db=createClient(supabaseUrl(),supabaseSecretKey(),{auth:{autoRefreshToken:false,persistSession:false}});
  const {data:specialties,error:specialtyError}=await db.from('specialties').select('id,nom');
  if(specialtyError||!specialties?.length)return reply({error:'run_migrations_first'},409);
  const ids=new Map(specialties.map(s=>[s.nom,s.id]));const records=new Map<string,string>();
  for(const seed of users){
    let {data:profile}=await db.from('profiles').select('id').eq('identifiant',seed.identifier).maybeSingle();
    let id=profile?.id as string|undefined;
    if(!id){const {data,error}=await db.auth.admin.createUser({email:`${seed.identifier}@cabinet.local`,password,email_confirm:true});if(error||!data.user)return reply({error:'user_create_failed',identifier:seed.identifier,message:error?.message},400);id=data.user.id}
    records.set(seed.identifier,id!);
    const {error:profileError}=await db.from('profiles').upsert({id,nom:seed.nom,prenom:seed.prenom,telephone:seed.phone,identifiant:seed.identifier,status:'actif'});
    if(profileError)return reply({error:'profile_seed_failed',identifier:seed.identifier,message:profileError.message},400);
    const {error:roleError}=await db.from('user_roles').upsert({user_id:id,role:seed.role},{onConflict:'user_id'});
    if(roleError)return reply({error:'role_seed_failed',identifier:seed.identifier,message:roleError.message},400);
    if(seed.role==='patient'){
      const {error}=await db.from('patients').upsert({id,groupe_sanguin:seed.blood,antecedents:seed.history});if(error)return reply({error:'patient_seed_failed',message:error.message},400);
    }else if(seed.role==='medecin'){
      const {error}=await db.from('doctors').upsert({id,numero_licence:seed.license,specialite_id:ids.get(seed.specialty)});if(error)return reply({error:'doctor_seed_failed',message:error.message},400);
    }else{
      const {error}=await db.from('administrators').upsert({id,niveau_acces:'standard'});if(error)return reply({error:'admin_seed_failed',message:error.message},400);
    }
  }
  const doctorRows=users.filter(u=>u.role==='medecin');
  for(const doctor of doctorRows){
    const doctorId=records.get(doctor.identifier)!;
    const availabilitySeed=[] as Array<{medecin_id:string;date_debut:string;date_fin:string;duree_creneau_min:number;status:string}>;
    const first=new Date();first.setUTCHours(0,0,0,0);const through=new Date(first);through.setUTCDate(through.getUTCDate()+15);
    const {data:existingRows}=await db.from('availabilities').select('date_debut').eq('medecin_id',doctorId).gte('date_debut',first.toISOString()).lt('date_debut',through.toISOString());
    const existingStarts=new Set((existingRows??[]).map(row=>new Date(row.date_debut).toISOString()));
    for(let offset=1;offset<=14;offset++){
      const d=new Date();d.setUTCDate(d.getUTCDate()+offset);if(d.getUTCDay()===0)continue;
      for(const [start,end] of [['08:30','12:30'],['14:00','17:00']]){
        const startAt=`${d.toISOString().slice(0,10)}T${start}:00Z`,endAt=`${d.toISOString().slice(0,10)}T${end}:00Z`;
        if(!existingStarts.has(new Date(startAt).toISOString()))availabilitySeed.push({medecin_id:doctorId,date_debut:startAt,date_fin:endAt,duree_creneau_min:30,status:'actif'});
      }
    }
    if(availabilitySeed.length){const {error}=await db.from('availabilities').insert(availabilitySeed);if(error)return reply({error:'availability_seed_failed',message:error.message},400)}
  }
  const sampleAppointments=[
    {patient:'aminata.demo',specialty:'Médecine générale',days:1,time:'09:30',status:'confirmé'},
    {patient:'moussa.demo',specialty:'Cardiologie',days:2,time:'10:00',status:'demandé'},
    {patient:'fatou.patient.demo',specialty:'Pédiatrie',days:3,time:'11:30',status:'confirmé'},
    {patient:'ibrahima.patient.demo',specialty:'Médecine générale',days:-1,time:'14:00',status:'terminé'},
    {patient:'mariama.demo',specialty:'Cardiologie',days:5,time:'09:00',status:'annulé'},
  ];
  for(const row of sampleAppointments){
    const d=new Date();d.setUTCDate(d.getUTCDate()+row.days);const date=`${d.toISOString().slice(0,10)}T${row.time}:00Z`,patientId=records.get(row.patient)!,specialtyId=ids.get(row.specialty)!;
    const {data:existing}=await db.from('appointments').select('id').eq('patient_id',patientId).eq('date',date).maybeSingle();
    if(!existing){const {error}=await db.from('appointments').insert({patient_id:patientId,specialite_id:specialtyId,date,statut:row.status});if(error)return reply({error:'appointment_seed_failed',message:error.message},400)}
  }
  await db.from('audit_log').insert({actor_id:records.get('admin.demo'),action:'initialisation données démo',entity:'système',details:{accounts:users.length}});
  return reply({success:true,accounts:users.map(u=>({identifiant:u.identifier,role:u.role})),message:'Comptes de démonstration initialisés. Le mot de passe partagé est celui de DEMO_PASSWORD.'});
});
