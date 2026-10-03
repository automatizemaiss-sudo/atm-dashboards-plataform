import {createClient} from '@supabase/supabase-js';
import {createHmac} from 'node:crypto';
import {validateRegistration} from '../../../lib/registration';
export const runtime='nodejs';
export async function POST(request:Request){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!key)return Response.json({error:'As inscrições ainda não estão abertas. Tente novamente mais tarde.'},{status:503});
 const origin=request.headers.get('origin');if(origin&&origin!==new URL(request.url).origin)return Response.json({error:'Origem inválida.'},{status:403});
 if(!request.headers.get('content-type')?.includes('application/json'))return Response.json({error:'Formato inválido.'},{status:415});
 try{
 const body=await request.text();if(body.length>5000)return Response.json({error:'Dados muito longos.'},{status:413});
 const raw=JSON.parse(body);if(raw.website)return Response.json({ok:true});
 const data=validateRegistration(raw);
 // Vercel's proxy supplies the address. Persist only a keyed hash, never the raw IP.
 const address=request.headers.get('x-vercel-forwarded-for')??request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()??'unknown';
 const fingerprint=createHmac('sha256',key).update(address).digest('hex');
 const server=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const result=await server.rpc('submit_registration',{data,fingerprint});
 if(result.error){if(result.error.message==='FORM_RATE_LIMIT')return Response.json({error:'Muitas tentativas. Aguarde alguns minutos e tente novamente.'},{status:429});return Response.json({error:'Não foi possível registrar agora. Tente novamente mais tarde.'},{status:503});}
 return Response.json({ok:true});
 }catch(e){return Response.json({error:e instanceof SyntaxError?'Dados inválidos.':e instanceof Error?e.message:'Confira os campos preenchidos.'},{status:400});}
}
