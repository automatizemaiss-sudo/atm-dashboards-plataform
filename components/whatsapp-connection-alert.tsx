'use client';
import {useEffect,useState} from 'react';
import {supabase} from '../lib/supabase';
type Instance={id:string;name:string};
type Connection={instance_id:string;status:string;checked_at:string};
export default function WhatsappConnectionAlert({org,onConnect}:{org:string;onConnect?:()=>void}){
 const [instances,setInstances]=useState<Instance[]>([]),[connections,setConnections]=useState<Connection[]>([]),[error,setError]=useState(false),[now,setNow]=useState(Date.now());
 useEffect(()=>{let active=true;
  async function load(){try{
   const result=await supabase!.from('whatsapp_instances').select('id,name').eq('organization_id',org).eq('enabled',true);
   if(result.error)throw result.error;
   const rows=result.data as Instance[];
   const status=rows.length?await supabase!.from('whatsapp_connection_status').select('instance_id,status,checked_at').in('instance_id',rows.map(i=>i.id)):{data:[],error:null};
   if(status.error)throw status.error;
   if(active){setInstances(rows);setConnections(status.data as Connection[]);setError(false);setNow(Date.now())}
  }catch{if(active){setError(true);setNow(Date.now())}}}
  void load();const timer=setInterval(()=>void load(),15000);
  return()=>{active=false;clearInterval(timer)};
 },[org]);
 return <>{error&&<div className="alert" role="alert">Não foi possível verificar a conexão do WhatsApp. Confira a conexão e o monitoramento.</div>}{instances.map(instance=>{
  const connection=connections.find(c=>c.instance_id===instance.id);
  const stale=!connection||now-new Date(connection.checked_at).getTime()>180000;
  if(!stale&&connection.status==='connected')return null;
  const labels:Record<string,string>={disconnected:'desconectado',connecting:'conectando',hibernated:'em hibernação'};
  return <section key={instance.id} className="alert" role="alert"><strong>{instance.name}: {stale?'conexão sem verificação recente':`WhatsApp ${labels[connection.status]||'sem conexão confirmada'}`}</strong><p>{stale?'Não há confirmação atual da conexão. Confira o monitoramento.':'Os disparos podem estar interrompidos. Abra Conexão WhatsApp para verificar e reconectar.'}</p>{onConnect&&<button className="secondary" onClick={onConnect}>Abrir conexão WhatsApp</button>}{connection&&<small>Última verificação: {new Date(connection.checked_at).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'})} · horário de Brasília</small>}</section>;
 })}</>;
}
