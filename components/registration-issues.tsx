'use client';
import {useEffect,useState} from 'react';
import {supabase} from '../lib/supabase';
import type {Customer} from '../lib/domain';
type Issue={id:string;source:'sheet'|'campaign';customer_id:string|null;recipient_id:string|null;row_number:number|null;contact_name:string|null;field:string;value:string|null;message:string;queued:boolean;campaign_recipients:{campaign_id:string}|null};
const sheetUrl='https://docs.google.com/spreadsheets/d/1ugjC_pxX2MqC5_5e_gBOTagv_kN-3ZuN2tffQ8Mb3CI/edit#gid=0';
export default function RegistrationIssues({org,campaign,refreshVersion,onEdit,onOpenPending}:{org:string;campaign?:string;refreshVersion:number;onEdit:(customer:Customer)=>void;onOpenPending?:()=>void}){
 const [issues,setIssues]=useState<Issue[]>([]),[errors,setErrors]=useState<{id:string;error:string;snapshot:{name?:string}}[]>([]),[error,setError]=useState(''),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[revision,setRevision]=useState(0),[page,setPage]=useState(0),[hasNext,setHasNext]=useState(false);
 useEffect(()=>{let active=true;setLoading(true);setError('');async function load(){
  const query=supabase!.from('registration_issues').select('*,campaign_recipients(campaign_id)').eq('organization_id',org).is('resolved_at',null).order('updated_at',{ascending:false});
  if(campaign)query.eq('source','campaign').eq('campaign_recipients.campaign_id',campaign).not('campaign_recipients','is',null);else query.eq('queued',true);
  const [r,e]=await Promise.all([query.range(page*50,page*50+50),campaign?supabase!.from('campaign_recipients').select('id,error,snapshot,registration_issues(id)').eq('organization_id',org).eq('campaign_id',campaign).not('error','is',null).is('registration_issues',null).order('id').range(page*50,page*50+50):Promise.resolve({data:[],error:null})]);
  if(!active)return;
  if(r.error||e.error)setError('Não foi possível carregar as pendências. Confira se a atualização de pendências foi aplicada no Supabase.');
  else{setIssues((r.data??[]).slice(0,50) as Issue[]);setHasNext((r.data??[]).length>50||(e.data??[]).length>50);setErrors((e.data??[]).slice(0,50) as typeof errors);}
  setLoading(false);
 }void load();return()=>{active=false}},[org,campaign,refreshVersion,revision,page]);
 async function action(fn:()=>Promise<void>){setBusy(true);setError('');setNotice('');try{await fn();setRevision(v=>v+1)}catch(e){setError(e instanceof Error?e.message:'Operação não concluída.')}finally{setBusy(false)}}
 const unclassified=errors.filter(e=>!issues.some(i=>i.recipient_id===e.id));
 return <section className="panel"><h2>{campaign?'Erros de cadastro nesta campanha':'Pendências da planilha'}</h2><p>{campaign?'O contato com cadastro inválido fica fora dos próximos envios desta campanha. Encaminhe a pendência para correção.':'Corrija os dados indicados. Erros da planilha são conferidos novamente na próxima sincronização.'}</p>
 {loading&&<p role="status">Carregando pendências…</p>}{error&&<p role="alert" className="alert">{error}</p>}{notice&&<p role="status" className="notice">{notice}</p>}
 {issues.map(issue=><article key={issue.id} className="rule-group"><h3>{issue.contact_name||'Cadastro sem nome'}{issue.row_number?` · linha ${issue.row_number}`:''}</h3><p><strong>{issue.field}</strong>{issue.value?` · Valor informado: ${issue.value}`:''}</p><p role={campaign?'alert':undefined}>{issue.message}</p><div className="toolbar">
 {issue.source==='sheet'?<a href={sheetUrl+`&range=A${issue.row_number??1}:P${issue.row_number??1}`} target="_blank" rel="noreferrer">Corrigir na planilha</a>:<>
 <button className="secondary" disabled={busy} onClick={()=>void action(async()=>{const r=await supabase!.from('customers').select('*,customer_teams(teams(name))').eq('organization_id',org).eq('id',issue.customer_id!).single();if(r.error)throw new Error(r.error.message);onEdit(r.data as Customer)})}>Editar cadastro</button>
 {campaign?(issue.queued?<button className="secondary" onClick={onOpenPending}>Ver nas Pendências da planilha</button>:<button disabled={busy} onClick={()=>void action(async()=>{const r=await supabase!.rpc('queue_registration_issue',{issue:issue.id});if(r.error)throw new Error(r.error.message);setNotice('Contato encaminhado para Pendências da planilha.')})}>Enviar para Pendências da planilha</button>):<button className="secondary" disabled={busy} onClick={()=>void action(async()=>{const r=await supabase!.rpc('resolve_registration_issue',{issue:issue.id});if(r.error)throw new Error(r.error.message);setNotice('Pendência resolvida. O contato não será reenviado automaticamente na campanha original.')})}>Validar correção e resolver</button>}
 </>}</div></article>)}
 {campaign&&unclassified.slice(0,50).map(r=><article className="rule-group" key={r.id}><h3>{r.snapshot.name||'Contato'}</h3><p role="alert">{r.error}</p><p>Se você identificou um erro no cadastro, encaminhe para correção. Resultados incertos de envio continuam exigindo conferência antes de reenviar.</p><button className="secondary" disabled={busy} onClick={()=>void action(async()=>{const result=await supabase!.rpc('report_campaign_registration_issue',{recipient:r.id});if(result.error)throw new Error(result.error.message);setNotice('Erro encaminhado para Pendências da planilha. O estado do envio foi preservado.')})}>É erro de cadastro: enviar para pendências</button></article>)}
 {!loading&&!error&&!issues.length&&!unclassified.length&&<p>Nenhuma pendência de cadastro.</p>}
 {(page>0||hasNext)&&<div className="toolbar"><button className="secondary" disabled={page===0||busy||loading} onClick={()=>setPage(p=>p-1)}>Anterior</button><span>Página {page+1}</span><button className="secondary" disabled={!hasNext||busy||loading} onClick={()=>setPage(p=>p+1)}>Próxima</button></div>}
 </section>;
}
