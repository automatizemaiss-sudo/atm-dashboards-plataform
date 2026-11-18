'use client';
import {useEffect,useState} from 'react';
import {supabase} from '../lib/supabase';
type Alert={dispatch_id:string;campaign_id:string;campaign_name:string;contact_name:string|null;status:string;created_at:string;ready_at:string;message:string};
export function useDeliveryAlerts(org:string|undefined){
 const [result,setResult]=useState<{org:string;alerts:Alert[];error:string}>();
 const [revision,setRevision]=useState(0);
 useEffect(()=>{
  if(!org)return;
  const organizationId=org;
  let active=true;
  async function load(){
   const r=await supabase!.rpc('campaign_delivery_alerts',{org:organizationId});
   if(!active)return;
   if(r.error)setResult(previous=>({
    org:organizationId,
    alerts:previous?.org===organizationId?previous.alerts:[],
    error:'Não foi possível verificar os bloqueios de envio. Atualize a página ou confira a conexão com o Supabase.'
   }));
   else setResult({org:organizationId,alerts:r.data as Alert[],error:''});
  }
  void load();
  const timer=setInterval(()=>void load(),15000);
  return()=>{active=false;clearInterval(timer)};
 },[org,revision]);
 return {
  alerts:result?.org===org?result?.alerts??[]:[],
  error:result?.org===org?result?.error??'':'',
  refresh:()=>setRevision(n=>n+1)
 };
}

export default function DeliveryAlerts({alerts,onConfirmed}:{alerts:Alert[];onConfirmed:()=>void}){
 const [error,setError]=useState(''),[busy,setBusy]=useState(false);
 return <details className="campaign-delivery">
  <summary>Conferir envios bloqueados ({alerts.length})</summary>
  <p>A fila da instância afetada fica bloqueada até a conferência.</p>
  {error&&<div className="alert" role="alert">{error}</div>}
  {alerts.map(a=><article key={a.dispatch_id} className="rule-group"><h3>{a.contact_name||'Contato'}</h3><p>{a.message}</p><p>Reservado em {new Date(a.created_at).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'})} · horário de Brasília</p><small>Tentativa: {a.dispatch_id}</small>{a.status!=='reserved'&&<div><button className="secondary" disabled={busy} onClick={async()=>{if(!confirm('Você conferiu na Uazapi ou com o destinatário que esta mensagem foi enviada? Confirmar libera a fila e impede o reenvio desta tentativa.'))return;setBusy(true);setError('');try{const r=await supabase!.rpc('confirm_whatsapp_dispatch_sent',{dispatch_id:a.dispatch_id});if(r.error)throw new Error(r.error.message);onConfirmed()}catch(e){setError(e instanceof Error?e.message:'Não foi possível confirmar.')}finally{setBusy(false)}}}>Conferi: a mensagem foi enviada</button></div>}</article>)}
 </details>;
}
