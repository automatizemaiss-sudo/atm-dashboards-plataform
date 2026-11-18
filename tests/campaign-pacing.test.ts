import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('campanhas: edição versionada, intervalo, fila por instância, pausa, exclusão e retomada',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid,bucket_id text,name text);alter table storage.objects enable row level security;create function storage.foldername(name text) returns text[] language sql as $$ select string_to_array(name,'/') $$;`);
 for(const f of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')&&!f.startsWith('022_')).sort())await db.exec(readFileSync('supabase/migrations/'+f,'utf8').replace('create extension if not exists pgcrypto;',''));
 const org=(await db.query<{id:string}>("select id from organizations where slug='futpb'")).rows[0].id;
 await db.exec("insert into auth.users values('11111111-1111-1111-1111-111111111111','owner@test.local');insert into organization_users select id,'11111111-1111-1111-1111-111111111111' from organizations;set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';");
 await db.query("insert into customers(organization_id,name,phone) values($1,'A','+5542999883017'),($1,'B','+5542999883018')",[org]);
 const instance=(await db.query<{id:string}>('update whatsapp_instances set enabled=true where organization_id=$1 returning id',[org])).rows[0].id;
 const segment=(await db.query<{id:string}>("insert into segments(organization_id,name) values($1,'Todos') returning id",[org])).rows[0].id;
 async function create(min:number,max:number){return(await db.query<{id:string}>("select create_campaign_with_delay($1,'Teste',$2,$3,'[{\"kind\":\"text\",\"body\":\"Olá\"}]',null,$4,$5) id",[org,segment,instance,min,max])).rows[0].id;}
 async function claim(){return(await db.query<{r:any}>('select claim_whatsapp_dispatch() r')).rows[0].r;}
 async function authorize(id:string){return(await db.query<{r:any}>('select authorize_whatsapp_dispatch($1) r',[id])).rows[0].r;}
 async function finish(id:string,provider:string){return(await db.query<{r:any}>('select finish_whatsapp_dispatch($1,$2::jsonb) r',[id,JSON.stringify({messageid:provider,status:'Sent'})])).rows[0].r;}
 await assert.rejects(create(30,15));const campaign=await create(15,30);
 const first=await claim();assert.equal(first.text,'Olá');assert.equal(first.available,true);assert.equal((await claim()).available,false);assert.equal((await authorize(first.dispatch_id)).allowed,true);
 const result=await finish(first.dispatch_id,'msg-1');assert.ok(result.delay_seconds>=15&&result.delay_seconds<=30);
 const second=await claim();assert.equal(second.available,true);assert.ok(second.wait_seconds>=14&&second.wait_seconds<=30);await assert.rejects(authorize(second.dispatch_id));
 // Upgrade with an accepted dispatch and a reservation already in the queue.
 await db.exec(readFileSync('supabase/migrations/022_campaign_message_history.sql','utf8'));
 const other=await create(60,120);
 await db.query('select update_campaign_delay($1,60,120)',[other]);
 await assert.rejects(db.query('select update_campaign_delay($1,30,15)',[other]));
 const history=async()=> (await db.query<{message_id:string;revision:number;is_current:boolean;body:string;sent:number;attempts:number}>('select * from campaign_message_history($1)',[campaign])).rows;
 const [original]=await history();
 const edit=(revision:number,body:string)=>db.query('select edit_campaign_message($1,$2,$3)',[original.message_id,revision,body]);
 await assert.rejects(edit(1,'Hoje é sábado'),/Pause a campanha/);
 await db.query("select control_campaign($1,'pause')",[campaign]);assert.equal((await authorize(second.dispatch_id)).allowed,false);
 await assert.rejects(edit(1,'\n\t'),/Preencha o texto/);
 await edit(1,'Hoje é sábado, {{nome}}');
 await edit(2,'Hoje é sábado, {{nome}}');
 await assert.rejects(edit(1,'Alteração desatualizada'),/A mensagem foi alterada/);
 assert.deepEqual((await history()).map(v=>[v.revision,v.is_current,v.body,v.sent,v.attempts]),[
  [2,true,'Hoje é sábado, {{nome}}',0,0],
  [1,false,'Olá',1,1],
 ]);
 await db.query("select control_campaign($1,'resume')",[campaign]);
 // Paused reservations are skipped, not accepted: the same recipient must still be sent after resume.
 const third=await claim();assert.equal(third.available,true);assert.equal(third.number,second.number);assert.match(third.text,/^Hoje é sábado, [AB]$/);
 await db.query("update whatsapp_dispatches set ready_at=clock_timestamp()-interval '1 second' where id=$1",[third.dispatch_id]);assert.equal((await authorize(third.dispatch_id)).allowed,true);await finish(third.dispatch_id,'msg-2');
 assert.equal((await db.query<{status:string}>('select status from campaigns where id=$1',[campaign])).rows[0].status,'completed');
 const results=await history();
 assert.deepEqual(results.map(v=>[v.revision,v.sent,v.attempts]),[[2,1,1],[1,1,1]]);
 for(const [version, id] of [[2,third.dispatch_id],[1,first.dispatch_id]]){
  const {rows}=await db.query<{dispatch_id:string}>('select dispatch_id from campaign_message_recipients($1,$2,0)',[original.message_id,version]);
  assert.deepEqual(rows,[{dispatch_id:id}]);
 }
 const fourth=await claim();assert.equal(fourth.available,true);await db.query('select set_campaign_archived($1,true)',[other]);assert.equal((await authorize(fourth.dispatch_id)).allowed,false);
 assert.equal((await claim()).available,false);await db.query('select set_campaign_archived($1,false)',[other]);assert.equal((await db.query<{status:string}>('select status from campaigns where id=$1',[other])).rows[0].status,'cancelled');await assert.rejects(db.query("select control_campaign($1,'resume')",[other]));
 assert.equal((await db.query<{n:number}>('select count(*) n from campaign_recipients where campaign_id=$1',[other])).rows[0].n,2);
 }finally{await db.close()}
});
test('worker aguarda antes de autorizar, permanece inativo e não repete HTTP',()=>{
 const flow=JSON.parse(readFileSync('integrations/n8n/03-processar-campanhas.json','utf8'));assert.equal(flow.active,false);
 const wait=flow.nodes.find((n:any)=>n.name==='Aguardar intervalo da campanha');assert.equal(wait.parameters.unit,'seconds');
 assert.equal(flow.connections['Há mensagem?'].main[0][0].node,wait.name);assert.equal(flow.connections[wait.name].main[0][0].node,'É texto?');
 assert.ok(!flow.nodes.find((n:any)=>n.name==='Enviar Uazapi — sem retry').retryOnFail);
});
