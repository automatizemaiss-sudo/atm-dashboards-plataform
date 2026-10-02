import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {PGlite} from '@electric-sql/pglite';
const require=createRequire(import.meta.url);
const validator=require('../integrations/n8n/validate-sheet.cjs');
const syncSource=readFileSync('integrations/n8n/sync-sheet.cjs','utf8');
const moduleObject:{exports:any}={exports:{}};
new Function('module','normalizeRow','booleanValue','birthdayValue',syncSource)(moduleObject,validator.normalizeRow,(value:any)=>value===''||value==null?null:['sim','true'].includes(String(value).toLowerCase()),validator.birthdayValue);
const {HEADERS,parseGrid,guardedWrites}=moduleObject.exports;
const row=['Teste','(83) 99999-1111','Barcelona Home','Corinthians; Barcelona','G','15/04/1990','Sim','Sim','','','','','',''];
test('guarda de planilha detecta edição e mantém IDs ao trocar ordem',()=>{
 const parsed=parseGrid([HEADERS,row]);const id='11111111-1111-1111-1111-111111111111';
 const plan={run_id:id,writes:[{customer_id:id,original_id:null,expected:parsed[0].value,value:parsed[0].value,version:1}],conflicts:[]};
 const write=guardedWrites(plan,[HEADERS,[],row]);assert.equal(write.body.data[0].range,"'Página1'!A3:O3");assert.equal(write.body.data[0].values[0][8],id);
 assert.throws(()=>guardedWrites(plan,[HEADERS,['Outro nome',...row.slice(1)]]));
 assert.throws(()=>parseGrid([HEADERS,row,row]));
});
test('reconciliação idempotente, merges, conflito e retentativa após perda de ACK',async()=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon; create role authenticated; create role service_role; create schema auth; create table auth.users(id uuid primary key,email text); create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; create schema storage; create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]); create table storage.objects(id uuid,bucket_id text,name text); alter table storage.objects enable row level security; create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const file of ['001_initial.sql','002_campaign_functions.sql','003_sheet_sync.sql','004_customer_tools.sql','005_campaign_worker.sql','006_archive_customers.sql'])await db.exec(readFileSync('supabase/migrations/'+file,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 async function begin(){return (await db.query<{result:{run_id:string}}>('select sheet_sync_begin() result')).rows[0].result.run_id}
 async function plan(token:string,rows:any[]){return (await db.query<{result:any}>('select sheet_sync_plan($1,$2::jsonb) result',[token,JSON.stringify(rows)])).rows[0].result}
 async function ack(token:string){await db.query('select sheet_sync_ack($1)',[token])}
 let incoming=parseGrid([HEADERS,row]).map(({cells,row_number,...r}:any)=>r);
 let token=await begin();await assert.rejects(begin());let p=await plan(token,incoming);const id=p.writes[0].customer_id;assert.equal(p.conflicts.length,0);assert.equal(p.writes[0].value.teams.length,2);await ack(token);
 assert.equal(Number((await db.query<{n:number}>('select count(*) n from customers')).rows[0].n),1);
 assert.equal(Number((await db.query<{n:number}>('select count(*) n from integration_jobs')).rows[0].n),0);
 const savedValue=p.writes[0].value;
 incoming=[{customer_id:id,value:savedValue}];token=await begin();p=await plan(token,incoming);await ack(token);
 const oldVersion=Number((await db.query<{version:number}>('select version from customers where id=$1',[id])).rows[0].version);
 token=await begin();p=await plan(token,incoming);await ack(token);assert.equal(Number((await db.query<{version:number}>('select version from customers where id=$1',[id])).rows[0].version),oldVersion);
 await db.query("update customers set size='M',last_update_source='dashboard' where id=$1",[id]);
 incoming=[{customer_id:id,value:{...savedValue,name:'Novo nome'}}];token=await begin();p=await plan(token,incoming);assert.equal(p.writes[0].value.size,'M');assert.equal(p.writes[0].value.name,'Novo nome');await ack(token);
 const baseline=p.writes[0].value;await db.query("update customers set size='P' where id=$1",[id]);
 token=await begin();p=await plan(token,[{customer_id:id,value:{...baseline,size:'GG'}}]);assert.equal(p.conflicts.length,1);assert.equal(p.writes.length,0);await ack(token);
 assert.equal((await db.query<{size:string}>('select size from customers where id=$1',[id])).rows[0].size,'P');
 // Resolve by making both sides agree. No manual deletion of state needed.
 token=await begin();p=await plan(token,[{customer_id:id,value:{...baseline,size:'P'}}]);assert.equal(p.conflicts.length,0);await ack(token);
 // Changed phone preserves the customer ID.
 token=await begin();p=await plan(token,[{customer_id:id,value:{...p.writes[0].value,phone:'+5583999992222'}}]);await ack(token);assert.equal(p.writes[0].customer_id,id);
 token=await begin();p=await plan(token,[]);assert.equal(p.conflicts.length,1);assert.equal(p.writes.length,0);await ack(token);
 // Retry an imported but unacknowledged row: one customer remains per phone.
 const second={...savedValue,name:'Segundo',phone:'+5583999993333'};
 token=await begin();p=await plan(token,[{customer_id:null,value:second}]);
 await db.query("update sheet_sync_runs set expires_at=now()-interval '1 second' where id=$1",[token]);
 token=await begin();p=await plan(token,[{customer_id:null,value:second}]);await ack(token);
 assert.equal(Number((await db.query<{n:number}>('select count(*) n from customers where phone=$1',[second.phone])).rows[0].n),1);

 // Customer tools run with the owner's permissions and optimistic version.
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@example.test'); insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations where slug='futpb'; grant usage on schema public,auth to authenticated; grant select,insert,update,delete on all tables in schema public to authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111'; set role authenticated");
 const full=(await db.query<{v:any}>('select sync_customer_value($1) v',[id])).rows[0].v;
 const version=Number((await db.query<{v:number}>('select version v from customers where id=$1',[id])).rows[0].v);
 await db.query('select save_customer($1,$2,$3,$4,$5)',[org,id,version,JSON.stringify(full),JSON.stringify(['Milan','Barcelona'])]);
 await assert.rejects(db.query('select save_customer($1,$2,$3,$4,$5)',[org,id,version,JSON.stringify(full),'[]']));
 const updatedVersion=Number((await db.query<{v:number}>('select version v from customers where id=$1',[id])).rows[0].v);
 await db.query('select set_customer_archived($1,true,$2)',[id,updatedVersion]);
 const active=(await db.query<{r:any}>('select list_customers($1) r',[org])).rows[0].r;
 assert.equal(Number(active.total),1);assert.equal((await db.query<{r:any}>('select list_archived_customers($1) r',[org])).rows[0].r.rows.length,1);
 const segment=(await db.query<{id:string}>("insert into segments(organization_id,name) values($1,'Todos ativos') returning id",[org])).rows[0].id;
 await db.exec('reset role');await db.query('update whatsapp_instances set enabled=true where organization_id=$1',[org]);
 const instance=(await db.query<{id:string}>('select id from whatsapp_instances where organization_id=$1',[org])).rows[0].id;
 const campaign=(await db.query<{id:string}>(`select create_campaign($1,'Campanha',$2,$3,'[{"kind":"text","body":"Olá {{nome}}"}]') id`,[org,segment,instance])).rows[0].id;
 assert.equal((await db.query('select * from campaign_recipients where campaign_id=$1',[campaign])).rows.length,1);
 const task=(await db.query<{r:any}>('select claim_whatsapp_dispatch() r')).rows[0].r;assert.equal(task.available,true);
 assert.equal((await db.query<{r:any}>('select claim_whatsapp_dispatch() r')).rows[0].r.available,false);
 assert.equal((await db.query<{r:any}>('select authorize_whatsapp_dispatch($1) r',[task.dispatch_id])).rows[0].r.allowed,true);
 await assert.rejects(db.query('select authorize_whatsapp_dispatch($1)',[task.dispatch_id]));
 await db.query('select finish_whatsapp_dispatch($1,$2)',[task.dispatch_id,JSON.stringify({messageid:'MSG1',id:'internal1',status:'Sent'})]);
 await db.query("insert into whatsapp_webhook_keys values($1,encode(sha256(convert_to('test-token','UTF8')),'hex'))",[instance]);
 const event={token:'test-token',EventType:'messages_update',state:'Read',event:{MessageIDs:['MSG1'],Timestamp:Math.floor(Date.now()/1000),IsFromMe:true,IsGroup:false}};
 assert.equal((await db.query<{r:any}>('select ingest_uazapi_webhook($1) r',[JSON.stringify(event)])).rows[0].r.status,'stored');
 assert.equal((await db.query<{r:any}>('select ingest_uazapi_webhook($1) r',[JSON.stringify(event)])).rows[0].r.status,'duplicate');
 assert.ok((await db.query<{read_at:string}>('select read_at from campaign_recipients where campaign_id=$1',[campaign])).rows[0].read_at);
 await assert.rejects(db.query('select ingest_uazapi_webhook($1)',[JSON.stringify({...event,token:'wrong'})]));
 assert.equal((await db.query<{payload:any}>("select payload from integration_events where provider='uazapi'")).rows[0].payload.token,undefined);
 await db.exec("set request.jwt.claim.sub=''");
 await db.exec('grant usage on schema public to authenticated; set role authenticated');await assert.rejects(db.query('select sheet_sync_begin()'));
 }finally{await db.close()}
});


