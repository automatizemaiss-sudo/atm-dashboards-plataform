import {createClient} from '@supabase/supabase-js';
import {connectionView,instanceConfig} from '../../../lib/uazapi';
export const runtime='nodejs';
const json=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store, private'}});
async function handle(request:Request,connect:boolean){
 const origin=request.headers.get('origin');
 if(origin&&origin!==new URL(request.url).origin)return json({error:'Origem inválida.'},403);
 const bearer=request.headers.get('authorization');
 if(!bearer?.startsWith('Bearer '))return json({error:'Entre novamente para acessar a conexão.'},401);
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
 if(!url||!key)return json({error:'Conexão indisponível. Configure o Supabase no servidor.'},503);
 try{
 const client=createClient(url,key,{global:{headers:{Authorization:bearer}},auth:{persistSession:false,autoRefreshToken:false}});
 const {data:auth,error:authError}=await client.auth.getUser(bearer.slice(7));
 if(authError||!auth.user)return json({error:'Sessão expirada. Entre novamente.'},401);
 const id=new URL(request.url).searchParams.get('instance');
 if(!id||!/^[0-9a-f-]{36}$/i.test(id))return json({error:'Selecione uma instância válida.'},400);
 // RLS verifies organization membership before any credential lookup or provider call.
 const {data:instance,error}=await client.from('whatsapp_instances').select('id,provider').eq('id',id).maybeSingle();
 if(error)return json({error:'Não foi possível verificar o acesso à instância.'},503);
 if(!instance||instance.provider!=='uazapi')return json({error:'Instância não disponível para seu usuário.'},403);
 const config=instanceConfig(id);
 if(!config)return json({error:'A conexão desta instância ainda precisa ser configurada no servidor.'},503);
 const call=async(path:string,post=false)=>{
  const response=await fetch(`${config.url}/instance/${path}`,{method:post?'POST':'GET',headers:{token:config.token,...(post?{'Content-Type':'application/json'}:{})},body:post?'{}':undefined,cache:'no-store',redirect:'error',signal:AbortSignal.timeout(15000)});
  if(!response.ok){if(response.status===409&&post)return null;throw new Error('PROVIDER');}
  return response.json();
 };
 let raw=await call('status');
 let view=connectionView(raw);
 if(connect&&['disconnected','hibernated'].includes(view.status)){
  raw=await call('connect',true);
  // Connect can acknowledge the request before it has a QR or a full instance object.
  try{view=connectionView(raw)}catch{view=connectionView(await call('status'))}
 }
 let monitoringSaved=false;
 const service=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(service){
  const server=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const saved=await server.rpc('record_whatsapp_connection',{instance:id,connection_status:view.status});
  monitoringSaved=!saved.error;
 }
 return json({...view,monitoringSaved});
 }catch{return json({error:'Não foi possível consultar a Uazapi. Verifique a configuração ou tente novamente em alguns instantes.'},502);}
}
export function GET(request:Request){return handle(request,false)}
export function POST(request:Request){return handle(request,true)}
