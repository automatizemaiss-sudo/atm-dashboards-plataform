import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('envio incerto gera aviso com limite, confirmação auditada libera sem repetir e respeita organização',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 await db.query("insert into customers(organization_id,name,phone) values($1,'A','+5542999883017'),($1,'B','+5542999883018')",[org]);
 const instance=(await db.query<{id:string}>('update whatsapp_instances set enabled=true where organization_id=$1 returning id',[org])).rows[0].id;
 const segment=(await db.query<{id:string}>("insert into segments(organization_id,name) values($1,'Todos') returning id",[org])).rows[0].id;
 async function rpc(q:string,args:any[]=[]){return(await db.query<{r:any}>(q+' r',args)).rows[0].r;}
 await rpc(`select create_campaign_with_delay($1,'Avisos',$2,$3,'[{"kind":"text","body":"Olá"}]',null,1,1)`,[org,segment,instance]);
 const first=await rpc('select claim_whatsapp_dispatch()');
 let unavailable=await rpc('select claim_whatsapp_dispatch()');assert.equal(unavailable.blocked,false);assert.equal(unavailable.reason,'instance_busy');
 assert.equal((await rpc('select campaign_delivery_alerts($1)',[org])).length,0);
 await db.query("update whatsapp_dispatches set ready_at=now()-interval '3 minutes' where id=$1",[first.dispatch_id]);
 assert.equal((await rpc('select campaign_delivery_alerts($1)',[org]))[0].status,'reserved');
 await rpc('select authorize_whatsapp_dispatch($1)',[first.dispatch_id]);
 await rpc(`select finish_whatsapp_dispatch($1,'{"error":"timeout"}')`,[first.dispatch_id]);
 unavailable=await rpc('select claim_whatsapp_dispatch()');assert.equal(unavailable.available,false);assert.equal(unavailable.blocked,true);assert.equal(unavailable.reason,'uncertain_delivery');assert.equal(unavailable.notify,true);
 const alerts=await rpc('select campaign_delivery_alerts($1)',[org]);assert.equal(alerts.length,1);assert.equal(alerts[0].campaign_name,'Avisos');assert.equal(alerts[0].dispatch_id,first.dispatch_id);
 assert.equal((await rpc('select claim_whatsapp_dispatch()')).notify,false,'alerta não pode disparar a cada cinco segundos');
 await db.exec("set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';set role authenticated;");
 assert.deepEqual(await rpc('select campaign_delivery_alerts($1)',[org]),[]);await assert.rejects(db.query('select confirm_whatsapp_dispatch_sent($1)',[first.dispatch_id]),/Acesso negado/);
 await db.exec("reset role;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 await db.query('select confirm_whatsapp_dispatch_sent($1)',[first.dispatch_id]);await db.query('select confirm_whatsapp_dispatch_sent($1)',[first.dispatch_id]);
 assert.equal((await rpc('select campaign_delivery_alerts($1)',[org])).length,0);
 assert.equal((await db.query("select * from integration_events where provider='manual_dispatch_confirmation'")).rows.length,1);
 const second=await rpc('select claim_whatsapp_dispatch()');assert.equal(second.available,true);assert.notEqual(second.number,first.number);
 assert.equal((await db.query<any>('select status from whatsapp_dispatches where id=$1',[first.dispatch_id])).rows[0].status,'accepted');
 }finally{await db.close()}
});
test('worker diferencia fila bloqueada de vazia e aciona erro apenas no aviso devido',()=>{
 const flow=JSON.parse(readFileSync('integrations/n8n/03-processar-campanhas.json','utf8'));
 const node=flow.nodes.find((n:any)=>n.name==='Explicar fila sem envio');assert.equal(flow.connections['Há mensagem?'].main[1][0].node,node.name);
 const run=(data:any)=>new Function('$input',node.parameters.jsCode)({first:()=>({json:data})});
 assert.throws(()=>run({blocked:true,notify:true,dispatch_id:'id',message:'Envio sem confirmação'}),/Envio sem confirmação/);
 assert.equal(run({blocked:true,notify:false})[0].json.status,'bloqueada');assert.equal(run({reason:'instance_busy'})[0].json.status,'aguardando');
});
