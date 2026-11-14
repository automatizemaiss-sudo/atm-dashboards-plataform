const fs = require('node:fs');
const group = '120363432266870295@g.us';
const base = 'https://automatizemais.uazapi.com';
const node = (name,type,parameters,x) => ({id:name,name,type:'n8n-nodes-base.'+type,typeVersion:type==='httpRequest'?4.2:type==='code'?2:type==='scheduleTrigger'?1.2:1,parameters,position:[x,0]});
const send = () => ({...node('Enviar alerta ao grupo','httpRequest',{
 method:'POST',url:base+'/send/text',authentication:'genericCredentialType',genericAuthType:'httpHeaderAuth',sendBody:true,specifyBody:'json',jsonBody:'={{ JSON.stringify({number:"'+group+'",text:$json.text,linkPreview:false}) }}',options:{timeout:30000}
},600),notesInFlow:true,notes:'Usar credencial Header Auth exclusiva: Uazapi — Alertas (final 69fb). Header: token. Não selecionar a credencial FUTPB. O valor da credencial deve ser o token da instância remetente solicitada pelo dono.'});
const edge = (a,b) => ({[a]:{main:[[{node:b,type:'main',index:0}]]}});
const settings = {executionOrder:'v1',timezone:'America/Sao_Paulo',saveDataSuccessExecution:'none',saveDataErrorExecution:'all'};
function write(file,name,nodes,connections){fs.writeFileSync('integrations/n8n/'+file,JSON.stringify({name,nodes,connections,active:false,settings},null,2)+'\n');}
write('06-alertas-erros.json','ATM — Alertas de erros no grupo',[
 node('Erro de execução','errorTrigger',{},0),
 node('Preparar alerta','code',{jsCode:`const e=$input.first().json;const failure=e.execution?.error??e.trigger?.error??{};
// Somente resumo operacional: nunca encaminhar o payload, stack, headers ou tokens.
const clean=value=>String(value??'Não informado').replace(/https?:\\/\\/[^\\s]+/g,'[URL omitida]').replace(/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/gi,'[identificador omitido]').replace(/((?:token|authorization|apikey|api_key|password|secret)\\s*[:=]\\s*)[^\\s,;]+/gi,'$1[omitido]').slice(0,500);
const workflowId=String(e.workflow?.id??'');const executionId=String(e.execution?.id??'');
const url=/^[a-zA-Z0-9_-]+$/.test(workflowId)&&/^\\d+$/.test(executionId)?'https://n8n.automatizemais.com/workflow/'+workflowId+'/executions/'+executionId:'';
return [{json:{text:['🚨 Erro na automação','Fluxo: '+clean(e.workflow?.name),'Nó: '+clean(e.execution?.lastNodeExecuted??failure.node?.name),'Erro: '+clean(failure.message??failure.cause?.message),'Horário: '+new Date().toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'}),url,'Confira a execução antes de tentar reenviar mensagens.'].filter(Boolean).join('\\n')}}];`},300),send()
],{...edge('Erro de execução','Preparar alerta'),...edge('Preparar alerta','Enviar alerta ao grupo')});
write('07-monitorar-conexao.json','ATM — Monitorar conexão WhatsApp',[
 node('A cada minuto','scheduleTrigger',{rule:{interval:[{field:'minutes',minutesInterval:1}]}},0),
 node('Consultar instância monitorada','httpRequest',{method:'GET',url:base+'/instance/status',authentication:'genericCredentialType',genericAuthType:'httpHeaderAuth',options:{timeout:15000}},200),
 node('Verificar conexão','code',{jsCode:`const data=$input.first().json;const status=String(data.instance?.status??data.status??'').toLowerCase();
if(!['connected','disconnected','connecting','hibernated'].includes(status))throw new Error('Resposta de status não reconhecida; revisar contrato da Uazapi');
const state=$getWorkflowStaticData('global');
if(status==='connected'){state.lastAlertAt=0;return [];}
if(Date.now()-(state.lastAlertAt??0)<15*60*1000)return [];
return [{json:{text:'⚠️ WhatsApp sem conexão pronta para envio\\nEstado: '+status+'\\nHorário: '+new Date().toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'})+'\\nConfira a instância monitorada no painel Uazapi. Os disparos podem estar interrompidos.'}}];`},400),send(),
 node('Registrar alerta enviado','code',{jsCode:`if(!$input.first().json.messageid || $input.first().json.error)throw new Error('Uazapi não confirmou a aceitação do alerta');const state=$getWorkflowStaticData('global');state.lastAlertAt=Date.now();return $input.all();`},800)
],{...edge('A cada minuto','Consultar instância monitorada'),...edge('Consultar instância monitorada','Verificar conexão'),...edge('Verificar conexão','Enviar alerta ao grupo'),...edge('Enviar alerta ao grupo','Registrar alerta enviado')});
