import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { supabasePublicKey, supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';
const cors={ 'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS' };
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});

Deno.serve(async req=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return reply({error:'method_not_allowed'},405);
  const body=await req.json(),identifier=String(body.identifier??'').trim(),password=String(body.password??'');
  if(!identifier||!password)return reply({error:'invalid_credentials',message:'Identifiant ou mot de passe incorrect.'},401);
  const url=supabaseUrl(),serviceKey=supabaseSecretKey(),anonKey=supabasePublicKey();
  const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false}});
  const normalized=identifier.toLowerCase(),digits=identifier.replace(/[^0-9+]/g,'');
  let {data:profile}=await admin.from('profiles').select('id,identifiant,status').eq('identifiant',normalized).maybeSingle();
  if(!profile&&digits.length>=7){
    const {data:matches}=await admin.from('profiles').select('id,identifiant,status').eq('telephone',digits).limit(2);
    if(matches?.length===1)profile=matches[0];
  }
  if(!profile)return reply({error:'invalid_credentials',message:'Identifiant ou mot de passe incorrect.'},401);
  if(profile.status==='bloqué')return reply({error:'account_blocked',message:'Ce compte est bloqué. Contactez le cabinet.'},403);
  const publicClient=createClient(url,anonKey,{auth:{autoRefreshToken:false,persistSession:false}});
  const {data,error}=await publicClient.auth.signInWithPassword({email:`${profile.identifiant}@cabinet.local`,password});
  if(error||!data.session)return reply({error:'invalid_credentials',message:'Identifiant ou mot de passe incorrect.'},401);
  return reply({access_token:data.session.access_token,refresh_token:data.session.refresh_token});
});
