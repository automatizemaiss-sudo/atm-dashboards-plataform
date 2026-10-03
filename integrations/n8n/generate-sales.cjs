const fs=require('node:fs');
const validation=fs.readFileSync('integrations/n8n/validate-sheet.cjs','utf8').replace(/module.exports=.*;/,'');
const sync=fs.readFileSync('integrations/n8n/sync-sales.cjs','utf8').replace(/module.exports=.*;/,'');
const shared=validation+'\n'+sync+'\n';
const sheet='1ugjC_pxX2MqC5_5e_gBOTagv_kN-3ZuN2tffQ8Mb3CI';
const base='https://wlhugaduwhevmoymyhad.supabase.co/rest/v1/rpc/';
const readUrl=`https://sheets.googleapis.com/v4/spreadsheets/${sheet}/values/`+encodeURIComponent("'Vendas'!A1:L10001")+'?valueRenderOption=FORMATTED_VALUE';
const nodes=[],connections={};
function add(name,type,parameters,x,version=1){nodes.push({id:name,name,type:'n8n-nodes-base.'+type,typeVersion:version,parameters,position:[x,0]});return name;}
function connect(a,b,branch=0){connections[a]??={main:[]};connections[a].main[branch]??=[];connections[a].main[branch].push({node:b,type:'main',index:0});}
function http(name,url,auth,body,x){return add(name,'httpRequest',{method:body?'POST':'GET',url,authentication:'predefinedCredentialType',nodeCredentialType:auth,...(body?{sendBody:true,specifyBody:'json',jsonBody:body}:{}),options:{timeout:30000}},x,4.2);}
add('Teste manual','manualTrigger',{},0);add('A cada minuto','scheduleTrigger',{rule:{interval:[{field:'minutes',minutesInterval:1}]}},0,1.2);
http('Reservar sincronização',base+'sales_sync_begin','supabaseApi','{}',220);
http('Ler planilha',readUrl,'googleSheetsOAuth2Api',null,440);
add('Validar leitura','code',{jsCode:shared+"return [{json:{run_id:$('Reservar sincronização').first().json.run_id,rows:parseGrid($input.first().json.values)}}];"},660,2);
http('Reconciliar no Supabase',base+'sales_sync_plan','supabaseApi',"={{ JSON.stringify({run_id:$json.run_id,rows:$json.rows.map(({cells,row_number,...r})=>r)}) }}",880);
http('Reler antes de gravar',readUrl,'googleSheetsOAuth2Api',null,1100);
add('Conferir alterações concorrentes','code',{jsCode:shared+"return [{json:guardedWrites($('Reconciliar no Supabase').first().json,$input.first().json.values)}];"},1320,2);
http('Validar reserva antes da escrita',base+'sales_sync_validate','supabaseApi',"={{ JSON.stringify({run_id:$('Conferir alterações concorrentes').first().json.run_id}) }}",1430);
add('Há gravações?','if',{conditions:{options:{caseSensitive:true,leftValue:'',typeValidation:'strict',version:2},conditions:[{id:'writes',leftValue:"={{ $('Conferir alterações concorrentes').first().json.has_writes }}",rightValue:true,operator:{type:'boolean',operation:'true',singleValue:true}}],combinator:'and'},options:{}},1540,2.2);
http('Atualizar planilha',`https://sheets.googleapis.com/v4/spreadsheets/${sheet}/values:batchUpdate`,'googleSheetsOAuth2Api',"={{ JSON.stringify($('Conferir alterações concorrentes').first().json.body) }}",1760);
http('Confirmar sincronização',base+'sales_sync_ack','supabaseApi',"={{ JSON.stringify({run_id:$('Conferir alterações concorrentes').first().json.run_id}) }}",1980);
connect('Teste manual','Reservar sincronização');connect('A cada minuto','Reservar sincronização');
for(const [a,b] of [['Reservar sincronização','Ler planilha'],['Ler planilha','Validar leitura'],['Validar leitura','Reconciliar no Supabase'],['Reconciliar no Supabase','Reler antes de gravar'],['Reler antes de gravar','Conferir alterações concorrentes'],['Conferir alterações concorrentes','Validar reserva antes da escrita'],['Validar reserva antes da escrita','Há gravações?'],['Há gravações?','Atualizar planilha'],['Atualizar planilha','Confirmar sincronização']])connect(a,b);
connect('Há gravações?','Confirmar sincronização',1);
fs.writeFileSync('integrations/n8n/05-sincronizacao-vendas.json',JSON.stringify({name:'FUTPB — Vendas Sheets ↔ Supabase',nodes,connections,settings:{executionOrder:'v1',timezone:'America/Sao_Paulo',executionTimeout:120},active:false},null,2)+'\n');
