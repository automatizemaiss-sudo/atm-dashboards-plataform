import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {PGlite} from '@electric-sql/pglite';
const require=createRequire(import.meta.url);
const validation=readFileSync('integrations/n8n/validate-sheet.cjs','utf8').replace(/module.exports=.*;/,'');
const source=readFileSync('integrations/n8n/sync-sales.cjs','utf8');
const {HEADERS,parseGrid,guardedWrites}=new Function(validation+'\n'+source.replace(/module.exports=.*;/,'')+'\nreturn {HEADERS,parseGrid,guardedWrites};')();
const cid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',sid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
test('vendas: valida referência, ID, datas e escrita concorrente',()=>{
 const row=['','pedido-1',cid,'','','','','10,50','01/10/2026','','Não',''];
 const parsed=parseGrid([HEADERS,row]);assert.equal(parsed[0].value.amount,10.5);
 assert.throws(()=>parseGrid([HEADERS,row,row]),/duplicada/);
 assert.throws(()=>parseGrid([HEADERS,[...row.slice(0,2),'bad',...row.slice(3)]]),/ID inválido/);
 const plan={run_id:sid,writes:[{sale_id:sid,expected:parsed[0].value,value:parsed[0].value,version:1}],conflicts:[]};
 assert.equal(guardedWrites(plan,[HEADERS,[],row]).body.data[0].range,"'Vendas'!A3:L3");
 assert.throws(()=>guardedWrites(plan,[HEADERS,[...row.slice(0,7),'20',...row.slice(8)]]),/alterada/);
});
test('vendas: autorização, versão, importação idempotente, merges e cancelamento',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of ['001_initial','002_campaign_functions','003_sheet_sync','004_customer_tools','005_campaign_worker','006_archive_customers','007_contact_interests','008_feminine_team_search','009_manual_sales','010_public_registration'])await db.exec(readFileSync(`supabase/migrations/${f}.sql`,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.query('insert into customers(id,organization_id,name,phone) values($1,$2,$3,$4)',[cid,org,'Dono','+5542999883017']);
 const campaign=(await db.query<{id:string}>('insert into campaigns(organization_id,name) values($1,$2) returning id',[org,'Teste'])).rows[0].id;
 const owner='11111111-1111-1111-1111-111111111111';await db.query('insert into auth.users values($1,$2)',[owner,'owner@example.test']);await db.query('insert into organization_users values($1,$2)',[org,owner]);
 await db.exec(`grant usage on schema public,auth to authenticated;grant select,insert,update,delete on all tables in schema public to authenticated;set request.jwt.claim.sub='${owner}';set role authenticated;`);
 const data={reference:'pedido-1',customer_id:cid,campaign_id:campaign,amount:50,purchased_on:'2026-10-01',notes:null,voided:false};
 const id=(await db.query<{id:string}>('select save_sale($1,null,null,$2::jsonb) id',[org,JSON.stringify(data)])).rows[0].id;
 await assert.rejects(db.query('select save_sale($1,null,null,$2::jsonb)',[org,JSON.stringify(data)]));
 await assert.rejects(db.query('select save_sale($1,$2,99,$3::jsonb)',[org,id,JSON.stringify(data)]));
 await assert.rejects(db.query('select save_sale($1,null,null,$2::jsonb)',[org,JSON.stringify({...data,reference:'future',purchased_on:'2099-01-01'})]));
 await db.exec('reset role');const other=(await db.query<{id:string}>("insert into organizations(slug,display_name) values('other','Other') returning id")).rows[0].id;
 await db.exec('set role authenticated');await assert.rejects(db.query('select list_sales($1)',[other]));await db.exec("reset role;set request.jwt.claim.sub='';");
 async function begin(){return (await db.query<{r:any}>('select sales_sync_begin() r')).rows[0].r.run_id;}
 async function plan(token:string,rows:any[]){return (await db.query<{r:any}>('select sales_sync_plan($1,$2::jsonb) r',[token,JSON.stringify(rows)])).rows[0].r;}
 async function ack(token:string){return db.query('select sales_sync_ack($1)',[token]);}
 let token=await begin();await assert.rejects(begin());let p=await plan(token,[]);assert.equal(p.writes.length,1);assert.equal(p.writes[0].labels.contact_name,'Dono');await ack(token);
 const baseline=p.writes[0].value;
 await db.query('update sales set amount=60 where id=$1',[id]);
 token=await begin();p=await plan(token,[{sale_id:id,value:{...baseline,notes:'Via WhatsApp'}}]);assert.equal(p.conflicts.length,0);assert.equal(p.writes[0].value.amount,60);await ack(token);
 const merged=p.writes[0].value;await db.query('update sales set amount=70 where id=$1',[id]);
 token=await begin();p=await plan(token,[{sale_id:id,value:{...merged,amount:80}}]);assert.equal(p.conflicts.length,1);assert.equal(p.writes.length,0);await ack(token);
 const newData={...data,reference:'pedido-2'};token=await begin();p=await plan(token,[{sale_id:null,value:newData}]);const secondId=p.writes[0].sale_id;
 await db.query("update sales_sync_runs set expires_at=now()-interval '1 second' where id=$1",[token]);token=await begin();p=await plan(token,[{sale_id:null,value:newData}]);assert.equal(p.writes[0].sale_id,secondId);await ack(token);
 assert.equal((await db.query<{n:number}>('select count(*) n from sales where reference=$1',['pedido-2'])).rows[0].n,1);
 // The public endpoint only invokes this service-only RPC; existing profiles stay unchanged.
 const form={submission_id:'22222222-2222-2222-2222-222222222222',name:'Novo contato',phone:'+5542999883018',desired_shirt:'Barcelona',teams:['Barcelona'],size:'M',birthday:'1995-01-01',has_purchased:false,has_referrals:null,can_receive_campaigns:false};
 await db.query('select submit_registration($1::jsonb,$2)',[JSON.stringify(form),'ip-test']);
 await db.query('select submit_registration($1::jsonb,$2)',[JSON.stringify(form),'ip-test']);
 assert.equal((await db.query<{n:number}>("select count(*) n from customers where phone=$1",[form.phone])).rows[0].n,1);
 assert.equal((await db.query<{allowed:boolean}>("select can_receive_campaigns allowed from customers where phone=$1",[form.phone])).rows[0].allowed,false);
 const repeated={...form,submission_id:'33333333-3333-3333-3333-333333333333',name:'Tentativa de alterar',phone:'+5542999883017',can_receive_campaigns:true};
 await db.query('select submit_registration($1::jsonb,$2)',[JSON.stringify(repeated),'ip-test']);
 assert.equal((await db.query<{name:string}>('select name from customers where id=$1',[cid])).rows[0].name,'Dono');
 assert.equal((await db.query<{status:string}>('select status from registration_submissions where id=$1',[repeated.submission_id])).rows[0].status,'review');
 await db.exec('set role anon');await assert.rejects(db.query('select submit_registration($1::jsonb,$2)',[JSON.stringify(form),'ip-test']));await db.exec('reset role');
 const v=(await db.query<{version:number}>('select version from sales where id=$1',[id])).rows[0].version;
 await db.exec(`set request.jwt.claim.sub='${owner}';set role authenticated;`);await db.query('select save_sale($1,$2,$3,$4::jsonb)',[org,id,v,JSON.stringify({...data,voided:true})]);
 const list=(await db.query<{r:any}>('select list_sales($1,0,$2) r',[org,campaign])).rows[0].r;assert.equal(list.total,2);assert.equal(list.rows.find((r:any)=>r.id===id).voided,true);
 }finally{await db.close()}
});
test('workflow de vendas fica inativo e tem código e conexões válidos',()=>{
 const flow=JSON.parse(readFileSync('integrations/n8n/05-sincronizacao-vendas.json','utf8'));assert.equal(flow.active,false);const names=new Set(flow.nodes.map((n:any)=>n.name));
 for(const node of flow.nodes){if(node.type==='n8n-nodes-base.code')new Function(node.parameters.jsCode);}
 for(const paths of Object.values(flow.connections) as any[])for(const branch of paths.main)for(const target of branch??[])assert.ok(names.has(target.node));
});
