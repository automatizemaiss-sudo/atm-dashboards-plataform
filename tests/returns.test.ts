import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('retornos: agendamento, contagens, cancelamento, permissões e envio',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");

 const instance=(await db.query<{id:string}>('update whatsapp_instances set enabled=true where organization_id=$1 returning id',[org])).rows[0].id;
 async function save(id:string|null,version:number|null,automatic:boolean,date:string|null){return (await db.query<{id:string}>(`select save_customer($1,$2,$3,$4::jsonb,'[]') id`,[org,id,version,JSON.stringify({name:'Retorno',phone:'+5583999991234',return_date:date,return_automatic:automatic,return_message:'Olá {{nome}}',return_instance_id:instance})])).rows[0].id;}
 async function customer(id:string){return (await db.query<any>('select * from customers where id=$1',[id])).rows[0];}
 const today=(await db.query<{d:string}>("select to_char(now() at time zone 'America/Sao_Paulo','YYYY-MM-DD') d")).rows[0].d;
 const id=await save(null,null,false,today);
 async function list(auto:boolean){return (await db.query<{r:any}>('select customer_returns($1,$2,0) r',[org,auto])).rows[0].r;}
 assert.equal((await list(false)).manual,1);assert.equal((await list(true)).automatic,0);
 let c=await customer(id);await save(id,c.version,true,today);c=await customer(id);
 const first=c.return_campaign_id;assert.ok(first);assert.equal((await list(false)).manual,0);assert.equal((await list(true)).automatic,1);
 assert.equal((await db.query('select * from campaign_recipients where campaign_id=$1',[first])).rows.length,1);
 assert.equal((await list(true)).rows[0].phone,'+5583999991234');
 await save(id,c.version,false,today);c=await customer(id);
 assert.equal((await db.query<{status:string}>('select status from campaigns where id=$1',[first])).rows[0].status,'cancelled');
 assert.equal((await list(false)).manual,1);
 await save(id,c.version,false,null);c=await customer(id);assert.equal((await list(false)).manual,0);
 await assert.rejects(db.query("update customers set return_automatic=true,return_date=current_date,return_message=null where id=$1",[id]));
 await save(id,c.version,true,today);c=await customer(id);
 const dispatch=(await db.query<{r:any}>('select claim_whatsapp_dispatch() r')).rows[0].r;assert.equal(dispatch.available,true);
 await db.query('select authorize_whatsapp_dispatch($1)',[dispatch.dispatch_id]);
 await assert.rejects(save(id,c.version,false,null));
 await db.query(`select finish_whatsapp_dispatch($1,'{"messageid":"return-1","status":"Sent"}')`,[dispatch.dispatch_id]);assert.equal((await list(true)).automatic,0);
 // Updating contact details cannot create another send after provider acceptance.
 await db.query("update customers set name='Novo nome' where id=$1",[id]);assert.equal((await customer(id)).return_campaign_id,c.return_campaign_id);
 await db.exec("set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';");
 assert.equal((await list(false)).manual,0);assert.equal((await list(true)).rows.length,0);
 }finally{await db.close()}
});
