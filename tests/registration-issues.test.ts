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
 const issues=[164,220].map(row_number=>({row_number,field:'Última Compra',value:'2099-12-06',contact_name:'Teste',message:'Data futura'}));
 const report=await rpc('select sheet_sync_report_validation($1,$2::jsonb)',[run.run_id,JSON.stringify(issues)]);assert.equal(report.valid,false);
 assert.equal((await db.query('select * from registration_issues where resolved_at is null')).rows.length,2);
 const sheetIssue=(await db.query<{id:string}>('select id from registration_issues limit 1')).rows[0].id;
 await assert.rejects(db.query('select resolve_registration_issue($1)',[sheetIssue]),/Corrija na planilha/);
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