test('workflow tem conexões válidas, código compilável e não contém credenciais',()=>{
 const workflow=JSON.parse(readFileSync('integrations/n8n/02-sincronizacao-bidirecional.json','utf8'));
 const names=new Set(workflow.nodes.map((n:any)=>n.name));
 for(const [name,connection] of Object.entries(workflow.connections) as any){assert.ok(names.has(name));for(const branch of connection.main)for(const edge of branch??[])assert.ok(names.has(edge.node));}
 for(const node of workflow.nodes){assert.equal(node.credentials,undefined);if(node.type==='n8n-nodes-base.code')assert.doesNotThrow(()=>new Function('$input','$',node.parameters.jsCode));}
 assert.equal(workflow.active,false);assert.equal(workflow.settings.executionTimeout,120);
});

 test('aceita cabeçalhos atuais e anteriores sem mudar o mapeamento',()=>{
 const old=[...HEADERS];old[2]='Camisa Preferida';old[5]='Data';
 assert.deepEqual(parseGrid([old,row])[0].value,parseGrid([HEADERS,row])[0].value);
 const invalid=[...HEADERS];invalid[0]='Outro';assert.throws(()=>parseGrid([invalid,row]));
 });

test('fluxos de campanhas ficam desativados e bloqueiam envio sem configuração',()=>{
 for(const file of ['03-processar-campanhas.json','04-retornos-uazapi.json']){
  const flow=JSON.parse(readFileSync('integrations/n8n/'+file,'utf8'));assert.equal(flow.active,false);
  const names=new Set(flow.nodes.map((n:any)=>n.name));
  for(const connection of Object.values(flow.connections) as any[])for(const branch of connection.main)for(const edge of branch??[])assert.ok(names.has(edge.node));
  for(const node of flow.nodes){assert.equal(node.credentials,undefined);if(node.type==='n8n-nodes-base.code')assert.doesNotThrow(()=>new Function('$input','$',node.parameters.jsCode));}
  if(file.startsWith('03')){const guard=flow.nodes.find((n:any)=>n.name.startsWith('Configuração'));assert.throws(()=>new Function(guard.parameters.jsCode)(),/Envios desativados/);}
 }
});
