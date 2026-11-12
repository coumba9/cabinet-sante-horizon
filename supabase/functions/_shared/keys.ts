type KeyMap = Record<string,string>;
const defaultKey=(name:string)=>{try{return (JSON.parse(Deno.env.get(name)??'{}') as KeyMap).default}catch{return undefined}};
export const supabaseUrl=()=>Deno.env.get('SUPABASE_URL')!;
export const supabaseSecretKey=()=>defaultKey('SUPABASE_SECRET_KEYS')??Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
export const supabasePublicKey=()=>defaultKey('SUPABASE_PUBLISHABLE_KEYS')??Deno.env.get('SUPABASE_ANON_KEY')!;
