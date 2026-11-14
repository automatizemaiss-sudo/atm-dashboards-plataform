import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
import {parseCSV,prepareContacts} from '../lib/contact-import.ts';
test('CSV: aspas, BOM, multiline, duplicados e erros',()=>{
 const rows=parseCSV('\uFEFFNome,Telefone,Labels\r\n"Maria, Silva",11999999999,"Quente; Cliente"\r\nMaria,5511999999999,Retorno\r\nInválido,123,Quente');
 const r=prepareContacts(rows.slice(1),0,1,2,'',{'Quente':'Interessados','Cliente':'Clientes','Retorno':'Interessados'});
 assert.equal(r.contacts.length,1);assert.equal(r.contacts[0].name,'Maria, Silva');assert.deepEqual(r.contacts[0].tags,['Interessados','Clientes']);assert.equal(r.duplicates,1);assert.equal(r.errors.length,1);
 assert.equal(parseCSV('Nome;Telefone;Etiquetas\n"Maria\nSilva";11999999999;Quente')[1][0],'Maria\nSilva');
 assert.throws(()=>parseCSV('Nome,Telefone\n"Maria,123'),/aspas/);
});
test('importação: prévia sem escrita, aprovação atômica, públicos, preservação e isolamento',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 const contacts=JSON.stringify([{name:'Maria',phone:'+5511999999999',tags:['Interessados','Clientes']}]);
 const rpc=(data=contacts,approve=true,o=org)=>db.query('select import_contacts($1,$2::jsonb,$3)',[o,data,approve]);
 await rpc(contacts,false);assert.equal((await db.query('select * from customers')).rows.length,0);assert.equal((await db.query('select * from segments')).rows.length,0);
 await rpc();await rpc();assert.equal((await db.query('select * from customers')).rows.length,1);assert.equal((await db.query('select * from segments')).rows.length,2);
 assert.equal(Number((await db.query<{n:number}>("select segment_count(id) n from segments where name='Interessados'")).rows[0].n),1);
 await db.exec("update customers set can_receive_campaigns=false,size='G'");
 await rpc(JSON.stringify([{name:'Outro nome',phone:'+5511999999999',tags:['Retorno']}]));
 const c=(await db.query<{name:string;size:string;can_receive_campaigns:boolean;segment_tags:string[]}>('select * from customers')).rows[0];assert.equal(c.name,'Maria');assert.equal(c.size,'G');assert.equal(c.can_receive_campaigns,false);assert.equal(c.segment_tags.length,3);
 await assert.rejects(rpc(JSON.stringify([{name:'Nova',phone:'+5511888888888',tags:[]},{name:'Inválido',phone:'1',tags:[]}])));assert.equal((await db.query('select * from customers')).rows.length,1);
 await db.exec("update customers set archived_at=now()");await rpc(JSON.stringify([{name:'Maria',phone:'+5511999999999',tags:['Ignorar']}]));assert.equal((await db.query("select * from segments where name='Ignorar'")).rows.length,0);
 await assert.rejects(rpc(contacts,true,'22222222-2222-2222-2222-222222222222'),/Acesso negado/);
 assert.ok((await db.query('select * from integration_jobs')).rows.length>0);
 }finally{await db.close();}
});
