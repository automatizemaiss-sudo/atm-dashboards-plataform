'use client';
import {useEffect,useRef,useState} from 'react';
import {supabase} from '../lib/supabase';
type Connection={status:string;qrcode:string|null;phone:string|null;checked_at:string;monitoringSaved:boolean};
const labels:Record<string,string>={connected:'Conectado',connecting:'Aguardando conexão',disconnected:'Desconectado',hibernated:'Em hibernação'};
export default function WhatsappConnection({instances}:{instances:{id:string;name:string;enabled:boolean}[]}){
 const [selected,setSelected]=useState('');
 const id=instances.some(i=>i.id===selected)?selected:instances[0]?.id??'';
 const [connection,setConnection]=useState<Connection|null>(null),[error,setError]=useState(''),[busy,setBusy]=useState(false);
 const sequence=useRef(0),inFlight=useRef(false);
 useEffect(()=>{
  const current=++sequence.current;let stopped=false;let timer:ReturnType<typeof setTimeout>;
  setConnection(null);setError('');setBusy(false);inFlight.current=false;
  async function poll(){
   if(!id||stopped)return;
   if(!inFlight.current){await request(false,id,current);}
   if(!stopped)timer=setTimeout(()=>void poll(),5000);
  }
  void poll();return()=>{stopped=true;clearTimeout(timer);sequence.current++};
 },[id]);
 async function request(connect:boolean,instance=id,current=sequence.current){
  if(inFlight.current)return;inFlight.current=true;setBusy(true);
  try{
   const {data}=await supabase!.auth.getSession();
   if(!data.session)throw new Error('Entre novamente para acessar a conexão.');
   const response=await fetch(`/api/whatsapp?instance=${encodeURIComponent(instance)}`,{method:connect?'POST':'GET',headers:{Authorization:`Bearer ${data.session.access_token}`},cache:'no-store'});
   const result=await response.json();
   if(!response.ok)throw new Error(result.error||'Não foi possível verificar a conexão.');
   if(current===sequence.current){setConnection(result);setError('');}
  }catch(e){if(current===sequence.current){setConnection(null);setError(e instanceof Error?e.message:'Não foi possível verificar a conexão.')}}
  finally{if(current===sequence.current){inFlight.current=false;setBusy(false)}}
 }
 return <section className="panel whatsapp-connection"><h2>Conectar seu WhatsApp</h2><p>Conecte ou reconecte o WhatsApp usado nas suas campanhas.</p>{!instances.length?<p>Nenhuma instância de WhatsApp cadastrada para sua organização.</p>:<><label>Instância<select value={id} onChange={e=>setSelected(e.target.value)}>{instances.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}</select></label><div className="toolbar"><strong role="status">{error?'Conexão sem verificação':connection?labels[connection.status]:'Verificando conexão…'}</strong>{connection?.phone&&<span>+{connection.phone}</span>}</div>{error&&<p className="alert" role="alert">{error}</p>}{connection?.status==='connected'?<p className="notice">WhatsApp conectado com sucesso.</p>:<><p>No celular, abra o WhatsApp → Aparelhos conectados → Conectar um aparelho e escaneie o QR Code.</p>{connection?.qrcode?<img className="whatsapp-qr" src={connection.qrcode} alt="QR Code para conectar o WhatsApp" width={280} height={280}/>:connection?.status==='connecting'?<p>Aguardando o QR Code ou a conclusão da conexão. A tela será atualizada automaticamente.</p>:null}</>}<div className="toolbar"><button disabled={busy||!connection||connection.status==='connected'||connection.status==='connecting'} onClick={()=>void request(true)}>{connection?.status==='hibernated'?'Reconectar WhatsApp':'Conectar WhatsApp'}</button><button className="secondary" disabled={busy} onClick={()=>void request(false)}>Verificar conexão</button></div>{connection&&<small>Última verificação: {new Date(connection.checked_at).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'})} · horário de Brasília</small>}{connection&&!connection.monitoringSaved&&<p>O status foi consultado, mas o monitoramento do dashboard não pôde ser atualizado.</p>}{!instances.find(i=>i.id===id)?.enabled&&<p>Esta instância está desabilitada para envios. Conectar o WhatsApp não habilita campanhas automaticamente.</p>}</>}</section>;
}
