import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('migrations, audit, snapshot, recusas e isolamento de organização',async()=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon; create role authenticated; create schema auth; create table auth.users(id uuid primary key,email text); create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; create schema storage; create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]); create table storage.objects(id uuid,bucket_id text,name text); alter table storage.objects enable row level security; create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const file of ['001_initial.sql','002_campaign_functions.sql'])await db.exec(readFileSync('supabase/migrations/'+file,'utf8').replace('create extension if not exists pgcrypto;',''));
 await db.exec(`insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@example.test'); insert into public.organization_users select id,'11111111-1111-1111-1111-111111111111' from public.organizations; insert into public.organizations(slug,display_name) values('other','Other'); grant usage on schema public,auth to authenticated; grant select,insert,update,delete on all tables in schema public to authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';`);
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.query("update whatsapp_instances set enabled=true where organization_id=$1",[org]);
 const instance=(await db.query<{id:string}>('select id from whatsapp_instances where organization_id=$1',[org])).rows[0].id;
 await db.query("insert into customers(organization_id,name,phone,size,can_receive_campaigns) values($1,'Permitido','+5583999991111','G',null),($1,'Bloqueado','+5583999992222','G',false)",[org]);
 const segment=(await db.query<{id:string}>(`insert into segments(organization_id,name,rules) values($1,'G','{"operator":"and","conditions":[{"field":"size","op":"eq","value":"G"}]}') returning id`,[org])).rows[0].id;
 assert.equal(Number((await db.query<{n:number}>('select count(*) n from customer_events')).rows[0].n),2);
 await db.exec('set role authenticated');
 assert.equal((await db.query('select * from organizations')).rows.length,1);
 await assert.rejects(db.query("insert into customers(organization_id,name,phone) values((select id from organizations where slug='other'),'Intruso','+5583999993333')"));
 assert.equal(Number((await db.query<{n:number}>('select segment_count($1) n',[segment])).rows[0].n),2);
 const campaign=(await db.query<{id:string}>(`select create_campaign($1,'Teste',$2,$3,'[{"kind":"text","body":"Olá {{nome}}"}]',null) id`,[org,segment,instance])).rows[0].id;
 assert.equal((await db.query('select * from campaign_recipients where campaign_id=$1',[campaign])).rows.length,1);
 await assert.rejects(db.query("insert into campaigns(organization_id,name) values($1,'Direta')",[org]));
 assert.equal((await db.query("update customer_events set source='system' returning id")).rows.length,0);
 await db.query("select control_campaign($1,'pause')",[campaign]);
 assert.equal((await db.query<{status:string}>('select status from campaigns where id=$1',[campaign])).rows[0].status,'paused');
 await assert.rejects(db.query("select control_campaign($1,'pause')",[campaign]));
 await db.exec('reset role');
 assert.equal(Number((await db.query<{n:number}>('select count(*) n from integration_jobs')).rows[0].n),4);
 }finally{await db.close()}
});
