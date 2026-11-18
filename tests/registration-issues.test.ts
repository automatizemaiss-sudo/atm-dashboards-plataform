import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {validateContactDates} from '../lib/contact-validation.ts';
test('cadastro bloqueia datas inválidas e futuras antes de salvar',()=>{
 for(const birthday of ['2026-02-30','0026-10-21','2026-12-06'])assert.throws(()=>validateContactDates({birthday},'2026-11-14'));
 assert.throws(()=>validateContactDates({last_purchase_at:'2026-12-06'},'2026-11-14'),/Última compra/);
 assert.doesNotThrow(()=>validateContactDates({birthday:'1990-04-15',last_purchase_at:'2026-11-14'},'2026-11-14'));
});
test('pendências: lease, relatório completo, encaminhamento, isolamento e envio sem repetição',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 await assert.rejects(db.query("insert into customers(organization_id,name,phone,last_purchase_at) values($1,'Inválido','+5583999991234',current_date+10)",[org]),/Última Compra/);
 async function rpc(query:string,args:any[]=[]){return(await db.query<{r:any}>(query+' r',args)).rows[0].r;}
 let run=await rpc('select sheet_sync_begin()');
 const cells=Array.from({length:16},(_,index)=>index===13?'2099-12-06':'');
 const issues=[164,220].map(row_number=>({row_number,cells,field:'Última Compra',value:'2099-12-06',contact_name:'Teste',message:'Data futura'}));
 const report=await rpc('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,JSON.stringify(issues)]);assert.equal(report.valid,false);assert.equal(report.can_sync,true);
 assert.equal((await db.query('select * from registration_issues where resolved_at is null')).rows.length,2);
 const sheetIssue=(await db.query<{id:string}>('select id from registration_issues limit 1')).rows[0].id;
 await assert.rejects(db.query('select resolve_registration_issue($1)',[sheetIssue]),/Corrija na planilha/);
 await rpc("select sheet_sync_plan($1,'[]')",[run.run_id]);await rpc('select sheet_sync_ack($1)',[run.run_id]);
 const expected=JSON.stringify(cells);
 await db.exec('set role authenticated');
 await assert.rejects(db.query("select request_sheet_repair($1,'[]','{\"13\":\"2020-01-01\"}')",[sheetIssue]),/linha mudou/);
 await assert.rejects(db.query("select request_sheet_repair($1,$2,'{}',true)",[sheetIssue,expected]),/identificada como duplicada/);
 await db.query("select request_sheet_repair($1,$2,$3)",[sheetIssue,expected,JSON.stringify({13:'2020-01-01'})]);
 await assert.rejects(db.query("select request_sheet_repair($1,$2,$3)",[sheetIssue,expected,JSON.stringify({13:'2019-01-01'})]),/aguardando sincronização/);
 await assert.rejects(db.query('select sheet_sync_pending_repairs($1)',[run.run_id]),/permission denied/);
 await db.exec('reset role');
 run=await rpc('select sheet_sync_begin()');
 await db.exec('set role service_role');
 await rpc('select sheet_sync_validate_repair($1)',[run.run_id]);
 const pendingRepairs=await rpc('select sheet_sync_pending_repairs($1)',[run.run_id]);
 assert.equal(pendingRepairs.repairs[0].issue_id,sheetIssue);
 assert.deepEqual(pendingRepairs.repairs[0].changes,{13:'2020-01-01'});
 await rpc('select sheet_sync_finish_repairs($1,$2)',[run.run_id,JSON.stringify([{issue_id:sheetIssue,status:'applied'}])]);
 assert.deepEqual(await rpc('select sheet_sync_pending_repairs($1)',[run.run_id]),{repairs:[]});
 await db.exec('reset role');
 const fatal=await rpc('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,JSON.stringify([{row_number:1,field:'Estrutura da planilha',message:'Cabeçalhos inválidos'}])]);
 assert.equal(fatal.can_sync,false);assert.equal((await db.query('select * from registration_issues where resolved_at is null')).rows.length,3);
 run=await rpc('select sheet_sync_begin()');await rpc("select sheet_sync_report_validation($1,'[]')",[run.run_id]);
 assert.equal((await db.query('select * from registration_issues where resolved_at is null')).rows.length,0);
 await assert.rejects(db.query('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,'null']),/Relatório inválido/);
 const cid=(await db.query<{id:string}>("insert into customers(organization_id,name,phone) values($1,'Contato','+5583999991234') returning id",[org])).rows[0].id;
 const instance=(await db.query<{id:string}>('update whatsapp_instances set enabled=true where organization_id=$1 returning id',[org])).rows[0].id;
 const segment=(await db.query<{id:string}>("insert into segments(organization_id,name) values($1,'Todos') returning id",[org])).rows[0].id;
 const campaign=await rpc(`select create_campaign_with_delay($1,'Teste',$2,$3,'[{"kind":"text","body":"Olá"}]',null,1,1)`,[org,segment,instance]);
 await db.query(`update campaign_recipients set snapshot=jsonb_set(snapshot,'{last_purchase_at}','"2099-12-06"') where campaign_id=$1`,[campaign]);
 const dispatch=await rpc('select claim_whatsapp_dispatch()');assert.equal(dispatch.available,true);
 assert.equal((await rpc('select authorize_whatsapp_dispatch($1)',[dispatch.dispatch_id])).allowed,false);
 let issue=(await db.query<any>("select * from registration_issues where source='campaign'")).rows[0];assert.equal(issue.queued,false);assert.equal(issue.customer_id,cid);
 assert.equal((await rpc('select claim_whatsapp_dispatch()')).available,false);
 await db.query('select queue_registration_issue($1)',[issue.id]);
 issue=(await db.query<any>('select * from registration_issues where id=$1',[issue.id])).rows[0];assert.equal(issue.queued,true);
 await db.query('select resolve_registration_issue($1)',[issue.id]);
 assert.equal((await rpc('select claim_whatsapp_dispatch()')).available,false);
 assert.equal((await db.query<any>('select status from whatsapp_dispatches where id=$1',[dispatch.dispatch_id])).rows[0].status,'skipped');
 // Manual classification of a provider error never authorizes/repeats an uncertain send.
 await db.query("update whatsapp_dispatches set status='unknown' where id=$1",[dispatch.dispatch_id]);
 await db.query("update campaign_recipients set error='Resultado incerto; revisar antes de reenviar' where id=$1",[issue.recipient_id]);
 await db.query('select report_campaign_registration_issue($1)',[issue.recipient_id]);
 assert.equal((await db.query<any>('select status from whatsapp_dispatches where id=$1',[dispatch.dispatch_id])).rows[0].status,'unknown');
 await db.exec("set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';set role authenticated;");
 await assert.rejects(db.query('select queue_registration_issue($1)',[issue.id]),/acesso negado/i);
 await assert.rejects(db.query('select report_campaign_registration_issue($1)',[issue.recipient_id]),/Acesso negado/);
 assert.equal((await db.query('select * from registration_issues')).rows.length,0);
 await assert.rejects(db.query("select sheet_sync_report_validation($1,'[]')",[run.run_id]),/permission denied/);
 }finally{await db.close()}
});

test('sincronização parcial mantém baseline inválido, evita duplicata e envia somente aos válidos',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 async function rpc(query:string,args:any[]=[]){return(await db.query<{r:any}>(query+' r',args)).rows[0].r;}
 const contacts=(await db.query<any>("insert into customers(organization_id,name,phone) values($1,'Válido','+5583999991234'),($1,'Inválido na planilha','+5583999992222') returning id,phone",[org])).rows;
 for(const c of contacts)await db.query('insert into sheet_sync_state(organization_id,customer_id,base) values($1,$2,sync_customer_value($2))',[org,c.id]);
 const good=contacts.find(c=>c.phone.endsWith('1234')),bad=contacts.find(c=>c.phone.endsWith('2222'));
 const value=await rpc('select sync_customer_value($1)',[good.id]);
 const badBase=await rpc('select sync_customer_value($1)',[bad.id]);
 let run=await rpc('select sheet_sync_begin()');
 const report=await rpc('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,JSON.stringify([{row_number:3,customer_id:bad.id,phone:bad.phone,contact_name:'Inválido na planilha',field:'Última Compra',value:'2099-12-06',message:'Data futura'}])]);assert.equal(report.can_sync,true);
 const rows=[{customer_id:good.id,row_number:2,value:{...value,name:'Válido atualizado'}},{customer_id:null,row_number:4,value:{...value,name:'Novo válido',phone:'+5583999993333'}},{customer_id:null,row_number:5,value:{...value,name:'Falha no banco',phone:'+5583999994444',birthday:'2099-01-01'}}];
 let plan=await rpc('select sheet_sync_plan($1,$2::jsonb)',[run.run_id,JSON.stringify(rows)]);
 assert.equal(plan.writes.length,2);assert.equal(plan.conflicts.length,0);assert.equal(plan.skipped,2);
 assert.equal(plan.writes.some((w:any)=>w.customer_id===bad.id),false);
 assert.equal((await db.query("select * from customers where phone='+5583999994444'")).rows.length,0,'falha por linha deve reverter inclusive o insert inicial');
 assert.equal((await db.query('select * from customers')).rows.length,3);
 const ack=await rpc('select sheet_sync_ack($1)',[run.run_id]);assert.equal(ack.status,'done');assert.equal(ack.synced,2);assert.equal(ack.skipped,2);
 assert.deepEqual((await db.query<any>('select base from sheet_sync_state where customer_id=$1',[bad.id])).rows[0].base,badBase);
 assert.equal((await db.query('select * from sheet_sync_conflicts where customer_id=$1',[bad.id])).rows.length,0);
 // A new run with the same invalid row must not append/export it or duplicate new contacts.
 run=await rpc('select sheet_sync_begin()');await rpc('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,JSON.stringify([{row_number:3,customer_id:bad.id,phone:bad.phone,field:'Última Compra',message:'Data futura'}])]);
 const saved=plan.writes.map((w:any,i:number)=>({customer_id:w.customer_id,row_number:i+2,value:w.value}));
 plan=await rpc('select sheet_sync_plan($1,$2::jsonb)',[run.run_id,JSON.stringify(saved)]);await rpc('select sheet_sync_ack($1)',[run.run_id]);
 assert.equal(plan.writes.length,2);assert.equal((await db.query('select * from customers')).rows.length,3);
 const instance=(await db.query<{id:string}>('update whatsapp_instances set enabled=true where organization_id=$1 returning id',[org])).rows[0].id;
 const segment=(await db.query<{id:string}>("insert into segments(organization_id,name) values($1,'Todos') returning id",[org])).rows[0].id;
 await rpc(`select create_campaign_with_delay($1,'Teste parcial',$2,$3,'[{"kind":"text","body":"Olá"}]',null,1,1)`,[org,segment,instance]);
 let sent=0,blocked=0;
 for(let tick=0;tick<5;tick++){
  const dispatch=await rpc('select claim_whatsapp_dispatch()');if(!dispatch.available)break;
  await db.query("update whatsapp_dispatches set ready_at=clock_timestamp()-interval '1 second' where id=$1",[dispatch.dispatch_id]);
  const permission=await rpc('select authorize_whatsapp_dispatch($1)',[dispatch.dispatch_id]);
  if(permission.allowed){sent++;await rpc('select finish_whatsapp_dispatch($1,$2::jsonb)',[dispatch.dispatch_id,JSON.stringify({messageid:'partial-'+tick,status:'Sent'})]);}
  else {blocked++;assert.equal(dispatch.number,'5583999992222');}
 }
 assert.equal(sent,2);assert.equal(blocked,1);
 const pending=(await db.query<any>("select * from registration_issues where source='campaign'")).rows;assert.equal(pending.length,1);assert.equal(pending[0].customer_id,bad.id);
 // Correcting the sheet clears its block without changing the other baselines.
 run=await rpc('select sheet_sync_begin()');await rpc("select sheet_sync_report_validation($1,'[]')",[run.run_id]);
 plan=await rpc('select sheet_sync_plan($1,$2::jsonb)',[run.run_id,JSON.stringify([...saved,{customer_id:bad.id,row_number:5,value:{...badBase,last_purchase_at:'2020-10-21'}}])]);
 assert.equal(plan.writes.length,3);await rpc('select sheet_sync_ack($1)',[run.run_id]);
 assert.equal((await db.query("select * from registration_issues where source='sheet' and resolved_at is null")).rows.length,0);
 assert.equal((await db.query('select * from customers')).rows.length,3);
 // Two different sheet identities pointing to one customer must both be isolated before updates.
 run=await rpc('select sheet_sync_begin()');await rpc("select sheet_sync_report_validation($1,'[]')",[run.run_id]);
 const aliasRows=plan.writes.map((w:any,i:number)=>({customer_id:w.customer_id,row_number:i+2,value:w.value}));
 const alias=aliasRows.find((r:any)=>r.customer_id===good.id);
 plan=await rpc('select sheet_sync_plan($1,$2::jsonb)',[run.run_id,JSON.stringify([...aliasRows,{...alias,customer_id:null,row_number:20,value:{...alias.value,name:'Não sobrescrever'}}])]);
 assert.equal(plan.writes.some((w:any)=>w.customer_id===good.id),false);
 assert.equal(plan.conflicts.some((c:any)=>c.customer_id===good.id),false);
 assert.equal((await db.query<any>('select name from customers where id=$1',[good.id])).rows[0].name,'Válido atualizado');
 await rpc('select sheet_sync_ack($1)',[run.run_id]);
 // A stale/unknown UUID is isolated, while the other rows still reconcile.
 run=await rpc('select sheet_sync_begin()');await rpc("select sheet_sync_report_validation($1,'[]')",[run.run_id]);
 const staleRows=aliasRows.map((r:any)=>r.customer_id===good.id?{...r,customer_id:'99999999-9999-9999-9999-999999999999'}:r);
 plan=await rpc('select sheet_sync_plan($1,$2::jsonb)',[run.run_id,JSON.stringify(staleRows)]);
 assert.equal(plan.writes.length,2);assert.equal(plan.conflicts.some((c:any)=>c.customer_id===good.id),false);
 await rpc('select sheet_sync_ack($1)',[run.run_id]);
 // No access to helper RPCs for a dashboard session.
 await db.exec('set role authenticated');await assert.rejects(db.query('select sheet_sync_record_issue($1,$2::jsonb)',[org,'{}']),/permission denied/);
 }finally{await db.close()}
});
